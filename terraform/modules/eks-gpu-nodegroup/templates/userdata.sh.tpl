MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: text/cloud-boothook; charset="us-ascii"

#!/bin/bash
# LVM Setup + EKS Bootstrap for GPU nodes
set -ex

exec > >(tee /var/log/gpu-node-bootstrap.log)
exec 2>&1

# g7 (10de:2c3a) open-kmod fixup: the AMI's nvidia-open supported-devices
# allowlist is missing the RTX PRO 4500 Server Edition PCI ID, so the
# proprietary kmod gets loaded — Blackwell requires the open kmod and all
# GPUs fail with RmInitAdapter 0x22:0x56:897. Appending the ID here lets
# the AMI's own nvidia-kmod-load.service (After=network-online, i.e. always
# after this boothook) pick the open kmod itself. Auto no-op once the AMI
# list is fixed upstream (awslabs/amazon-eks-ami#2768); non-g7 instance
# types skip the whole block via the lspci gate.
# ⚠️ Never `systemctl start` a service that is After=network-online from a
# boothook — network-online waits for cloud-init, which waits for this
# script: three-way deadlock, the instance never finishes booting.
echo "=== NVIDIA open-kmod fixup (g7 / 2C3A) ==="
SUPPORTED_LIST=$(ls /etc/eks/nvidia-open-supported-devices-*.txt 2>/dev/null | head -1)
if [ -n "$SUPPORTED_LIST" ] && lspci -n -d 10de: 2>/dev/null | grep -qi "2c3a"; then
  grep -qi "^0x2C3A" "$SUPPORTED_LIST" || \
    echo "0x2C3A  NVIDIA RTX PRO 4500 Blackwell" >> "$SUPPORTED_LIST"
  REBOOT_MARKER=/var/lib/nvidia-open-fixup-rebooted
  if lsmod | grep -q "^nvidia " && modinfo nvidia 2>/dev/null | grep -q "^license:.*NVIDIA$"; then
    if [ ! -f "$REBOOT_MARKER" ]; then
      echo "Proprietary kmod on Blackwell — one-shot reboot to reload as nvidia-open"
      touch "$REBOOT_MARKER"
      shutdown -r now
      exit 0
    else
      echo "ERROR: proprietary kmod still loaded after fixup reboot — manual intervention needed"
    fi
  fi
fi

echo "=== Starting GPU Node LVM Setup ==="

# containerd MUST start exactly once, on the final LV. The AMI's containerd
# starts on the root volume at boot; the previous flow stopped it (without
# waiting for boltdb to flush), rsynced a moving content store with errors
# swallowed (|| true), umounted without sync, then started it again. That race
# left metadata.db referencing blobs whose files never landed on EBS -> a
# minority of nodes hit "blob not found" / ImagePullBackOff (DaemonSets, which
# schedule the instant the node is Ready, are the ones that land in the window).
# Mask containerd up front so it never starts on the root volume, migrate
# fail-fast + synced, then unmask. (The SystemdCgroup reload below issues the
# single start on /var/lib/containerd via `systemctl restart containerd`.)
echo "Masking containerd to prevent premature start on the root volume..."
systemctl stop containerd 2>/dev/null || true
systemctl mask containerd
# Safety net: under `set -e`, ANY failure between here and the explicit unmask
# below would otherwise leave containerd masked (a symlink to /dev/null) — and
# a masked unit can't be started, so nodeadm-run.service's EnsureRunning fails
# and the node never joins. This EXIT trap guarantees containerd is unmasked no
# matter where the script aborts. (The explicit unmask on the happy path is
# kept; this is idempotent belt-and-suspenders.)
trap 'systemctl unmask containerd 2>/dev/null || true' EXIT

# Wait for containerd to actually exit before touching its data dir.
for i in $(seq 1 30); do
  pgrep -x containerd >/dev/null || { echo "containerd fully stopped"; break; }
  echo "Waiting for containerd to stop... ($i/30)"
  sleep 1
done
sync

${ebs_data_disk_detect_snippet}

echo "Waiting for EBS data disk..."
DISK=$(detect_ebs_data_disk 60) || {
  echo "ERROR: No EBS data disk found after 60 seconds"
  echo "Available disks:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
  # Unmask so the node can still join (containerd runs on the root volume).
  systemctl unmask containerd
  systemctl start containerd
  exit 1
}
echo "Found EBS data disk: $DISK"

if vgs vg_data &>/dev/null; then
  echo "LVM already configured (reboot scenario), mounting..."
  mount /dev/vg_data/lv_containerd /var/lib/containerd || true
else
  dnf install -y lvm2 rsync
  pvcreate "$DISK"
  vgcreate vg_data "$DISK"
  lvcreate -l 100%VG -n lv_containerd vg_data
  mkfs.xfs /dev/vg_data/lv_containerd

  mkdir -p /mnt/runtime/containerd
  mount /dev/vg_data/lv_containerd /mnt/runtime/containerd

  # fail-fast: a partial copy must NOT survive. --delete keeps the target clean.
  # On ANY rsync error we must NOT continue onto an empty LV: AL2023 EKS AMIs
  # (built after 2024-11-12, awslabs/amazon-eks-ami#2000 — all K8s versions on
  # AL2023, not just 1.31) pre-cache the pause image and pin
  # `sandbox_image = localhost/kubernetes/pause`, a LOCAL reference that CANNOT
  # be re-pulled from any registry. Booting containerd on an empty store would
  # reproduce awslabs/amazon-eks-ami#2122 (pause pull -> 127.0.0.1:443 refused,
  # node never joins). So on failure we ABANDON the data-disk migration and keep
  # containerd on the AMI's root-volume /var/lib/containerd (pre-cache intact):
  # degraded (containerd data not on the LV) but the node still joins.
  if rsync -aHAX --delete /var/lib/containerd/ /mnt/runtime/containerd/; then
    # Force blob data onto EBS before swapping the mount (XFS may have committed
    # metadata while blob file data is still in page cache).
    sync
    sleep 2

    umount /mnt/runtime/containerd
    mount /dev/vg_data/lv_containerd /var/lib/containerd

    grep -q "lv_containerd" /etc/fstab || \
      echo "/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2" >> /etc/fstab
  else
    echo "ERROR: rsync failed; abandoning data-disk migration to preserve the"
    echo "AMI's pre-cached pause image. containerd stays on the root volume."
    umount /mnt/runtime/containerd || true
    # Tear down the half-built LV so a reboot doesn't remount an empty volume
    # over the (intact) root-volume /var/lib/containerd.
    lvremove -f /dev/vg_data/lv_containerd 2>/dev/null || true
    vgremove -f vg_data 2>/dev/null || true
    pvremove -f "$DISK" 2>/dev/null || true
  fi
fi

# /var/lib/containerd is now the LV — unmask so the SystemdCgroup reload below
# (and nodeadm-run.service) can start containerd on the final mount.
echo "Unmasking containerd"
systemctl unmask containerd

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

# Lustre client for FSx Lustre. Best-effort: this MUST NOT gate the containerd
# start below — under `set -e` an unguarded failure here would abort the
# boothook before `systemctl restart containerd`, leaving containerd
# unmasked-but-stopped and the node NotReady.
echo "=== Installing Lustre Client ==="
dnf install -y lustre-client 2>&1 | tail -5 || echo "WARN: lustre-client install failed"
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
#
# Guard both restarts: this is the ONLY start of containerd on the happy path
# (the LVM block above no longer starts it in-line), and the script runs under
# `set -e`. A bare `systemctl restart` that fails would abort the boothook here,
# skipping the kubelet restart and EFA install and leaving containerd stopped
# (node NotReady). On restart failure, fall back to a plain start so containerd
# is at least running, and never let it abort the rest of bringup.
if ! systemctl restart containerd; then
  echo "WARN: containerd restart failed; attempting plain start"
  systemctl start containerd || echo "ERROR: containerd failed to start"
fi
if ! systemctl restart kubelet; then
  echo "WARN: kubelet restart failed; attempting plain start"
  systemctl start kubelet || echo "ERROR: kubelet failed to start"
fi

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
