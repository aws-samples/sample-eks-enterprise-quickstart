# =====================================================================
# eks-gpu-stack — K8s-side GPU components
# =====================================================================
# Two mutually-exclusive modes:
#   stack_mode=standard  (default)
#     - nvidia-device-plugin (helm)
#     - aws-efa-k8s-device-plugin (kubernetes_daemon_set)
#     - dcgm-exporter (helm)
#     - node-problem-detector (helm)
#     - gpu-health-check (kubernetes_daemon_set + RBAC)
#   stack_mode=operator
#     - nvidia/gpu-operator (helm; driver/toolkit/mofed disabled)
#     - aws-efa-k8s-device-plugin (still installed by us)
# =====================================================================

variable "stack_mode" {
  type        = string
  description = "Mutually exclusive GPU stack mode: 'standard' or 'operator'"
  default     = "standard"

  validation {
    condition     = contains(["standard", "operator"], var.stack_mode)
    error_message = "stack_mode must be 'standard' or 'operator'."
  }
}

variable "region" {
  type        = string
  description = "AWS region (used to derive EFA device-plugin ECR image for cn-* mirroring)"
}

variable "helm_replace_existing" {
  type    = bool
  default = false
}

# -------------------- shared (both modes) --------------------
variable "install_efa_device_plugin" {
  type    = bool
  default = true
}

variable "efa_device_plugin_version" {
  type    = string
  default = "v0.5.19"
}

variable "efa_device_plugin_image" {
  type        = string
  default     = ""
  description = "Override the full EFA device-plugin image (e.g. private mirror in CN regions)"
}

# -------------------- standard mode --------------------
variable "nvidia_device_plugin_version" {
  type    = string
  default = "v0.19.1"
}

variable "nvidia_device_plugin_repo" {
  type    = string
  default = "nvcr.io/nvidia/k8s-device-plugin"
}

variable "install_dcgm_exporter" {
  type    = bool
  default = true
}

variable "dcgm_exporter_version" {
  type    = string
  default = "4.8.2"
}

variable "install_node_problem_detector" {
  type    = bool
  default = true
}

variable "node_problem_detector_version" {
  type    = string
  default = "2.3.14"
}

variable "install_gpu_health_check" {
  type    = bool
  default = true
}

# -------------------- operator mode --------------------
variable "gpu_operator_version" {
  type        = string
  default     = "v25.3.4"
  description = "NVIDIA GPU Operator chart version. Strip leading 'v' to get the helm chart version."
}

variable "gpu_operator_namespace" {
  type    = string
  default = "gpu-operator"
}

variable "gpu_operator_driver_enabled" {
  type        = bool
  default     = false
  description = "Operator's containerized driver. EKS GPU AMI ships a tested driver; keep false."
}

variable "gpu_operator_toolkit_enabled" {
  type        = bool
  default     = false
  description = "Operator's containerized toolkit. EKS GPU AMI ships nvidia-container-toolkit; keep false."
}

variable "gpu_operator_mofed_enabled" {
  type        = bool
  default     = false
  description = "Operator's MOFED driver. AWS EFA plugin owns /dev/infiniband/uverbs*; keep false."
}

variable "gpu_operator_mig_strategy" {
  type        = string
  default     = "none"
  description = "MIG strategy: 'none' (no migManager), 'single', or 'mixed'. Only A100/H100 multi-tenancy use cases need this."

  validation {
    condition     = contains(["none", "single", "mixed"], var.gpu_operator_mig_strategy)
    error_message = "gpu_operator_mig_strategy must be one of: none, single, mixed."
  }
}
