# Root-stack zero-diff guard for the 1.37 default: an existing 1.35
# deployment with unchanged tfvars (k8s_version / karpenter_version omitted
# or pinned to the old defaults) must plan exactly as before: control plane
# 1.35 and the Karpenter chart actually pinned by module.eks_karpenter
# 1.12.1. Only the module.eks_cluster.k8s_version assertion of
# existing_135_pinned also works on the pre-change main branch (where 1.35 /
# 1.12.1 were the variable defaults); its Karpenter assertion reads the
# eks-karpenter output karpenter_version added by this change, so it is not a
# comparison against main. The Karpenter 1.12.1 zero diff rests on the golden
# controller-policy hash (verified to match main) and the module's version
# pin. The other runs depend on modules/k8s-version and its check. The EKS lookup of modules/k8s-version is mocked as
# "cluster test-cluster exists on 1.35" unless a run overrides it.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16", enable_dns_support = true, enable_dns_hostnames = true }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = {
      supported_architectures    = ["x86_64"]
      instance_storage_supported = true
      default_vcpus              = 192
      gpus                       = [{ count = 8, manufacturer = "NVIDIA", memory_size = 81920, name = "H100" }]
    }
  }
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v1.0.0-eksbuild.1" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_eks_clusters" {
    defaults = { names = ["test-cluster"] }
  }
  mock_data "aws_eks_cluster" {
    defaults = { version = "1.35" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      endpoint              = "https://ABC.gr7.us-west-2.eks.amazonaws.com"
      certificate_authority = [{ data = "LS0tLS1CRUdJTg==" }]
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-west-2.amazonaws.com/id/ABC" }] }]
    }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_security_group" {
    defaults = { id = "sg-0123456789abcdef0" }
  }
  mock_resource "aws_eks_node_group" {
    defaults = {
      resources = [{
        autoscaling_groups              = [{ name = "eks-mock-asg" }]
        remote_access_security_group_id = ""
      }]
    }
  }
  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:us-west-2:123456789012:mock"
      url = "https://sqs.us-west-2.amazonaws.com/123456789012/mock"
    }
  }
}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "time" {}
mock_provider "null" {}
mock_provider "tls" {}
mock_provider "cloudinit" {}
mock_provider "http" {
  mock_data "http" {
    defaults = { response_body = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

# Independent of the Kubernetes version; its subnet-AZ precondition cannot
# be satisfied by for_each mocks.
override_module {
  target = module.vpc_endpoints
  outputs = {
    endpoints_security_group_id = "sg-0aaaaaaaaaaaaaaaa"
    interface_endpoint_ids      = {}
    interface_endpoints_skipped = []
    s3_gateway_endpoint_id      = "vpce-0aaaaaaaaaaaaaaaa"
    s3_gateway_endpoint_skipped = false
  }
}

variables {
  cluster_name                     = "test-cluster"
  aws_region                       = "us-west-2"
  vpc_id                           = "vpc-12345678"
  private_subnet_ids               = ["subnet-11111111", "subnet-22222222"]
  public_subnet_ids                = ["subnet-33333333", "subnet-44444444"]
  alb_controller_iam_policy_source = "file"

  # Every k8s_version consumer is planned.
  install_karpenter      = true
  install_efs_csi        = true
  install_fsx_csi        = true
  install_s3_csi         = true
  s3_csi_bucket_arns     = ["arn:aws:s3:::my-bucket"]
  install_gpu_nodegroups = true
  gpu_nodegroups         = [{ gpu_type = "p5.48xlarge", purchase_option = "od" }]
}

# Existing 1.35 cluster, both versions omitted.
run "existing_135_omitted" {
  command = plan
  module {
    source = "../.."
  }
  # Advisory warning in a real plan (exit code unchanged). Not on main.
  expect_failures = [check.k8s_version_behind_default]
  assert {
    condition     = module.eks_cluster.k8s_version == "1.35"
    error_message = "control plane must stay on 1.35, got ${module.eks_cluster.k8s_version}."
  }
  assert {
    condition     = module.eks_karpenter[0].karpenter_version == "1.12.1"
    error_message = "Karpenter chart must stay on 1.12.1, got ${module.eks_karpenter[0].karpenter_version}."
  }
}

# Existing 1.35 cluster, old defaults pinned explicitly.
run "existing_135_pinned" {
  command = plan
  module {
    source = "../.."
  }
  variables {
    k8s_version       = "1.35"
    karpenter_version = "1.12.1"
  }
  assert {
    condition     = module.eks_cluster.k8s_version == "1.35"
    error_message = "control plane must stay on 1.35, got ${module.eks_cluster.k8s_version}."
  }
  assert {
    condition     = module.eks_karpenter[0].karpenter_version == "1.12.1"
    error_message = "Karpenter chart must stay on 1.12.1, got ${module.eks_karpenter[0].karpenter_version}."
  }
}

# --- After the 1.37-default change only ---------------------------------

run "existing_135_resolves_old_defaults" {
  command = plan
  module {
    source = "../.."
  }
  expect_failures = [check.k8s_version_behind_default]
  assert {
    condition     = module.k8s_version.k8s_version == "1.35" && module.k8s_version.karpenter_version == "1.12.1"
    error_message = "expected 1.35 / Karpenter 1.12.1"
  }
}

run "new_cluster_defaults_to_137" {
  command = plan
  module {
    source = "../.."
  }
  override_data {
    target = module.k8s_version.data.aws_eks_clusters.this
    values = { names = [] }
  }
  assert {
    condition     = module.eks_cluster.k8s_version == "1.37" && module.k8s_version.karpenter_version == "1.15.1"
    error_message = "new cluster: expected 1.37 / Karpenter 1.15.1, got ${module.eks_cluster.k8s_version} / ${module.k8s_version.karpenter_version}"
  }
  assert {
    condition     = module.eks_karpenter[0].karpenter_version == "1.15.1"
    error_message = "new cluster: Karpenter chart must be pinned to 1.15.1, got ${module.eks_karpenter[0].karpenter_version}."
  }
}

run "invalid_k8s_version_rejected" {
  command = plan
  module {
    source = "../.."
  }
  variables {
    k8s_version = "1.36.1"
  }
  expect_failures = [var.k8s_version]
}
