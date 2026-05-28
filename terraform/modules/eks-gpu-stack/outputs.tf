output "stack_mode" {
  value       = var.stack_mode
  description = "Resolved stack_mode (standard|operator)"
}

output "nvidia_device_plugin_release_name" {
  value       = local.is_standard ? try(helm_release.nvidia_device_plugin[0].name, null) : null
  description = "nvidia-device-plugin helm release name (null in operator mode)"
}

output "gpu_operator_release_name" {
  value       = local.is_operator ? try(helm_release.gpu_operator[0].name, null) : null
  description = "gpu-operator helm release name (null in standard mode)"
}

output "efa_device_plugin_daemonset_name" {
  value       = var.install_efa_device_plugin ? try(kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name, null) : null
  description = "AWS EFA device plugin DaemonSet name"
}
