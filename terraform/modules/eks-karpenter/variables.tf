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
    max_nodes             = optional(number, 1)        # NodePool limit, expressed in nodes of instance_type
    instance_store_policy = optional(string, "RAID0")  # "RAID0" (containerd/kubelet on Instance Store NVMe) or "" (root EBS)
    root_volume_size      = optional(number, 100)      # GiB
    consolidate_after     = optional(string, "1h")     # idle time before an EMPTY node is removed; "Never" disables
    expire_after          = optional(string, "Never")  # forced node rotation; "Never" for long-running GPU nodes
  }))
  default     = []
  description = "Karpenter GPU NodePools. Each entry renders an EC2NodeClass (AL2023 NVIDIA AMI, EFA NIC layout from modules/gpu-instance-catalog, optional Instance Store RAID0, EFA userspace bootstrap) and a NodePool (workload-type=gpu label, nvidia.com/gpu taint, capacity-type/zone requirements, GPU limit)."

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
  description = "AMI for GPU NodePools: an AL2023 alias (\"al2023@latest\" / \"al2023@v20260818\" — Karpenter picks the NVIDIA variant for GPU types) or a custom AMI id (\"ami-...\", must derive from the EKS AL2023 NVIDIA AMI)."

  validation {
    condition     = can(regex("^(al2023@(latest|v[0-9]{8})|ami-[0-9a-f]{8,17})$", var.gpu_ami_selector))
    error_message = "gpu_ami_selector must be \"al2023@latest\", \"al2023@vYYYYMMDD\" or an \"ami-...\" id."
  }
}

variable "gpu_install_efa_userspace" {
  type        = bool
  default     = true
  description = "Install the EFA userspace (from the AMI's own installer release) on GPU NodePool nodes, same as the GPU nodegroups."
}

variable "gpu_efa_installer_version" {
  type        = string
  default     = "1.48.0"
  description = "Fallback aws-efa-installer version when the AMI carries no installer record (same semantics as the GPU nodegroups)."
}
