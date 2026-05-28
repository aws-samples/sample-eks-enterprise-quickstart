output "karpenter_node_role_arn" {
  value = aws_iam_role.karpenter_node.arn
}

output "karpenter_controller_role_arn" {
  value = aws_iam_role.karpenter_controller.arn
}

output "karpenter_interruption_queue_arn" {
  value = aws_sqs_queue.karpenter_interruption.arn
}
