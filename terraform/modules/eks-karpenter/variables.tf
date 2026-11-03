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
