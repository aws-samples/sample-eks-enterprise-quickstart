variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }
variable "cluster_security_group_id" { type = string }
variable "region" { type = string }
variable "karpenter_version" { type = string }
variable "ssh_public_key" {
  type    = string
  default = ""
}
variable "helm_replace_existing" {
  type        = bool
  description = "Set helm_release.replace=true (only safe in dev/test)."
  default     = false
}
variable "system_node_label_key" { type = string }
variable "system_node_label_value" { type = string }
variable "private_subnet_ids" { type = list(string) }

variable "pod_identity_propagation_wait" {
  type        = string
  default     = "30s"
  description = "How long to wait after creating/replacing this module's EKS Pod Identity associations before deploying the pods that use them (time_sleep create_duration, e.g. \"30s\", \"1m\"). Associations are eventually consistent; a pod admitted before propagation never gets the AWS_CONTAINER_* env and falls back to the node role (issue #2)."
}

# ---------------------------------------------------------------------
# GPU NodePools (one EC2NodeClass + NodePool per entry)
# ---------------------------------------------------------------------
variable "gpu_nodepools" {
  type = list(object({
    name                  = string # NodePool / EC2NodeClass name suffix: gpu-<name>
    instance_type         = string # exactly one type per pool (NIC/EFA layout is per type)
    capacity_types        = optional(list(string), ["spot"])
    zones                 = optional(list(string), []) # e.g. ["ap-south-2c"]; [] = every AZ the discovery subnets cover
    max_nodes             = optional(number, 1)        # NodePool limit in nodes of instance_type (rendered as nvidia.com/gpu or aws.amazon.com/neuron)
    instance_store_policy = optional(string, "RAID0")  # "RAID0" (containerd/kubelet on Instance Store NVMe) or "" (root EBS)
    root_volume_size      = optional(number, 100)      # GiB
    consolidate_after     = optional(string, "1h")     # idle time before an EMPTY node is removed; "Never" disables
    expire_after          = optional(string, "Never")  # forced node rotation; "Never" for long-running GPU nodes
  }))
  default     = []
  description = <<-EOT
    Karpenter accelerator NodePools. Each entry renders an EC2NodeClass (EFA NIC
    layout from modules/gpu-instance-catalog, optional Instance Store RAID0, EFA
    userspace bootstrap) and a NodePool (capacity-type/zone requirements, device
    limit). The vendor is detected from instance_type by modules/gpu-instance-catalog
    (neuron_instance_type_regex: trn*/inf* -> neuron, everything else -> nvidia):
      - NVIDIA pools: AL2023 NVIDIA AMI variant via gpu_ami_selector, label
        workload-type=gpu, taint + limit nvidia.com/gpu (cpu limit when EC2
        reports no GPUs), userData = EFA boothook + g7 open-kmod fixup + the
        NVIDIA containerd runtime overlay.
      - Neuron pools: AL2023 x86_64 Neuron AMI variant via neuron_ami_selector,
        label workload-type=neuron, taint aws.amazon.com/neuron, limit in whole
        aws.amazon.com/neuron devices, userData = EFA boothook only.
    inf1 / inf2 have no Instance Store: set instance_store_policy = "".
    Neuroncore pitfall: Karpenter assumes devices x physical cores (devices x 8
    on trn2) while the Neuron device plugin advertises devices x 4 at the
    default LNC=2 — trn2.48xlarge 128 vs 64 (requests of 65-128), trn2.3xlarge
    8 vs 4 (requests of 5-8) make Karpenter launch a node the pod can never
    fit on. trn1 / inf1 / inf2 (no LNC) are unaffected. Request
    aws.amazon.com/neuron instead.
  EOT

  validation {
    condition     = alltrue([for p in var.gpu_nodepools : can(regex("^[a-z0-9]([-a-z0-9]{0,40}[a-z0-9])?$", p.name))])
    error_message = "gpu_nodepools[].name must be a lowercase DNS label (a-z, 0-9, '-'), at most 42 chars."
  }
  validation {
    condition     = length(distinct([for p in var.gpu_nodepools : p.name])) == length(var.gpu_nodepools)
    error_message = "gpu_nodepools[].name must be unique."
  }
  validation {
    condition = alltrue([for p in var.gpu_nodepools :
      length(p.capacity_types) > 0 && alltrue([for c in p.capacity_types : contains(["spot", "on-demand"], c)])
    ])
    error_message = "gpu_nodepools[].capacity_types must be a non-empty subset of [\"spot\", \"on-demand\"]."
  }
  validation {
    condition     = alltrue([for p in var.gpu_nodepools : contains(["RAID0", ""], p.instance_store_policy)])
    error_message = "gpu_nodepools[].instance_store_policy must be \"RAID0\" or \"\"."
  }
  validation {
    condition     = alltrue([for p in var.gpu_nodepools : p.max_nodes >= 1 && floor(p.max_nodes) == p.max_nodes])
    error_message = "gpu_nodepools[].max_nodes must be a positive integer."
  }
  validation {
    condition = alltrue([for p in var.gpu_nodepools :
      can(regex("^(Never|[0-9]+(s|m|h))$", p.consolidate_after)) && can(regex("^(Never|[0-9]+(s|m|h))$", p.expire_after))
    ])
    error_message = "gpu_nodepools[].consolidate_after / expire_after must be \"Never\" or a duration like \"30m\" / \"720h\"."
  }
}

variable "gpu_ami_selector" {
  type        = string
  default     = "al2023@latest"
  description = "AMI for GPU NodePools: an AL2023 alias (\"al2023@latest\" / \"al2023@v20260818\" — Karpenter picks the NVIDIA variant for GPU types) or a custom AMI id (\"ami-...\", must derive from the EKS AL2023 NVIDIA AMI). NVIDIA pools only; Neuron (trn*/inf*) pools use neuron_ami_selector."

  validation {
    condition     = can(regex("^(al2023@(latest|v[0-9]{8})|ami-[0-9a-f]{8,17})$", var.gpu_ami_selector))
    error_message = "gpu_ami_selector must be \"al2023@latest\", \"al2023@vYYYYMMDD\" or an \"ami-...\" id."
  }
}

variable "neuron_ami_selector" {
  type        = string
  default     = "al2023@latest"
  description = "AMI for Neuron (trn*/inf*) GPU NodePools only: an AL2023 alias (\"al2023@latest\" / \"al2023@vYYYYMMDD\" — Karpenter resolves the x86_64 neuron variant via karpenter.k8s.aws/instance-accelerator-count) or an \"ami-...\" id that MUST derive from amazon-eks-node-al2023-x86_64-neuron-* (rendered with amiFamily AL2023). Never set this to the NVIDIA AMI. The format is checked by a precondition on helm_release.karpenter_pools ONLY when a Neuron pool exists: the root always derives and passes this value (possibly from an unrelated, ignored gpu_ami_release_version), so a variable-level validation would break NVIDIA-only plans."
}

variable "gpu_install_efa_userspace" {
  type        = bool
  default     = true
  description = "Install the EFA userspace (from the AMI's own installer release) on GPU NodePool nodes (NVIDIA and Neuron), same as the GPU nodegroups."
}

variable "gpu_efa_installer_version" {
  type        = string
  default     = "1.48.0"
  description = "Fallback aws-efa-installer version when the AMI carries no installer record (same semantics as the GPU nodegroups)."
}
