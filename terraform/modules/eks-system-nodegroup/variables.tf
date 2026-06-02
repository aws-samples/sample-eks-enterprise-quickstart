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
variable "vpc_id" {
  type        = string
  description = "VPC ID. REQUIRED when node_management = \"self_managed\" (used to attach the node SG to the right VPC). Ignored in managed mode — EKS picks the VPC from the cluster config."
  default     = ""
}

variable "node_management" {
  type        = string
  default     = "managed"
  description = <<-EOT
    System node group provisioning mode.

      - "managed" (default): EKS Managed Node Group (aws_eks_node_group). EKS
        owns the underlying ASG, including self-healing (terminates and
        replaces unhealthy instances → instance IDs change), AZ rebalancing,
        and rolling updates. Cluster-autoscaler discovery tags are applied
        to the EKS-owned ASG via aws_autoscaling_group_tag.

      - "self_managed": Customer-owned ASG (aws_autoscaling_group) with all
        ASG-driven self-healing disabled (suspended_processes =
        [ReplaceUnhealthy, AZRebalance], no instance_refresh, lifecycle
        ignore_changes on desired_capacity). Instance IDs are stable until
        you explicitly retire them via:
            aws autoscaling terminate-instance-in-auto-scaling-group \
              --instance-id <id> --should-decrement-desired-capacity
        You take ownership of K8s version upgrades (cordon → drain →
        terminate → CA brings up replacement). cluster-autoscaler is
        required for elastic scaling — set var.install_cluster_autoscaler
        true (this stack installs ours) or deploy your own.

    Cross-module convention: when this is "self_managed", set
    var.node_management on eks-gpu-nodegroup to the same value. Mixing modes
    inside one cluster is not supported by this stack.

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
    Default disables ALL ASG-driven self-healing:
      - ReplaceUnhealthy: prevents ASG from terminating + replacing
        health-check-failed instances (which would change instance ID).
      - AZRebalance: prevents ASG from terminating instances in
        over-populated AZs.

    NOT suspended (validation rejects suspending these):
      - Launch: needed by Cluster Autoscaler to scale up.
      - Terminate: needed by 'terminate-instance-in-auto-scaling-group
        --instance-id ...' for targeted retirement.
      - HealthCheck: kept enabled so unhealthy instances are still flagged
        (visibility), they're just not auto-replaced.

    Ignored when node_management = "managed".
  EOT

  validation {
    condition     = !contains(var.asg_suspended_processes, "Launch")
    error_message = "Suspending 'Launch' breaks scale-up (Cluster Autoscaler can't add capacity). Remove from list."
  }

  validation {
    condition     = !contains(var.asg_suspended_processes, "Terminate")
    error_message = "Suspending 'Terminate' breaks targeted retirement (terminate-instance-in-auto-scaling-group fails). Remove from list."
  }
}

variable "extra_asg_tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags applied to the self-managed ASG (e.g. cost-allocation tags Owner / CostCenter / Environment). Ignored when node_management = \"managed\" — for managed NGs, attach tags via aws_eks_node_group.tags upstream."
}
