# Root-level guard: the same ami- id must not reach an NVIDIA consumer and a
# Neuron consumer that live in DIFFERENT modules (nodegroup vs Karpenter
# pool); the per-module preconditions cannot see that mix.
#
# vars_only/variables.tf is a symlink to the ROOT terraform/variables.tf, so
# these runs evaluate the real variable validations without planning any
# module or provider.

variables {
  cluster_name         = "test-cluster"
  aws_region           = "ap-south-2"
  vpc_id               = "vpc-12345678"
  private_subnet_ids   = ["subnet-11111111", "subnet-22222222"]
  public_subnet_ids    = ["subnet-33333333", "subnet-44444444"]
  gpu_custom_ami_id    = "ami-0aaaaaaaaaaaaaaaa"
  neuron_custom_ami_id = "ami-0aaaaaaaaaaaaaaaa"
}

run "nvidia_nodegroup_plus_neuron_pool_same_ami_rejected" {
  command = plan
  module { source = "./vars_only" }
  variables {
    install_gpu_nodegroups  = true
    gpu_nodegroups          = [{ gpu_type = "p5.48xlarge", purchase_option = "od" }]
    install_karpenter       = true
    karpenter_gpu_nodepools = [{ name = "trn2", instance_type = "trn2.48xlarge" }]
  }
  expect_failures = [var.neuron_custom_ami_id]
}

run "neuron_nodegroup_plus_nvidia_pool_same_ami_rejected" {
  command = plan
  module { source = "./vars_only" }
  variables {
    install_gpu_nodegroups  = true
    gpu_nodegroups          = [{ gpu_type = "trn2.48xlarge", purchase_option = "od" }]
    install_karpenter       = true
    karpenter_gpu_nodepools = [{ name = "p5", instance_type = "p5.48xlarge" }]
  }
  expect_failures = [var.neuron_custom_ami_id]
}

# Different AMIs across the same mix plan fine (validation passes).
run "split_mix_different_amis_ok" {
  command = plan
  module { source = "./vars_only" }
  variables {
    neuron_custom_ami_id    = "ami-0bbbbbbbbbbbbbbbb"
    install_gpu_nodegroups  = true
    gpu_nodegroups          = [{ gpu_type = "p5.48xlarge", purchase_option = "od" }]
    install_karpenter       = true
    karpenter_gpu_nodepools = [{ name = "trn2", instance_type = "trn2.48xlarge" }]
  }
}

# Same AMI but only Neuron consumers (no NVIDIA consumer): allowed.
run "same_ami_neuron_only_ok" {
  command = plan
  module { source = "./vars_only" }
  variables {
    install_karpenter       = true
    karpenter_gpu_nodepools = [{ name = "trn2", instance_type = "trn2.48xlarge" }]
  }
}
