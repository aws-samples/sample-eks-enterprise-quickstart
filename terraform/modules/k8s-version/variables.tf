variable "cluster_name" {
  type        = string
  description = "EKS cluster name to look up (read-only eks:ListClusters + eks:DescribeCluster)."
}

variable "k8s_version" {
  type        = string
  default     = null
  description = "Explicit Kubernetes minor (e.g. \"1.36\"). null = the running version of an existing cluster, else default_k8s_version."
}

variable "karpenter_version" {
  type        = string
  default     = null
  description = "Explicit Karpenter chart version. null = 1.12.1 when the basis minor is <= 1.35, else 1.15.1 (basis: running minor of an existing cluster, else the effective minor)."
}

variable "install_karpenter" {
  type        = bool
  default     = false
  description = "Enables the Karpenter compatibility guard."
}
