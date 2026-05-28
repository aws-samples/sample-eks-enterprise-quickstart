# =====================================================================
# Module split: eks-gpu-nodegroup → eks-gpu-stack
# =====================================================================
# 2026-05-22: helm/kubernetes resources for the K8s GPU stack moved out
# of the AWS-side eks-gpu-nodegroup module into a dedicated eks-gpu-stack
# module so the two layers can be iterated independently and to support
# the standard|operator mode dispatch.
#
# Without these `moved` blocks, an existing user's first `terraform apply`
# after the upgrade would destroy and re-create the EFA DaemonSet and the
# nvidia-device-plugin helm release — a brief outage that interrupts any
# in-flight EFA jobs while vpc.amazonaws.com/efa is unregistered.
# With the blocks, Terraform refactors the address in state and the next
# plan shows zero changes for these resources.
#
# Both old resources lived inside `count = var.install_gpu_nodegroups ? 1 : 0`
# in the old module, so the source addresses include `[0]`. The new module
# is also count-gated (`count = var.install_gpu_stack ? 1 : 0`), so the
# destination address also has `[0]`. The EFA DaemonSet inside the new
# module is itself count-gated (`var.install_efa_device_plugin`), so its
# instance index is `[0]` too.
#
# These blocks are no-ops for fresh installs (no source resource in state).
# Safe to keep indefinitely; remove only after every existing environment
# has applied at least once.
# =====================================================================

moved {
  from = module.eks_gpu_nodegroup[0].helm_release.nvidia_device_plugin
  to   = module.eks_gpu_stack[0].helm_release.nvidia_device_plugin[0]
}

moved {
  from = module.eks_gpu_nodegroup[0].kubernetes_daemon_set_v1.efa_device_plugin
  to   = module.eks_gpu_stack[0].kubernetes_daemon_set_v1.efa_device_plugin[0]
}
