# modules/gpu-instance-catalog: vendor classification + per-vendor AMI-arch
# reduction, driven with LITERAL maps.
#
# Why here and not in tests/neuron_nodegroup: override_data / mock_data apply
# one value to every for_each instance of data.aws_ec2_instance_type.gpu, so
# a module-level test can never give an NVIDIA type and a Neuron type
# different architectures. The reduction eks-gpu-nodegroup relies on
# (nvidia_ami_arches feeds null_resource.validate_arch_uniform) is therefore
# pinned here with real per-type inputs.

# The case the NVIDIA-only vendor filter exists for: an arm64-only NVIDIA type
# next to an x86_64-only trn2. Without the filter nvidia_ami_arches would be
# ["arm64", "x86_64"] and validate_arch_uniform would reject a valid apply.
run "arm64_nvidia_plus_x86_neuron" {
  command = plan
  module {
    source = "../../modules/gpu-instance-catalog"
  }
  variables {
    supported_architectures_by_instance_type = {
      "g5g.16xlarge"  = ["arm64"]
      "trn2.48xlarge" = ["x86_64"]
    }
  }

  assert {
    condition     = output.nvidia_ami_arches == tolist(["arm64"])
    error_message = "Neuron types must not contribute to nvidia_ami_arches (got ${jsonencode(output.nvidia_ami_arches)})."
  }
  assert {
    condition     = output.ami_arch_by_instance_type == { "g5g.16xlarge" = "arm64", "trn2.48xlarge" = "x86_64" }
    error_message = "ami_arch_by_instance_type must reflect each type's own architectures."
  }
  assert {
    condition     = length(output.neuron_types_without_x86_64) == 0
    error_message = "trn2.48xlarge is x86_64 and must not be flagged."
  }
}

# NVIDIA-only inputs reproduce the pre-Neuron inline expression: arm64 wins
# when supported, distinct in key order, x86_64 otherwise.
run "nvidia_only_matches_pre_neuron_expression" {
  command = plan
  module {
    source = "../../modules/gpu-instance-catalog"
  }
  variables {
    supported_architectures_by_instance_type = {
      "p5.48xlarge"  = ["x86_64"]
      "g6e.48xlarge" = ["x86_64"]
    }
  }

  assert {
    condition     = output.nvidia_ami_arches == tolist(["x86_64"])
    error_message = "Homogeneous x86_64 NVIDIA types must reduce to [\"x86_64\"]."
  }
}

run "mixed_nvidia_arches_detected" {
  command = plan
  module {
    source = "../../modules/gpu-instance-catalog"
  }
  variables {
    supported_architectures_by_instance_type = {
      "g5g.16xlarge" = ["arm64"]
      "p5.48xlarge"  = ["x86_64"]
    }
  }

  assert {
    condition     = output.nvidia_ami_arches == tolist(["arm64", "x86_64"])
    error_message = "Two NVIDIA types of different arches must both appear (validate_arch_uniform relies on length > 1)."
  }
}

run "arm64_neuron_flagged" {
  command = plan
  module {
    source = "../../modules/gpu-instance-catalog"
  }
  variables {
    supported_architectures_by_instance_type = {
      "trn2.48xlarge" = ["arm64"]
      "p5.48xlarge"   = ["x86_64"]
    }
  }

  assert {
    condition     = output.neuron_types_without_x86_64 == tolist(["trn2.48xlarge"])
    error_message = "A Neuron type without x86_64 must be reported."
  }
  assert {
    condition     = output.nvidia_ami_arches == tolist(["x86_64"])
    error_message = "The arm64 Neuron type must not leak into nvidia_ami_arches."
  }
}

# Default inputs keep every existing caller (Karpenter, userdata fixture) inert.
run "defaults_inert" {
  command = plan
  module {
    source = "../../modules/gpu-instance-catalog"
  }

  assert {
    condition     = length(output.nvidia_ami_arches) == 0 && length(output.ami_arch_by_instance_type) == 0 && length(output.neuron_types_without_x86_64) == 0 && length(output.vendor_by_instance_type) == 0
    error_message = "Default (empty) inputs must produce empty helper outputs."
  }
}

run "vendor_classification" {
  command = plan
  module {
    source = "../../modules/gpu-instance-catalog"
  }
  variables {
    instance_types = ["p5.48xlarge", "g6e.48xlarge", "trn2.48xlarge", "trn1n.32xlarge", "inf2.48xlarge", "trn3s-es.48xlarge"]
  }

  assert {
    condition = output.vendor_by_instance_type == {
      "p5.48xlarge"       = "nvidia"
      "g6e.48xlarge"      = "nvidia"
      "trn2.48xlarge"     = "neuron"
      "trn1n.32xlarge"    = "neuron"
      "inf2.48xlarge"     = "neuron"
      "trn3s-es.48xlarge" = "neuron"
    }
    error_message = "Name-based vendor classification regressed: ${jsonencode(output.vendor_by_instance_type)}"
  }
}

# The instance types modules/eks-karpenter passes from gpu_nodepools: every
# Neuron family a Karpenter pool may name (trn2u included — classified Neuron
# by name, then rejected by the karpenter module's NeuronInfo precondition)
# next to the NVIDIA types the existing pools use.
run "karpenter_pool_type_classification" {
  command = plan
  module {
    source = "../../modules/gpu-instance-catalog"
  }
  variables {
    instance_types = ["trn2.48xlarge", "trn2.3xlarge", "trn1.2xlarge", "trn1n.32xlarge", "inf2.xlarge", "inf2.48xlarge", "trn2u.48xlarge", "p5.48xlarge", "g5.48xlarge", "p6-b300.48xlarge", "g6e.8xlarge"]
  }

  assert {
    condition = output.vendor_by_instance_type == {
      "trn2.48xlarge"    = "neuron"
      "trn2.3xlarge"     = "neuron"
      "trn1.2xlarge"     = "neuron"
      "trn1n.32xlarge"   = "neuron"
      "inf2.xlarge"      = "neuron"
      "inf2.48xlarge"    = "neuron"
      "trn2u.48xlarge"   = "neuron"
      "p5.48xlarge"      = "nvidia"
      "g5.48xlarge"      = "nvidia"
      "p6-b300.48xlarge" = "nvidia"
      "g6e.8xlarge"      = "nvidia"
    }
    error_message = "Karpenter pool type classification regressed: ${jsonencode(output.vendor_by_instance_type)}"
  }
}
