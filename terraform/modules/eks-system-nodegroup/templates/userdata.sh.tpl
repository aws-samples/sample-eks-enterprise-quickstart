MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: text/cloud-boothook; charset="us-ascii"

#!/bin/bash
# LVM Setup - executed before EKS bootstrap
set -ex

exec > >(tee /var/log/lvm-setup.log)
exec 2>&1

echo "=== Starting LVM Setup ==="

# containerd MUST start exactly once, on the final LV. The AMI's containerd
# starts on the root volume at boot; the previous flow stopped it (without
# waiting for boltdb to flush), rsynced a moving content store with errors
# swallowed (|| true), umounted without sync, then started it again. That race
# left metadata.db referencing blobs whose files never landed on EBS -> a
# minority of nodes hit "blob not found" / ImagePullBackOff. Mask containerd up
# front so it never starts on the root volume, migrate fail-fast + synced, then
# unmask so nodeadm-run.service starts it once on /var/lib/containerd (the LV).
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
  echo "Installing lvm2 and rsync..."
  dnf install -y lvm2 rsync

  echo "Creating LVM on $DISK..."
  pvcreate "$DISK"
  vgcreate vg_data "$DISK"
  lvcreate -l 100%VG -n lv_containerd vg_data
  mkfs.xfs /dev/vg_data/lv_containerd

  echo "Mounting and migrating containerd data..."
  mkdir -p /mnt/runtime/containerd
  mount /dev/vg_data/lv_containerd /mnt/runtime/containerd

  # fail-fast: a partial copy must NOT survive. --delete keeps the target
  # clean; on ANY rsync error we wipe the target and let containerd start from
  # an empty store (images are re-pulled at runtime) rather than from a corrupt
  # one. No more "|| true" silently keeping a half-copied content store.
  echo "Copying containerd data (including pre-cached pause image) from AMI..."
  if ! rsync -aHAX --delete /var/lib/containerd/ /mnt/runtime/containerd/; then
    echo "ERROR: rsync failed; wiping target to avoid a partial/corrupt content store"
    rm -rf /mnt/runtime/containerd/* /mnt/runtime/containerd/.[!.]* 2>/dev/null || true
  fi

  # Force blob data onto EBS before swapping the mount (XFS may have committed
  # metadata while blob file data is still in page cache).
  echo "Syncing migrated data to disk..."
  sync
  sleep 2

  echo "Unmounting temporary directory"
  umount /mnt/runtime/containerd

  echo "Mounting LV to final destination: /var/lib/containerd"
  mount /dev/vg_data/lv_containerd /var/lib/containerd

  grep -q "lv_containerd" /etc/fstab || \
    echo "/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2" >> /etc/fstab

  echo "LVM setup completed successfully"
  df -h /var/lib/containerd
  vgs
  lvs
fi

# /var/lib/containerd is now the LV — unmask so nodeadm-run.service starts
# containerd exactly once, on the final mount.
echo "Unmasking containerd; nodeadm-run.service will start it on the LV"
systemctl unmask containerd

echo "=== LVM Setup Complete ==="

# Lustre client for FSx Lustre CSI driver (best-effort).
echo "=== Installing Lustre client (for FSx Lustre CSI) ==="
dnf install -y lustre-client 2>&1 | tail -5 || echo "WARN: lustre-client install failed"
modprobe lustre || true

echo "=== boothook complete; NodeConfig is delivered as a separate node.eks.aws MIME part ==="

--==BOUNDARY==
Content-Type: application/node.eks.aws

# AL2023 EKS bootstrap. nodeadm-config.service (shipped in the AMI) parses
# THIS part from user-data, writes /run/eks/nodeadm/config.json, then
# nodeadm-run.service starts kubelet. Do NOT hand-write NodeConfig + call
# `nodeadm init` in the boothook: nodeadm-config.service runs before
# cloud-init boothooks, fails with "no config in chain", and that failure
# hard-blocks nodeadm-run (Requires=) so kubelet never starts.
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
      - "--node-labels=${node_labels}"
%{ endif ~}

--==BOUNDARY==--
