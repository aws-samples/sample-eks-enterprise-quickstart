output "nodegroup_names" {
  value = [for ng in aws_eks_node_group.gpu : ng.node_group_name]
}

output "nodegroup_arns" {
  value = { for k, ng in aws_eks_node_group.gpu : k => ng.arn }
}

output "gpu_node_role_arn" {
  value = aws_iam_role.gpu_node.arn
}

output "gpu_security_group_id" {
  value = aws_security_group.gpu.id
}
