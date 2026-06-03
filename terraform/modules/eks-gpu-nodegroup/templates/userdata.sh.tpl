MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: text/cloud-boothook; charset="us-ascii"

#!/bin/bash
# LVM Setup + EKS Bootstrap for GPU nodes
set -ex

exec > >(tee /var/log/gpu-node-bootstrap.log)
exec 2>&1

echo "=== Starting GPU Node LVM Setup ==="

systemctl stop containerd || true

${ebs_data_disk_detect_snippet}

echo "Waiting for EBS data disk..."
DISK=$(detect_ebs_data_disk 60) || {
  echo "ERROR: No EBS data disk found after 60 seconds"
  echo "Available disks:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
  systemctl start containerd
  exit 1
}
echo "Found EBS data disk: $DISK"

if vgs vg_data &>/dev/null; then
  echo "LVM already configured, mounting..."
  mount /dev/vg_data/lv_containerd /var/lib/containerd || true
  systemctl start containerd
else
  dnf install -y lvm2 rsync
  pvcreate "$DISK"
  vgcreate vg_data "$DISK"
  lvcreate -l 100%VG -n lv_containerd vg_data
  mkfs.xfs /dev/vg_data/lv_containerd

  mkdir -p /mnt/runtime/containerd
  mount /dev/vg_data/lv_containerd /mnt/runtime/containerd
  rsync -aHAX /var/lib/containerd/ /mnt/runtime/containerd/ || true
  umount /mnt/runtime/containerd
  mount /dev/vg_data/lv_containerd /var/lib/containerd

  grep -q "lv_containerd" /etc/fstab || \
    echo "/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2" >> /etc/fstab

  systemctl start containerd
fi

echo "=== LVM Setup Complete ==="

# ============================================================
# Local Instance Store LVM (ephemeral scratch)
# ============================================================
LOCAL_SSD_TOTAL_GB=0
%{ if enable_local_lvm }
echo "=== Setting up Local Instance Store LVM ==="

command -v lvcreate >/dev/null || dnf install -y lvm2

install -m 0755 /dev/stdin /usr/local/sbin/setup-local-lvm.sh <<'SETUP_LOCAL_LVM'
#!/bin/bash
set -e

VG_NAME="${local_lvm_vg_name}"
LV_NAME="${local_lvm_lv_name}"
MOUNT_POINT="${local_lvm_mount}"
FS_TYPE="${local_lvm_fs}"
STRIPE_KB="${local_lvm_stripe_kb}"

log() { echo "[local-lvm] $*"; }

LOCAL_DISKS=()
for sys_path in /sys/block/nvme*n1; do
  [ -e "$sys_path" ] || continue
  model=$(cat "$sys_path/device/model" 2>/dev/null | xargs)
  case "$model" in
    *"Instance Storage"*) LOCAL_DISKS+=("/dev/$(basename "$sys_path")") ;;
  esac
done

if [ $${#LOCAL_DISKS[@]} -eq 0 ]; then
  log "No Instance Store NVMe disks detected; skipping"
  exit 0
fi
log "Detected $${#LOCAL_DISKS[@]} local NVMe disk(s): $${LOCAL_DISKS[*]}"

mkdir -p "$MOUNT_POINT"

if mountpoint -q "$MOUNT_POINT"; then
  log "$MOUNT_POINT already mounted"
  exit 0
fi

if vgs "$VG_NAME" >/dev/null 2>&1; then
  log "VG $VG_NAME already exists, activating and mounting"
  vgchange -ay "$VG_NAME"
  mount -o noatime,nodiratime,discard "/dev/$VG_NAME/$LV_NAME" "$MOUNT_POINT"
  exit 0
fi

log "Building $VG_NAME across $${#LOCAL_DISKS[@]} disk(s)"
for d in "$${LOCAL_DISKS[@]}"; do
  wipefs -a "$d" || true
  pvcreate -ff -y "$d"
done

vgcreate "$VG_NAME" "$${LOCAL_DISKS[@]}"

if [ $${#LOCAL_DISKS[@]} -gt 1 ]; then
  lvcreate -y -i "$${#LOCAL_DISKS[@]}" -I "$STRIPE_KB" -l 100%FREE -n "$LV_NAME" "$VG_NAME"
else
  lvcreate -y -l 100%FREE -n "$LV_NAME" "$VG_NAME"
fi

case "$FS_TYPE" in
  xfs)  mkfs.xfs -f "/dev/$VG_NAME/$LV_NAME" ;;
  ext4) mkfs.ext4 -F "/dev/$VG_NAME/$LV_NAME" ;;
  *)    log "Unsupported FS: $FS_TYPE"; exit 1 ;;
esac

mount -o noatime,nodiratime,discard "/dev/$VG_NAME/$LV_NAME" "$MOUNT_POINT"
chmod 1777 "$MOUNT_POINT"
log "Mounted /dev/$VG_NAME/$LV_NAME at $MOUNT_POINT"
df -h "$MOUNT_POINT"
SETUP_LOCAL_LVM

cat > /etc/systemd/system/setup-local-lvm.service <<'UNIT'
[Unit]
Description=Initialize and mount local NVMe Instance Store LVM
DefaultDependencies=no
After=local-fs-pre.target systemd-udev-settle.service
Before=local-fs.target kubelet.service containerd.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-local-lvm.sh
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=local-fs.target
UNIT

systemctl daemon-reload
systemctl enable --now setup-local-lvm.service

if [ -b "/dev/${local_lvm_vg_name}/${local_lvm_lv_name}" ]; then
  LOCAL_SSD_TOTAL_BYTES=$(blockdev --getsize64 "/dev/${local_lvm_vg_name}/${local_lvm_lv_name}" 2>/dev/null || echo 0)
  LOCAL_SSD_TOTAL_GB=$(( LOCAL_SSD_TOTAL_BYTES / 1024 / 1024 / 1024 ))
fi
echo "Local SSD total: $${LOCAL_SSD_TOTAL_GB} GB"
echo "=== Local Instance Store LVM Setup Complete ==="
%{ else }
echo "Local Instance Store LVM disabled"
%{ endif }

# Lustre client for FSx Lustre
echo "=== Installing Lustre Client ==="
dnf install -y lustre-client
modprobe lustre || true

echo "=== Starting EKS Node Bootstrap ==="

NODE_LABEL_FLAGS=""
NODE_TAINT_FLAGS=""
LOCAL_SSD_LABELS=""
if [ "$${LOCAL_SSD_TOTAL_GB}" -gt 0 ]; then
  LOCAL_SSD_LABELS="local-ssd=true,local-ssd-size-gb=$${LOCAL_SSD_TOTAL_GB}"
fi

%{ if node_management == "self_managed" ~}
# Self-managed mode: EKS no longer injects the labels/taints that the EKS
# Managed Node Group API used to. Embed them in the kubelet command line
# via NodeConfig.spec.kubelet.flags. Combine the GPU-NG-specific labels
# (passed in from terraform) with any local-SSD labels detected above.
EXTRA_LABELS="${extra_node_labels}"
COMBINED_LABELS="$${EXTRA_LABELS}"
if [ -n "$${LOCAL_SSD_LABELS}" ]; then
  if [ -n "$${COMBINED_LABELS}" ]; then
    COMBINED_LABELS="$${COMBINED_LABELS},$${LOCAL_SSD_LABELS}"
  else
    COMBINED_LABELS="$${LOCAL_SSD_LABELS}"
  fi
fi
if [ -n "$${COMBINED_LABELS}" ]; then
  NODE_LABEL_FLAGS="--node-labels=$${COMBINED_LABELS}"
fi
%{ if node_taints != "" ~}
NODE_TAINT_FLAGS="--register-with-taints=${node_taints}"
%{ endif ~}
%{ else ~}
# Managed mode: EKS injects workload-type / gpu-instance-type / purchase-option
# labels and the nvidia.com/gpu taint via the NodeGroup API. We only need to
# write LOCAL_SSD-related labels here (everything else comes from EKS).
if [ -n "$${LOCAL_SSD_LABELS}" ]; then
  NODE_LABEL_FLAGS="--node-labels=$${LOCAL_SSD_LABELS}"
fi
%{ endif ~}

# ============================================================
# NodeConfig — pin SystemdCgroup=true via NodeConfig.containerd.config
# ============================================================
# Background: nodeadm's containerd config template (config2.template.toml)
# DOES set SystemdCgroup=true in [runtimes.<RuntimeName>.options], but the
# NVIDIA AMI's bootstrap path runs `nvidia-ctk runtime configure` afterwards
# which has been observed (on toolkit 1.19) to drop SystemdCgroup back to
# its default (false). Result on workload pods:
#   FailedCreatePodSandBox: expected cgroupsPath to be of format
#   "slice:prefix:name" for systemd cgroups
# because kubelet (systemd cgroup driver) and runc (cgroupfs) disagree.
#
# Fix: supply SystemdCgroup=true via NodeConfig's containerd.config. nodeadm
# merges this LAST, after both its own template and any nvidia-ctk overlay,
# so the final on-disk config always carries SystemdCgroup=true.
#
# We deliberately DO NOT touch:
#   - nvidia-container-runtime mode      → let toolkit 1.19's default jit-cdi
#                                          handle device injection
#   - enable_cdi flag in containerd      → AMI default for k8s 1.32+ is true
#                                          (eks-ami PR #2173) and required by
#                                          jit-cdi
#   - accept-nvidia-visible-devices-*    → not needed in jit-cdi path
# Earlier revisions of this file forced legacy mode + envvar workarounds,
# which actively BROKE workload pod driver injection on toolkit 1.19+.
mkdir -p /etc/eks/nodeadm.d
{
  echo "---"
  echo "apiVersion: node.eks.aws/v1alpha1"
  echo "kind: NodeConfig"
  echo "spec:"
  echo "  cluster:"
  echo "    name: ${cluster_name}"
  echo "    apiServerEndpoint: ${cluster_endpoint}"
  echo "    certificateAuthority: ${cluster_ca}"
  echo "    cidr: ${service_ipv4_cidr}"
  if [ -n "$${NODE_LABEL_FLAGS}" ] || [ -n "$${NODE_TAINT_FLAGS}" ]; then
    echo "  kubelet:"
    echo "    flags:"
    if [ -n "$${NODE_LABEL_FLAGS}" ]; then
      echo "      - \"$${NODE_LABEL_FLAGS}\""
    fi
    if [ -n "$${NODE_TAINT_FLAGS}" ]; then
      echo "      - \"$${NODE_TAINT_FLAGS}\""
    fi
  fi
  echo "  containerd:"
  echo "    config: |"
  echo "      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.nvidia.options]"
  echo "      SystemdCgroup = true"
} > /etc/eks/nodeadm.d/nodeconfig.yaml

echo "NodeConfig written"
cat /etc/eks/nodeadm.d/nodeconfig.yaml

nodeadm init --config-source file:///etc/eks/nodeadm.d/nodeconfig.yaml

# ============================================================
# Force containerd + kubelet to reload config
# ============================================================
# nodeadm's EnsureRunning() uses systemd StartUnit which is a no-op when
# containerd is already running (enabled at boot). The freshly-written
# /etc/containerd/config.toml — including the NodeConfig.containerd.config
# overlay above (SystemdCgroup=true) — therefore never gets loaded; the
# in-memory config remains the boot-time default with SystemdCgroup unset.
# Symptom: pod sandboxes are created with cgroupfs-format cgroupsPath and
# fail with:
#   runc create failed: expected cgroupsPath to be of format
#   "slice:prefix:name" for systemd cgroups
#
# Fix landed upstream as awslabs/amazon-eks-ami#2705 (StartDaemon →
# RestartDaemon) but the patched nodeadm only ships in AMIs released
# after 2026-05-13. Until our pinned AMI carries the fix, force the
# reload here. kubelet must follow because its CRI runtime info is
# cached and would otherwise stay tied to the old containerd PID.
systemctl restart containerd
systemctl restart kubelet

# ============================================================
# EFA userspace (libfabric-aws + openmpi5-aws)
# ============================================================
%{ if install_efa_userspace }
if [ ! -x /opt/amazon/efa/bin/fi_info ]; then
  # Pin a specific installer version (e.g. "1.48.0") so node bringup is
  # reproducible. Empty efa_installer_version falls back to "latest" —
  # convenient for tracking but breaks reproducibility across reboots.
  EFA_INSTALLER_TARBALL="aws-efa-installer-${ efa_installer_version != "" ? efa_installer_version : "latest" }.tar.gz"
  echo "=== Installing EFA userspace ($EFA_INSTALLER_TARBALL) ==="
  ( cd /tmp && \
    curl -fsSLO "https://efa-installer.amazonaws.com/$EFA_INSTALLER_TARBALL" && \
    tar -xf "$EFA_INSTALLER_TARBALL" && \
    cd aws-efa-installer && \
    ./efa_installer.sh -y --skip-kmod 2>&1 | tail -30 ) || \
    echo "WARN: efa_installer failed; containers with their own libfabric will still work"
  if [ -x /opt/amazon/efa/bin/fi_info ]; then
    echo "EFA userspace installed at /opt/amazon/efa/"
    /opt/amazon/efa/bin/fi_info --version 2>&1 | head -1 || true
  fi
fi
%{ endif }

systemctl enable kubelet containerd

echo "=== GPU Node Bootstrap Complete ==="

--==BOUNDARY==--
