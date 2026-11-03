# Regression guard for the GPU containerd storage option (issue #12):
#   containerd_storage = "ebs"            (default) — dedicated gp3 data
#     volume + boothook LVM migration; rendering must be unchanged.
#   containerd_storage = "instance_store" — nodeadm localStorage RAID0 over
#     Instance Store NVMe; no data volume; mutually exclusive with the
#     local-LVM scratch volume; rejected on types without Instance Store.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = {
      supported_architectures    = ["x86_64"]
      instance_storage_supported = true
    }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
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
}
mock_provider "null" {}

variables {
  cluster_name              = "test-cluster"
  cluster_endpoint          = "https://ABC.gr7.us-west-2.eks.amazonaws.com"
  cluster_ca                = "LS0tLS1CRUdJTg=="
  cluster_security_group_id = "sg-12345678"
  service_ipv4_cidr         = "172.20.0.0/16"
  vpc_id                    = "vpc-12345678"
  region                    = "us-west-2"
  k8s_version               = "1.34"
  private_subnet_ids        = ["subnet-11111111", "subnet-22222222"]
  gpu_nodegroups = [
    { gpu_type = "p5.48xlarge", purchase_option = "od" },
  ]
}

run "default_is_ebs" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  assert {
    condition     = length([for b in aws_launch_template.gpu["p5-48xlarge-od"].block_device_mappings : b if b.device_name == "/dev/xvdb"]) == 1
    error_message = "default (ebs) must keep the /dev/xvdb containerd data volume."
  }
  assert {
    condition     = !strcontains(base64decode(aws_launch_template.gpu["p5-48xlarge-od"].user_data), "localStorage")
    error_message = "ebs mode must not configure nodeadm localStorage."
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.gpu["p5-48xlarge-od"].user_data), "systemctl mask containerd")
    error_message = "ebs mode must keep the boothook containerd migration."
  }
}

run "module_default_instance_store" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    containerd_storage = "instance_store"
    enable_local_lvm   = false
  }

  assert {
    condition     = length([for b in aws_launch_template.gpu["p5-48xlarge-od"].block_device_mappings : b if b.device_name == "/dev/xvdb"]) == 0
    error_message = "instance_store must not attach the /dev/xvdb data volume."
  }
  assert {
    condition     = length([for b in aws_launch_template.gpu["p5-48xlarge-od"].block_device_mappings : b if b.device_name == "/dev/xvda"]) == 1
    error_message = "instance_store must keep the root volume."
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.gpu["p5-48xlarge-od"].user_data), "localStorage:\n      strategy: RAID0")
    error_message = "instance_store must set NodeConfig spec.instance.localStorage.strategy = RAID0."
  }
  assert {
    condition     = !strcontains(base64decode(aws_launch_template.gpu["p5-48xlarge-od"].user_data), "systemctl mask containerd")
    error_message = "instance_store must not run the boothook EBS migration (nodeadm moves containerd)."
  }
}

run "per_nodegroup_override" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    enable_local_lvm = false
    gpu_nodegroups = [
      { gpu_type = "p5.48xlarge", purchase_option = "od", containerd_storage = "instance_store" },
      { gpu_type = "p5.48xlarge", purchase_option = "spot" },
    ]
  }

  assert {
    condition     = length([for b in aws_launch_template.gpu["p5-48xlarge-od"].block_device_mappings : b if b.device_name == "/dev/xvdb"]) == 0
    error_message = "the instance_store nodegroup must not attach /dev/xvdb."
  }
  assert {
    condition     = length([for b in aws_launch_template.gpu["p5-48xlarge-spot"].block_device_mappings : b if b.device_name == "/dev/xvdb"]) == 1
    error_message = "a nodegroup without containerd_storage must fall back to the module default (ebs)."
  }
}

run "instance_store_excludes_local_lvm" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    containerd_storage = "instance_store"
    enable_local_lvm   = true
  }

  expect_failures = [var.gpu_nodegroups]
}

run "instance_store_needs_instance_storage" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    containerd_storage = "instance_store"
    enable_local_lvm   = false
  }

  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      supported_architectures    = ["x86_64"]
      instance_storage_supported = false
    }
  }

  expect_failures = [aws_launch_template.gpu]
}

run "invalid_value_rejected" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_nodegroups = [
      { gpu_type = "p5.48xlarge", purchase_option = "od", containerd_storage = "nvme" },
    ]
  }

  expect_failures = [var.gpu_nodegroups]
}
