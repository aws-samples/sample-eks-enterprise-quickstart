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
