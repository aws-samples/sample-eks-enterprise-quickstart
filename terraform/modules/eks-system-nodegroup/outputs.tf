output "nodegroup_name" {
  value = aws_eks_node_group.system.node_group_name
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
