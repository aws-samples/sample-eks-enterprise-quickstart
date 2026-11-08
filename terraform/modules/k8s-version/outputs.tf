output "k8s_version" {
  description = "Effective Kubernetes minor: explicit k8s_version > running version of the existing cluster > default_k8s_version."
  value       = local.effective_k8s_version

  precondition {
    condition     = local.version_step_ok
    error_message = "k8s_version = \"${coalesce(var.k8s_version, "-")}\" is not allowed for EKS cluster \"${var.cluster_name}\", which runs ${coalesce(local.running_k8s_version, "-")}: EKS cannot downgrade and upgrades one minor at a time. Keep \"${coalesce(local.running_k8s_version, "-")}\" (or omit k8s_version)${local.next_minor <= local.default_minor ? ", or upgrade in order: ${local.upgrade_order}" : ""}."
  }
}

output "karpenter_version" {
  description = "Effective Karpenter chart version."
  value       = local.effective_karpenter_version

  precondition {
    condition     = !var.install_karpenter || local.karpenter_compatible || local.k8s_unchanged
    error_message = "Karpenter ${local.effective_karpenter_version} does not support Kubernetes ${local.effective_k8s_version} (needs >= ${local.karpenter_required_str}, https://karpenter.sh/docs/upgrading/compatibility/). ${local.cluster_exists ? "Upgrade Karpenter first, in its own apply with k8s_version = \"${local.running_k8s_version}\": set karpenter_version = \"${local.latest_karpenter_version}\", apply the Karpenter ${local.latest_karpenter_version} CRDs and terraform apply; then raise k8s_version" : "Omit karpenter_version (default for ${local.effective_k8s_version}: ${local.karpenter_default}) or set a supported version"} (terraform/README.md \"Kubernetes version and upgrades\")."
  }
}

output "running_k8s_version" {
  description = "Kubernetes minor of the existing cluster (null when it does not exist yet)."
  value       = local.running_k8s_version
}

output "warnings" {
  description = "Advisory checks ({ ok, message }), surfaced as warnings by the root check blocks."
  value       = local.warnings
}
