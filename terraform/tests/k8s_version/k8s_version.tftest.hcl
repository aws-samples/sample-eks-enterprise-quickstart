# modules/k8s-version: explicit k8s_version > running version > 1.37, the
# Karpenter default keyed on the RUNNING minor, and the plan-time guards.

mock_provider "aws" {
  # Default: no cluster with this name yet.
  mock_data "aws_eks_clusters" {
    defaults = { names = ["other-cluster"] }
  }
  mock_data "aws_eks_cluster" {
    defaults = { version = "1.35" }
  }
}

variables {
  cluster_name      = "test-cluster"
  install_karpenter = true
}

run "new_cluster_defaults" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  assert {
    condition     = output.k8s_version == "1.37" && output.karpenter_version == "1.15.1" && output.running_k8s_version == null
    error_message = "new cluster: expected 1.37 / 1.15.1, got ${output.k8s_version} / ${output.karpenter_version}"
  }
  assert {
    condition     = alltrue([for w in output.warnings : w.ok])
    error_message = "a new cluster must not warn"
  }
}

run "new_cluster_pinned_135" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  variables {
    k8s_version = "1.35"
  }
  assert {
    condition     = output.k8s_version == "1.35" && output.karpenter_version == "1.12.1"
    error_message = "new 1.35 cluster: expected 1.35 / 1.12.1, got ${output.k8s_version} / ${output.karpenter_version}"
  }
}

run "new_cluster_old_karpenter_rejected" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  variables {
    karpenter_version = "1.12.1"
  }
  expect_failures = [output.karpenter_version]
}

# Zero diff: existing 1.35 cluster, nothing set -> 1.35 / 1.12.1 + advisory warning.
run "existing_135_omitted" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster", "other-cluster"] }
  }
  assert {
    condition     = output.k8s_version == "1.35" && output.karpenter_version == "1.12.1" && output.running_k8s_version == "1.35"
    error_message = "existing 1.35: expected 1.35 / 1.12.1, got ${output.k8s_version} / ${output.karpenter_version}"
  }
  assert {
    condition     = !output.warnings.k8s_version_behind_default.ok && output.warnings.karpenter_version_compatible.ok
    error_message = "expected only the behind-default warning"
  }
  assert {
    condition     = strcontains(output.warnings.k8s_version_behind_default.message, "1) set karpenter_version = \"1.15.1\"") && strcontains(output.warnings.k8s_version_behind_default.message, "2) set k8s_version = \"1.36\"")
    error_message = "the warning must spell out Karpenter first, then 1.36: ${output.warnings.k8s_version_behind_default.message}"
  }
}

# Zero diff, old defaults pinned: no warning.
run "existing_135_pinned" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  variables {
    k8s_version       = "1.35"
    karpenter_version = "1.12.1"
  }
  assert {
    condition     = output.k8s_version == "1.35" && output.karpenter_version == "1.12.1"
    error_message = "existing 1.35 pinned: expected 1.35 / 1.12.1"
  }
  assert {
    condition     = alltrue([for w in output.warnings : w.ok])
    error_message = "pinned old defaults must not warn"
  }
}

# Raising k8s_version does not move the default Karpenter, so 1.36 with the
# default 1.12.1 fails: Karpenter must be upgraded first (runbook step 1).
run "existing_135_to_136_karpenter_omitted" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  variables {
    k8s_version = "1.36"
  }
  expect_failures = [output.karpenter_version]
}

# Runbook step 1: Karpenter first, control plane unchanged.
run "existing_135_karpenter_first" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  variables {
    k8s_version       = "1.35"
    karpenter_version = "1.15.1"
  }
  assert {
    condition     = output.k8s_version == "1.35" && output.karpenter_version == "1.15.1"
    error_message = "expected 1.35 / 1.15.1"
  }
}

# Runbook step 2.
run "existing_135_to_136" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  variables {
    k8s_version       = "1.36"
    karpenter_version = "1.15.1"
  }
  assert {
    condition     = output.k8s_version == "1.36" && output.karpenter_version == "1.15.1"
    error_message = "expected 1.36 / 1.15.1"
  }
}

# Matrix boundary for 1.36: 1.13.0 is the minimum (accepted), 1.12.9 is not.
run "existing_135_to_136_karpenter_1130" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  variables {
    k8s_version       = "1.36"
    karpenter_version = "1.13.0"
  }
  assert {
    condition     = output.karpenter_version == "1.13.0" && output.warnings.karpenter_version_compatible.ok
    error_message = "Karpenter 1.13.0 must be accepted for 1.36"
  }
}

run "existing_135_to_136_karpenter_1129" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  variables {
    k8s_version       = "1.36"
    karpenter_version = "1.12.9"
  }
  expect_failures = [output.karpenter_version]
}

# Without Karpenter the Karpenter guard is off.
run "existing_135_to_136_no_karpenter" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  variables {
    k8s_version       = "1.36"
    install_karpenter = false
  }
  assert {
    condition     = output.k8s_version == "1.36"
    error_message = "expected 1.36"
  }
}

run "existing_135_skip_to_137_rejected" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  variables {
    k8s_version       = "1.37"
    karpenter_version = "1.15.1"
  }
  expect_failures = [output.k8s_version]
}

run "existing_136_downgrade_rejected" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  override_data {
    target = data.aws_eks_cluster.this
    values = { version = "1.36" }
  }
  variables {
    k8s_version       = "1.35"
    karpenter_version = "1.15.1"
  }
  expect_failures = [output.k8s_version]
}

# Upgraded to 1.36, versions omitted again: Karpenter default follows the
# running minor; still behind the 1.37 default -> warning.
run "existing_136_omitted" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  override_data {
    target = data.aws_eks_cluster.this
    values = { version = "1.36" }
  }
  assert {
    condition     = output.k8s_version == "1.36" && output.karpenter_version == "1.15.1" && !output.warnings.k8s_version_behind_default.ok
    error_message = "expected 1.36 / 1.15.1 + behind-default warning"
  }
}

run "existing_137_omitted_no_warning" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  override_data {
    target = data.aws_eks_cluster.this
    values = { version = "1.37" }
  }
  assert {
    condition     = output.k8s_version == "1.37" && output.karpenter_version == "1.15.1"
    error_message = "expected 1.37 / 1.15.1"
  }
  assert {
    condition     = alltrue([for w in output.warnings : w.ok])
    error_message = "a 1.37 cluster must not warn"
  }
}

# Explicit Karpenter below the matrix minimum while upgrading -> error.
run "explicit_karpenter_below_minimum_rejected" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  variables {
    k8s_version       = "1.36"
    karpenter_version = "1.12.1"
  }
  expect_failures = [output.karpenter_version]
}

# An unchanged deployment that is already outside the matrix keeps planning
# (warning only), so no new error for existing tfvars.
run "existing_135_old_karpenter_pin_warns_only" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  variables {
    k8s_version       = "1.35"
    karpenter_version = "1.8.0"
  }
  assert {
    condition     = output.karpenter_version == "1.8.0" && !output.warnings.karpenter_version_compatible.ok
    error_message = "explicit karpenter_version must pass through unchanged, with a warning"
  }
}

# Running 1.36: no unchanged-deployment exemption, so a Karpenter downgrade
# below the 1.36 minimum (1.13) fails, with k8s_version omitted or pinned.
run "existing_136_karpenter_downgrade_rejected" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  override_data {
    target = data.aws_eks_cluster.this
    values = { version = "1.36" }
  }
  variables {
    karpenter_version = "1.12.1"
  }
  expect_failures = [output.karpenter_version]
}

run "existing_136_pinned_karpenter_downgrade_rejected" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  override_data {
    target = data.aws_eks_cluster.this
    values = { version = "1.36" }
  }
  variables {
    k8s_version       = "1.36"
    karpenter_version = "1.12.1"
  }
  expect_failures = [output.karpenter_version]
}

# Runbook text: wait for the managed nodegroups, not every node (Karpenter CPU
# EC2NodeClasses stay on 1.35 AMIs).
run "upgrade_order_waits_for_managed_nodegroups" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  assert {
    condition     = strcontains(output.warnings.k8s_version_behind_default.message, "wait until the managed nodegroups report v1.36") && !strcontains(output.warnings.k8s_version_behind_default.message, "every node")
    error_message = "upgrade order must wait for the managed nodegroups, not every node"
  }
}

# Without Karpenter the runbook text names no Karpenter step or nodes.
run "existing_135_omitted_no_karpenter_text" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  variables {
    install_karpenter = false
  }
  assert {
    condition     = !output.warnings.k8s_version_behind_default.ok && !strcontains(output.warnings.k8s_version_behind_default.message, "Karpenter")
    error_message = "install_karpenter = false: the warning must not mention Karpenter: ${output.warnings.k8s_version_behind_default.message}"
  }
}

# Helm tag-constraint pins (valid on main): a missing patch counts as 0.
run "existing_135_karpenter_minor_pin_no_warning" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  variables {
    k8s_version       = "1.35"
    karpenter_version = "1.12"
  }
  assert {
    condition     = alltrue([for w in output.warnings : w.ok])
    error_message = "a \"1.12\" pin on 1.35 must not warn"
  }
}

run "existing_136_karpenter_tilde_pin_accepted" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  override_data {
    target = data.aws_eks_cluster.this
    values = { version = "1.36" }
  }
  variables {
    karpenter_version = "~1.13"
  }
  assert {
    condition     = output.warnings.karpenter_version_compatible.ok
    error_message = "a \"~1.13\" pin on 1.36 must be accepted"
  }
}

# Still checked when the minor is too old ("1.12" on 1.36).
run "existing_136_karpenter_minor_pin_below_minimum_rejected" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  override_data {
    target = data.aws_eks_clusters.this
    values = { names = ["test-cluster"] }
  }
  override_data {
    target = data.aws_eks_cluster.this
    values = { version = "1.36" }
  }
  variables {
    karpenter_version = "1.12"
  }
  expect_failures = [output.karpenter_version]
}

# Unparseable constraints (">=", "^") are not checked rather than rejected.
run "new_cluster_karpenter_range_not_checked" {
  command = plan
  module {
    source = "../../modules/k8s-version"
  }
  variables {
    karpenter_version = ">=1.15.0"
  }
  assert {
    condition     = output.karpenter_version == ">=1.15.0" && output.warnings.karpenter_version_compatible.ok
    error_message = "an unparseable constraint must pass the matrix check"
  }
}
