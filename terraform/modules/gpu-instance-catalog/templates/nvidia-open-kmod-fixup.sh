# g7 (10de:2c3a) open-kmod fixup: the AMI's nvidia-open supported-devices
# allowlist is missing the RTX PRO 4500 Server Edition PCI ID, so the
# proprietary kmod gets loaded — Blackwell requires the open kmod and all
# GPUs fail with RmInitAdapter 0x22:0x56:897. Appending the ID here lets
# the AMI's own nvidia-kmod-load.service (After=network-online, i.e. always
# after this boothook) pick the open kmod itself; non-g7 instance types skip
# the whole block via the lspci gate.
#
# UPSTREAM STATUS (checked 2026-08-20): awslabs/amazon-eks-ami#2768 was
# closed 2026-07-22 WITHOUT adding the ID to the 580 list. 0x2C3A ships only
# in nvidia-open-supported-devices-595.txt, and AWS stated they "don't plan
# to look into support for the same on 580". The default EKS NVIDIA AMI is
# still 580 (v20260810 = 580.159.03, v20260818 = 580.178.04) and SSM
# publishes no 595 variant, so this block does NOT auto-no-op today — it is
# load-bearing for every g7 node launched on the default AMI. Empirically
# the 580 open kmod does drive this GPU (verified on g7.48xlarge / EKS 1.34:
# 8 GPUs, open kmod, Dual MIT/GPL), but that combination is not AWS-
# supported. AWS's supported path is a custom 595 AMI — see
# awslabs/amazon-eks-ami doc/usage/g7-ami.md, then point
# var.gpu_custom_ami_id at it. NOTE 595 is incompatible with P3 / P3dn /
# G6f, so a 595 AMI cannot serve a mixed fleet; keep those on 580 in a
# separate nodegroup. The block self-disables once a default AMI ships
# driver >= 595 (its allowlist already contains 0x2C3A).
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
