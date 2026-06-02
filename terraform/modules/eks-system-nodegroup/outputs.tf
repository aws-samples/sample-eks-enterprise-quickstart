output "nodegroup_name" {
  description = "EKS Managed NG name when node_management = managed; ASG name when self_managed."
  value = (
    var.node_management == "managed"
    ? aws_eks_node_group.system[0].node_group_name
    : aws_autoscaling_group.system[0].name
  )
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "node_role_name" {
  value = aws_iam_role.node.name
}

output "launch_template_id" {
  value = aws_launch_template.system.id
}
