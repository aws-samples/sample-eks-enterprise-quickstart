output "karpenter_node_role_arn" {
  value = aws_iam_role.karpenter_node.arn
}

output "karpenter_controller_role_arn" {
  value = aws_iam_role.karpenter_controller.arn
}

output "karpenter_interruption_queue_arn" {
  value = aws_sqs_queue.karpenter_interruption.arn
}

output "gpu_nodepool_vendors" {
  description = "Map gpu_nodepools[].name -> \"nvidia\" | \"neuron\" (name-based via modules/gpu-instance-catalog; known at plan time)."
  value       = local.gpu_pool_vendor
}
