variable "cluster_name" { type = string }
variable "k8s_version" { type = string }
variable "cluster_endpoint" { type = string }
variable "cluster_ca" { type = string }
variable "cluster_security_group_id" { type = string }
variable "service_ipv4_cidr" { type = string }
variable "subnet_ids" { type = list(string) }
variable "instance_type" { type = string }
variable "root_volume_size" { type = number }
variable "data_volume_size" { type = number }
variable "desired_capacity" { type = number }
variable "min_size" { type = number }
variable "max_size" { type = number }
variable "node_label_key" { type = string }
variable "node_label_value" { type = string }
variable "ec2_key_name" {
  type    = string
  default = ""
}
variable "region" { type = string }
