variable "cluster_name" { type = string }
variable "vpc_id" { type = string }
variable "region" { type = string }
variable "k8s_version" { type = string }
variable "cluster_autoscaler_version" { type = string }
variable "cluster_autoscaler_chart_version" { type = string }
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
