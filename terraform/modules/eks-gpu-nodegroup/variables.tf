variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }
variable "cluster_ca" { type = string }
variable "cluster_security_group_id" { type = string }
variable "service_ipv4_cidr" { type = string }
variable "vpc_id" { type = string }
variable "region" { type = string }
variable "k8s_version" { type = string }

variable "gpu_ami_release_version" {
  type        = string
  description = <<EOT
EKS-optimized AL2023 NVIDIA AMI release tag, e.g. "v20260512". Empty = use
SSM 'recommended' (latest). Pin a specific version to keep the GPU runtime
stack reproducible: AMI ships with a specific containerd, nodeadm,
nvidia-driver, nvidia-container-toolkit, kernel module bundle, and a wrong
combination produces silent regressions (workload pod driver-injection failure
on v20260509-v20260512 with containerd 2.2.3 + toolkit 1.19; cgroupsPath
crash on the same window before nodeadm #2705 landed). Verified working
combinations should be recorded in docs/AMI_VERSIONS.md.

Ignored when gpu_custom_ami_id is set.
EOT
  default     = ""
}

variable "gpu_custom_ami_id" {
  type        = string
  description = <<EOT
Override the SSM-resolved AWS EKS-NVIDIA AMI with a fully-specified AMI ID.
Use this when the operator maintains a custom AMI baked from the EKS-NVIDIA
base — typical reasons: pre-installed corporate CA certificates, internal
monitoring agents, preloaded container images for faster cold start,
compliance audit trails. Empty (default) falls back to the SSM-resolved
AWS AMI selected by gpu_ami_release_version.

The custom AMI MUST derive from amazon-eks-node-al2023-*-nvidia-* and
preserve the EKS bootstrap chain (nodeadm + kubelet + nvidia-driver +
nvidia-container-toolkit jit-cdi config in /etc/containerd/config.toml).
Building from plain AL2023 is unsupported — see docs/AMI_VERSIONS.md for
the tightly-coupled-stack rationale.

When set, gpu_ami_release_version is ignored.
EOT
  default     = ""

  validation {
    condition     = var.gpu_custom_ami_id == "" || can(regex("^ami-[0-9a-f]+$", var.gpu_custom_ami_id))
    error_message = "gpu_custom_ami_id must be empty or a valid AMI ID matching ^ami-[0-9a-f]+$."
  }
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "gpu_nodegroups" {
  type = list(object({
    gpu_type                = string
    purchase_option         = string
    suffix                  = optional(string, "")
    subnet_ids              = optional(list(string))
    capacity_reservation_id = optional(string)
    placement_group         = optional(string, "none")
    desired_capacity        = optional(number, 0)
    min_size                = optional(number, 0)
    max_size                = optional(number, 8)
  }))
  default = []

  # Module is conditionally instantiated by root via `count = install_gpu_nodegroups ? 1 : 0`.
  # If the module exists we require at least one nodegroup — empty list is meaningless.
  validation {
    condition     = length(var.gpu_nodegroups) >= 1
    error_message = "gpu_nodegroups must contain at least one entry when install_gpu_nodegroups=true."
  }

  validation {
    condition = alltrue([
      for ng in var.gpu_nodegroups :
      contains(["od", "spot", "odcr", "cb"], ng.purchase_option)
    ])
    error_message = "Each gpu_nodegroups[].purchase_option must be one of: od, spot, odcr, cb."
  }

  validation {
    condition = alltrue([
      for ng in var.gpu_nodegroups :
      ng.purchase_option != "odcr" && ng.purchase_option != "cb" || (try(ng.capacity_reservation_id, "") != "")
    ])
    error_message = "purchase_option=odcr|cb requires capacity_reservation_id."
  }

  validation {
    condition = alltrue([
      for ng in var.gpu_nodegroups :
      contains(["none", "cluster"], ng.placement_group)
    ])
    error_message = "placement_group must be 'none' or 'cluster'."
  }
}

variable "root_volume_size" {
  type    = number
  default = 50
}

variable "data_volume_size" {
  type    = number
  default = 100
}

variable "install_efa_userspace" {
  type    = bool
  default = true
}

variable "efa_installer_version" {
  type        = string
  description = "aws-efa-installer tarball version pinned in node userdata, e.g. \"1.48.0\". The EKS GPU AMI ships only kernel-side EFA; userspace (libfabric-aws + openmpi5-aws) is fetched from https://efa-installer.amazonaws.com at first boot. Pinning a version makes node bringup reproducible across time. Empty = use \"latest\" (not recommended for production)."
  default     = "1.48.0"
}

variable "enable_local_lvm" {
  type    = bool
  default = true
}

variable "local_lvm_vg_name" {
  type    = string
  default = "vg_local"
}

variable "local_lvm_lv_name" {
  type    = string
  default = "lv_scratch"
}

variable "local_lvm_mount" {
  type    = string
  default = "/data"
}

variable "local_lvm_fs" {
  type    = string
  default = "xfs"
}

variable "local_lvm_stripe_kb" {
  type    = number
  default = 256
}

variable "ec2_key_name" {
  type    = string
  default = ""
}

# Note: helm/kubernetes resources for the K8s GPU stack
# (nvidia-device-plugin, EFA device plugin, dcgm-exporter, etc.) live in
# the eks-gpu-stack module. This module is now AWS-only (IAM/SG/LT/NG).
