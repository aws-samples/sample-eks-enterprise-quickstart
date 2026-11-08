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
      gpus                       = [{ count = 8, manufacturer = "NVIDIA", memory_size = 81920, name = "H100" }]
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

# Cluster Autoscaler scale-from-zero hint (self_managed ASGs). `gpus` is a set
# in the provider schema; the old try(gpus[0].count, 0) always produced "0",
# so CA was told every GPU node has nvidia.com/gpu=0 and never scaled a GPU
# ASG up from zero for GPU-requesting pods.
run "self_managed_ca_gpu_resource_hint" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    node_management = "self_managed"
  }

  assert {
    condition = one([for t in aws_autoscaling_group.gpu["p5-48xlarge-od"].tag : t.value
    if t.key == "k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu"]) == "8"
    error_message = "self_managed GPU ASG must advertise the real GPU count (8) to Cluster Autoscaler, not 0."
  }
}

# ---------------------------------------------------------------------------
# NVIDIA golden guards (added before Trainium/Neuron support landed).
#
# These pin the EXACT rendered bytes / maps an existing NVIDIA-only deployment
# produces today, so any refactor of the nodegroup module that would change a
# Launch Template (new LT version -> managed-NG rollout / ASG refresh), a
# nodegroup label/taint, or a CA ASG tag fails CI instead of surfacing as a
# surprise diff on a live cluster. If one of these fails, the change is NOT
# backward compatible — fix the change, do not re-pin the hash.
# ---------------------------------------------------------------------------
run "nvidia_golden_managed" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  assert {
    condition     = sha256(base64decode(aws_launch_template.gpu["p5-48xlarge-od"].user_data)) == "90600e29b9636ff3bdf8a4befc4fdb362f165a116b82923dbcff52c901184dc1"
    error_message = "managed NVIDIA user_data bytes changed — this would roll every existing GPU nodegroup."
  }
  assert {
    condition     = aws_launch_template.gpu["p5-48xlarge-od"].image_id == "ami-0123456789abcdef0"
    error_message = "NVIDIA LT image_id must come from data.aws_ssm_parameter.gpu_ami."
  }
  assert {
    condition = aws_eks_node_group.gpu["p5-48xlarge-od"].labels == tomap({
      workload-type     = "gpu"
      gpu-instance-type = "p5.48xlarge"
      purchase-option   = "od"
    })
    error_message = "NVIDIA managed nodegroup labels changed."
  }
  assert {
    condition     = [for t in aws_eks_node_group.gpu["p5-48xlarge-od"].taint : "${t.key}=${t.value}:${t.effect}"] == ["nvidia.com/gpu=true:NO_SCHEDULE"]
    error_message = "NVIDIA managed nodegroup taint changed."
  }
  assert {
    condition = toset(keys(aws_autoscaling_group_tag.gpu)) == toset([
      "p5-48xlarge-od-enabled",
      "p5-48xlarge-od-owned",
      "p5-48xlarge-od-instance-type",
    ])
    error_message = "NVIDIA managed-mode CA ASG tag set changed."
  }
  assert {
    condition     = length(aws_launch_template.gpu["p5-48xlarge-od"].network_interfaces) == 32
    error_message = "p5.48xlarge must keep its 32-NIC EFA layout."
  }
  assert {
    condition     = data.aws_ssm_parameter.gpu_ami[0].name == "/aws/service/eks/optimized-ami/1.34/amazon-linux-2023/x86_64/nvidia/recommended/image_id"
    error_message = "NVIDIA recommended AMI SSM path changed."
  }
  # The Neuron SSM lookup must be gated off by has_neuron for NVIDIA-only
  # input. Mocks answer any SSM name, so without this an ungated lookup
  # (which on real AWS fails with ParameterNotFound wherever no Neuron AMI /
  # inherited release tag exists) would go unnoticed.
  assert {
    condition     = length(data.aws_ssm_parameter.neuron_ami) == 0
    error_message = "NVIDIA-only config must not read the Neuron AMI SSM parameter (has_neuron gate regressed)."
  }
}

run "nvidia_golden_self_managed" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    node_management = "self_managed"
  }

  assert {
    condition     = sha256(base64decode(aws_launch_template.gpu["p5-48xlarge-od"].user_data)) == "5762559564a8b6d5aa1f3f9f70c8167141f295c47037d38dd573dc24114223b7"
    error_message = "self_managed NVIDIA user_data bytes changed — this would refresh every existing GPU ASG's LT."
  }
  assert {
    condition = { for t in aws_autoscaling_group.gpu["p5-48xlarge-od"].tag : t.key => t.value } == {
      "k8s.io/cluster-autoscaler/enabled"                                       = "true"
      "k8s.io/cluster-autoscaler/test-cluster"                                  = "owned"
      "k8s.io/cluster-autoscaler/node-template/label/workload-type"             = "gpu"
      "k8s.io/cluster-autoscaler/node-template/label/gpu-instance-type"         = "p5.48xlarge"
      "k8s.io/cluster-autoscaler/node-template/label/purchase-option"           = "od"
      "k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu"            = "true:NoSchedule"
      "k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu"        = "8"
      "k8s.io/cluster-autoscaler/node-template/resources/vpc.amazonaws.com/efa" = "32"
      "Name"                                                                    = "test-cluster-gpu-p5-48xlarge-node"
      "kubernetes.io/cluster/test-cluster"                                      = "owned"
      "gpu-instance-type"                                                       = "p5.48xlarge"
      "purchase-option"                                                         = "od"
    }
    error_message = "self_managed NVIDIA ASG tag map changed."
  }
  # The Neuron SSM lookup must be gated off by has_neuron for NVIDIA-only
  # input. Mocks answer any SSM name, so without this an ungated lookup
  # (which on real AWS fails with ParameterNotFound wherever no Neuron AMI /
  # inherited release tag exists) would go unnoticed.
  assert {
    condition     = length(data.aws_ssm_parameter.neuron_ami) == 0
    error_message = "NVIDIA-only config must not read the Neuron AMI SSM parameter (has_neuron gate regressed)."
  }
}

run "nvidia_pinned_release_path" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_ami_release_version = "v20261031"
  }

  assert {
    condition     = data.aws_ssm_parameter.gpu_ami[0].name == "/aws/service/eks/optimized-ami/1.34/amazon-linux-2023/x86_64/nvidia/amazon-eks-node-al2023-x86_64-nvidia-1.34-v20261031/image_id"
    error_message = "NVIDIA pinned-release AMI SSM path changed."
  }
  # The Neuron SSM lookup must be gated off by has_neuron for NVIDIA-only
  # input. Mocks answer any SSM name, so without this an ungated lookup
  # (which on real AWS fails with ParameterNotFound wherever no Neuron AMI /
  # inherited release tag exists) would go unnoticed.
  assert {
    condition     = length(data.aws_ssm_parameter.neuron_ami) == 0
    error_message = "NVIDIA-only config must not read the Neuron AMI SSM parameter (has_neuron gate regressed)."
  }
}

run "nvidia_custom_ami" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_custom_ami_id = "ami-0fedcba9876543210"
  }

  assert {
    condition     = length(data.aws_ssm_parameter.gpu_ami) == 0
    error_message = "gpu_custom_ami_id must skip the NVIDIA SSM lookup."
  }
  assert {
    condition     = aws_launch_template.gpu["p5-48xlarge-od"].image_id == "ami-0fedcba9876543210"
    error_message = "gpu_custom_ami_id must be used verbatim as the NVIDIA LT image_id."
  }
  # The Neuron SSM lookup must be gated off by has_neuron for NVIDIA-only
  # input. Mocks answer any SSM name, so without this an ungated lookup
  # (which on real AWS fails with ParameterNotFound wherever no Neuron AMI /
  # inherited release tag exists) would go unnoticed.
  assert {
    condition     = length(data.aws_ssm_parameter.neuron_ami) == 0
    error_message = "NVIDIA-only config must not read the Neuron AMI SSM parameter (has_neuron gate regressed)."
  }
}
