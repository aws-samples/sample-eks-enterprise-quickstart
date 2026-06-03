output "nodegroup_names" {
  description = "EKS Managed NG names (managed mode) or ASG names (self_managed mode)."
  value = (
    var.node_management == "managed"
    ? [for ng in aws_eks_node_group.gpu : ng.node_group_name]
    : [for asg in aws_autoscaling_group.gpu : asg.name]
  )
}

output "nodegroup_arns" {
  description = "EKS Managed NG ARNs (managed mode) or ASG ARNs (self_managed mode), keyed by NG identifier."
  value = (
    var.node_management == "managed"
    ? { for k, ng in aws_eks_node_group.gpu : k => ng.arn }
    : { for k, asg in aws_autoscaling_group.gpu : k => asg.arn }
  )
}

output "gpu_node_role_arn" {
  value = aws_iam_role.gpu_node.arn
}

output "gpu_security_group_id" {
  value = aws_security_group.gpu.id
}
