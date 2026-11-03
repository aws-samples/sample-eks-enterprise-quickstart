variable "cluster_name" { type = string }
variable "region" { type = string }
variable "k8s_version" { type = string }
variable "install_efs" {
  type    = bool
  default = false
}
variable "install_fsx" {
  type    = bool
  default = false
}
variable "install_s3" {
  type    = bool
  default = false
}
variable "s3_bucket_arns" {
  type    = list(string)
  default = []

  # Cross-variable validation (Terraform 1.9+).
  # install_s3=true requires at least one bucket ARN — otherwise we'd
  # create a Pod-Identity role with no bucket-scoped policy and Mountpoint
  # pods would crashloop on PVC mount.
  validation {
    condition     = !var.install_s3 || length(var.s3_bucket_arns) > 0
    error_message = "install_s3=true requires s3_bucket_arns to be non-empty. Mountpoint for S3 needs explicit bucket ARNs (standard S3 or S3 Express One Zone)."
  }
}
variable "system_node_label_key" { type = string }
variable "system_node_label_value" { type = string }

variable "pod_identity_propagation_wait" {
  type        = string
  default     = "30s"
  description = "How long to wait after creating/replacing this module's EKS Pod Identity associations before deploying the pods that use them (time_sleep create_duration, e.g. \"30s\", \"1m\"). Associations are eventually consistent; a pod admitted before propagation never gets the AWS_CONTAINER_* env and falls back to the node role (issue #2)."
}
