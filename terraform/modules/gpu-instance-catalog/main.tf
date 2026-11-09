# =====================================================================
# gpu-instance-catalog — per-accelerator-instance-type facts (NVIDIA + Neuron)
# shared by every accelerator provisioning path (EKS managed/self-managed
# nodegroups in eks-gpu-nodegroup and Karpenter GPU NodePools in
# eks-karpenter), so the two can't drift:
#   - efa_layout: NIC layout (EFA-only NIC count, whether NIC0 carries EFA)
#   - vendor_by_instance_type / accelerator_profiles: accelerator vendor
#     (nvidia | neuron) per instance type and the per-vendor node contract
#     (workload-type label, taint, extended resources, AMI SSM variant)
#   - ami_arch_by_instance_type / nvidia_ami_arches /
#     neuron_types_without_x86_64: per-vendor AMI-architecture reduction over
#     caller-supplied EC2 supported_architectures (a pure function of its
#     inputs, so it is unit-testable with literal maps)
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

variable "instance_types" {
  type        = list(string)
  default     = []
  description = "Optional: instance types to classify into vendor_by_instance_type (eks-gpu-nodegroup passes its gpu_type list; eks-karpenter passes gpu_nodepools[].instance_type). Default [] keeps existing callers inert."
}

variable "supported_architectures_by_instance_type" {
  type        = map(list(string))
  default     = {}
  description = "Optional: instance_type -> EC2 supported_architectures (e.g. from data.aws_ec2_instance_type). Feeds ami_arch_by_instance_type / nvidia_ami_arches / neuron_types_without_x86_64; vendor is classified from the map KEYS with neuron_instance_type_regex (independent of var.instance_types). Default {} keeps existing callers inert."
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

    # AWS Trainium (Neuron). Same model as p5: primary NIC (card 0, dev 0)
    # carries EFA, one efa-only NIC on dev 0 of every other network card, which
    # reaches MaximumEfaInterfaces. Verified with `aws ec2
    # describe-instance-types` (read-only), 2026-11:
    #   trn2.48xlarge  — 16 network cards / MaximumEfaInterfaces 16 (offered in
    #                    e.g. us-east-2, ap-south-2; not in us-east-1)
    #   trn2.3xlarge   — 1 network card / 1 EFA (e.g. sa-east-1, ap-south-2)
    #   trn1n.32xlarge — 16 network cards / 16 EFA
    #   trn1.32xlarge  — 8 network cards / 8 EFA
    # Deliberately absent (fall back to efa_layout_default = no EFA):
    #   trn1.2xlarge, inf2.* (no EFA), inf1.* (only inf1.24xlarge has a single
    #   EFA v1 — best-effort, not a verified target).
    # trn2u.48xlarge is UNSUPPORTED (not a fallback): EC2 describes it (e.g.
    # ap-south-2: 16 network cards / 16 EFA) but publishes no NeuronInfo, so
    # eks-gpu-nodegroup cannot derive Neuron device/core counts and its Launch
    # Template precondition rejects it at plan. Add a row (and a device-count
    # source) only once EC2 reports NeuronInfo for it.
    "trn2.48xlarge"  = { efa_only_count = 15, primary_efa = true }
    "trn2.3xlarge"   = { efa_only_count = 0, primary_efa = true }
    "trn1n.32xlarge" = { efa_only_count = 15, primary_efa = true }
    "trn1.32xlarge"  = { efa_only_count = 7, primary_efa = true }
  }
}

output "efa_layout" {
  description = "Map instance_type -> { efa_only_count, primary_efa }. Types not listed have no EFA (use efa_layout_default)."
  value       = local.efa_layout
}

output "efa_layout_default" {
  value = local.efa_layout_default
}

# ===================================================================
# Accelerator vendor classification + per-vendor node contract
#
# Vendor is derived from the instance type NAME, not from
# data.aws_ec2_instance_type: callers read that data source with
# depends_on = [module.eks_addons], which defers the read to apply time on a
# fresh plan — anything keyed off it (for_each keys, counts, labels) would
# become "known after apply". A constant regex over a plan-time-known string
# keeps every vendor-dependent decision static. Callers SHOULD cross-check the
# name-based answer against the data source's gpus / neuron_devices in a
# precondition (eks-gpu-nodegroup does, on the Launch Template).
#
# Anything that doesn't match neuron_instance_type_regex is "nvidia" — the
# behaviour every caller had before Neuron support existed.
# ===================================================================
locals {
  # trn1 / trn1n / trn2 / trn2u / trn3* / inf1 / inf2 — incl. hyphenated
  # variants such as trn3s-es.48xlarge listed by the Neuron Helm chart.
  neuron_instance_type_regex = "^(trn|inf)[0-9]+[a-z0-9-]*\\."

  # NOTE: the nvidia row holds the literals in use since before Neuron
  # support; changing any of them changes every NVIDIA nodegroup (new LT
  # version / managed-NG rollout / CA tag churn).
  accelerator_profiles = {
    nvidia = {
      workload_type    = "gpu"
      taint            = { key = "nvidia.com/gpu", value = "true", effect = "NoSchedule" }
      device_resource  = "nvidia.com/gpu"
      core_resource    = null
      ami_ssm_variant  = "nvidia"
      supported_arches = tolist(["x86_64", "arm64"])
    }
    neuron = {
      workload_type    = "neuron"
      taint            = { key = "aws.amazon.com/neuron", value = "true", effect = "NoSchedule" }
      device_resource  = "aws.amazon.com/neuron"
      core_resource    = "aws.amazon.com/neuroncore"
      ami_ssm_variant  = "neuron"
      supported_arches = tolist(["x86_64"]) # AWS publishes no arm64 EKS Neuron AMI
    }
  }

  vendor_by_instance_type = {
    for t in distinct(var.instance_types) :
    t => can(regex(local.neuron_instance_type_regex, t)) ? "neuron" : "nvidia"
  }
}

# ===================================================================
# Per-vendor AMI architecture reduction
#
# EKS publishes one AL2023 AMI per (vendor x arch): NVIDIA has x86_64 + arm64,
# Neuron x86_64 only. A caller that resolves ONE NVIDIA AMI for many types
# needs the distinct NVIDIA arch set (must be <= 1) with Neuron types left
# OUT of it — otherwise an arm64-only NVIDIA type (g5g.*, p6e-gb200) next to
# an x86_64-only trn2 would look like a mixed-arch NVIDIA deploy. Kept here as
# a pure function so the vendor filter is tested with literal maps
# (tests/gpu_instance_catalog) — a mocked data source cannot give two
# for_each instances different architectures.
#
# The arm64 ternary is the exact pre-Neuron eks-gpu-nodegroup expression, so
# an NVIDIA-only caller gets the same arch value it always did.
# ===================================================================
locals {
  arch_input_vendor = {
    for t, _ in var.supported_architectures_by_instance_type :
    t => can(regex(local.neuron_instance_type_regex, t)) ? "neuron" : "nvidia"
  }

  ami_arch_by_instance_type = {
    for t, archs in var.supported_architectures_by_instance_type :
    t => contains(archs, "arm64") ? "arm64" : "x86_64"
  }

  nvidia_ami_arches = distinct([
    for t, a in local.ami_arch_by_instance_type : a
    if local.arch_input_vendor[t] == "nvidia"
  ])

  neuron_types_without_x86_64 = tolist([
    for t, archs in var.supported_architectures_by_instance_type : t
    if local.arch_input_vendor[t] == "neuron" && !contains(archs, "x86_64")
  ])
}

output "ami_arch_by_instance_type" {
  description = "Map instance_type -> \"arm64\" | \"x86_64\" (arm64 if the type supports it) for every key of var.supported_architectures_by_instance_type."
  value       = local.ami_arch_by_instance_type
}

output "nvidia_ami_arches" {
  description = "Distinct AMI arches of the NVIDIA (non-Neuron) keys of var.supported_architectures_by_instance_type, in key order. Neuron types never contribute. A single-AMI caller must require length <= 1."
  value       = local.nvidia_ami_arches
}

output "neuron_types_without_x86_64" {
  description = "Neuron keys of var.supported_architectures_by_instance_type that do not support x86_64 (AWS publishes no arm64 EKS Neuron AMI). Must be empty."
  value       = local.neuron_types_without_x86_64
}

output "neuron_instance_type_regex" {
  description = "RE2 regex: instance types matching it are AWS Neuron (Trainium/Inferentia); everything else is treated as NVIDIA."
  value       = local.neuron_instance_type_regex
}

output "accelerator_profiles" {
  description = "Map vendor (nvidia | neuron) -> { workload_type, taint { key, value, effect }, device_resource, core_resource, ami_ssm_variant, supported_arches }. The nvidia row holds the pre-Neuron literals verbatim."
  value       = local.accelerator_profiles
}

output "vendor_by_instance_type" {
  description = "Map instance_type -> \"nvidia\" | \"neuron\" for every entry of var.instance_types (empty when none were passed)."
  value       = local.vendor_by_instance_type
}

output "nvidia_open_kmod_fixup_snippet" {
  description = "Boothook fragment: g7 (10de:2c3a) open-kmod fixup; no-op on other GPUs."
  value       = file("${path.module}/templates/nvidia-open-kmod-fixup.sh")
}

output "efa_userspace_snippet" {
  description = "Boothook fragment: install the EFA userspace from the AMI's own aws-efa-installer release (fallback efa_installer_version), GPG-verified; never aborts bringup."
  value       = templatefile("${path.module}/templates/efa-userspace.sh.tpl", { efa_installer_version = var.efa_installer_version })
}
