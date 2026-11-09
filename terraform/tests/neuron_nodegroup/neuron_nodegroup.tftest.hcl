# AWS Neuron (Trainium / Inferentia) support in modules/eks-gpu-nodegroup.
#
# Vendor is detected from gpu_type by name (modules/gpu-instance-catalog
# neuron_instance_type_regex: trn*/inf* => neuron) and drives, per nodegroup:
#   - AMI: x86_64 EKS AL2023 Neuron AMI (data.aws_ssm_parameter.neuron_ami)
#     vs the NVIDIA AMI (data.aws_ssm_parameter.gpu_ami)
#   - label workload-type=neuron, taint aws.amazon.com/neuron=true:NoSchedule
#   - userdata: no NVIDIA containerd runtime overlay / g7 open-kmod fixup
#   - Cluster Autoscaler hints: aws.amazon.com/neuron, aws.amazon.com/neuroncore
#     (LNC-aware), vpc.amazonaws.com/efa
# Mixed NVIDIA + Neuron configs must leave the NVIDIA nodegroup byte-identical
# to the NVIDIA-only golden values (see gpu_containerd_storage fixture).
#
# The aws_ec2_instance_type mock carries BOTH device sets so the same mock
# serves p5 and trn2 entries; override_data blocks replace the mock entirely
# (they do not merge), so every override repeats supported_architectures +
# instance_storage_supported.

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
      neuron_devices             = [{ count = 16, core_count = 8, core_version = 3, memory_size = 98304, name = "Trainium2" }]
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

# Distinct Neuron AMI so tests can tell which SSM lookup fed which LT.
override_data {
  target = data.aws_ssm_parameter.neuron_ami
  values = { value = "ami-0aaaaaaaaaaaaaaaa" }
}

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
    { gpu_type = "trn2.48xlarge", purchase_option = "od" },
  ]
}

run "neuron_managed" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  assert {
    condition     = aws_eks_node_group.gpu["trn2-48xlarge-od"].labels["workload-type"] == "neuron"
    error_message = "Neuron managed nodegroup must be labelled workload-type=neuron."
  }
  assert {
    condition     = [for t in aws_eks_node_group.gpu["trn2-48xlarge-od"].taint : "${t.key}=${t.value}:${t.effect}"] == ["aws.amazon.com/neuron=true:NO_SCHEDULE"]
    error_message = "Neuron managed nodegroup must carry exactly the aws.amazon.com/neuron taint."
  }
  assert {
    condition     = aws_launch_template.gpu["trn2-48xlarge-od"].image_id == "ami-0aaaaaaaaaaaaaaaa"
    error_message = "Neuron LT must use the Neuron AMI."
  }
  assert {
    condition     = length(data.aws_ssm_parameter.gpu_ami) == 0
    error_message = "A Neuron-only config must not look up the NVIDIA AMI."
  }
  assert {
    condition     = data.aws_ssm_parameter.neuron_ami[0].name == "/aws/service/eks/optimized-ami/1.34/amazon-linux-2023/x86_64/neuron/recommended/image_id"
    error_message = "Neuron recommended AMI SSM path is wrong."
  }
  assert {
    condition     = length(aws_launch_template.gpu["trn2-48xlarge-od"].network_interfaces) == 16
    error_message = "trn2.48xlarge must get 16 NICs (1 primary EFA + 15 efa-only)."
  }
  assert {
    condition     = [for n in aws_launch_template.gpu["trn2-48xlarge-od"].network_interfaces : n.interface_type if n.network_card_index == 0] == ["efa"]
    error_message = "trn2.48xlarge primary NIC (card 0) must be type efa."
  }
  assert {
    condition     = !strcontains(base64decode(aws_launch_template.gpu["trn2-48xlarge-od"].user_data), "runtimes.nvidia")
    error_message = "Neuron user_data must not carry the NVIDIA containerd runtime overlay."
  }
  assert {
    condition     = !strcontains(base64decode(aws_launch_template.gpu["trn2-48xlarge-od"].user_data), "SystemdCgroup = true")
    error_message = "Neuron user_data must not carry the NVIDIA SystemdCgroup overlay."
  }
  assert {
    condition     = !strcontains(base64decode(aws_launch_template.gpu["trn2-48xlarge-od"].user_data), "10de:2c3a")
    error_message = "Neuron user_data must not carry the NVIDIA g7 open-kmod fixup."
  }
  # The boothook (re)start of containerd + kubelet is NVIDIA-only (nvidia-ctk
  # SystemdCgroup reload). On Neuron it started kubelet before nodeadm-run's
  # localStorage RAID0 bind mount and left DaemonSet pods (device plugin) on a
  # stale /var/lib/kubelet — found live on trn2. nodeadm-run starts both.
  assert {
    condition     = length(regexall("(?m)^\\s*(if ! )?systemctl (re)?start kubelet", base64decode(aws_launch_template.gpu["trn2-48xlarge-od"].user_data))) == 0
    error_message = "Neuron user_data must not (re)start kubelet in the boothook (nodeadm-run starts it after localStorage)."
  }
  assert {
    condition     = length(regexall("(?m)^(if ! )?systemctl restart containerd", base64decode(aws_launch_template.gpu["trn2-48xlarge-od"].user_data))) == 0
    error_message = "Neuron user_data must not (re)start containerd in the boothook (nodeadm-run starts it)."
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.gpu["trn2-48xlarge-od"].user_data), "systemctl unmask containerd")
    error_message = "Neuron user_data (ebs) must still unmask containerd after the LVM migration so nodeadm-run can start it."
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.gpu["trn2-48xlarge-od"].user_data), "efa_installer.sh")
    error_message = "Neuron user_data must keep the EFA userspace install."
  }
  assert {
    condition     = aws_autoscaling_group_tag.gpu["trn2-48xlarge-od-neuron-resource"].tag[0].value == "16"
    error_message = "trn2.48xlarge must advertise aws.amazon.com/neuron=16 to CA."
  }
  assert {
    condition     = aws_autoscaling_group_tag.gpu["trn2-48xlarge-od-neuroncore-resource"].tag[0].value == "64"
    error_message = "trn2.48xlarge must advertise aws.amazon.com/neuroncore=64 (16 devices x 8 cores / LNC=2) to CA."
  }
  assert {
    condition     = aws_autoscaling_group_tag.gpu["trn2-48xlarge-od-efa-resource"].tag[0].value == "16"
    error_message = "trn2.48xlarge must advertise vpc.amazonaws.com/efa=16 to CA."
  }
  assert {
    condition     = aws_autoscaling_group_tag.gpu["trn2-48xlarge-od-neuron-taint"].tag[0].value == "true:NoSchedule"
    error_message = "Neuron managed ASG must carry the CA taint hint."
  }
  assert {
    condition     = aws_autoscaling_group_tag.gpu["trn2-48xlarge-od-workload-label"].tag[0].value == "neuron"
    error_message = "Neuron managed ASG must carry the CA workload-type=neuron label hint."
  }
  assert {
    condition     = length(keys(aws_autoscaling_group_tag.gpu)) == 8
    error_message = "Neuron managed nodegroup must get exactly 8 CA ASG tags (3 base + label + taint + neuron + neuroncore + efa)."
  }
}

run "neuron_self_managed" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    node_management = "self_managed"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.gpu["trn2-48xlarge-od"].user_data), "--node-labels=workload-type=neuron,gpu-instance-type=trn2.48xlarge,purchase-option=od")
    error_message = "self_managed Neuron user_data must embed workload-type=neuron in --node-labels."
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.gpu["trn2-48xlarge-od"].user_data), "--register-with-taints=aws.amazon.com/neuron=true:NoSchedule")
    error_message = "self_managed Neuron user_data must register the aws.amazon.com/neuron taint."
  }
  assert {
    condition     = { for t in aws_autoscaling_group.gpu["trn2-48xlarge-od"].tag : t.key => t.value }["k8s.io/cluster-autoscaler/node-template/label/workload-type"] == "neuron"
    error_message = "self_managed Neuron ASG must carry the workload-type=neuron CA label hint."
  }
  assert {
    condition     = { for t in aws_autoscaling_group.gpu["trn2-48xlarge-od"].tag : t.key => t.value }["k8s.io/cluster-autoscaler/node-template/taint/aws.amazon.com/neuron"] == "true:NoSchedule"
    error_message = "self_managed Neuron ASG must carry the aws.amazon.com/neuron CA taint hint."
  }
  assert {
    condition     = { for t in aws_autoscaling_group.gpu["trn2-48xlarge-od"].tag : t.key => t.value }["k8s.io/cluster-autoscaler/node-template/resources/aws.amazon.com/neuron"] == "16"
    error_message = "self_managed trn2.48xlarge must advertise aws.amazon.com/neuron=16."
  }
  assert {
    condition     = { for t in aws_autoscaling_group.gpu["trn2-48xlarge-od"].tag : t.key => t.value }["k8s.io/cluster-autoscaler/node-template/resources/aws.amazon.com/neuroncore"] == "64"
    error_message = "self_managed trn2.48xlarge must advertise aws.amazon.com/neuroncore=64."
  }
  assert {
    condition     = { for t in aws_autoscaling_group.gpu["trn2-48xlarge-od"].tag : t.key => t.value }["k8s.io/cluster-autoscaler/node-template/resources/vpc.amazonaws.com/efa"] == "16"
    error_message = "self_managed trn2.48xlarge must advertise vpc.amazonaws.com/efa=16."
  }
  assert {
    condition     = length([for t in aws_autoscaling_group.gpu["trn2-48xlarge-od"].tag : t.key if strcontains(t.key, "nvidia.com/gpu")]) == 0
    error_message = "self_managed Neuron ASG must not carry any nvidia.com/gpu CA hint."
  }
}

run "mixed_nvidia_neuron_managed" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_nodegroups = [
      { gpu_type = "p5.48xlarge", purchase_option = "od" },
      { gpu_type = "trn2.48xlarge", purchase_option = "od" },
    ]
  }

  assert {
    condition     = sha256(base64decode(aws_launch_template.gpu["p5-48xlarge-od"].user_data)) == "90600e29b9636ff3bdf8a4befc4fdb362f165a116b82923dbcff52c901184dc1"
    error_message = "Adding a Neuron nodegroup must leave the NVIDIA managed user_data byte-identical to the golden value."
  }
  assert {
    condition     = aws_launch_template.gpu["p5-48xlarge-od"].image_id == "ami-0123456789abcdef0"
    error_message = "NVIDIA LT must keep the NVIDIA AMI in a mixed config."
  }
  assert {
    condition     = aws_launch_template.gpu["trn2-48xlarge-od"].image_id == "ami-0aaaaaaaaaaaaaaaa"
    error_message = "Neuron LT must use the Neuron AMI in a mixed config."
  }
  assert {
    condition = aws_eks_node_group.gpu["p5-48xlarge-od"].labels == tomap({
      workload-type     = "gpu"
      gpu-instance-type = "p5.48xlarge"
      purchase-option   = "od"
    })
    error_message = "NVIDIA nodegroup labels must equal the golden values in a mixed config."
  }
  assert {
    condition     = [for t in aws_eks_node_group.gpu["p5-48xlarge-od"].taint : "${t.key}=${t.value}:${t.effect}"] == ["nvidia.com/gpu=true:NO_SCHEDULE"]
    error_message = "NVIDIA nodegroup taint must equal the golden value in a mixed config."
  }
  assert {
    condition     = aws_eks_node_group.gpu["trn2-48xlarge-od"].labels["workload-type"] == "neuron"
    error_message = "Neuron nodegroup must be labelled workload-type=neuron in a mixed config."
  }
  assert {
    condition     = [for t in aws_eks_node_group.gpu["trn2-48xlarge-od"].taint : t.key] == ["aws.amazon.com/neuron"]
    error_message = "Neuron nodegroup must carry the aws.amazon.com/neuron taint in a mixed config."
  }
  assert {
    condition     = length([for k in keys(aws_autoscaling_group_tag.gpu) : k if startswith(k, "p5-48xlarge-od-")]) == 3
    error_message = "NVIDIA nodegroup must keep exactly its 3 CA ASG tags in a mixed config."
  }
  assert {
    condition     = length([for k in keys(aws_autoscaling_group_tag.gpu) : k if startswith(k, "trn2-48xlarge-od-")]) == 8
    error_message = "Neuron nodegroup must get its 8 CA ASG tags in a mixed config."
  }
}

run "mixed_nvidia_neuron_self_managed" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    node_management = "self_managed"
    gpu_nodegroups = [
      { gpu_type = "p5.48xlarge", purchase_option = "od" },
      { gpu_type = "trn2.48xlarge", purchase_option = "od" },
    ]
  }

  assert {
    condition     = sha256(base64decode(aws_launch_template.gpu["p5-48xlarge-od"].user_data)) == "5762559564a8b6d5aa1f3f9f70c8167141f295c47037d38dd573dc24114223b7"
    error_message = "Adding a Neuron nodegroup must leave the NVIDIA self_managed user_data byte-identical to the golden value."
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
    error_message = "NVIDIA self_managed ASG tag map must equal the golden 12-key map in a mixed config."
  }
}

run "mixed_arm64_nvidia_plus_neuron" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_nodegroups = [
      { gpu_type = "p5.48xlarge", purchase_option = "od" },
      { gpu_type = "trn2.48xlarge", purchase_option = "od" },
    ]
  }

  # Both types report arm64 support: the NVIDIA AMI resolves to arm64, the
  # Neuron AMI stays x86_64 (x86_64 is also supported, so no precondition
  # fails). This only checks the per-vendor AMI PATH split. It does NOT test
  # the NVIDIA-only filter in front of validate_arch_uniform: override_data
  # applies one value to every for_each instance, so p5 and trn2 cannot be
  # given different architectures here. That filter (an arm64-only NVIDIA
  # type next to an x86_64-only trn2) is pinned with literal maps in
  # tests/gpu_instance_catalog (run "arm64_nvidia_plus_x86_neuron").
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      supported_architectures    = ["x86_64", "arm64"]
      instance_storage_supported = true
      gpus                       = [{ count = 8, manufacturer = "NVIDIA", memory_size = 81920, name = "H100" }]
      neuron_devices             = [{ count = 16, core_count = 8, core_version = 3, memory_size = 98304, name = "Trainium2" }]
    }
  }

  assert {
    condition     = strcontains(data.aws_ssm_parameter.gpu_ami[0].name, "/arm64/nvidia/")
    error_message = "NVIDIA AMI path must follow the NVIDIA types' arch."
  }
  assert {
    condition     = strcontains(data.aws_ssm_parameter.neuron_ami[0].name, "/x86_64/neuron/")
    error_message = "Neuron AMI path must always be x86_64."
  }
}

run "neuron_release_inherits_gpu_pin" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_ami_release_version = "v20261031"
  }

  assert {
    condition     = data.aws_ssm_parameter.neuron_ami[0].name == "/aws/service/eks/optimized-ami/1.34/amazon-linux-2023/x86_64/neuron/amazon-eks-node-al2023-x86_64-neuron-1.34-v20261031/image_id"
    error_message = "neuron_ami_release_version = null must inherit gpu_ami_release_version."
  }
}

run "neuron_release_override_recommended" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_ami_release_version    = "v20261031"
    neuron_ami_release_version = ""
    gpu_nodegroups = [
      { gpu_type = "p5.48xlarge", purchase_option = "od" },
      { gpu_type = "trn2.48xlarge", purchase_option = "od" },
    ]
  }

  assert {
    condition     = data.aws_ssm_parameter.neuron_ami[0].name == "/aws/service/eks/optimized-ami/1.34/amazon-linux-2023/x86_64/neuron/recommended/image_id"
    error_message = "neuron_ami_release_version = \"\" must follow the Neuron recommended AMI."
  }
  assert {
    condition     = strcontains(data.aws_ssm_parameter.gpu_ami[0].name, "-nvidia-1.34-v20261031")
    error_message = "The NVIDIA pin must be unaffected by neuron_ami_release_version."
  }
}

run "neuron_custom_ami" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    neuron_custom_ami_id = "ami-0bbbbbbbbbbbbbbbb"
    gpu_custom_ami_id    = "ami-0cccccccccccccccc"
    gpu_nodegroups = [
      { gpu_type = "p5.48xlarge", purchase_option = "od" },
      { gpu_type = "trn2.48xlarge", purchase_option = "od" },
    ]
  }

  assert {
    condition     = length(data.aws_ssm_parameter.neuron_ami) == 0
    error_message = "neuron_custom_ami_id must skip the Neuron SSM lookup."
  }
  assert {
    condition     = length(data.aws_ssm_parameter.gpu_ami) == 0
    error_message = "gpu_custom_ami_id must skip the NVIDIA SSM lookup."
  }
  assert {
    condition     = aws_launch_template.gpu["trn2-48xlarge-od"].image_id == "ami-0bbbbbbbbbbbbbbbb"
    error_message = "Neuron LT must use neuron_custom_ami_id."
  }
  assert {
    condition     = aws_launch_template.gpu["p5-48xlarge-od"].image_id == "ami-0cccccccccccccccc"
    error_message = "NVIDIA LT must use gpu_custom_ami_id."
  }
}

run "gpu_custom_ami_not_applied_to_neuron" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_custom_ami_id = "ami-0cccccccccccccccc"
  }

  assert {
    condition     = aws_launch_template.gpu["trn2-48xlarge-od"].image_id == "ami-0aaaaaaaaaaaaaaaa"
    error_message = "gpu_custom_ami_id (an NVIDIA-derived AMI) must never be applied to a Neuron nodegroup."
  }
}

run "neuron_requires_x86" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      supported_architectures    = ["arm64"]
      instance_storage_supported = true
      neuron_devices             = [{ count = 16, core_count = 8, core_version = 3, memory_size = 98304, name = "Trainium2" }]
    }
  }

  expect_failures = [null_resource.validate_arch_uniform]
}

run "neuron_type_without_devices_rejected" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      supported_architectures    = ["x86_64"]
      instance_storage_supported = true
      gpus                       = []
      neuron_devices             = []
    }
  }

  expect_failures = [aws_launch_template.gpu]
}

run "unclassified_neuron_family_rejected" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_nodegroups = [
      { gpu_type = "p5.48xlarge", purchase_option = "od" },
    ]
  }

  # Simulates a future Neuron family whose name the catalog regex misses.
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      supported_architectures    = ["x86_64"]
      instance_storage_supported = true
      gpus                       = []
      neuron_devices             = [{ count = 16, core_count = 8, core_version = 3, memory_size = 98304, name = "Trainium2" }]
    }
  }

  expect_failures = [aws_launch_template.gpu]
}

run "bad_neuron_release_rejected" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    neuron_ami_release_version = "20261031"
  }

  expect_failures = [var.neuron_ami_release_version]
}

run "bad_neuron_custom_ami_rejected" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    neuron_custom_ami_id = "foo"
  }

  expect_failures = [var.neuron_custom_ami_id]
}

run "trn1_counts_and_layout" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    node_management = "self_managed"
    gpu_nodegroups = [
      { gpu_type = "trn1.32xlarge", purchase_option = "od" },
    ]
  }

  # trn1.32xlarge: 16 Trainium devices x 2 NeuronCore-v2 (no LNC halving).
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      supported_architectures    = ["x86_64"]
      instance_storage_supported = true
      neuron_devices             = [{ count = 16, core_count = 2, core_version = 2, memory_size = 32768, name = "Trainium" }]
    }
  }

  assert {
    condition     = length(aws_launch_template.gpu["trn1-32xlarge-od"].network_interfaces) == 8
    error_message = "trn1.32xlarge must get 8 NICs (1 primary EFA + 7 efa-only)."
  }
  assert {
    condition     = { for t in aws_autoscaling_group.gpu["trn1-32xlarge-od"].tag : t.key => t.value }["k8s.io/cluster-autoscaler/node-template/resources/aws.amazon.com/neuroncore"] == "32"
    error_message = "trn1.32xlarge must advertise aws.amazon.com/neuroncore=32."
  }
  assert {
    condition     = { for t in aws_autoscaling_group.gpu["trn1-32xlarge-od"].tag : t.key => t.value }["k8s.io/cluster-autoscaler/node-template/resources/aws.amazon.com/neuron"] == "16"
    error_message = "trn1.32xlarge must advertise aws.amazon.com/neuron=16."
  }
  assert {
    condition     = { for t in aws_autoscaling_group.gpu["trn1-32xlarge-od"].tag : t.key => t.value }["k8s.io/cluster-autoscaler/node-template/resources/vpc.amazonaws.com/efa"] == "8"
    error_message = "trn1.32xlarge must advertise vpc.amazonaws.com/efa=8."
  }
}

# ---------------------------------------------------------------------------
# Capacity Blocks reject placement groups (EC2: "You can't specify a placement
# group when you launch instances into a Capacity Block"). The documented trn2
# CB example is single-subnet, so placement_group = "cluster" there would make
# it pg_eligible and every launch would fail. The LT precondition must catch
# that, but only when a PG would actually be attached.
# ---------------------------------------------------------------------------
run "cb_with_cluster_placement_group_rejected" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_nodegroups = [
      { gpu_type = "trn2.48xlarge", purchase_option = "cb", capacity_reservation_id = "cr-0123456789abcdef0", placement_group = "cluster", subnet_ids = ["subnet-11111111"] },
    ]
  }

  expect_failures = [aws_launch_template.gpu]
}

# NVIDIA CB entries: the same misconfiguration planned before Neuron support,
# so it must NOT fail the plan (backward compatibility: an unchanged NVIDIA
# tfvars keeps planning with zero diff). It is reported by the warn-only
# check.cb_nodegroups_without_placement_group instead, and the PG / LT
# placement block it had before are kept as-is.
run "nvidia_cb_with_cluster_placement_group_warns_only" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_nodegroups = [
      { gpu_type = "p5.48xlarge", purchase_option = "cb", capacity_reservation_id = "cr-0123456789abcdef0", placement_group = "cluster", subnet_ids = ["subnet-11111111"] },
    ]
  }

  # Only the check block may fail (a warning); the LT precondition must pass.
  expect_failures = [check.cb_nodegroups_without_placement_group]

  assert {
    condition     = length(aws_placement_group.gpu) == 1
    error_message = "pre-existing NVIDIA cb + cluster PG entry must keep its placement group (no destroy on upgrade)"
  }
  assert {
    condition     = length(aws_launch_template.gpu["p5-48xlarge-cb"].placement) == 1
    error_message = "pre-existing NVIDIA cb + cluster PG LT must keep its placement block (no new LT version on upgrade)"
  }
}

# cb + "cluster" + multiple subnets is NOT pg_eligible (no PG attached) and
# launches today — it must keep planning, with no placement group.
run "cb_cluster_multi_subnet_still_plans" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_nodegroups = [
      { gpu_type = "p5.48xlarge", purchase_option = "cb", capacity_reservation_id = "cr-0123456789abcdef0", placement_group = "cluster" },
    ]
  }

  assert {
    condition     = length(aws_placement_group.gpu) == 0
    error_message = "multi-subnet cb entry must not get a placement group"
  }
  assert {
    condition     = length(aws_launch_template.gpu["p5-48xlarge-cb"].placement) == 0
    error_message = "multi-subnet cb LT must carry no placement block"
  }
}

# The documented trn2 CB example (no placement_group) must plan, with a
# capacity-block market and no placement group.
run "documented_trn2_cb_example_plans" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_nodegroups = [
      { gpu_type = "trn2.48xlarge", purchase_option = "cb", capacity_reservation_id = "cr-0123456789abcdef0", subnet_ids = ["subnet-11111111"] },
    ]
  }

  assert {
    condition     = length(aws_placement_group.gpu) == 0
    error_message = "trn2 CB example must not create a placement group"
  }
  assert {
    condition     = aws_launch_template.gpu["trn2-48xlarge-cb"].instance_market_options[0].market_type == "capacity-block"
    error_message = "trn2 CB example must use market_type = capacity-block"
  }
}

# trn2u.48xlarge: EC2 describes it (16 cards / 16 EFA) but publishes no
# NeuronInfo -> rejected at plan by the Neuron-devices precondition (documented
# as unsupported, not as a no-EFA fallback).
run "trn2u_without_neuron_info_rejected" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    gpu_nodegroups = [
      { gpu_type = "trn2u.48xlarge", purchase_option = "od" },
    ]
  }

  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      supported_architectures    = ["x86_64"]
      instance_storage_supported = true
      gpus                       = []
      neuron_devices             = []
    }
  }

  expect_failures = [aws_launch_template.gpu]
}

# Live regression (trn2.48xlarge, ap-south-2, 2026-11-07): with
# containerd_storage = "instance_store" the NVIDIA-only boothook restart of
# containerd + kubelet started kubelet BEFORE nodeadm-run's localStorage RAID0
# bind mount; the neuron-device-plugin pod started in that window kept a
# hostPath into the hidden root-disk /var/lib/kubelet and never registered
# (aws.amazon.com/neuron = 0). Neuron boothooks must leave both daemons to
# nodeadm-run; the NVIDIA nodegroup next to it must stay byte-identical.
run "neuron_instance_store_no_early_kubelet" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    enable_local_lvm = false
    gpu_nodegroups = [
      { gpu_type = "p5.48xlarge", purchase_option = "od", containerd_storage = "instance_store" },
      { gpu_type = "trn2.48xlarge", purchase_option = "spot", containerd_storage = "instance_store" },
    ]
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.gpu["trn2-48xlarge-spot"].user_data), "strategy: RAID0")
    error_message = "Neuron instance_store NodeConfig must request localStorage RAID0."
  }
  assert {
    condition     = length(regexall("(?m)^\\s*(if ! )?systemctl (re)?start kubelet", base64decode(aws_launch_template.gpu["trn2-48xlarge-spot"].user_data))) == 0
    error_message = "Neuron instance_store boothook must never (re)start kubelet before nodeadm-run applies localStorage."
  }
  assert {
    condition     = length(regexall("(?m)^\\s*(if ! )?systemctl (re)?start containerd", base64decode(aws_launch_template.gpu["trn2-48xlarge-spot"].user_data))) == 0
    error_message = "Neuron instance_store boothook must never (re)start containerd before nodeadm-run applies localStorage."
  }
  assert {
    condition     = length(regexall("(?m)^if ! systemctl restart kubelet", base64decode(aws_launch_template.gpu["p5-48xlarge-od"].user_data))) == 1
    error_message = "The NVIDIA nodegroup must keep its SystemdCgroup reload (pre-Neuron behaviour)."
  }
}

# Same custom AMI on NVIDIA and Neuron nodegroups must fail the plan (parity
# with the Karpenter pool guard); a Neuron-only config may reuse
# gpu_custom_ami_id's value because no NVIDIA nodegroup renders it.
run "same_custom_ami_nvidia_and_neuron_rejected" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    neuron_custom_ami_id = "ami-0dddddddddddddddd"
    gpu_custom_ami_id    = "ami-0dddddddddddddddd"
    gpu_nodegroups = [
      { gpu_type = "p5.48xlarge", purchase_option = "od" },
      { gpu_type = "trn2.48xlarge", purchase_option = "od" },
    ]
  }

  expect_failures = [aws_launch_template.gpu["trn2-48xlarge-od"]]
}

run "same_custom_ami_neuron_only_ok" {
  command = plan

  module {
    source = "../../modules/eks-gpu-nodegroup"
  }

  variables {
    neuron_custom_ami_id = "ami-0dddddddddddddddd"
    gpu_custom_ami_id    = "ami-0dddddddddddddddd"
    gpu_nodegroups = [
      { gpu_type = "trn2.48xlarge", purchase_option = "od" },
    ]
  }

  assert {
    condition     = aws_launch_template.gpu["trn2-48xlarge-od"].image_id == "ami-0dddddddddddddddd"
    error_message = "Neuron-only config must accept neuron_custom_ami_id even if it equals gpu_custom_ami_id."
  }
}
