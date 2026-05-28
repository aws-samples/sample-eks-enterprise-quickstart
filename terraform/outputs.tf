output "cluster_name" {
  value = module.eks_cluster.cluster_name
}

output "cluster_endpoint" {
  value = module.eks_cluster.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value     = module.eks_cluster.cluster_certificate_authority_data
  sensitive = true
}

output "cluster_security_group_id" {
  value = module.eks_cluster.cluster_security_group_id
}

output "oidc_provider_arn" {
  value = module.eks_cluster.oidc_provider_arn
}

output "system_nodegroup_name" {
  value = module.eks_system_nodegroup.nodegroup_name
}

output "gpu_nodegroup_names" {
  value = try(module.eks_gpu_nodegroup[0].nodegroup_names, [])
}

output "gpu_stack_mode" {
  value = try(module.eks_gpu_stack[0].stack_mode, null)
}

output "kubeconfig_command" {
  value       = "aws eks update-kubeconfig --name ${module.eks_cluster.cluster_name} --region ${var.aws_region}"
  description = "Run this to populate ~/.kube/config from a host with VPC access."
}
