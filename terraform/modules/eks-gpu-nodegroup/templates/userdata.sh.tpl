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

echo "=== Local Instance Store LVM Setup Complete ==="
%{ else }
echo "Local Instance Store LVM disabled"
%{ endif }

# Lustre client for FSx Lustre
echo "=== Installing Lustre Client ==="
dnf install -y lustre-client
modprobe lustre || true

echo "=== boothook complete; NodeConfig is delivered as a separate node.eks.aws MIME part ==="

# ============================================================
# Force containerd + kubelet to reload config (SystemdCgroup=true)
# ============================================================
# NodeConfig (including the containerd.config overlay that pins
# SystemdCgroup=true) is parsed by the AMI's nodeadm-config.service from the
# application/node.eks.aws MIME part below, BEFORE this boothook runs (the
# systemd unit fires at ~t=5s, cloud-init boothooks at ~t=6s). nodeadm writes
# /etc/containerd/config.toml but its EnsureRunning() uses systemd StartUnit,
# a no-op when containerd is already running (enabled at boot) — so the fresh
# config (SystemdCgroup=true) is on disk but never loaded into the running
# daemon. Background: nodeadm's template DOES set SystemdCgroup=true, but the
# NVIDIA AMI runs `nvidia-ctk runtime configure` afterwards which (on toolkit
# 1.19) drops it back to false; our overlay merges last so the on-disk config
# is correct. Symptom if not reloaded — workload pods fail with:
#   FailedCreatePodSandBox / runc create failed: expected cgroupsPath to be of
#   format "slice:prefix:name" for systemd cgroups
# because kubelet (systemd driver) and runc (cgroupfs) disagree.
#
# Fix landed upstream as awslabs/amazon-eks-ami#2705 (StartDaemon →
# RestartDaemon) but only ships in AMIs released after 2026-05-13. Until our
# pinned AMI carries the fix, force the reload here. kubelet must follow
# because its CRI runtime info is cached and would otherwise stay tied to the
# old containerd PID.
#
# We deliberately DO NOT touch nvidia-container-runtime mode / enable_cdi /
# accept-nvidia-visible-devices — toolkit 1.19's jit-cdi default handles
# device injection; forcing legacy mode BREAKS workload pod driver injection.
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

echo "=== GPU Node Bootstrap Complete ==="

--==BOUNDARY==
Content-Type: application/node.eks.aws

# AL2023 EKS bootstrap. nodeadm-config.service (shipped in the AMI) parses
# THIS part from user-data, writes /run/eks/nodeadm/config.json, then
# nodeadm-run.service starts kubelet. Do NOT hand-write NodeConfig + call
# `nodeadm init` in the boothook: nodeadm-config.service runs before
# cloud-init boothooks, fails with "no config in chain", and that failure
# hard-blocks nodeadm-run (Requires=) so kubelet never starts.
#
# SystemdCgroup=true is pinned via containerd.config (nodeadm merges it LAST,
# after its own template and the NVIDIA AMI's nvidia-ctk overlay). The
# boothook above force-restarts containerd+kubelet so this on-disk config is
# actually loaded into the running daemon.
%{ if node_management == "self_managed" ~}
# self_managed: EKS no longer injects labels/taints via the NodeGroup API, so
# embed them in kubelet flags here. (managed mode omits this block — EKS
# injects workload-type / gpu-instance-type / purchase-option + the
# nvidia.com/gpu taint itself.)
%{ endif ~}
---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${cluster_name}
    apiServerEndpoint: ${cluster_endpoint}
    certificateAuthority: ${cluster_ca}
    cidr: ${service_ipv4_cidr}
%{ if node_management == "self_managed" ~}
  kubelet:
    flags:
%{ if extra_node_labels != "" ~}
      - "--node-labels=${extra_node_labels}"
%{ endif ~}
%{ if node_taints != "" ~}
      - "--register-with-taints=${node_taints}"
%{ endif ~}
%{ endif ~}
  containerd:
    config: |
      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.nvidia.options]
      SystemdCgroup = true

--==BOUNDARY==--
