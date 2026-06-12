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
