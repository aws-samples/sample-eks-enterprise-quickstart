# =====================================================================
# gpu-instance-catalog — per-GPU-instance-type facts shared by every GPU
# provisioning path (EKS managed/self-managed nodegroups in eks-gpu-nodegroup
# and Karpenter GPU NodePools in eks-karpenter), so the two can't drift:
#   - efa_layout: NIC layout (EFA-only NIC count, whether NIC0 carries EFA)
#   - nvidia_open_kmod_fixup_snippet / efa_userspace_snippet: node bootstrap
#     shell fragments (g7 open-kmod fixup; EFA userspace from the AMI's own
#     installer release, GPG-verified without gpg-agent)
# Pure locals — no providers, no resources.
# =====================================================================

variable "efa_installer_version" {
  type        = string
  default     = "1.48.0"
  description = "Fallback aws-efa-installer version for efa_userspace_snippet (used only when the AMI carries no /opt/amazon/efa_installed_packages record)."
}

# ===================================================================
# Per-instance-type EFA layout
#
# efa_only_count: number of EFA-only NICs on indices 1..N (primary NIC at
# index 0). p6-b300 is special: NIC 0 is ENA-only, NIC 1..16 carry EFA.
# Unknown instance types fall back to no EFA (efa_only_count=0,
# primary_efa=false) — the LT will then provision a plain ENA NIC and
# silently skip the EFA-only NICs.
# ===================================================================
locals {
  efa_layout_default = { efa_only_count = 0, primary_efa = false }
  efa_layout = {
    # Multi-NIC training accelerators
    "p5.48xlarge"      = { efa_only_count = 31, primary_efa = true }
    "p5e.48xlarge"     = { efa_only_count = 31, primary_efa = true } # H200; same 32-NIC layout as p5
    "p5en.48xlarge"    = { efa_only_count = 15, primary_efa = true }
    "p6-b200.48xlarge" = { efa_only_count = 7, primary_efa = true }
    "p6-b300.48xlarge" = { efa_only_count = 16, primary_efa = false } # NIC 0 = ENA only

    # G6e (NVIDIA L40S) — EFA enabled on 8xlarge+; smaller sizes have no EFA.
    # MaximumNetworkCards: 1 for 8/12/16xlarge, 2 for 24xlarge, 4 for 48xlarge.
    "g6e.8xlarge"  = { efa_only_count = 0, primary_efa = true }
    "g6e.12xlarge" = { efa_only_count = 0, primary_efa = true }
    "g6e.16xlarge" = { efa_only_count = 0, primary_efa = true }
    "g6e.24xlarge" = { efa_only_count = 1, primary_efa = true }
    "g6e.48xlarge" = { efa_only_count = 3, primary_efa = true }

    # G7e (NVIDIA RTX PRO 6000 Blackwell) — EFAv4, GPUDirect RDMA on multi-GPU sizes.
    # MaximumNetworkCards: 1 for 8/12xlarge, 2 for 24xlarge, 4 for 48xlarge.
    # 2/4xlarge sizes have no EFA support and intentionally absent.
    "g7e.8xlarge"  = { efa_only_count = 0, primary_efa = true }
    "g7e.12xlarge" = { efa_only_count = 0, primary_efa = true }
    "g7e.24xlarge" = { efa_only_count = 1, primary_efa = true }
    "g7e.48xlarge" = { efa_only_count = 3, primary_efa = true }

    # G7 (NVIDIA RTX PRO 4500 Blackwell) — EFA on 8xlarge+.
    # MaximumNetworkCards: 1 for 8/12/24xlarge, 2 for 48xlarge (per
    # DescribeInstanceTypes MaximumEfaInterfaces). 2/4xlarge have no EFA.
    "g7.8xlarge"  = { efa_only_count = 0, primary_efa = true }
    "g7.12xlarge" = { efa_only_count = 0, primary_efa = true }
    "g7.24xlarge" = { efa_only_count = 0, primary_efa = true }
    "g7.48xlarge" = { efa_only_count = 1, primary_efa = true }
  }
}

output "efa_layout" {
  description = "Map instance_type -> { efa_only_count, primary_efa }. Types not listed have no EFA (use efa_layout_default)."
  value       = local.efa_layout
}

output "efa_layout_default" {
  value = local.efa_layout_default
}

output "nvidia_open_kmod_fixup_snippet" {
  description = "Boothook fragment: g7 (10de:2c3a) open-kmod fixup; no-op on other GPUs."
  value       = file("${path.module}/templates/nvidia-open-kmod-fixup.sh")
}

output "efa_userspace_snippet" {
  description = "Boothook fragment: install the EFA userspace from the AMI's own aws-efa-installer release (fallback efa_installer_version), GPG-verified; never aborts bringup."
  value       = templatefile("${path.module}/templates/efa-userspace.sh.tpl", { efa_installer_version = var.efa_installer_version })
}
