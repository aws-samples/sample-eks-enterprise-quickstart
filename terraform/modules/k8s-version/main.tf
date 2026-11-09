# Resolves the Kubernetes and Karpenter versions for the whole stack.
#
# Read-only: data sources + locals, NO resources. Do not add depends_on to
# the module call or pass in other modules' outputs: the reads would be
# deferred to apply time, every version would become "known after apply"
# and an unchanged deployment would show a diff.

data "aws_eks_clusters" "this" {}

locals {
  cluster_exists = contains(data.aws_eks_clusters.this.names, var.cluster_name)
}

data "aws_eks_cluster" "this" {
  count = local.cluster_exists ? 1 : 0
  name  = var.cluster_name
}

locals {
  # Default for NEW clusters. When adding a minor, update default_k8s_version,
  # latest_karpenter_version (default for minors >= 1.36, named in every
  # runbook message; must meet karpenter_min[default_k8s_version]),
  # karpenter_min below and the Cluster Autoscaler map (modules/eks-addons).
  default_k8s_version      = "1.37"
  latest_karpenter_version = "1.15.1"

  running_k8s_version   = local.cluster_exists ? data.aws_eks_cluster.this[0].version : null
  effective_k8s_version = coalesce(var.k8s_version, local.running_k8s_version, local.default_k8s_version)

  running_minor   = local.cluster_exists ? tonumber(split(".", local.running_k8s_version)[1]) : null
  effective_minor = tonumber(split(".", local.effective_k8s_version)[1])
  default_minor   = tonumber(split(".", local.default_k8s_version)[1])

  # Explicit k8s_version against a running cluster: same minor or +1 only.
  version_step_ok = local.cluster_exists && var.k8s_version != null ? (
    local.effective_minor >= local.running_minor && local.effective_minor <= local.running_minor + 1
  ) : true

  # Karpenter default keyed on the RUNNING minor of an existing cluster, so
  # raising k8s_version never moves the default Karpenter in the same apply.
  karpenter_basis_minor       = local.cluster_exists ? local.running_minor : local.effective_minor
  karpenter_default           = local.karpenter_basis_minor <= 35 ? "1.12.1" : local.latest_karpenter_version
  effective_karpenter_version = coalesce(var.karpenter_version, local.karpenter_default)

  # Minimum Karpenter per Kubernetes minor
  # (https://karpenter.sh/docs/upgrading/compatibility/), encoded
  # major*1e6 + minor*1e3 + patch. Minors not listed are not checked.
  # karpenter_version may be a Helm tag constraint ("1.12", "~1.12", "v1.12.1"):
  # a missing patch counts as 0; anything else (">=1.12", "^1") is not
  # checked here (modules/eks-karpenter reads a range's lower bound for its
  # >= 1.13 IAM gate and turns that IAM on when it cannot parse one).
  karpenter_min = {
    "1.35" = 1009000
    "1.36" = 1013000
    "1.37" = 1015000
  }
  karpenter_parts    = try(regex("^[v=~\\s]*([0-9]+)\\.([0-9]+)(?:\\.([0-9]+))?", local.effective_karpenter_version), null)
  karpenter_num      = local.karpenter_parts == null ? null : tonumber(local.karpenter_parts[0]) * 1000000 + tonumber(local.karpenter_parts[1]) * 1000 + tonumber(coalesce(local.karpenter_parts[2], "0"))
  karpenter_required = lookup(local.karpenter_min, local.effective_k8s_version, null)
  karpenter_required_str = local.karpenter_required == null ? "" : format("%d.%d.%d",
    floor(local.karpenter_required / 1000000), floor(local.karpenter_required / 1000) % 1000, local.karpenter_required % 1000
  )
  karpenter_compatible = local.karpenter_required == null ? true : (
    local.karpenter_num == null ? true : local.karpenter_num >= local.karpenter_required
  )
  # A pre-existing deployment (running <= 1.35, the old default) with k8s_version
  # unchanged that is already outside the matrix (e.g. an old explicit
  # karpenter_version) only warns, so it keeps planning. Clusters on 1.36+ get
  # no exemption: Karpenter below their minimum (e.g. a downgrade) is an error.
  k8s_unchanged = local.cluster_exists ? (local.effective_k8s_version == local.running_k8s_version && local.running_minor <= 35) : false

  # Runbook text shared by the warning and the errors.
  next_minor      = coalesce(local.running_minor, local.effective_minor) + 1
  karpenter_first = var.install_karpenter && (local.karpenter_num == null ? true : local.karpenter_num < local.karpenter_min[local.default_k8s_version])
  upgrade_order   = "${local.karpenter_first ? "1) set karpenter_version = \"${local.latest_karpenter_version}\", apply the Karpenter ${local.latest_karpenter_version} CRDs and terraform apply; 2) " : ""}set k8s_version = \"1.${local.next_minor}\", terraform apply and wait until the managed nodegroups report v1.${local.next_minor}${var.install_karpenter ? " (Karpenter CPU nodes stay on 1.35, see README)" : ""}; repeat one minor per apply (terraform/README.md \"Kubernetes version and upgrades\")"
}

# Advisory warnings: output.warnings, surfaced by check blocks in the ROOT
# terraform/main.tf (tofu test cannot expect_failures a child module's
# checks).
locals {
  warnings = {
    k8s_version_behind_default = {
      ok      = var.k8s_version == null && local.cluster_exists ? local.running_minor >= local.default_minor : true
      message = "EKS cluster \"${var.cluster_name}\" runs Kubernetes ${coalesce(local.running_k8s_version, "-")}; new clusters now default to ${local.default_k8s_version}. Nothing changes: with k8s_version omitted the stack keeps the running version${var.install_karpenter ? " (and Karpenter ${local.effective_karpenter_version})" : ""}. Silence this warning by pinning k8s_version = \"${coalesce(local.running_k8s_version, "-")}\". To move to ${local.default_k8s_version}, ${local.upgrade_order}."
    }
    # Also covers an unchanged deployment running <= 1.35 that is already
    # outside the matrix (the output precondition lets it keep planning).
    karpenter_version_compatible = {
      ok      = !var.install_karpenter || local.karpenter_compatible
      message = "Karpenter ${local.effective_karpenter_version} is below the minimum ${local.karpenter_required_str} for Kubernetes ${local.effective_k8s_version} (https://karpenter.sh/docs/upgrading/compatibility/). Upgrade Karpenter (karpenter_version = \"${local.latest_karpenter_version}\" + its CRDs, own apply) before raising k8s_version."
    }
  }
}
