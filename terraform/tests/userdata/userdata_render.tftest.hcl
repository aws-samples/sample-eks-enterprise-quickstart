# Regression guard for the AL2023 nodeadm bootstrap contract.
#
# History: a "Fix nodeadm bootstrap" change once moved NodeConfig into a
# cloud-boothook that hand-wrote nodeconfig.yaml and called `nodeadm init`
# directly. On AL2023 EKS AMIs the shipped nodeadm-config.service parses
# user-data BEFORE cloud-init boothooks run, fails with "no config in chain",
# and that failure hard-blocks nodeadm-run.service (Requires=) — kubelet never
# starts and the node never joins. These tests pin the correct shape so the
# regression can't silently return.
#
# Pure templatefile() rendering — runs in CI with no AWS provider/credentials.

run "self_managed_render" {
  command = plan

  variables {
    node_management = "self_managed"
  }

  # --- The contract: NodeConfig is a standalone node.eks.aws MIME part ---
  assert {
    condition     = output.system_nodeconfig_part_count == 1
    error_message = "system user-data must contain exactly one standalone 'application/node.eks.aws' MIME part (nodeadm-config.service parses it)."
  }
  assert {
    condition     = output.gpu_nodeconfig_part_count == 1
    error_message = "gpu user-data must contain exactly one standalone 'application/node.eks.aws' MIME part."
  }

  # --- The anti-pattern: no manual `nodeadm init` in the boothook ---
  assert {
    condition     = output.system_manual_nodeadm_init_count == 0
    error_message = "system boothook must NOT call `nodeadm init` manually — let nodeadm-config.service consume the MIME part."
  }
  assert {
    condition     = output.gpu_manual_nodeadm_init_count == 0
    error_message = "gpu boothook must NOT call `nodeadm init` manually — let nodeadm-config.service consume the MIME part."
  }

  # --- MIME structure: standard multipart header is present ---
  assert {
    condition     = strcontains(output.system_userdata, "Content-Type: multipart/mixed; boundary=\"==BOUNDARY==\"")
    error_message = "system user-data must be a multipart/mixed MIME document."
  }

  # --- self_managed must embed labels (EKS NG API no longer injects them) ---
  assert {
    condition     = strcontains(output.system_userdata, "--node-labels=workload-type=eks-utils")
    error_message = "self_managed system NodeConfig must carry kubelet --node-labels."
  }
  assert {
    condition     = strcontains(output.gpu_userdata, "--node-labels=workload-type=gpu,gpu-instance-type=p5.48xlarge,purchase-option=od")
    error_message = "self_managed gpu NodeConfig must carry the per-NG kubelet --node-labels."
  }
  assert {
    condition     = strcontains(output.gpu_userdata, "--register-with-taints=nvidia.com/gpu=true:NoSchedule")
    error_message = "self_managed gpu NodeConfig must carry the nvidia.com/gpu taint."
  }

  # --- GPU-specific: SystemdCgroup overlay + reload workaround preserved ---
  assert {
    condition     = strcontains(output.gpu_userdata, "SystemdCgroup = true")
    error_message = "gpu NodeConfig must pin SystemdCgroup=true via containerd.config overlay."
  }
  assert {
    condition     = strcontains(output.gpu_boothook, "systemctl restart containerd")
    error_message = "gpu boothook must keep the containerd reload workaround (loads the SystemdCgroup overlay into the running daemon)."
  }

  # --- local-ssd label was intentionally dropped (runtime-probed, can't be static) ---
  assert {
    condition     = !strcontains(output.gpu_userdata, "local-ssd")
    error_message = "gpu user-data must not reference the runtime-probed local-ssd label (removed when NodeConfig moved to a static MIME part)."
  }
}

run "managed_render" {
  command = plan

  variables {
    node_management = "managed"
  }

  # The MIME part contract holds in managed mode too.
  assert {
    condition     = output.system_nodeconfig_part_count == 1
    error_message = "managed system user-data must still contain exactly one 'application/node.eks.aws' MIME part."
  }
  assert {
    condition     = output.gpu_nodeconfig_part_count == 1
    error_message = "managed gpu user-data must still contain exactly one 'application/node.eks.aws' MIME part."
  }
  assert {
    condition     = output.system_manual_nodeadm_init_count == 0
    error_message = "managed system boothook must NOT call `nodeadm init` manually."
  }
  assert {
    condition     = output.gpu_manual_nodeadm_init_count == 0
    error_message = "managed gpu boothook must NOT call `nodeadm init` manually."
  }

  # In managed mode EKS injects labels/taints via the NodeGroup API — the
  # NodeConfig must NOT duplicate them.
  assert {
    condition     = !strcontains(output.system_userdata, "--node-labels")
    error_message = "managed system NodeConfig must NOT embed kubelet --node-labels (EKS NG API injects them)."
  }
  assert {
    condition     = !strcontains(output.gpu_userdata, "--node-labels")
    error_message = "managed gpu NodeConfig must NOT embed kubelet --node-labels (EKS NG API injects them)."
  }
  assert {
    condition     = !strcontains(output.gpu_userdata, "--register-with-taints")
    error_message = "managed gpu NodeConfig must NOT embed taints (EKS NG API injects nvidia.com/gpu)."
  }

  # SystemdCgroup overlay is mode-independent and must persist in managed mode.
  assert {
    condition     = strcontains(output.gpu_userdata, "SystemdCgroup = true")
    error_message = "gpu NodeConfig must pin SystemdCgroup=true in managed mode too."
  }
}
