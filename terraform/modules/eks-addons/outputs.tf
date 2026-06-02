output "cluster_autoscaler_role_arn" {
  description = "ARN of the IAM role this stack created for cluster-autoscaler. Empty string when var.install_cluster_autoscaler = false (external CA path)."
  value       = var.install_cluster_autoscaler ? aws_iam_role.cluster_autoscaler[0].arn : ""
}

output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}
