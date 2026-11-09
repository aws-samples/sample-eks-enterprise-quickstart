# Karpenter GPU NodePools (modules/eks-karpenter var.gpu_nodepools).
# The rendered EC2NodeClass / NodePool objects are read back from the
# karpenter-pools helm release values.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = {
      instance_storage_supported = true
      default_vcpus              = 192
      gpus                       = [{ count = 8, manufacturer = "NVIDIA", memory_size = 275040, name = "B300" }]
      neuron_devices             = [{ count = 16, core_count = 8, core_version = 3, memory_size = 98304, name = "Trainium2" }]
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
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

variables {
  cluster_name              = "test-cluster"
  cluster_endpoint          = "https://ABC.gr7.us-west-2.eks.amazonaws.com"
  cluster_security_group_id = "sg-12345678"
  region                    = "ap-south-2"
  karpenter_version         = "1.12.1"
  system_node_label_key     = "app"
  system_node_label_value   = "eks-utils"
  private_subnet_ids        = ["subnet-11111111", "subnet-22222222"]
}

run "no_gpu_pools_keeps_cpu_pools_unchanged" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  assert {
    condition     = length(yamldecode(helm_release.karpenter_pools.values[0]).resources) == 4
    error_message = "with no gpu_nodepools the karpenter-pools release must render exactly the 4 CPU objects (no diff for existing clusters)."
  }
}

run "b300_spot_single_az" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [{
      name           = "p6-b300-spot"
      instance_type  = "p6-b300.48xlarge"
      capacity_types = ["spot"]
      zones          = ["ap-south-2c"]
      max_nodes      = 1
    }]
    gpu_ami_selector = "al2023@v20260818"
  }

  assert {
    condition     = length(yamldecode(helm_release.karpenter_pools.values[0]).resources) == 6
    error_message = "one GPU pool must add exactly one EC2NodeClass + one NodePool."
  }
  # --- EC2NodeClass
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : length(r.spec.networkInterfaces)
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-p6-b300-spot"][0] == 17
    error_message = "p6-b300 needs 17 interfaces: NIC0 interface + efa-only on cards 1..16."
  }
  assert {
    condition = alltrue([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : alltrue([
      for i in r.spec.networkInterfaces : i.interfaceType == "efa-only" if !(i.networkCardIndex == 0 && i.deviceIndex == 0)
      ]) && anytrue([for i in r.spec.networkInterfaces : i.networkCardIndex == 0 && i.deviceIndex == 0 && i.interfaceType == "interface"])
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-p6-b300-spot"])
    error_message = "(0,0) must be the 'interface' (CRD rule) and every other interface efa-only."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.instanceStorePolicy
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-p6-b300-spot"][0] == "RAID0"
    error_message = "default instance_store_policy must render instanceStorePolicy: RAID0."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.amiSelectorTerms[0].alias
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-p6-b300-spot"][0] == "al2023@v20260818"
    error_message = "the GPU EC2NodeClass must use the pinned AL2023 alias."
  }
  assert {
    condition = alltrue([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources :
      strcontains(r.spec.userData, "Content-Type: text/cloud-boothook")
      && strcontains(r.spec.userData, "efa-keyring.gpg")
      && strcontains(r.spec.userData, "SystemdCgroup = true")
      && strcontains(r.spec.userData, "NVIDIA open-kmod fixup")
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-p6-b300-spot"])
    error_message = "GPU userData must carry the shared g7 fixup + EFA userspace boothook and the SystemdCgroup NodeConfig overlay."
  }
  # --- NodePool
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : [for q in r.spec.template.spec.requirements : q.values if q.key == "topology.kubernetes.io/zone"][0]
    if r.kind == "NodePool" && r.metadata.name == "gpu-p6-b300-spot"][0] == ["ap-south-2c"]
    error_message = "zones must render a topology.kubernetes.io/zone requirement."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : [for q in r.spec.template.spec.requirements : q.values if q.key == "karpenter.sh/capacity-type"][0]
    if r.kind == "NodePool" && r.metadata.name == "gpu-p6-b300-spot"][0] == ["spot"]
    error_message = "capacity_types must render the karpenter.sh/capacity-type requirement."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.limits["nvidia.com/gpu"]
    if r.kind == "NodePool" && r.metadata.name == "gpu-p6-b300-spot"][0] == "8"
    error_message = "max_nodes=1 on an 8-GPU type must limit the pool to nvidia.com/gpu=8."
  }
  assert {
    condition = alltrue([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources :
      r.spec.template.metadata.labels["workload-type"] == "gpu"
      && r.spec.template.spec.taints[0].key == "nvidia.com/gpu"
      && r.spec.template.spec.expireAfter == "Never"
    if r.kind == "NodePool" && r.metadata.name == "gpu-p6-b300-spot"])
    error_message = "GPU NodePool must label workload-type=gpu, taint nvidia.com/gpu and default expireAfter=Never."
  }
}

run "efa_layouts_per_type" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [
      { name = "p5", instance_type = "p5.48xlarge" },
      { name = "g6e8", instance_type = "g6e.8xlarge" },
      { name = "g5", instance_type = "g5.48xlarge", instance_store_policy = "" },
    ]
  }
  # p5: NIC0 carries EFA -> extra efa-only at (0,1); 1 + 1 + 31 = 33.
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : length(r.spec.networkInterfaces)
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-p5"][0] == 33
    error_message = "p5.48xlarge must get 33 interfaces (interface + efa-only at (0,1) + 31 efa-only cards)."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.networkInterfaces
      if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-g6e8"][0] == [
      { networkCardIndex = 0, deviceIndex = 0, interfaceType = "interface" },
      { networkCardIndex = 0, deviceIndex = 1, interfaceType = "efa-only" },
    ]
    error_message = "single-NIC EFA types (g6e.8xlarge) must get interface + efa-only on card 0."
  }
  # Not in the catalog -> no EFA -> no networkInterfaces at all.
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : !contains(keys(r.spec), "networkInterfaces") && !contains(keys(r.spec), "instanceStorePolicy")
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-g5"][0]
    error_message = "types without an EFA layout must not render networkInterfaces; instance_store_policy=\"\" must omit instanceStorePolicy."
  }
  # CRD rule on every pool: unique (card,device) pairs, at most one efa-only per card.
  assert {
    condition = alltrue([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : (
      length(distinct([for i in r.spec.networkInterfaces : "${i.networkCardIndex}/${i.deviceIndex}"])) == length(r.spec.networkInterfaces)
      && length(distinct([for i in r.spec.networkInterfaces : i.networkCardIndex if i.interfaceType == "efa-only"])) == length([for i in r.spec.networkInterfaces : 1 if i.interfaceType == "efa-only"])
    ) if r.kind == "EC2NodeClass" && contains(keys(r.spec), "networkInterfaces")])
    error_message = "networkInterfaces must satisfy the EC2NodeClass CRD rules (unique card/device, <=1 efa-only per card)."
  }
}

run "raid0_without_instance_store_fails" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [{ name = "p5", instance_type = "p5.48xlarge" }]
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      instance_storage_supported = false
      default_vcpus              = 192
      gpus                       = [{ count = 8, manufacturer = "NVIDIA", memory_size = 81920, name = "H100" }]
    }
  }
  expect_failures = [helm_release.karpenter_pools]
}

run "invalid_capacity_type_rejected" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [{ name = "x", instance_type = "p5.48xlarge", capacity_types = ["reserved"] }]
  }
  expect_failures = [var.gpu_nodepools]
}

# Golden guards added BEFORE Neuron support (phase 2) — NVIDIA-only output must never change.
run "golden_nvidia_no_gpu_pools" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  assert {
    condition     = sha256(helm_release.karpenter_pools.values[0]) == "4b42a79cd9c9cb0dee44bf55530be4f5d627304a41b0f5d3a7db196669608730"
    error_message = "the karpenter-pools release with no gpu_nodepools changed (byte-level): ${sha256(helm_release.karpenter_pools.values[0])}"
  }
}

# Golden guards added BEFORE Neuron support (phase 2) — NVIDIA-only output must never change.
run "golden_nvidia_mixed_pools" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [
      { name = "p6-b300-spot", instance_type = "p6-b300.48xlarge", zones = ["ap-south-2c"] },
      { name = "p5", instance_type = "p5.48xlarge", capacity_types = ["on-demand"], max_nodes = 2 },
      { name = "g5", instance_type = "g5.48xlarge", instance_store_policy = "" },
    ]
    gpu_ami_selector = "al2023@v20260818"
  }
  assert {
    condition     = sha256(helm_release.karpenter_pools.values[0]) == "fc7da63fdd98b45b73e62128d45f6e7f4be26b63a3c734ca8d3fb0722fbf3c4a"
    error_message = "NVIDIA-only GPU NodePools changed (byte-level): ${sha256(helm_release.karpenter_pools.values[0])}"
  }
  assert {
    condition = sha256([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.userData
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-p5"][0]) == "a848a20d163d301fe04a94da455049cc50cef6d22a81855b9b9f0fda8bda58f3"
    error_message = "NVIDIA GPU NodePool userData changed."
  }
  assert {
    condition = sha256(jsonencode([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-p5"][0])) == "72a6498dd51e77c06725fcc61e2429a70c597e70b9f0710eefdcef59df210d84"
    error_message = "EC2NodeClass gpu-p5 changed."
  }
  assert {
    condition = sha256(jsonencode([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r
    if r.kind == "NodePool" && r.metadata.name == "gpu-p5"][0])) == "477201457c6d76026576a2fea49f2322ace76b743677d506c887c41a4258ec34"
    error_message = "NodePool gpu-p5 changed."
  }
  # H_SUB: the decoded resource list. mixed_nvidia_and_neuron_pools filters
  # its trn2 objects out and must land on the same hash.
  assert {
    condition     = sha256(jsonencode(yamldecode(helm_release.karpenter_pools.values[0]).resources)) == "81df70c479619d31c3b357add8e1cb4c521e846a2ca82c4b7f7e2cbab8f9bec1"
    error_message = "NVIDIA-only decoded resource list (H_SUB) changed."
  }
}

# Golden guards added BEFORE Neuron support (phase 2) — NVIDIA-only output must never change.
run "golden_nvidia_custom_ami_id" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools    = [{ name = "p5", instance_type = "p5.48xlarge" }]
    gpu_ami_selector = "ami-0123456789abcdef0"
  }
  assert {
    condition     = sha256(helm_release.karpenter_pools.values[0]) == "a3b5166018fb5bb0cba09917e40ca48c4ccde70961421ee37c66538ff57c8865"
    error_message = "NVIDIA GPU NodePool with a custom AMI id changed (byte-level): ${sha256(helm_release.karpenter_pools.values[0])}"
  }
}

# =====================================================================
# Neuron (trn*/inf*) GPU NodePools (phase 2)
#
# NOTE: override_data REPLACES the file-level mock (no merge), so every
# override repeats instance_storage_supported, default_vcpus, gpus and
# neuron_devices. It also applies to EVERY instance of
# data.aws_ec2_instance_type.gpu — per-type device counts are only realistic
# in the single-type runs below.
# =====================================================================

# NVIDIA and Neuron pools side by side: the NVIDIA objects must be exactly
# the golden_nvidia_mixed_pools ones; trn2 gets the Neuron contract.
run "mixed_nvidia_and_neuron_pools" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [
      { name = "p6-b300-spot", instance_type = "p6-b300.48xlarge", zones = ["ap-south-2c"] },
      { name = "p5", instance_type = "p5.48xlarge", capacity_types = ["on-demand"], max_nodes = 2 },
      { name = "g5", instance_type = "g5.48xlarge", instance_store_policy = "" },
      { name = "trn2", instance_type = "trn2.48xlarge", capacity_types = ["on-demand"], max_nodes = 2 },
    ]
    gpu_ami_selector    = "al2023@v20260818"
    neuron_ami_selector = "al2023@v20261031"
  }

  # --- NVIDIA side unchanged
  assert {
    condition = sha256(jsonencode([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r
    if r.metadata.name != "gpu-trn2"])) == "81df70c479619d31c3b357add8e1cb4c521e846a2ca82c4b7f7e2cbab8f9bec1"
    error_message = "adding a Neuron pool changed the NVIDIA / CPU objects (H_SUB mismatch)."
  }
  assert {
    condition = sha256(jsonencode([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-p5"][0])) == "72a6498dd51e77c06725fcc61e2429a70c597e70b9f0710eefdcef59df210d84"
    error_message = "EC2NodeClass gpu-p5 changed next to a Neuron pool."
  }
  assert {
    condition = sha256(jsonencode([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r
    if r.kind == "NodePool" && r.metadata.name == "gpu-p5"][0])) == "477201457c6d76026576a2fea49f2322ace76b743677d506c887c41a4258ec34"
    error_message = "NodePool gpu-p5 changed next to a Neuron pool."
  }
  assert {
    condition = sha256([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.userData
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-p5"][0]) == "a848a20d163d301fe04a94da455049cc50cef6d22a81855b9b9f0fda8bda58f3"
    error_message = "NVIDIA userData changed next to a Neuron pool."
  }

  # --- trn2 NodePool
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.template.metadata.labels
    if r.kind == "NodePool" && r.metadata.name == "gpu-trn2"][0] == { "workload-type" = "neuron", "gpu-instance-type" = "trn2.48xlarge" }
    error_message = "Neuron NodePool labels must be exactly workload-type=neuron + gpu-instance-type."
  }
  assert {
    condition = jsonencode([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.template.spec.taints
    if r.kind == "NodePool" && r.metadata.name == "gpu-trn2"][0]) == jsonencode([{ key = "aws.amazon.com/neuron", value = "true", effect = "NoSchedule" }])
    error_message = "Neuron NodePool must taint aws.amazon.com/neuron=true:NoSchedule (and nothing else)."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.limits
    if r.kind == "NodePool" && r.metadata.name == "gpu-trn2"][0] == { "aws.amazon.com/neuron" = "32" }
    error_message = "max_nodes=2 x 16 Trainium2 devices must limit the pool to aws.amazon.com/neuron=32 (never neuroncore / nvidia.com/gpu)."
  }
  # Vendor-agnostic NodePool fields (shared with NVIDIA; not covered by H_SUB,
  # which filters gpu-trn2 out): pin them so a vendor split cannot drop
  # capacity_types or misroute nodeClassRef unnoticed.
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources :
      jsonencode(r.spec.template.spec.nodeClassRef) == jsonencode({ group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "gpu-trn2" })
      && jsonencode(r.spec.template.spec.requirements) == jsonencode([
        { key = "node.kubernetes.io/instance-type", operator = "In", values = ["trn2.48xlarge"] },
        { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
      ])
      && r.spec.template.spec.expireAfter == "Never"
      && jsonencode(r.spec.disruption) == jsonencode({ budgets = [{ nodes = "1" }], consolidateAfter = "1h", consolidationPolicy = "WhenEmpty" })
      && r.spec.weight == 50
    if r.kind == "NodePool" && r.metadata.name == "gpu-trn2"][0]
    error_message = "Neuron NodePool must reference EC2NodeClass gpu-trn2 and keep the shared instance-type / capacity-type requirements, expireAfter, disruption and weight."
  }

  # --- trn2 EC2NodeClass
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources :
      jsonencode(r.spec.amiSelectorTerms) == jsonencode([{ alias = "al2023@v20261031" }]) && !contains(keys(r.spec), "amiFamily")
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-trn2"][0]
    error_message = "Neuron EC2NodeClass must use neuron_ami_selector as an alias (no amiFamily)."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.instanceStorePolicy
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-trn2"][0] == "RAID0"
    error_message = "trn2 must keep the default instanceStorePolicy: RAID0."
  }
  assert {
    condition = jsonencode([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.networkInterfaces
      if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-trn2"][0]) == jsonencode(concat(
      [{ networkCardIndex = 0, deviceIndex = 0, interfaceType = "interface" }],
      [{ networkCardIndex = 0, deviceIndex = 1, interfaceType = "efa-only" }],
      [for i in range(1, 16) : { networkCardIndex = i, deviceIndex = 0, interfaceType = "efa-only" }],
    ))
    error_message = "trn2.48xlarge needs 17 interfaces: (0,0) interface, (0,1) efa-only, cards 1..15 efa-only."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.tags["gpu-instance-type"]
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-trn2"][0] == "trn2.48xlarge"
    error_message = "Neuron EC2NodeClass must tag gpu-instance-type."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources :
      strcontains(r.spec.userData, "Content-Type: text/cloud-boothook")
      && strcontains(r.spec.userData, "efa-keyring.gpg")
      && strcontains(r.spec.userData, "Neuron Node Bootstrap Complete")
      && !strcontains(r.spec.userData, "SystemdCgroup")
      && !strcontains(r.spec.userData, "runtimes.nvidia")
      && !strcontains(r.spec.userData, "NVIDIA open-kmod fixup")
      && !strcontains(r.spec.userData, "application/node.eks.aws")
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-trn2"][0]
    error_message = "Neuron userData must be the EFA boothook only (no NVIDIA containerd overlay, no g7 kmod fixup, no NodeConfig part)."
  }
  assert {
    condition     = output.gpu_nodepool_vendors == { "p6-b300-spot" = "nvidia", p5 = "nvidia", g5 = "nvidia", trn2 = "neuron" }
    error_message = "gpu_nodepool_vendors must classify by name: ${jsonencode(output.gpu_nodepool_vendors)}"
  }
}

# An NVIDIA custom ami- id must never leak to Neuron pools.
run "neuron_ami_routing_nvidia_custom_id" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [
      { name = "p5", instance_type = "p5.48xlarge" },
      { name = "trn2", instance_type = "trn2.48xlarge" },
    ]
    gpu_ami_selector = "ami-0123456789abcdef0"
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources :
      jsonencode(r.spec.amiSelectorTerms) == jsonencode([{ id = "ami-0123456789abcdef0" }]) && r.spec.amiFamily == "AL2023"
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-p5"][0]
    error_message = "NVIDIA pool must use the custom AMI id with amiFamily AL2023."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources :
      jsonencode(r.spec.amiSelectorTerms) == jsonencode([{ alias = "al2023@latest" }]) && !contains(keys(r.spec), "amiFamily")
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-trn2"][0]
    error_message = "Neuron pool must keep the default al2023@latest alias (no amiFamily) when only gpu_ami_selector is an ami- id."
  }
}

run "neuron_ami_routing_neuron_custom_id" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [
      { name = "p5", instance_type = "p5.48xlarge" },
      { name = "trn2", instance_type = "trn2.48xlarge" },
    ]
    gpu_ami_selector    = "al2023@latest"
    neuron_ami_selector = "ami-0fedcba9876543210"
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources :
      jsonencode(r.spec.amiSelectorTerms) == jsonencode([{ id = "ami-0fedcba9876543210" }]) && r.spec.amiFamily == "AL2023"
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-trn2"][0]
    error_message = "Neuron pool must use neuron_ami_selector's ami- id with amiFamily AL2023."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources :
      jsonencode(r.spec.amiSelectorTerms) == jsonencode([{ alias = "al2023@latest" }]) && !contains(keys(r.spec), "amiFamily")
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-p5"][0]
    error_message = "NVIDIA pool must keep gpu_ami_selector's alias (no amiFamily)."
  }
}

run "same_custom_ami_for_both_vendors_rejected" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [
      { name = "p5", instance_type = "p5.48xlarge" },
      { name = "trn2", instance_type = "trn2.48xlarge" },
    ]
    gpu_ami_selector    = "ami-0123456789abcdef0"
    neuron_ami_selector = "ami-0123456789abcdef0"
  }
  expect_failures = [helm_release.karpenter_pools]
}

# Regression: the reuse guard needs BOTH vendors. Neuron-only pools with a
# Neuron ami- id copied (not moved) into karpenter_neuron_ami_selector while
# the old karpenter_gpu_ami_selector is left in place: gpu_ami_selector is
# never rendered, so the plan must succeed and the trn2 pool must use the id.
run "same_custom_ami_neuron_only_ok" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools       = [{ name = "trn2", instance_type = "trn2.48xlarge" }]
    gpu_ami_selector    = "ami-0123456789abcdef0"
    neuron_ami_selector = "ami-0123456789abcdef0"
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources :
      jsonencode(r.spec.amiSelectorTerms) == jsonencode([{ id = "ami-0123456789abcdef0" }]) && r.spec.amiFamily == "AL2023"
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-trn2"][0]
    error_message = "a Neuron-only config must accept gpu_ami_selector == neuron_ami_selector and render the id with amiFamily AL2023."
  }
}

# The reuse guard only fires when a Neuron pool exists.
run "same_custom_ami_nvidia_only_ok" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools       = [{ name = "p5", instance_type = "p5.48xlarge" }]
    gpu_ami_selector    = "ami-0123456789abcdef0"
    neuron_ami_selector = "ami-0123456789abcdef0"
  }
  assert {
    condition     = sha256(helm_release.karpenter_pools.values[0]) == "a3b5166018fb5bb0cba09917e40ca48c4ccde70961421ee37c66538ff57c8865"
    error_message = "neuron_ami_selector must not affect NVIDIA-only output."
  }
}

# The neuron_ami_selector format check is a precondition gated on a Neuron
# pool existing (not a variable validation): the root always derives and
# passes a value, possibly from an ignored gpu_ami_release_version.
run "invalid_neuron_ami_selector_rejected" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    neuron_ami_selector = "al2023@foo"
    gpu_nodepools       = [{ name = "trn2", instance_type = "trn2.48xlarge" }]
  }
  expect_failures = [helm_release.karpenter_pools]
}

# Regression: NVIDIA-only config with a custom ami- id plus a leftover,
# malformed gpu_ami_release_version ("20260512", no leading v). The root
# renders neuron_ami_selector = "al2023@20260512"; it must be ignored and the
# output must stay byte-identical to golden_nvidia_custom_ami_id.
run "malformed_neuron_ami_selector_ignored_without_neuron_pool" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools       = [{ name = "p5", instance_type = "p5.48xlarge" }]
    gpu_ami_selector    = "ami-0123456789abcdef0"
    neuron_ami_selector = "al2023@20260512"
  }
  assert {
    condition     = sha256(helm_release.karpenter_pools.values[0]) == "a3b5166018fb5bb0cba09917e40ca48c4ccde70961421ee37c66538ff57c8865"
    error_message = "a malformed neuron_ami_selector must not fail or change an NVIDIA-only config."
  }
}

# Same, with no GPU pools at all.
run "malformed_neuron_ami_selector_ignored_without_gpu_pools" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    neuron_ami_selector = "al2023@20260512"
  }
  assert {
    condition     = sha256(helm_release.karpenter_pools.values[0]) == "4b42a79cd9c9cb0dee44bf55530be4f5d627304a41b0f5d3a7db196669608730"
    error_message = "a malformed neuron_ami_selector must not fail or change a config without GPU pools."
  }
}

# inf2: no EFA layout in the catalog, no Instance Store.
run "inf2_no_efa_no_instance_store" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [{ name = "inf2", instance_type = "inf2.48xlarge", instance_store_policy = "" }]
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      instance_storage_supported = false
      default_vcpus              = 192
      gpus                       = []
      neuron_devices             = [{ count = 12, core_count = 2, core_version = 2, memory_size = 32768, name = "Inferentia2" }]
    }
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : !contains(keys(r.spec), "networkInterfaces") && !contains(keys(r.spec), "instanceStorePolicy")
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-inf2"][0]
    error_message = "inf2 must render neither networkInterfaces (no EFA) nor instanceStorePolicy (instance_store_policy = \"\")."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources :
      r.spec.limits == { "aws.amazon.com/neuron" = "12" } && r.spec.template.metadata.labels["workload-type"] == "neuron"
    if r.kind == "NodePool" && r.metadata.name == "gpu-inf2"][0]
    error_message = "inf2.48xlarge (12 Inferentia2 devices) must limit aws.amazon.com/neuron=12 and label workload-type=neuron."
  }
}

run "inf2_raid0_default_fails" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [{ name = "inf2", instance_type = "inf2.48xlarge" }]
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      instance_storage_supported = false
      default_vcpus              = 192
      gpus                       = []
      neuron_devices             = [{ count = 12, core_count = 2, core_version = 2, memory_size = 32768, name = "Inferentia2" }]
    }
  }
  expect_failures = [helm_release.karpenter_pools]
}

run "trn1_32xlarge_layout" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [{ name = "trn1", instance_type = "trn1.32xlarge" }]
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      instance_storage_supported = true
      default_vcpus              = 128
      gpus                       = []
      neuron_devices             = [{ count = 16, core_count = 2, core_version = 2, memory_size = 32768, name = "Trainium" }]
    }
  }
  assert {
    condition = jsonencode([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.networkInterfaces
      if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-trn1"][0]) == jsonencode(concat(
      [{ networkCardIndex = 0, deviceIndex = 0, interfaceType = "interface" }],
      [{ networkCardIndex = 0, deviceIndex = 1, interfaceType = "efa-only" }],
      [for i in range(1, 8) : { networkCardIndex = i, deviceIndex = 0, interfaceType = "efa-only" }],
    ))
    error_message = "trn1.32xlarge needs 9 interfaces: (0,0) interface, (0,1) efa-only, cards 1..7 efa-only."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.limits
    if r.kind == "NodePool" && r.metadata.name == "gpu-trn1"][0] == { "aws.amazon.com/neuron" = "16" }
    error_message = "trn1.32xlarge (16 Trainium devices) must limit aws.amazon.com/neuron=16."
  }
}

run "trn2_3xlarge_layout" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [{ name = "trn2-3x", instance_type = "trn2.3xlarge" }]
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      instance_storage_supported = true
      default_vcpus              = 12
      gpus                       = []
      neuron_devices             = [{ count = 1, core_count = 8, core_version = 3, memory_size = 98304, name = "Trainium2" }]
    }
  }
  assert {
    condition = jsonencode([for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.networkInterfaces
      if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-trn2-3x"][0]) == jsonencode([
      { networkCardIndex = 0, deviceIndex = 0, interfaceType = "interface" },
      { networkCardIndex = 0, deviceIndex = 1, interfaceType = "efa-only" },
    ])
    error_message = "trn2.3xlarge (1 card, 1 EFA) must get interface + efa-only on card 0."
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.limits
    if r.kind == "NodePool" && r.metadata.name == "gpu-trn2-3x"][0] == { "aws.amazon.com/neuron" = "1" }
    error_message = "trn2.3xlarge (1 Trainium2 device) must limit aws.amazon.com/neuron=1."
  }
}

# Neuron by name but no NeuronInfo from EC2 (trn2u.48xlarge in ap-south-2;
# elsewhere EC2 does not describe it and the data source read fails first).
run "trn2u_without_neuroninfo_rejected" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [{ name = "trn2u", instance_type = "trn2u.48xlarge" }]
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      instance_storage_supported = true
      default_vcpus              = 192
      gpus                       = []
      neuron_devices             = []
    }
  }
  expect_failures = [helm_release.karpenter_pools]
}

# EC2 reports Neuron devices for a name the regex misses -> must fail rather
# than render the NVIDIA contract.
run "neuron_devices_on_non_neuron_name_rejected" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_nodepools = [{ name = "zz9", instance_type = "zz9.48xlarge" }]
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      instance_storage_supported = true
      default_vcpus              = 192
      gpus                       = []
      neuron_devices             = [{ count = 16, core_count = 8, core_version = 3, memory_size = 98304, name = "Trainium2" }]
    }
  }
  expect_failures = [helm_release.karpenter_pools]
}

run "neuron_old_karpenter_rejected" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = "1.10.0"
    gpu_nodepools     = [{ name = "trn2", instance_type = "trn2.48xlarge" }]
  }
  expect_failures = [helm_release.karpenter_pools]
}

# The Karpenter >= 1.11 floor is Neuron-only (NVIDIA behaviour unchanged).
run "nvidia_old_karpenter_unaffected" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = "1.10.0"
    gpu_nodepools     = [{ name = "p5", instance_type = "p5.48xlarge" }]
  }
  assert {
    condition     = length(yamldecode(helm_release.karpenter_pools.values[0]).resources) == 6
    error_message = "an NVIDIA-only pool must still plan with karpenter_version < 1.11."
  }
}

# The >= 1.11 floor applies only to Neuron pools that render
# networkInterfaces (EFA); inf2 renders none and plans on 1.10.
run "inf2_old_karpenter_ok" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = "1.10.0"
    gpu_nodepools     = [{ name = "inf2", instance_type = "inf2.48xlarge", instance_store_policy = "" }]
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      instance_storage_supported = false
      default_vcpus              = 192
      gpus                       = []
      neuron_devices             = [{ count = 12, core_count = 2, core_version = 2, memory_size = 32768, name = "Inferentia2" }]
    }
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources : r.spec.limits == { "aws.amazon.com/neuron" = "12" }
    if r.kind == "NodePool" && r.metadata.name == "gpu-inf2"][0]
    error_message = "a non-EFA Neuron pool must plan with karpenter_version 1.10."
  }
}

# Every Neuron pool still needs >= 1.1 (NeuronInfo-based capacity).
run "inf2_pre_1_1_karpenter_rejected" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = "1.0.8"
    gpu_nodepools     = [{ name = "inf2", instance_type = "inf2.48xlarge", instance_store_policy = "" }]
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = {
      instance_storage_supported = false
      default_vcpus              = 192
      gpus                       = []
      neuron_devices             = [{ count = 12, core_count = 2, core_version = 2, memory_size = 32768, name = "Inferentia2" }]
    }
  }
  expect_failures = [helm_release.karpenter_pools]
}

run "neuron_efa_userspace_disabled" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    gpu_install_efa_userspace = false
    gpu_nodepools             = [{ name = "trn2", instance_type = "trn2.48xlarge" }]
  }
  assert {
    condition = [for r in yamldecode(helm_release.karpenter_pools.values[0]).resources :
      strcontains(r.spec.userData, "EFA userspace install disabled") && !strcontains(r.spec.userData, "efa-keyring.gpg")
    if r.kind == "EC2NodeClass" && r.metadata.name == "gpu-trn2"][0]
    error_message = "gpu_install_efa_userspace = false must drop the EFA install from Neuron userData too."
  }
}
