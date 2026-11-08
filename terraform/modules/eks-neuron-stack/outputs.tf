output "helm_release_name" {
  value       = helm_release.neuron.name
  description = "Neuron Helm release name (neuron-helm-chart)."
}

output "efa_device_plugin_daemonset_name" {
  value       = try(kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name, null)
  description = "EFA device plugin DaemonSet name on Neuron nodes (null when install_efa_device_plugin = false)."
}

output "scheduler_name" {
  value       = var.install_scheduler ? "my-scheduler" : null
  description = "schedulerName Neuron pods must set to use the Neuron scheduler extension (null when install_scheduler = false)."
}

output "monitor_daemonset_name" {
  value       = try(kubernetes_daemon_set_v1.neuron_monitor[0].metadata[0].name, null)
  description = "neuron-monitor DaemonSet name in kube-system (null when install_monitor = false)."
}

output "monitor_service" {
  value       = try("${kubernetes_service_v1.neuron_monitor[0].metadata[0].name}.kube-system.svc:8000", null)
  description = "In-cluster scrape target of the neuron-monitor ClusterIP Service (plain HTTP /metrics; null when install_monitor = false)."
}
