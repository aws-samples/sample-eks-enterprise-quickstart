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

  echo "Copying containerd data (including pre-cached pause image) from AMI..."
  rsync -aHAX /var/lib/containerd/ /mnt/runtime/containerd/ || true

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

  systemctl start containerd
fi

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
