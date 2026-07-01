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

  # --- containerd content-store integrity (blob-not-found regression guard) ---
  # Applied to ALL FOUR provisioning paths (system, gpu, karpenter x86 +
  # graviton). Each assertion pins one element of the fix so the original race
  # (stop||true -> rsync/cp||true -> umount-without-sync -> start) and the
  # node-never-joins regressions (masked-without-reachable-unmask) can't return.

  # 1. mask containerd up front so it never starts on the root volume.
  assert {
    condition     = alltrue([for k, v in output.mask_containerd_count : v >= 1])
    error_message = "every boothook must `systemctl mask containerd` before the LVM migration (prevents the blob-not-found race). Offending paths render mask 0 times."
  }
  # 2. mask must be paired with a happy-path unmask, or kubelet never starts.
  assert {
    condition     = alltrue([for k, v in output.unmask_containerd_count : v >= 1])
    error_message = "every boothook must `systemctl unmask containerd` after migration (otherwise the node never joins)."
  }
  # 3. unmask must be REACHABLE on failure: an EXIT trap unmasks containerd so a
  #    `set -e` abort mid-migration can't leave it permanently masked.
  assert {
    condition     = alltrue([for k, v in output.unmask_trap_count : v >= 1])
    error_message = "every boothook must install `trap '... unmask containerd ...' EXIT` right after masking — otherwise a mid-migration failure under set -e strands containerd masked and the node never joins."
  }
  # 4. wait for the running containerd to exit before touching its data dir
  #    (root cause #1: stopped-without-waiting raced the content-store copy).
  assert {
    condition     = alltrue([for k, v in output.wait_for_exit_count : v >= 1])
    error_message = "every boothook must wait for containerd to exit (`pgrep -x containerd` loop) before migrating its data dir."
  }
  # 5. fail-fast migration form present (positive guard): the mount-swap must be
  #    gated on rsync success (`if rsync ...; then <swap>; else <abandon>`).
  assert {
    condition     = alltrue([for k, v in output.failfast_rsync_count : v >= 1])
    error_message = "every boothook must gate the mount-swap on `if rsync -aHAX ...` so a failed copy is never mounted over /var/lib/containerd."
  }
  # 6. NO swallowed copy errors — neither rsync||true nor cp||true (root cause
  #    #2; cp||true is the pre-fix form and must not silently return).
  assert {
    condition     = alltrue([for k, v in output.swallow_copy_error_count : v == 0])
    error_message = "no boothook may swallow a content-store copy error (`rsync ... || true` or `cp ... || true`) — a partial store must fail-fast."
  }
  # 7. a `sync` must sit BETWEEN the rsync and the umount (root cause #3).
  assert {
    condition     = alltrue([for k, v in output.sync_before_umount_count : v >= 1])
    error_message = "every boothook must `sync` between the rsync and the umount (force blob data onto EBS before the mount swap)."
  }
  # 8. awslabs/amazon-eks-ami#2122 guard: on rsync failure the migration must be
  #    ABANDONED (keep the AMI's root-volume /var/lib/containerd with its
  #    pre-cached localhost/kubernetes/pause), NOT wiped-and-mounted-empty.
  assert {
    condition     = alltrue([for k, v in output.wipe_target_count : v == 0])
    error_message = "no boothook may `rm -rf` the migration target — wiping then mounting an empty LV drops the pre-cached pause image and reproduces amazon-eks-ami#2122 (node never joins). Abandon the migration instead."
  }
  # 9. the failure branch must tear down the half-built LV so a reboot doesn't
  #    remount an empty volume over the intact root-volume content store.
  assert {
    condition     = alltrue([for k, v in output.failure_lvremove_count : v >= 1])
    error_message = "every boothook's rsync-failure branch must `lvremove` the half-built lv_containerd so a reboot doesn't remount an empty LV over /var/lib/containerd."
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
