# =====================================================================
# Required: cluster + network identity
# =====================================================================

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. Must be unique in the AWS account."
}

variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
}

variable "vpc_id" {
  type        = string
  description = "Existing VPC ID. This stack does not create a VPC."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs (one per AZ; min 2, max 4). EKS control plane ENIs and worker nodes are placed here."
  validation {
    condition     = length(var.private_subnet_ids) >= 2 && length(var.private_subnet_ids) <= 4
    error_message = "private_subnet_ids must contain 2 to 4 subnet IDs."
  }
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs (used for internet-facing LBs only). Optional for fully-private clusters."
  default     = []
}

# =====================================================================
# Cluster control-plane behavior
# =====================================================================

variable "cluster_mode" {
  type        = string
  description = "API endpoint exposure: 'private' (recommended) or 'public'."
  default     = "private"
  validation {
    condition     = contains(["private", "public"], var.cluster_mode)
    error_message = "cluster_mode must be 'private' or 'public'."
  }
}

variable "public_access_cidrs" {
  type        = list(string)
  description = "CIDR ranges allowed to reach the public API endpoint. Only used when cluster_mode=public."
  default     = ["0.0.0.0/0"]
}

variable "k8s_version" {
  type        = string
  description = "Kubernetes minor version (e.g. '1.35'). EKS picks the latest patch."
  default     = "1.35"
}

variable "service_ipv4_cidr" {
  type        = string
  description = "Kubernetes Service CIDR. Must not overlap the VPC CIDR."
  default     = "172.20.0.0/16"
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN for envelope-encrypting Kubernetes secrets at rest. Empty disables encryption (not recommended)."
  default     = ""
}

variable "enable_deletion_protection" {
  type        = bool
  description = "Block accidental cluster deletion via terraform destroy."
  default     = true
}

variable "enable_irsa" {
  type        = bool
  description = "Create the legacy IAM OIDC provider for IRSA. Default false to match the bash flow's `withOIDC: false` and the rest of this stack's Pod Identity-only design (Karpenter / Cluster Autoscaler / ALB Controller / every CSI driver are all Pod Identity-driven). Enable only if external workloads need to verify cluster-issued JWTs (e.g. GitHub Actions OIDC federation). Private clusters that opt in must also unblock oidc.eks.<region>.amazonaws.com DNS — the eks VPC interface endpoint's private hosted zone shadows that subdomain and breaks the OIDC issuer fetch."
  default     = false
}

variable "extra_api_ingress_security_group_ids" {
  type        = list(string)
  description = "Extra security groups allowed inbound to the cluster API on tcp/443. Use for in-VPC bastions / CI runners that need to reach a private API endpoint. Only works for sources in the same VPC; cross-VPC sources must use extra_api_ingress_cidrs."
  default     = []
}

variable "extra_api_ingress_cidrs" {
  type        = list(string)
  description = "Extra CIDR blocks allowed inbound to the cluster API on tcp/443. Use for operators / bastions reaching the cluster via DX / VPN / VPC peering / TGW — anywhere SG references can't span. Empty by default."
  default     = []
}

variable "extra_cluster_admin_role_arns" {
  type        = list(string)
  description = "Extra IAM role ARNs to grant cluster-admin RBAC. Cluster creator (the IAM that runs `terraform apply`) is admin automatically; list here only OTHER principals that need admin (typical case: bastion role differs from apply-time role). NEVER list the apply-time identity — the access entry already exists and will conflict."
  default     = []
}

# =====================================================================
# VPC Endpoints
# =====================================================================

variable "vpc_endpoints_mode" {
  type        = string
  description = "'full' for all 13 Interface Endpoints + S3 Gateway (private cluster); 'minimal' for the 4 endpoints required for node bootstrap + S3 Gateway."
  default     = "full"
  validation {
    condition     = contains(["full", "minimal"], var.vpc_endpoints_mode)
    error_message = "vpc_endpoints_mode must be 'full' or 'minimal'."
  }
}

# =====================================================================
# Node management mode (cluster-wide)
# =====================================================================
# A single switch governs both system + GPU node groups. Mixing modes
# inside one cluster is intentionally not supported — pick one path and
# stick with it.

variable "node_management" {
  type        = string
  default     = "managed"
  description = <<-EOT
    Node group provisioning mode for BOTH system and GPU node groups
    (mixing modes inside one cluster is not supported by this stack).

      - "managed" (default): EKS Managed Node Groups (aws_eks_node_group).
        EKS owns the underlying ASG and self-heals — terminates and
        replaces unhealthy instances (instance IDs change), does
        AZ-rebalancing, and handles rolling updates. cluster-autoscaler
        discovery tags are applied to the EKS-owned ASGs via
        aws_autoscaling_group_tag.

      - "self_managed": Customer-owned ASGs (aws_autoscaling_group).
        ASG-driven self-healing is fully OFF (suspended_processes =
        [ReplaceUnhealthy, AZRebalance], no instance_refresh,
        lifecycle ignore_changes on desired_capacity). Instance IDs are
        stable until you explicitly retire them via:
            aws autoscaling terminate-instance-in-auto-scaling-group \
              --instance-id <id> --should-decrement-desired-capacity
        You take ownership of K8s version upgrades (cordon → drain →
        terminate → CA brings up replacement). cluster-autoscaler is
        required for elastic scaling — set var.install_cluster_autoscaler
        true (this stack installs ours) or deploy your own.

    See docs/SELF_MANAGED_NG.md for the full design + operational runbook.
  EOT

  validation {
    condition     = contains(["managed", "self_managed"], var.node_management)
    error_message = "node_management must be 'managed' or 'self_managed'."
  }
}

variable "asg_suspended_processes" {
  type        = list(string)
  default     = ["ReplaceUnhealthy", "AZRebalance"]
  description = <<-EOT
    ASG processes to suspend when node_management = "self_managed".
    Default disables ALL ASG-driven self-healing (see
    var.node_management for context). Ignored when node_management
    = "managed".

    Suspending these is rejected by validation:
      - Launch    (Cluster Autoscaler can't scale up)
      - Terminate (terminate-instance-in-auto-scaling-group --instance-id
                   ... can't retire instances)
  EOT

  validation {
    condition     = !contains(var.asg_suspended_processes, "Launch")
    error_message = "Suspending 'Launch' breaks scale-up. Remove from list."
  }

  validation {
    condition     = !contains(var.asg_suspended_processes, "Terminate")
    error_message = "Suspending 'Terminate' breaks targeted retirement. Remove from list."
  }
}

variable "extra_asg_tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags applied to every self-managed ASG (e.g. cost-allocation tags Owner / CostCenter / Environment). Ignored when node_management = \"managed\" — for managed NGs, attach tags via the Managed NG's API tags."
}

variable "install_cluster_autoscaler" {
  type        = bool
  default     = true
  description = <<-EOT
    Whether this stack installs cluster-autoscaler. Default true installs
    the upstream chart with Pod Identity (image + chart version
    auto-aligned to var.k8s_version unless overridden via
    var.cluster_autoscaler_version / var.cluster_autoscaler_chart_version).

    Set false when an external CA is deployed by your team (e.g.
    customer-supplied CA running against the same EKS cluster). The NG
    modules continue to inline the standard
    `k8s.io/cluster-autoscaler/<cluster>=owned` discovery tags on the
    ASGs regardless of this flag, so any compatible CA can pick them up.

    See the "Bring-your-own Cluster Autoscaler" section of
    docs/SELF_MANAGED_NG.md for the cutover SOP.
  EOT
}

# =====================================================================
# System nodegroup
# =====================================================================

variable "system_node_instance_type" {
  type        = string
  description = "System nodegroup instance type. Architecture (arm64/x86_64) is auto-detected from the EC2 API."
  default     = "m8g.xlarge"
}

variable "system_node_root_volume_size" {
  type        = number
  description = "System nodegroup root EBS volume size in GiB."
  default     = 50
}

variable "system_node_data_volume_size" {
  type        = number
  description = "System nodegroup data (containerd LVM) EBS volume size in GiB."
  default     = 100
}

variable "system_node_desired_capacity" {
  type        = number
  default     = 3
  description = "System nodegroup desired node count."
}

variable "system_node_min_size" {
  type        = number
  default     = 3
  description = "System nodegroup min size."
}

variable "system_node_max_size" {
  type        = number
  default     = 6
  description = "System nodegroup max size."
}

variable "system_node_label_key" {
  type    = string
  default = "app"
}

variable "system_node_label_value" {
  type    = string
  default = "eks-utils"
}

variable "ec2_key_name" {
  type        = string
  description = "Optional EC2 key pair name for SSH access. Empty = SSM-only."
  default     = ""
}

# =====================================================================
# Component versions
# =====================================================================

variable "cluster_autoscaler_version" {
  type        = string
  description = "Cluster Autoscaler image tag (e.g. \"v1.35.0\"). Empty (default) auto-selects from the K8s-version → CA-version matrix in modules/eks-addons/main.tf. Set explicitly only when you need to override the matrix or use a vendor build. Major.minor must match k8s_version."
  default     = ""
}

variable "cluster_autoscaler_chart_version" {
  type        = string
  description = "kubernetes/autoscaler helm chart version (e.g. \"9.48.0\"). Empty (default) auto-selects from the K8s-version → chart-version matrix in modules/eks-addons/main.tf. Bump together with cluster_autoscaler_version if you override either."
  default     = ""
}

variable "alb_controller_chart_version" {
  type        = string
  description = "AWS Load Balancer Controller helm chart version. Must be paired with alb_controller_app_version (chart 1.14.x ↔ app v2.13.x; chart 1.16.x ↔ app v2.14.x). NOTE: upstream v3.0+ is a major bump (CRD changes + chart version scheme realignment with the app); deferred — pin v2.14.x until the v3 migration path is exercised end-to-end."
  default     = "1.16.0"
}

variable "alb_controller_app_version" {
  type        = string
  description = "AWS Load Balancer Controller image tag. Sourced from upstream release. The IAM policy fetched at apply time follows this tag exactly. See alb_controller_chart_version for the v3 deferral note."
  default     = "v2.14.1"
}

variable "alb_controller_iam_policy_source" {
  type        = string
  description = "Where to source the AWS Load Balancer Controller IAM policy: 'http' fetches from the upstream release tag (matches alb_controller_app_version), 'file' uses the bundled terraform/assets/iam/alb-controller-iam-policy.json. Use 'file' for air-gapped environments or when GitHub.com is blocked."
  default     = "http"
  validation {
    condition     = contains(["http", "file"], var.alb_controller_iam_policy_source)
    error_message = "alb_controller_iam_policy_source must be 'http' or 'file'."
  }
}

variable "karpenter_version" {
  type        = string
  default     = "1.12.1"
  description = "Karpenter helm chart version (matches app version)."
}

# =====================================================================
# CSI drivers
# =====================================================================

variable "install_efs_csi" {
  type    = bool
  default = false
}

variable "install_fsx_csi" {
  type    = bool
  default = false
}

variable "install_s3_csi" {
  type    = bool
  default = false
}

variable "s3_csi_bucket_arns" {
  type        = list(string)
  description = "S3 bucket ARNs the S3 CSI Driver may access. Supports both standard S3 and S3 Express One Zone ARNs."
  default     = []
}

# =====================================================================
# Optional: Karpenter
# =====================================================================

variable "install_karpenter" {
  type    = bool
  default = false
}

variable "karpenter_ssh_public_key" {
  type        = string
  description = "Optional SSH public key injected into Karpenter-provisioned nodes via userData."
  default     = ""
}

variable "helm_replace_existing" {
  type        = bool
  description = "Set helm_release.replace=true on every managed helm release (cluster-autoscaler, ALB controller, karpenter, karpenter-pools, nvidia-device-plugin). Only enable in dev/test — when true, an interrupted apply that left a stale release behind is auto-recovered, but in production this would silently take over a manually-managed release and is a footgun."
  default     = false
}

# =====================================================================
# GPU nodegroups
# =====================================================================

variable "install_gpu_nodegroups" {
  type    = bool
  default = false
}

variable "gpu_ami_release_version" {
  type        = string
  description = "EKS NVIDIA AL2023 AMI release tag, e.g. 'v20260512'. Empty = follow SSM 'recommended' (rolls forward). Pin a specific release to keep the GPU runtime stack reproducible. See docs/AMI_VERSIONS.md for verified combinations. Ignored when gpu_custom_ami_id is set."
  default     = ""
}

variable "gpu_custom_ami_id" {
  type        = string
  description = "Override the SSM-resolved AWS EKS-NVIDIA AMI with a fully-specified AMI ID. Use for operator-baked AMIs derived from the EKS-NVIDIA base (corporate certs / monitoring agents / preloaded images / compliance). The custom AMI MUST derive from amazon-eks-node-al2023-*-nvidia-* and preserve the EKS bootstrap chain (nodeadm + kubelet + nvidia-driver + nvidia-container-toolkit jit-cdi). Building from plain AL2023 is unsupported. When set, gpu_ami_release_version is ignored."
  default     = ""

  validation {
    condition     = var.gpu_custom_ami_id == "" || can(regex("^ami-[0-9a-f]+$", var.gpu_custom_ami_id))
    error_message = "gpu_custom_ami_id must be empty or a valid AMI ID matching ^ami-[0-9a-f]+$."
  }
}

variable "gpu_nodegroups" {
  type = list(object({
    gpu_type                = string                   # e.g. p5.48xlarge
    purchase_option         = string                   # od | spot | odcr | cb
    suffix                  = optional(string, "")     # disambiguates multiple NGs of same (type, purchase)
    subnet_ids              = optional(list(string))   # default: all private subnets
    capacity_reservation_id = optional(string)         # required for odcr / cb
    placement_group         = optional(string, "none") # none | cluster
    desired_capacity        = optional(number, 0)
    min_size                = optional(number, 0)
    max_size                = optional(number, 8)
  }))
  description = "Explicit list of GPU nodegroups to create. Replaces the bash DEPLOY_GPU_OD/SPOT/ODCR/CB toggles with declarative entries."
  default     = []
}

variable "gpu_node_root_volume_size" {
  type    = number
  default = 50
}

variable "gpu_node_data_volume_size" {
  type    = number
  default = 100
}

variable "gpu_install_efa_userspace" {
  type        = bool
  description = "Install full EFA userspace (libfabric-aws + openmpi5-aws) on GPU nodes via userdata. The EKS GPU AMI ships only kernel-side EFA."
  default     = true
}

variable "gpu_efa_installer_version" {
  type        = string
  description = "aws-efa-installer tarball version pinned in node userdata, e.g. \"1.48.0\". Pinning makes node bringup reproducible. Empty = follow \"latest\" (rolls forward, breaks reproducibility)."
  default     = "1.48.0"
}

variable "gpu_enable_local_lvm" {
  type        = bool
  description = "Stripe Instance Store NVMe disks into a local LVM volume mounted at gpu_local_lvm_mount."
  default     = true
}

variable "gpu_local_lvm_mount" {
  type    = string
  default = "/data"
}

variable "gpu_local_lvm_fs" {
  type    = string
  default = "xfs"
}

# =====================================================================
# K8s GPU stack (eks-gpu-stack module)
# =====================================================================
# Two mutually exclusive modes:
#   standard — nvidia-device-plugin + EFA + dcgm-exporter +
#              node-problem-detector + gpu-health-check
#   operator — NVIDIA GPU Operator (driver/toolkit/mofed disabled to
#              coexist with EKS GPU AMI + AWS EFA plugin) + EFA
variable "install_gpu_stack" {
  type        = bool
  description = "Install K8s-side GPU components (device-plugin / EFA / monitoring / Operator). Independent of install_gpu_nodegroups so users can iterate either layer alone. Default false to mirror install_gpu_nodegroups — enabling the stack on a cluster without GPU nodes creates DaemonSets that idle at desired=0 and helm releases that hold no actual workloads, which surprises operators."
  default     = false
}

variable "gpu_stack_mode" {
  type        = string
  description = "Mutually exclusive K8s GPU stack mode: 'standard' or 'operator'."
  default     = "standard"

  validation {
    condition     = contains(["standard", "operator"], var.gpu_stack_mode)
    error_message = "gpu_stack_mode must be 'standard' or 'operator'."
  }
}

# --- Shared (both modes) ---
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
  description = "Full image override for the AWS EFA k8s device plugin (e.g. private mirror in cn-* regions). Empty falls back to the public ECR image map."
  default     = ""
}

# --- Standard mode ---
variable "nvidia_device_plugin_version" {
  type    = string
  default = "v0.19.1"
}

variable "nvidia_device_plugin_repo" {
  type        = string
  default     = "nvcr.io/nvidia/k8s-device-plugin"
  description = "Override for regions where nvcr.io is unreachable (cn-*)."
}

variable "install_dcgm_exporter" {
  type        = bool
  description = "Install dcgm-exporter for pod-level GPU metrics (standard mode only — Operator bundles its own)."
  default     = true
}

variable "dcgm_exporter_version" {
  type    = string
  default = "4.8.2"
}

variable "install_node_problem_detector" {
  type        = bool
  description = "Install node-problem-detector to surface GPU XID errors / kernel issues as NodeConditions (standard mode only)."
  default     = true
}

variable "node_problem_detector_version" {
  type    = string
  default = "2.3.14"
}

variable "install_gpu_health_check" {
  type        = bool
  description = "Install boot-time GPU health-check DaemonSet that taints node with gpu-unhealthy=true:NoSchedule on nvidia-smi failure (standard mode only)."
  default     = true
}

# --- Operator mode ---
# NOTE: upstream v26.x is the latest major (released 2026-03-20). Stay on
# v25.3.4 until the v26 upgrade path is verified end-to-end on B300 — v25.3.4
# was verified 2026-05-22 (8× B300 SXM6, EFA + nvidia.com/gpu + DCGM metrics).
variable "gpu_operator_version" {
  type    = string
  default = "v25.3.4"
}

variable "gpu_operator_namespace" {
  type    = string
  default = "gpu-operator"
}

variable "gpu_operator_driver_enabled" {
  type        = bool
  description = "Operator's containerized driver. Default false because the EKS GPU AMI ships a tested driver."
  default     = false
}

variable "gpu_operator_toolkit_enabled" {
  type        = bool
  description = "Operator's containerized nvidia-container-toolkit. Default false because the EKS GPU AMI ships it."
  default     = false
}

variable "gpu_operator_mofed_enabled" {
  type        = bool
  description = "Operator's MOFED driver. Default false because AWS EFA plugin owns /dev/infiniband/uverbs*."
  default     = false
}

variable "gpu_operator_mig_strategy" {
  type        = string
  description = "MIG strategy: 'none' (no migManager), 'single', or 'mixed'. Set to 'single' or 'mixed' on A100/H100 multi-tenancy."
  default     = "none"

  validation {
    condition     = contains(["none", "single", "mixed"], var.gpu_operator_mig_strategy)
    error_message = "gpu_operator_mig_strategy must be one of: none, single, mixed."
  }
}

# =====================================================================
# Tagging
# =====================================================================

variable "default_tags" {
  type    = map(string)
  default = {}
}
