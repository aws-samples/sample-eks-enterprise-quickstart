# Self-contained render fixture for nodegroup user-data templates.
#
# templatefile() is a pure function — no AWS provider, data sources, or
# credentials are needed, so this runs in CI with zero cloud access. The
# accompanying *.tftest.hcl files assert the AL2023 bootstrap contract:
# NodeConfig MUST be delivered as a standalone `application/node.eks.aws`
# MIME part (parsed by the AMI's nodeadm-config.service), NOT hand-written
# in a cloud-boothook + manual `nodeadm init` (which fails with "no config
# in chain" because the boothook runs AFTER nodeadm-config.service).

variable "node_management" {
  type    = string
  default = "self_managed"
}

locals {
  system_userdata = templatefile("${path.module}/../../modules/eks-system-nodegroup/templates/userdata.sh.tpl", {
    cluster_name                 = "test-cluster"
    cluster_endpoint             = "https://ABC.gr7.us-east-1.eks.amazonaws.com"
    cluster_ca                   = "LS0tLS1CRUdJTg=="
    service_ipv4_cidr            = "172.20.0.0/16"
    node_management              = var.node_management
    node_labels                  = "workload-type=eks-utils"
    ebs_data_disk_detect_snippet = "detect_ebs_data_disk() { echo /dev/xvdb; }"
  })

  gpu_userdata = templatefile("${path.module}/../../modules/eks-gpu-nodegroup/templates/userdata.sh.tpl", {
    cluster_name                 = "test-cluster"
    cluster_endpoint             = "https://ABC.gr7.us-east-1.eks.amazonaws.com"
    cluster_ca                   = "LS0tLS1CRUdJTg=="
    service_ipv4_cidr            = "172.20.0.0/16"
    enable_local_lvm             = true
    local_lvm_vg_name            = "vg_local"
    local_lvm_lv_name            = "lv_scratch"
    local_lvm_mount              = "/mnt/scratch"
    local_lvm_fs                 = "xfs"
    local_lvm_stripe_kb          = "256"
    install_efa_userspace        = true
    efa_installer_version        = "1.48.0"
    ebs_data_disk_detect_snippet = "detect_ebs_data_disk() { echo /dev/xvdb; }"
    node_management              = var.node_management
    extra_node_labels            = var.node_management == "self_managed" ? "workload-type=gpu,gpu-instance-type=p5.48xlarge,purchase-option=od" : ""
    node_taints                  = var.node_management == "self_managed" ? "nvidia.com/gpu=true:NoSchedule" : ""
  })

  # The body of the cloud-boothook part only — i.e. everything BEFORE the
  # NodeConfig MIME part begins. Used to assert the boothook contains no
  # real `nodeadm init` call. We split on the node.eks.aws part header so
  # the explanatory comment inside that part (which mentions `nodeadm init`)
  # doesn't produce false positives.
  system_boothook = element(split("Content-Type: application/node.eks.aws", local.system_userdata), 0)
  gpu_boothook    = element(split("Content-Type: application/node.eks.aws", local.gpu_userdata), 0)

  # Karpenter EC2NodeClasses carry the SAME containerd content-store fix in
  # their inline userData. They are rendered the same way the eks-karpenter
  # module does (templatefile with CLUSTER_NAME + SSH_PUBLIC_KEY), then the LVM
  # boothook is extracted from spec.userData. Without this, 2 of the 4 fixed
  # provisioning paths would have no regression guard.
  karpenter_template_vars = {
    CLUSTER_NAME   = "test-cluster"
    SSH_PUBLIC_KEY = ""
  }
  x86_userdata      = yamldecode(templatefile("${path.module}/../../assets/karpenter/ec2nodeclass-x86.yaml", local.karpenter_template_vars)).spec.userData
  graviton_userdata = yamldecode(templatefile("${path.module}/../../assets/karpenter/ec2nodeclass-graviton.yaml", local.karpenter_template_vars)).spec.userData
  # The LVM boothook is the first cloud-boothook part; the second part (SSH key
  # injection) is split off so its body doesn't pollute the assertions.
  x86_boothook      = element(split("--==BOUNDARY==", local.x86_userdata), 1)
  graviton_boothook = element(split("--==BOUNDARY==", local.graviton_userdata), 1)
}

output "system_userdata" { value = local.system_userdata }
output "gpu_userdata" { value = local.gpu_userdata }
output "system_boothook" { value = local.system_boothook }
output "gpu_boothook" { value = local.gpu_boothook }

# Count of standalone NodeConfig MIME parts (must be exactly 1 each).
output "system_nodeconfig_part_count" {
  value = length(regexall("(?m)^Content-Type: application/node.eks.aws\\s*$", local.system_userdata))
}
output "gpu_nodeconfig_part_count" {
  value = length(regexall("(?m)^Content-Type: application/node.eks.aws\\s*$", local.gpu_userdata))
}

# Count of REAL manual `nodeadm init` invocations in the boothook (a line
# whose first non-space token is `nodeadm`). Comments (`# ... nodeadm init`)
# are excluded by the leading-whitespace-then-nodeadm anchor.
output "system_manual_nodeadm_init_count" {
  value = length(regexall("(?m)^[[:space:]]*nodeadm[[:space:]]+init", local.system_boothook))
}
output "gpu_manual_nodeadm_init_count" {
  value = length(regexall("(?m)^[[:space:]]*nodeadm[[:space:]]+init", local.gpu_boothook))
}

# --- containerd content-store integrity contract (blob-not-found regression) -
# The LVM migration must NOT race a running containerd. Each boothook must:
#   1. mask containerd up front (so it never starts on the root volume) AND
#      install an EXIT trap that unmasks it (so a `set -e` abort mid-migration
#      can't leave it permanently masked -> node never joins);
#   2. wait for the running containerd to exit before touching its data dir;
#   3. migrate the content store fail-fast (`if ! rsync ... --delete`), with NO
#      swallowed errors (no `rsync ... || true`, no `cp ... || true`);
#   4. `sync` between the rsync and the umount (force blob data onto EBS);
#   5. unmask afterwards so containerd starts exactly once on the LV.
# The counts/booleans below pin that shape across ALL FOUR provisioning paths
# (system + gpu .tpl, karpenter x86 + graviton inline userData) so the old race
# (stop||true -> rsync/cp||true -> umount -> start) can't silently return.
#
# Map of path-name => extracted boothook body, so each assertion is expressed
# once and applied to every path via the for-expressions below.
locals {
  _boothooks = {
    system   = local.system_boothook
    gpu      = local.gpu_boothook
    x86      = local.x86_boothook
    graviton = local.graviton_boothook
  }
}

# `systemctl mask containerd` present (real command line, not a comment).
output "mask_containerd_count" {
  value = { for k, b in local._boothooks : k => length(regexall("(?m)^[[:space:]]*systemctl[[:space:]]+mask[[:space:]]+containerd", b)) }
}
# `systemctl unmask containerd` present on the happy path.
output "unmask_containerd_count" {
  value = { for k, b in local._boothooks : k => length(regexall("(?m)^[[:space:]]*systemctl[[:space:]]+unmask[[:space:]]+containerd", b)) }
}
# An EXIT trap that unmasks containerd must exist — guarantees unmask is
# REACHABLE even if a migration command aborts the script under set -e.
output "unmask_trap_count" {
  value = { for k, b in local._boothooks : k => length(regexall("trap[^\n]*unmask containerd[^\n]*EXIT", b)) }
}
# The wait-for-exit loop (root cause #1: stopped-without-waiting) must exist.
output "wait_for_exit_count" {
  value = { for k, b in local._boothooks : k => length(regexall("pgrep[[:space:]]+-x[[:space:]]+containerd", b)) }
}
# Fail-fast migration form must be present (positive guard — removing the
# `if ! rsync ... ` form must fail CI, not just removing a `|| true`).
output "failfast_rsync_count" {
  value = { for k, b in local._boothooks : k => length(regexall("if[[:space:]]*![[:space:]]*rsync", b)) }
}
# NO swallowed copy errors: neither `rsync ... || true` NOR `cp ... || true`
# for the content-store copy (a cp||true revert is the original root cause #2).
output "swallow_copy_error_count" {
  value = { for k, b in local._boothooks : k => length(regexall("(rsync|cp)[^\n]*\\|\\|[[:space:]]*true", b)) }
}
# A `sync` must sit BETWEEN the rsync and the umount (root cause #3:
# umounted-without-sync). Ordering is checked, not just a raw count, so
# deleting the load-bearing pre-umount sync fails CI even though another sync
# (after the stop loop) remains.
output "sync_before_umount_count" {
  value = { for k, b in local._boothooks : k => length(regexall("rsync[\\s\\S]*\n[[:space:]]*sync[[:space:]]*\n[\\s\\S]*umount", b)) }
}
