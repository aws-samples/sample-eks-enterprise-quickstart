variable "cluster_name" { type = string }
variable "vpc_id" { type = string }
variable "region" { type = string }
variable "k8s_version" { type = string }

variable "install_cluster_autoscaler" {
  type        = bool
  default     = true
  description = <<-EOT
    Whether this stack installs cluster-autoscaler. Default true installs the
    standard upstream chart with Pod Identity (5 resources: IAM role + inline
    policy, ServiceAccount, Pod Identity Association, helm_release).

    Set false when an external Cluster Autoscaler is deployed by your team
    (e.g. customer-supplied CA running against the same EKS cluster). The
    NG modules continue to inline the standard
    `k8s.io/cluster-autoscaler/<cluster>=owned` discovery tags on the ASGs
    regardless of this flag, so any compatible CA can pick them up.

    See the "Bring-your-own Cluster Autoscaler" section of
    docs/SELF_MANAGED_NG.md for the cutover SOP (typical lifecycle: Phase 1
    install ours, validate, then flip to false in Phase 2 and roll out the
    customer's CA).
  EOT
}

variable "cluster_autoscaler_version" {
  type        = string
  default     = ""
  description = <<-EOT
    Cluster-autoscaler container image tag (e.g. "v1.35.0"). Empty (default)
    auto-selects from the matrix in main.tf based on var.k8s_version. Set
    explicitly to override the matrix or to use a vendor build.
  EOT
}

variable "cluster_autoscaler_chart_version" {
  type        = string
  default     = ""
  description = <<-EOT
    Cluster-autoscaler helm chart version (e.g. "9.46.6"). Empty (default)
    auto-selects from the matrix in main.tf based on var.k8s_version. Set
    explicitly to override the matrix.
  EOT
}

variable "helm_replace_existing" {
  type    = bool
  default = false
}
variable "alb_controller_chart_version" { type = string }
variable "alb_controller_app_version" { type = string }
variable "alb_controller_iam_policy_source" {
  type    = string
  default = "http"
}
variable "system_node_label_key" { type = string }
variable "system_node_label_value" { type = string }

variable "pod_identity_propagation_wait" {
  type        = string
  default     = "30s"
  description = "How long to wait after creating/replacing this module's EKS Pod Identity associations before deploying the pods that use them (time_sleep create_duration, e.g. \"30s\", \"1m\"). Associations are eventually consistent; a pod admitted before propagation never gets the AWS_CONTAINER_* env and falls back to the node role (issue #2)."
}
