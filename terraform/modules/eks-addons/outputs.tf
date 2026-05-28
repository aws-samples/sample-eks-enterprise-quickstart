output "cluster_autoscaler_role_arn" {
  value = aws_iam_role.cluster_autoscaler.arn
}

output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}
