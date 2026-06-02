data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_vpc" "main" {
  id = var.vpc_id
}

# =====================================================================
# VPC Endpoints (replaces 1_enable_vpc_dns.sh + 3_create_vpc_endpoints.sh)
# =====================================================================
module "vpc_endpoints" {
  source = "./modules/vpc-endpoints"

  cluster_name       = var.cluster_name
  vpc_id             = var.vpc_id
  vpc_cidr           = data.aws_vpc.main.cidr_block
  private_subnet_ids = var.private_subnet_ids
  endpoints_mode     = var.vpc_endpoints_mode
  region             = var.aws_region
}

# =====================================================================
# EKS control plane (replaces 4_install_eks_cluster.sh)
# =====================================================================
module "eks_cluster" {
  source = "./modules/eks-cluster"

  cluster_name                         = var.cluster_name
  k8s_version                          = var.k8s_version
  private_subnet_ids                   = var.private_subnet_ids
  public_subnet_ids                    = var.public_subnet_ids
  cluster_mode                         = var.cluster_mode
  public_access_cidrs                  = var.public_access_cidrs
  service_ipv4_cidr                    = var.service_ipv4_cidr
  kms_key_arn                          = var.kms_key_arn
  enable_deletion_protection           = var.enable_deletion_protection
  enable_irsa                          = var.enable_irsa
  extra_api_ingress_security_group_ids = var.extra_api_ingress_security_group_ids
  extra_api_ingress_cidrs              = var.extra_api_ingress_cidrs
  extra_cluster_admin_role_arns        = var.extra_cluster_admin_role_arns

  depends_on = [module.vpc_endpoints]
}

# =====================================================================
# System nodegroup (replaces 6_create_system_nodegroup.sh)
# =====================================================================
module "eks_system_nodegroup" {
  source = "./modules/eks-system-nodegroup"

  cluster_name              = module.eks_cluster.cluster_name
  k8s_version               = var.k8s_version
  cluster_endpoint          = module.eks_cluster.cluster_endpoint
  cluster_ca                = module.eks_cluster.cluster_certificate_authority_data
  cluster_security_group_id = module.eks_cluster.cluster_security_group_id
  service_ipv4_cidr         = module.eks_cluster.service_ipv4_cidr
  subnet_ids                = var.private_subnet_ids
  vpc_id                    = var.vpc_id
  instance_type             = var.system_node_instance_type
  root_volume_size          = var.system_node_root_volume_size
  data_volume_size          = var.system_node_data_volume_size
  desired_capacity          = var.system_node_desired_capacity
  min_size                  = var.system_node_min_size
  max_size                  = var.system_node_max_size
  node_label_key            = var.system_node_label_key
  node_label_value          = var.system_node_label_value
  ec2_key_name              = var.ec2_key_name
  region                    = var.aws_region

  node_management         = var.node_management
  asg_suspended_processes = var.asg_suspended_processes
  extra_asg_tags          = var.extra_asg_tags

  depends_on = [module.eks_cluster]
}

# =====================================================================
# Core addons: CoreDNS, Metrics Server, Cluster Autoscaler, ALB Controller
# (replaces 7_install_eks_addon.sh)
# =====================================================================
module "eks_addons" {
  source = "./modules/eks-addons"

  cluster_name                     = module.eks_cluster.cluster_name
  vpc_id                           = var.vpc_id
  region                           = var.aws_region
  k8s_version                      = var.k8s_version
  install_cluster_autoscaler       = var.install_cluster_autoscaler
  cluster_autoscaler_version       = var.cluster_autoscaler_version
  cluster_autoscaler_chart_version = var.cluster_autoscaler_chart_version
  alb_controller_chart_version     = var.alb_controller_chart_version
  alb_controller_app_version       = var.alb_controller_app_version
  alb_controller_iam_policy_source = var.alb_controller_iam_policy_source
  helm_replace_existing            = var.helm_replace_existing
  system_node_label_key            = var.system_node_label_key
  system_node_label_value          = var.system_node_label_value

  depends_on = [module.eks_system_nodegroup]
}

# =====================================================================
# CSI drivers (replaces option_install_csi_drivers.sh)
# =====================================================================
module "eks_csi_drivers" {
  source = "./modules/eks-csi-drivers"

  cluster_name            = module.eks_cluster.cluster_name
  region                  = var.aws_region
  k8s_version             = var.k8s_version
  install_efs             = var.install_efs_csi
  install_fsx             = var.install_fsx_csi
  install_s3              = var.install_s3_csi
  s3_bucket_arns          = var.s3_csi_bucket_arns
  system_node_label_key   = var.system_node_label_key
  system_node_label_value = var.system_node_label_value

  depends_on = [module.eks_addons]
}

# =====================================================================
# Karpenter (optional; replaces option_install_karpenter.sh)
# =====================================================================
module "eks_karpenter" {
  source = "./modules/eks-karpenter"
  count  = var.install_karpenter ? 1 : 0

  cluster_name              = module.eks_cluster.cluster_name
  cluster_endpoint          = module.eks_cluster.cluster_endpoint
  cluster_security_group_id = module.eks_cluster.cluster_security_group_id
  region                    = var.aws_region
  karpenter_version         = var.karpenter_version
  ssh_public_key            = var.karpenter_ssh_public_key
  helm_replace_existing     = var.helm_replace_existing
  system_node_label_key     = var.system_node_label_key
  system_node_label_value   = var.system_node_label_value
  private_subnet_ids        = var.private_subnet_ids

  depends_on = [module.eks_addons]
}

# =====================================================================
# GPU nodegroups — AWS infra (IAM/SG/LT/NodeGroup) only
# =====================================================================
module "eks_gpu_nodegroup" {
  source = "./modules/eks-gpu-nodegroup"
  count  = var.install_gpu_nodegroups ? 1 : 0

  cluster_name              = module.eks_cluster.cluster_name
  cluster_endpoint          = module.eks_cluster.cluster_endpoint
  cluster_ca                = module.eks_cluster.cluster_certificate_authority_data
  cluster_security_group_id = module.eks_cluster.cluster_security_group_id
  service_ipv4_cidr         = module.eks_cluster.service_ipv4_cidr
  vpc_id                    = var.vpc_id
  region                    = var.aws_region
  k8s_version               = var.k8s_version
  gpu_ami_release_version   = var.gpu_ami_release_version
  gpu_custom_ami_id         = var.gpu_custom_ami_id

  private_subnet_ids = var.private_subnet_ids
  gpu_nodegroups     = var.gpu_nodegroups

  root_volume_size      = var.gpu_node_root_volume_size
  data_volume_size      = var.gpu_node_data_volume_size
  install_efa_userspace = var.gpu_install_efa_userspace
  efa_installer_version = var.gpu_efa_installer_version
  enable_local_lvm      = var.gpu_enable_local_lvm
  local_lvm_mount       = var.gpu_local_lvm_mount
  local_lvm_fs          = var.gpu_local_lvm_fs
  ec2_key_name          = var.ec2_key_name

  node_management         = var.node_management
  asg_suspended_processes = var.asg_suspended_processes
  extra_asg_tags          = var.extra_asg_tags

  depends_on = [module.eks_addons]
}

# =====================================================================
# GPU K8s stack — device-plugin / EFA / monitoring / Operator
# =====================================================================
# Independent of install_gpu_nodegroups so the stack can be iterated
# without re-applying nodegroup infra. Mode is mutually exclusive
# (standard | operator) — see modules/eks-gpu-stack/main.tf for the
# conflict points the dispatch prevents.
module "eks_gpu_stack" {
  source = "./modules/eks-gpu-stack"
  count  = var.install_gpu_stack ? 1 : 0

  region                = var.aws_region
  helm_replace_existing = var.helm_replace_existing

  stack_mode = var.gpu_stack_mode

  install_efa_device_plugin = var.install_efa_device_plugin
  efa_device_plugin_version = var.efa_device_plugin_version
  efa_device_plugin_image   = var.efa_device_plugin_image

  # standard mode
  nvidia_device_plugin_version  = var.nvidia_device_plugin_version
  nvidia_device_plugin_repo     = var.nvidia_device_plugin_repo
  install_dcgm_exporter         = var.install_dcgm_exporter
  dcgm_exporter_version         = var.dcgm_exporter_version
  install_node_problem_detector = var.install_node_problem_detector
  node_problem_detector_version = var.node_problem_detector_version
  install_gpu_health_check      = var.install_gpu_health_check

  # operator mode
  gpu_operator_version         = var.gpu_operator_version
  gpu_operator_namespace       = var.gpu_operator_namespace
  gpu_operator_driver_enabled  = var.gpu_operator_driver_enabled
  gpu_operator_toolkit_enabled = var.gpu_operator_toolkit_enabled
  gpu_operator_mofed_enabled   = var.gpu_operator_mofed_enabled
  gpu_operator_mig_strategy    = var.gpu_operator_mig_strategy

  # Wait for nodegroup module so DaemonSets become Ready when nodes join.
  # When install_gpu_nodegroups=false, callers are expected to provide
  # GPU nodes another way (manual NG, Karpenter NodePool, etc.).
  depends_on = [
    module.eks_addons,
    module.eks_gpu_nodegroup,
  ]
}
