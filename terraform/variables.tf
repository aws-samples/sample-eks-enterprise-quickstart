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
  description = "Kubernetes minor version (e.g. '1.37'); EKS picks the latest patch. null (default) = keep the running version of an existing cluster with this name, or 1.37 for a new cluster. An explicit value may only stay on or go one minor above the running version. See README \"Kubernetes version and upgrades\"."
  default     = null
  validation {
    condition     = var.k8s_version == null || can(regex("^1\\.[0-9]+$", var.k8s_version))
    error_message = "k8s_version must be null or a Kubernetes minor such as \"1.37\" (no patch number)."
  }
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
  description = "Where to source the AWS Load Balancer Controller IAM policy: 'http' fetches from the upstream release tag (matches alb_controller_app_version), 'file' uses the bundled terraform/assets/iam/alb-controller/<alb_controller_app_version>/ copy. Either way the partition-specific variant (iam_policy.json / _cn / _us-gov / _iso / _isob) is picked from the AWS partition. Use 'file' for air-gapped environments or when GitHub.com is blocked (e.g. China regions); bundled versions: v2.14.1."
  default     = "http"
  validation {
    condition     = contains(["http", "file"], var.alb_controller_iam_policy_source)
    error_message = "alb_controller_iam_policy_source must be 'http' or 'file'."
  }
}

variable "karpenter_version" {
  type        = string
  default     = null
  description = "Karpenter helm chart version (matches app version). null (default) = 1.12.1 when the cluster runs (or, for a new cluster, is created on) Kubernetes <= 1.35, else 1.15.1. For an existing cluster the default follows the RUNNING minor, so raising k8s_version never moves it; upgrading Karpenter on an existing cluster also needs its new CRDs (README \"Kubernetes version and upgrades\")."
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

variable "pod_identity_propagation_wait" {
  type        = string
  description = <<-EOT
    How long to wait after creating (or replacing) EKS Pod Identity
    associations before deploying the pods that use them — cluster-autoscaler,
    ALB controller, EBS/EFS/FSx/S3 CSI controllers, Karpenter. Associations are
    eventually consistent ("several seconds" per the EKS API docs): a pod
    admitted before propagation never gets the AWS_CONTAINER_* env injected,
    falls back to the node role and fails with AccessDenied (issue #2;
    cluster-autoscaler then CrashLoops until its pods are recreated). The wait
    only runs when an association is created or replaced, not on every apply.
    Duration string for time_sleep, e.g. "30s", "1m"; "0s" disables it.
  EOT
  default     = "30s"

  validation {
    condition     = can(regex("^[0-9]+(s|m)$", var.pod_identity_propagation_wait))
    error_message = "pod_identity_propagation_wait must be a duration like \"30s\" or \"1m\" (\"0s\" disables the wait)."
  }
}

variable "helm_replace_existing" {
  type        = bool
  description = "Set helm_release.replace=true (helm install --replace) on every helm_release managed by this stack (cluster-autoscaler, aws-load-balancer-controller, karpenter, karpenter-pools, nvidia-device-plugin, dcgm-exporter, node-problem-detector, gpu-operator, neuron-helm-chart, neuron-monitor-servicemonitor). Only enable in dev/test — when true, an interrupted apply that left a failed / uninstalled release of the same name behind is auto-recovered. It does NOT adopt a deployed (e.g. manually installed) release: Helm still fails with \"cannot re-use a name that is still in use\"; use `terraform import` on the helm_release or `helm uninstall` it first."
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
  description = "EKS NVIDIA AL2023 AMI release tag, e.g. 'v20260512'. Empty = follow SSM 'recommended' (rolls forward). Pin a specific release to keep the GPU runtime stack reproducible. See docs/AMI_VERSIONS.md for verified combinations. Ignored for NVIDIA nodegroups/pools when gpu_custom_ami_id is set; still inherited by trn*/inf* nodegroups and Neuron Karpenter GPU NodePools whenever neuron_ami_release_version is null (and neuron_custom_ami_id / karpenter_neuron_ami_selector are unset and — for Neuron Karpenter pools only — karpenter_gpu_ami_selector is not an al2023@ alias, which takes precedence) — set neuron_ami_release_version (\"\" = latest, or a tag) to decouple. Applies to NVIDIA nodegroups and NVIDIA Karpenter GPU NodePools; trn*/inf* nodegroups and Neuron Karpenter GPU NodePools use neuron_ami_release_version (which inherits this value when null) / neuron_custom_ami_id."
  default     = ""
}

variable "gpu_custom_ami_id" {
  type        = string
  description = "Override the SSM-resolved AWS EKS-NVIDIA AMI with a fully-specified AMI ID. Use for operator-baked AMIs derived from the EKS-NVIDIA base (corporate certs / monitoring agents / preloaded images / compliance). The custom AMI MUST derive from amazon-eks-node-al2023-*-nvidia-* and preserve the EKS bootstrap chain (nodeadm + kubelet + nvidia-driver + nvidia-container-toolkit jit-cdi). Building from plain AL2023 is unsupported. When set, gpu_ami_release_version is ignored for NVIDIA nodegroups/pools only (Neuron ones still inherit it via neuron_ami_release_version = null); gpu_custom_ami_id itself never applies to Neuron. Applies to NVIDIA nodegroups and NVIDIA Karpenter GPU NodePools; trn*/inf* nodegroups and Neuron Karpenter GPU NodePools use neuron_ami_release_version / neuron_custom_ami_id."
  default     = ""

  validation {
    condition     = var.gpu_custom_ami_id == "" || can(regex("^ami-[0-9a-f]+$", var.gpu_custom_ami_id))
    error_message = "gpu_custom_ami_id must be empty or a valid AMI ID matching ^ami-[0-9a-f]+$."
  }
}

# AWS Neuron (Trainium / Inferentia) AMI — only used by gpu_nodegroups
# entries whose gpu_type is trn*/inf* and by karpenter_gpu_nodepools entries
# whose instance_type is trn*/inf* (vendor auto-detected by name).
variable "neuron_ami_release_version" {
  type        = string
  default     = null
  nullable    = true
  description = "EKS AL2023 Neuron AMI release tag (vYYYYMMDD) for trn*/inf* nodegroups and Neuron Karpenter GPU NodePools. null (default) = inherit gpu_ami_release_version (NVIDIA and Neuron AMIs share release tags; for Neuron Karpenter pools a karpenter_gpu_ami_selector al2023@ alias takes precedence over the inherited tag — see karpenter_neuron_ami_selector); \"\" = SSM recommended; ignored when neuron_custom_ami_id is set. x86_64 only."

  validation {
    condition     = var.neuron_ami_release_version == null || can(regex("^(v[0-9]{8})?$", var.neuron_ami_release_version))
    error_message = "neuron_ami_release_version must be null, \"\" (recommended) or a release tag like \"v20261031\"."
  }
}

variable "neuron_custom_ami_id" {
  type        = string
  default     = ""
  description = "Override the SSM-resolved EKS AL2023 Neuron AMI with a fully-specified AMI ID. MUST derive from amazon-eks-node-al2023-x86_64-neuron-* (aws-neuronx-dkms + EFA minimal + nodeadm). Applies to trn*/inf* nodegroups and Neuron Karpenter GPU NodePools only. When set, neuron_ami_release_version is ignored."

  validation {
    condition     = var.neuron_custom_ami_id == "" || can(regex("^ami-[0-9a-f]+$", var.neuron_custom_ami_id))
    error_message = "neuron_custom_ami_id must be empty or a valid AMI ID matching ^ami-[0-9a-f]+$."
  }

  # Cross-module guard (the eks-gpu-nodegroup and eks-karpenter preconditions
  # each only see their own NVIDIA+Neuron mix): the same ami- id must not
  # reach an NVIDIA consumer (NVIDIA nodegroup, or NVIDIA Karpenter pool via
  # karpenter_gpu_ami_selector -> gpu_custom_ami_id) AND a Neuron consumer
  # (Neuron nodegroup, or Neuron pool via karpenter_neuron_ami_selector ->
  # neuron_custom_ami_id). Vendor = the catalog's name rule
  # (modules/gpu-instance-catalog neuron_instance_type_regex). Plan-time,
  # variables only; neuron_custom_ami_id is new, so no existing config trips it.
  validation {
    condition = (
      var.neuron_custom_ami_id == "" || var.neuron_custom_ami_id != var.gpu_custom_ami_id || !(
        (
          (var.install_gpu_nodegroups && anytrue([for ng in var.gpu_nodegroups : !can(regex("^(trn|inf)[0-9]+[a-z0-9-]*\\.", ng.gpu_type))])) ||
          (var.install_karpenter && var.karpenter_gpu_ami_selector == "" && anytrue([for p in var.karpenter_gpu_nodepools : !can(regex("^(trn|inf)[0-9]+[a-z0-9-]*\\.", p.instance_type))]))
          ) && (
          (var.install_gpu_nodegroups && anytrue([for ng in var.gpu_nodegroups : can(regex("^(trn|inf)[0-9]+[a-z0-9-]*\\.", ng.gpu_type))])) ||
          (var.install_karpenter && var.karpenter_neuron_ami_selector == "" && anytrue([for p in var.karpenter_gpu_nodepools : can(regex("^(trn|inf)[0-9]+[a-z0-9-]*\\.", p.instance_type))]))
        )
      )
    )
    error_message = "neuron_custom_ami_id equals gpu_custom_ami_id while both NVIDIA and Neuron (trn*/inf*) consumers exist across gpu_nodegroups / karpenter_gpu_nodepools — one of them would boot the wrong AMI (a Neuron node on an NVIDIA image joins with aws.amazon.com/neuron = 0). Point neuron_custom_ami_id at an amazon-eks-node-al2023-x86_64-neuron-* derived AMI (or clear it), or fix gpu_custom_ami_id."
  }
}

variable "gpu_nodegroups" {
  type = list(object({
    gpu_type                = string                   # e.g. p5.48xlarge (NVIDIA) or trn2.48xlarge (Neuron)
    purchase_option         = string                   # od | spot | odcr | cb
    suffix                  = optional(string, "")     # disambiguates multiple NGs of same (type, purchase)
    subnet_ids              = optional(list(string))   # default: all private subnets
    capacity_reservation_id = optional(string)         # required for odcr / cb
    placement_group         = optional(string, "none") # none | cluster
    desired_capacity        = optional(number, 0)
    min_size                = optional(number, 0)
    max_size                = optional(number, 8)
    containerd_storage      = optional(string) # ebs | instance_store; null = gpu_containerd_storage
  }))
  description = "Explicit list of accelerator nodegroups to create. Replaces the bash DEPLOY_GPU_OD/SPOT/ODCR/CB toggles with declarative entries. gpu_type accepts NVIDIA (p*/g*) or AWS Neuron (trn*/inf*) instance types; the vendor is detected from the name and selects the AMI (NVIDIA vs Neuron), workload-type label (gpu vs neuron) and taint (nvidia.com/gpu vs aws.amazon.com/neuron). NVIDIA and Neuron entries may be mixed."
  default     = []
}

variable "gpu_containerd_storage" {
  type        = string
  description = <<-EOT
    Default backing store for /var/lib/containerd on GPU nodes; override per
    nodegroup with gpu_nodegroups[].containerd_storage.
      "ebs"            (default) — a dedicated gp3 data volume
                       (gpu_node_data_volume_size), LVM, containerd migrated by
                       the node boothook. Survives stop/start.
      "instance_store" — the EKS AMI's native nodeadm localStorage RAID0 over
                       ALL Instance Store NVMe disks; /var/lib/containerd,
                       /var/lib/kubelet (so emptyDir) and /var/log/pods move
                       onto it. No data EBS volume is attached. Ephemeral: the
                       content is lost on stop/start or replacement (images
                       re-pull). Requires an instance type with Instance Store
                       and is mutually exclusive with gpu_enable_local_lvm
                       (RAID0 takes every NVMe disk) — use emptyDir or
                       hostPath under /mnt/k8s-disks/0/ for scratch instead.
  EOT
  default     = "ebs"

  validation {
    condition     = contains(["ebs", "instance_store"], var.gpu_containerd_storage)
    error_message = "gpu_containerd_storage must be \"ebs\" or \"instance_store\"."
  }
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
  description = "FALLBACK aws-efa-installer version for GPU node userdata, e.g. \"1.48.0\". Node userdata installs the EFA userspace from the SAME installer release the AMI's EFA kmod came from (read from /opt/amazon/efa_installed_packages), so kmod/rdma-core/libfabric never drift; this value is used only when the AMI carries no such record (e.g. a custom AMI). Empty = \"latest\" (rolls forward, breaks reproducibility)."
  default     = "1.48.0"

  validation {
    condition     = can(regex("^(latest|[0-9]+\\.[0-9]+\\.[0-9]+)?$", var.gpu_efa_installer_version))
    error_message = "gpu_efa_installer_version must be empty, \"latest\", or an X.Y.Z version such as \"1.48.0\"."
  }
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
#   operator — NVIDIA GPU Operator (driver/toolkit/RDMA disabled to
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

# --- Shared (both modes; also shared by eks-neuron-stack) ---
variable "install_efa_device_plugin" {
  type        = bool
  description = "Install the AWS EFA k8s device plugin DaemonSet (vpc.amazonaws.com/efa) — shared by eks-gpu-stack (NVIDIA nodes) and eks-neuron-stack (Neuron nodes; separate DaemonSet)."
  default     = true
}

variable "efa_device_plugin_version" {
  type        = string
  description = "AWS EFA k8s device plugin image tag — shared by eks-gpu-stack and eks-neuron-stack."
  default     = "v0.5.19"
}

variable "efa_device_plugin_image" {
  type        = string
  description = "Full image override for the AWS EFA k8s device plugin (e.g. private mirror in cn-* / isolated regions). Empty falls back to the per-region EKS add-on ECR registry (<account>.dkr.ecr.<region>.<dns-suffix>/eks/aws-efa-k8s-device-plugin:<efa_device_plugin_version>, account map in modules/eks-addon-ecr-registry); regions missing from that map must set this. Shared by eks-gpu-stack and eks-neuron-stack."
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

# DEPRECATED (#13): this used to set a top-level `mofedDriver.enabled` Helm
# value that does not exist in the NVIDIA GPU Operator chart, so it never had
# any effect. Kept only so existing tfvars that set it to false keep working;
# setting it to true fails fast instead of silently doing nothing.
variable "gpu_operator_mofed_enabled" {
  type        = bool
  description = "DEPRECATED — has no effect and is no longer passed to the GPU stack. The GPU Operator chart has no `mofedDriver` key; its RDMA switch (driver.rdma, the nvidia-peermem sidecar of the Operator's driver DaemonSet) stays off because the EKS GPU AMI ships the driver and AWS EFA (efa-nv-peermem + aws-efa-k8s-device-plugin) owns GPUDirect RDMA and /dev/infiniband/uverbs*. Must be false; remove it from your tfvars."
  default     = false

  validation {
    condition     = var.gpu_operator_mofed_enabled == false
    error_message = "gpu_operator_mofed_enabled is deprecated and has no effect: the GPU Operator chart has no mofedDriver key, and on EKS GPU AMIs GPUDirect RDMA over EFA is provided by the AMI's efa-nv-peermem + aws-efa-k8s-device-plugin. Remove the setting (see issue #13)."
  }
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
# Neuron K8s stack (eks-neuron-stack module)
# =====================================================================
# AWS Neuron device plugin (+ optional scheduler extension) and a second
# EFA device-plugin DaemonSet for workload-type=neuron nodes. Independent
# of install_gpu_stack / gpu_stack_mode — NOT a third mode; both stacks can
# be installed side by side.
variable "install_neuron_stack" {
  type        = bool
  description = "Install K8s-side AWS Neuron components (neuron-helm-chart device plugin advertising aws.amazon.com/neuron + aws.amazon.com/neuroncore, and an EFA device-plugin DaemonSet on Neuron nodes). Independent of install_gpu_stack / gpu_stack_mode. Also reuses install_efa_device_plugin, efa_device_plugin_version and efa_device_plugin_image. Note: the chart's device plugin keeps its upstream cluster-wide RBAC (nodes/proxy get/list, pods update/patch, nodes/status patch) and a read-write host /run mount — see terraform/README.md \"Privileges (device plugin)\"."
  default     = false
}

variable "neuron_helm_chart_repository" {
  type        = string
  description = "Helm repository for neuron-helm-chart. Override with a private OCI mirror for cn-* / isolated / air-gapped regions (mirror the images too: neuron_device_plugin_image_repository, and with install_neuron_scheduler also neuron_scheduler_image_repository + neuron_kube_scheduler_image_repository)."
  default     = "oci://public.ecr.aws/neuron"
}

variable "neuron_helm_chart_version" {
  type        = string
  description = "neuron-helm-chart version (X.Y.Z). Pins the Neuron device-plugin / scheduler images and the Neuron instance-type list the device plugin's node affinity covers."
  default     = "1.11.2"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.neuron_helm_chart_version))
    error_message = "neuron_helm_chart_version must be an X.Y.Z chart version such as \"1.11.2\"."
  }
}

variable "neuron_device_plugin_image_repository" {
  type        = string
  description = "Override the Neuron device-plugin image repository (\"\" = chart default public.ecr.aws/neuron/neuron-device-plugin)."
  default     = ""
}

variable "neuron_device_plugin_image_tag" {
  type        = string
  description = "Override the Neuron device-plugin image tag (\"\" = chart default)."
  default     = ""
}

variable "install_neuron_scheduler" {
  type        = bool
  description = "Install the Neuron scheduler extension + a second kube-scheduler \"my-scheduler\". Pods must set schedulerName: my-scheduler. Only needed for partial-node multi-device requests that must land on contiguous Neuron devices; whole-node jobs don't need it. Exposure: adds ClusterIP Service kube-system/k8s-neuron-scheduler on TCP 12345 (pod network only; no hostNetwork / NodePort) serving plain HTTP with NO authentication; my-scheduler calls it for filter AND bind, and the extender binds pods with its own cluster-wide pods/binding + patch pods / nodes/status RBAC, so any client that can reach its pod IP can bind pending pods and rewrite the Neuron device annotations. Restrict ingress to the my-scheduler pods with a NetworkPolicy where the CNI enforces it (example in terraform/README.md)."
  default     = false
}

variable "neuron_kube_scheduler_image_tag" {
  type        = string
  description = "eks-distro kube-scheduler image tag for \"my-scheduler\" (e.g. \"v1.35.9-eks-1-35-16\"). REQUIRED when install_neuron_stack = true and install_neuron_scheduler = true: the chart default (v1.31.x in chart 1.11.2) is outside the kube-scheduler/kube-apiserver version skew of current EKS clusters."
  default     = ""

  validation {
    condition     = var.neuron_kube_scheduler_image_tag == "" || can(regex("^v[0-9]", var.neuron_kube_scheduler_image_tag))
    error_message = "neuron_kube_scheduler_image_tag must be empty or an image tag starting with \"v<digit>\"."
  }

  # Cross-variable validation (Terraform >= 1.9, see versions.tf). The tag
  # can't be derived from k8s_version (eks-distro build suffix), so require it.
  validation {
    condition     = !(var.install_neuron_stack && var.install_neuron_scheduler) || var.neuron_kube_scheduler_image_tag != ""
    error_message = "neuron_kube_scheduler_image_tag is required when install_neuron_scheduler = true: the chart default (v1.31.x in neuron-helm-chart 1.11.2) is outside the kube-scheduler/kube-apiserver version skew. Pick the eks-distro tag matching k8s_version from gallery.ecr.aws/eks-distro/kubernetes/kube-scheduler (e.g. \"v1.35.9-eks-1-35-16\")."
  }
}

# Scheduler image mirrors (cn-* / isolated / air-gapped regions); only used
# when install_neuron_scheduler = true. "" = chart default.
variable "neuron_scheduler_image_repository" {
  type        = string
  description = "Override the Neuron scheduler-extension image repository (\"\" = chart default public.ecr.aws/neuron/neuron-scheduler)."
  default     = ""
}

variable "neuron_scheduler_image_tag" {
  type        = string
  description = "Override the Neuron scheduler-extension image tag (\"\" = chart default)."
  default     = ""
}

variable "neuron_kube_scheduler_image_repository" {
  type        = string
  description = "Override the \"my-scheduler\" kube-scheduler image repository (\"\" = chart default public.ecr.aws/eks-distro/kubernetes/kube-scheduler)."
  default     = ""
}

# Neuron metrics (neuron-monitor) — opt-in, parity with dcgm-exporter: no
# metrics backend; ServiceMonitor + pod attribution off by default.
variable "install_neuron_monitor" {
  type        = bool
  description = "Install the neuron-monitor Prometheus exporter DaemonSet (kube-system/neuron-monitor) on workload-type=neuron nodes (inf1 excluded) plus a ClusterIP Service kube-system/neuron-monitor:8000. Exposure: pod-IP TCP 8000, plain HTTP, read-only /metrics, NO authentication, ClusterIP Service only — no hostNetwork / hostPort / NodePort / LoadBalancer / Ingress. The container runs privileged (neuron-monitor must read every /dev/neuron* device and the driver sysfs counters regardless of device-plugin allocation; same as the AWS manifests) and mounts host /opt/aws read-only at /opt-aws so the host LNC config (neuron/logical_nc_config) is honoured. No EFA metrics; not supported with the Neuron DRA driver. The Neuron Observer (chart observer.*, hostNetwork + unauthenticated API with fault injection on :7001) is intentionally NOT offered — see terraform/README.md. Requires install_neuron_stack = true."
  default     = false

  validation {
    condition     = !var.install_neuron_monitor || var.install_neuron_stack
    error_message = "install_neuron_monitor requires install_neuron_stack = true."
  }
}

variable "neuron_monitor_image" {
  type        = string
  description = "neuron-monitor image (amd64 only). Mirror it for cn-* / isolated / air-gapped regions."
  default     = "public.ecr.aws/neuron/neuron-monitor:1.13.0"
}

variable "neuron_monitor_service_monitor" {
  type        = bool
  description = "Also create a Prometheus Operator ServiceMonitor for neuron-monitor (15s, honorLabels false — same label schema as dcgm-exporter). Requires the monitoring.coreos.com/v1 CRDs already installed (otherwise apply fails with \"no matches for kind ServiceMonitor\"). Requires install_neuron_monitor = true."
  default     = false

  validation {
    condition     = !var.neuron_monitor_service_monitor || var.install_neuron_monitor
    error_message = "neuron_monitor_service_monitor requires install_neuron_monitor = true."
  }
}

variable "neuron_monitor_service_monitor_labels" {
  type        = map(string)
  description = "Extra labels on the neuron-monitor ServiceMonitor (e.g. { release = \"kube-prometheus-stack\" }) to match the Prometheus serviceMonitorSelector."
  default     = {}
}

variable "neuron_monitor_pod_attribution" {
  type        = bool
  description = "BETA: neuron-monitor --enable-k8s-info (pod / namespace / container labels). Grants the neuron-monitor SA `get nodes/pods` only (never nodes/proxy) and mounts /var/lib/kubelet/pod-resources read-only. Attribution comes from the AWS_NEURON_IDS pod annotation, which only the Neuron scheduler extension writes (install_neuron_scheduler = true, pods with schedulerName: my-scheduler); without it every device and core on the node is attributed to the first Neuron-holding pod, so it is correct only when one pod owns all of the node's Neuron devices; needs kubelet fine-grained authz (otherwise 403); unattributed series (no Neuron pod on the node, a 403 / lookup error, or — with the annotation — devices not listed in it) carry pod_name / namespace / container_name = \"None\" on the raw /metrics, which the ServiceMonitor blanks (no exported_pod / exported_namespace). Requires install_neuron_monitor = true."
  default     = false

  validation {
    condition     = !var.neuron_monitor_pod_attribution || var.install_neuron_monitor
    error_message = "neuron_monitor_pod_attribution requires install_neuron_monitor = true."
  }
}

# =====================================================================
# Tagging
# =====================================================================

variable "default_tags" {
  type    = map(string)
  default = {}
}

# =====================================================================
# Karpenter GPU NodePools
# =====================================================================
variable "karpenter_gpu_nodepools" {
  type = list(object({
    name                  = string
    instance_type         = string
    capacity_types        = optional(list(string), ["spot"])
    zones                 = optional(list(string), [])
    max_nodes             = optional(number, 1)
    instance_store_policy = optional(string, "RAID0")
    root_volume_size      = optional(number, 100)
    consolidate_after     = optional(string, "1h")
    expire_after          = optional(string, "Never")
  }))
  default     = []
  description = <<-EOT
    GPU capacity provisioned by Karpenter instead of (or alongside) the EKS
    GPU nodegroups. One EC2NodeClass + NodePool per entry, one instance type
    per pool (its EFA NIC layout comes from modules/gpu-instance-catalog, the
    same table the nodegroups use). Requires install_karpenter = true.
      capacity_types        ["spot"] (default) / ["on-demand"] / both
      zones                 restrict to AZs, e.g. ["ap-south-2c"]; [] = all
                            AZs of the Karpenter discovery subnets
      max_nodes             NodePool limit in nodes (converted to nvidia.com/gpu
                            for NVIDIA, aws.amazon.com/neuron for Neuron pools)
      instance_store_policy "RAID0" (default; containerd/kubelet/emptyDir on
                            Instance Store NVMe at /mnt/k8s-disks/0) or ""
      consolidate_after     idle time before an empty node is removed ("Never" to keep)
      expire_after          forced rotation ("Never" by default for GPU nodes)
    Spot interruptions: Karpenter's SQS interruption queue cordons/drains the
    node on the 2-minute notice and launches a replacement right away.
    Neuron (trn*/inf*) pools are auto-detected by instance type name
    (modules/gpu-instance-catalog) and get label workload-type=neuron, taint
    + limit aws.amazon.com/neuron (whole devices), the AL2023 Neuron AMI
    (karpenter_neuron_ami_selector chain) and an EFA-boothook-only userData
    (no NVIDIA containerd overlay / kmod fixup). They:
      - must be paired with install_neuron_stack = true (advisory check);
      - need karpenter_version >= 1.11 when they render EFA networkInterfaces
        (trn1.32xlarge / trn1n / trn2), >= 1.1 otherwise (inf1 / inf2 /
        trn1.2xlarge; conservative minimum — NeuronInfo-based device counts
        and aws.amazon.com/neuroncore arrive in v1.1.0); plan fails
        otherwise. NVIDIA pools have no floor;
      - inf1 / inf2: set instance_store_policy = "" (no Instance Store);
      - trn2 is rarely available as Spot — consider ["on-demand"].
    Neuroncore pitfall: Karpenter assumes devices x physical cores (devices x
    8 on trn2) while the Neuron device plugin advertises devices x 4 at the
    default LNC=2: trn2.48xlarge 128 vs 64 (requests of 65-128), trn2.3xlarge
    8 vs 4 (requests of 5-8). Such a pod makes Karpenter launch a node it
    never fits on (reclaimed after consolidate_after, then the loop repeats).
    trn1 / inf1 / inf2 (no LNC) are unaffected. Request aws.amazon.com/neuron.
  EOT

  validation {
    condition     = length(var.karpenter_gpu_nodepools) == 0 || var.install_karpenter
    error_message = "karpenter_gpu_nodepools requires install_karpenter = true."
  }
}

variable "karpenter_gpu_ami_selector" {
  type        = string
  default     = ""
  description = "Override the NVIDIA GPU NodePool AMI: \"al2023@latest\", \"al2023@vYYYYMMDD\" or \"ami-...\". Empty = gpu_custom_ami_id if set, else al2023@<gpu_ami_release_version>, else al2023@latest. NVIDIA pools only; Neuron (trn*/inf*) pools inherit it only when it is an al2023@ alias (see karpenter_neuron_ami_selector)."
}

variable "karpenter_neuron_ami_selector" {
  type        = string
  default     = ""
  description = "Override the Neuron (trn*/inf*) Karpenter NodePool AMI: \"al2023@latest\", \"al2023@vYYYYMMDD\" or \"ami-...\" (must derive from amazon-eks-node-al2023-x86_64-neuron-*). Empty = neuron_custom_ami_id if set, else al2023@<neuron_ami_release_version> when that is non-null (\"\" = latest), else karpenter_gpu_ami_selector when it is an al2023@ alias, else al2023@<gpu_ami_release_version>, else al2023@latest. An NVIDIA ami- id (gpu_custom_ami_id / karpenter_gpu_ami_selector) is never applied to Neuron pools."

  validation {
    condition     = var.karpenter_neuron_ami_selector == "" || can(regex("^(al2023@(latest|v[0-9]{8})|ami-[0-9a-f]{8,17})$", var.karpenter_neuron_ami_selector))
    error_message = "karpenter_neuron_ami_selector must be empty, \"al2023@latest\", \"al2023@vYYYYMMDD\" or an \"ami-...\" id."
  }
}
