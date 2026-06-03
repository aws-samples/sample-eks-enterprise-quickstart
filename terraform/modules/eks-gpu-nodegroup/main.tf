data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# ===================================================================
# Per-instance-type EFA layout
#
# efa_only_count: number of EFA-only NICs on indices 1..N (primary NIC at
# index 0). p6-b300 is special: NIC 0 is ENA-only, NIC 1..16 carry EFA.
# Unknown instance types fall back to no EFA (efa_only_count=0,
# primary_efa=false) — the LT will then provision a plain ENA NIC and
# silently skip the EFA-only NICs.
# ===================================================================
locals {
  efa_layout_default = { efa_only_count = 0, primary_efa = false }
  efa_layout = {
    # Multi-NIC training accelerators
    "p5.48xlarge"      = { efa_only_count = 31, primary_efa = true }
    "p5en.48xlarge"    = { efa_only_count = 15, primary_efa = true }
    "p6-b200.48xlarge" = { efa_only_count = 7, primary_efa = true }
    "p6-b300.48xlarge" = { efa_only_count = 16, primary_efa = false } # NIC 0 = ENA only

    # G6e (NVIDIA L40S) — EFA enabled on 8xlarge+; smaller sizes have no EFA.
    # MaximumNetworkCards: 1 for 8/12/16xlarge, 2 for 24xlarge, 4 for 48xlarge.
    "g6e.8xlarge"  = { efa_only_count = 0, primary_efa = true }
    "g6e.12xlarge" = { efa_only_count = 0, primary_efa = true }
    "g6e.16xlarge" = { efa_only_count = 0, primary_efa = true }
    "g6e.24xlarge" = { efa_only_count = 1, primary_efa = true }
    "g6e.48xlarge" = { efa_only_count = 3, primary_efa = true }

    # G7e (NVIDIA RTX PRO 6000 Blackwell) — EFAv4, GPUDirect RDMA on multi-GPU sizes.
    # MaximumNetworkCards: 1 for 8/12xlarge, 2 for 24xlarge, 4 for 48xlarge.
    # 2/4xlarge sizes have no EFA support and intentionally absent.
    "g7e.8xlarge"  = { efa_only_count = 0, primary_efa = true }
    "g7e.12xlarge" = { efa_only_count = 0, primary_efa = true }
    "g7e.24xlarge" = { efa_only_count = 1, primary_efa = true }
    "g7e.48xlarge" = { efa_only_count = 3, primary_efa = true }
  }

  # NG key = "<resource-name>-<purchase>-<suffix>". Used as for_each key
  # everywhere to keep all per-NG resources aligned.
  nodegroups_map = {
    for ng in var.gpu_nodegroups :
    "${replace(ng.gpu_type, ".", "-")}-${ng.purchase_option}${ng.suffix}" => ng
  }

  # Per-NG resolved EFA layout — pre-computed once, referenced by LT
  # primary NIC type and the EFA-only NIC dynamic block.
  ng_layout = {
    for k, ng in local.nodegroups_map : k => lookup(local.efa_layout, ng.gpu_type, local.efa_layout_default)
  }

  # Primary NIC interface_type per NG.
  #   - primary_efa=true : "efa" (EFA + ENA on the same NIC; covers single-NIC
  #                       EFA shapes like g6e.8/12/16xlarge and g7e.8/12xlarge
  #                       where efa_only_count=0 but the primary NIC still
  #                       carries EFA)
  #   - primary_efa=false: "interface" (pure ENA — p6-b300 NIC0, or non-EFA
  #                       fallback)
  ng_primary_interface_type = {
    for k, l in local.ng_layout : k => (l.primary_efa ? "efa" : "interface")
  }
}

# ===================================================================
# Architecture detection (all GPU types in a single deploy must share arch)
# ===================================================================
data "aws_ec2_instance_type" "gpu" {
  for_each      = toset([for ng in var.gpu_nodegroups : ng.gpu_type])
  instance_type = each.key
}

locals {
  # Architecture of the first declared GPU type — used for AMI lookup.
  # All declared GPU types must agree (validated below).
  gpu_arches = distinct([
    for it in data.aws_ec2_instance_type.gpu :
    contains(it.supported_architectures, "arm64") ? "arm64" : "x86_64"
  ])

  gpu_arch = length(local.gpu_arches) > 0 ? local.gpu_arches[0] : "x86_64"
}

resource "null_resource" "validate_arch_uniform" {
  lifecycle {
    precondition {
      condition     = length(local.gpu_arches) <= 1
      error_message = "gpu_nodegroups mixes architectures (${join(", ", local.gpu_arches)}). Split into separate apply runs with homogeneous gpu_type."
    }
  }
}

# SSM publishes per-release paths
#   /aws/service/eks/optimized-ami/<k8s>/amazon-linux-2023/<arch>/nvidia/amazon-eks-node-al2023-<arch>-nvidia-<k8s>-v<YYYYMMDD>/image_id
# and a moving alias
#   /aws/service/eks/optimized-ami/<k8s>/amazon-linux-2023/<arch>/nvidia/recommended/image_id
# Pinning to a specific release keeps the GPU stack reproducible; var=""
# means follow recommended (next apply may roll the AMI underneath you).
locals {
  gpu_ami_ssm_path = (
    var.gpu_ami_release_version == "" ?
    "/aws/service/eks/optimized-ami/${var.k8s_version}/amazon-linux-2023/${local.gpu_arch}/nvidia/recommended/image_id" :
    "/aws/service/eks/optimized-ami/${var.k8s_version}/amazon-linux-2023/${local.gpu_arch}/nvidia/amazon-eks-node-al2023-${local.gpu_arch}-nvidia-${var.k8s_version}-${var.gpu_ami_release_version}/image_id"
  )
}

data "aws_ssm_parameter" "gpu_ami" {
  # Skip the SSM lookup entirely when the operator pins a custom AMI;
  # otherwise we'd fail apply if the SSM path doesn't exist (e.g. running
  # on a k8s_version that AWS hasn't published a recommended NVIDIA AMI
  # for yet, but the operator has baked their own).
  count = var.gpu_custom_ami_id != "" ? 0 : 1
  name  = local.gpu_ami_ssm_path
}

# ===================================================================
# IAM role for GPU nodes (shared across all GPU NGs in this module)
# ===================================================================
resource "aws_iam_role" "gpu_node" {
  name = "GPUNodeRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gpu_worker" {
  role       = aws_iam_role.gpu_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "gpu_cni" {
  role       = aws_iam_role.gpu_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "gpu_ecr" {
  role       = aws_iam_role.gpu_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "gpu_ssm" {
  role       = aws_iam_role.gpu_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "gpu_nodeadm" {
  name = "NodeadmDescribeInstances"
  role = aws_iam_role.gpu_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances", "ec2:DescribeTags"]
      Resource = "*"
    }]
  })
}

# Self-managed ASGs launch EC2 instances directly from the Launch Template,
# so the LT must reference an IAM instance profile. (Managed NGs don't need
# this — EKS auto-creates an instance profile from the node_role_arn we
# pass on the aws_eks_node_group resource.)
resource "aws_iam_instance_profile" "gpu_node" {
  count = var.node_management == "self_managed" ? 1 : 0

  name = "GPUNodeProfile-${var.cluster_name}"
  role = aws_iam_role.gpu_node.name
}

resource "aws_eks_access_entry" "gpu_node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.gpu_node.arn
  type          = "EC2_LINUX"
}

# ===================================================================
# GPU security group with self-referencing all-traffic rules.
# Required for EFA / NCCL cross-node traffic per AWS docs.
# ===================================================================
resource "aws_security_group" "gpu" {
  name        = "${var.cluster_name}-gpu-node-sg"
  description = "Security group for GPU nodes with EFA"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.cluster_name}-gpu-node-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "gpu_self" {
  security_group_id            = aws_security_group.gpu.id
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.gpu.id
  description                  = "EFA self-allow"
}

resource "aws_vpc_security_group_egress_rule" "gpu_self" {
  security_group_id            = aws_security_group.gpu.id
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.gpu.id
  description                  = "EFA self-egress"
}

# ===================================================================
# Placement groups (only for NGs requesting cluster strategy)
# ===================================================================
locals {
  # Resolve effective subnets per NG (per-NG subnet_ids if set+non-empty,
  # else fall back to module-level private_subnet_ids).
  ng_subnets = {
    for k, ng in local.nodegroups_map : k => (
      ng.subnet_ids != null && length(coalesce(ng.subnet_ids, [])) > 0 ? ng.subnet_ids : var.private_subnet_ids
    )
  }

  # NGs requesting placement_group=cluster AND resolving to a single AZ.
  # Multi-AZ NGs cannot use cluster PG (AWS rejects), so we filter at plan time.
  pg_eligible = {
    for k, ng in local.nodegroups_map : k => ng
    if ng.placement_group == "cluster" && length(local.ng_subnets[k]) == 1
  }
}

resource "aws_placement_group" "gpu" {
  for_each = local.pg_eligible
  name     = "${var.cluster_name}-${each.key}-pg"
  strategy = "cluster"

  tags = {
    gpu-instance-type = each.value.gpu_type
  }
}

# ===================================================================
# Per-NG userdata
#
# In managed mode all entries share an identical userdata (EKS injects
# labels/taints via the NodeGroup API). In self_managed mode each entry
# gets its own userdata with extra kubelet --node-labels embedding the
# NG-specific identifiers (workload-type, gpu-instance-type,
# purchase-option, plus suffix/odcr-id when set), plus
# --register-with-taints=nvidia.com/gpu=true:NoSchedule (also injected
# by EKS in managed mode).
# ===================================================================
locals {
  # Per-NG capacity_reservation_id, normalised: optional+null in the
  # input schema collapses to "" so downstream string interpolation
  # never sees null. NOTE: do NOT use coalesce() here — Terraform's
  # coalesce rejects BOTH null AND "" and would throw on a spot/od entry
  # that legitimately has no CR id. Explicit null-check is the only
  # correct form.
  ng_capacity_reservation_id = {
    for k, ng in local.nodegroups_map : k => (ng.capacity_reservation_id != null ? ng.capacity_reservation_id : "")
  }

  # Per-NG extra labels (only meaningful when node_management = self_managed).
  # Comma-separated for kubelet --node-labels.
  ng_extra_node_labels = {
    for k, ng in local.nodegroups_map : k => join(",", compact([
      "workload-type=gpu",
      "gpu-instance-type=${ng.gpu_type}",
      "purchase-option=${ng.purchase_option}",
      ng.suffix != "" ? "ng-suffix=${trimprefix(ng.suffix, "-")}" : "",
      local.ng_capacity_reservation_id[k] != "" ? "capacity-reservation-id=${local.ng_capacity_reservation_id[k]}" : "",
    ]))
  }

  # Per-NG taint flag (only meaningful when self_managed; managed mode
  # uses aws_eks_node_group.taint which EKS API injects). Format matches
  # kubelet --register-with-taints.
  ng_node_taints = {
    for k, ng in local.nodegroups_map : k => "nvidia.com/gpu=true:NoSchedule"
  }

  userdata = {
    for k, ng in local.nodegroups_map : k => templatefile("${path.module}/templates/userdata.sh.tpl", {
      cluster_name                 = var.cluster_name
      cluster_endpoint             = var.cluster_endpoint
      cluster_ca                   = var.cluster_ca
      service_ipv4_cidr            = var.service_ipv4_cidr
      enable_local_lvm             = var.enable_local_lvm
      local_lvm_vg_name            = var.local_lvm_vg_name
      local_lvm_lv_name            = var.local_lvm_lv_name
      local_lvm_mount              = var.local_lvm_mount
      local_lvm_fs                 = var.local_lvm_fs
      local_lvm_stripe_kb          = var.local_lvm_stripe_kb
      install_efa_userspace        = var.install_efa_userspace
      efa_installer_version        = var.efa_installer_version
      ebs_data_disk_detect_snippet = file("${path.module}/templates/detect-ebs-disk.sh")
      node_management              = var.node_management
      extra_node_labels            = local.ng_extra_node_labels[k]
      node_taints                  = local.ng_node_taints[k]
    })
  }
}

# ===================================================================
# Launch Template per nodegroup
#
# network_interfaces is fully dynamic: primary NIC index 0 (efa or
# interface), then 1..efa_only_count NICs of type efa-only.
# ===================================================================
resource "aws_launch_template" "gpu" {
  for_each = local.nodegroups_map

  name        = "${var.cluster_name}-gpu-${each.key}-lt"
  description = "GPU LT (${each.value.gpu_type}, ${each.value.purchase_option})"

  # gpu_custom_ami_id (when set) bypasses SSM lookup entirely — for
  # operator-baked AMIs derived from the EKS-NVIDIA base.
  image_id  = var.gpu_custom_ami_id != "" ? var.gpu_custom_ami_id : data.aws_ssm_parameter.gpu_ami[0].value
  user_data = base64encode(local.userdata[each.key])
  key_name  = var.ec2_key_name != "" ? var.ec2_key_name : null

  # When InstanceType must live in the LT:
  #   - Capacity Block (any mode): CB requires InstanceType + InstanceMarketOptions
  #     embedded in the LT.
  #   - Self-managed mode (any purchase_option): the customer-owned ASG launches
  #     instances directly from the LT, so InstanceType is required here too.
  # When we leave it null:
  #   - Managed NG + non-CB purchase_option: aws_eks_node_group.instance_types[*]
  #     drives EKS, and specifying both can conflict on mismatch.
  instance_type = (
    each.value.purchase_option == "cb" || var.node_management == "self_managed"
    ? each.value.gpu_type
    : null
  )

  # IAM instance profile — only required in self_managed mode (managed NG
  # creates one implicitly from aws_eks_node_group.node_role_arn).
  dynamic "iam_instance_profile" {
    for_each = var.node_management == "self_managed" ? [1] : []
    content {
      name = aws_iam_instance_profile.gpu_node[0].name
    }
  }

  # instance_market_options dispatch by (purchase_option, node_management):
  #
  #   purchase_option = "cb"       any mode → market_type=capacity-block (CB
  #                                  requires it embedded in the LT)
  #   purchase_option = "spot"     self_managed → market_type=spot (the
  #                                  customer-owned ASG launches EC2 directly,
  #                                  so spot pricing must come from the LT).
  #                                  managed → leave OFF (EKS reads
  #                                  aws_eks_node_group.capacity_type="SPOT" and
  #                                  injects spot itself; setting the LT field
  #                                  AS WELL conflicts with EKS internals).
  #   purchase_option = "od"/"odcr" any mode → leave OFF (default OD pricing).
  #
  # spot_options: omitted on purpose. AWS defaults are
  # spot_instance_type=one-time, instance_interruption_behavior=terminate —
  # both align with the "no self-healing" contract on suspended_processes
  # (a reclaimed spot instance terminates and stays gone; no ASG replace).
  dynamic "instance_market_options" {
    for_each = (
      each.value.purchase_option == "cb"
      || (each.value.purchase_option == "spot" && var.node_management == "self_managed")
      ? [1] : []
    )
    content {
      market_type = each.value.purchase_option == "cb" ? "capacity-block" : "spot"
    }
  }

  dynamic "capacity_reservation_specification" {
    for_each = contains(["odcr", "cb"], each.value.purchase_option) ? [1] : []
    content {
      capacity_reservation_target {
        capacity_reservation_id = each.value.capacity_reservation_id
      }
    }
  }

  dynamic "placement" {
    for_each = contains(keys(local.pg_eligible), each.key) ? [1] : []
    content {
      group_name = aws_placement_group.gpu[each.key].name
      tenancy    = "default"
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  block_device_mappings {
    device_name = "/dev/xvdb"
    ebs {
      volume_size           = var.data_volume_size
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Primary NIC (NetworkCardIndex=0, DeviceIndex=0). interface_type comes
  # from local.ng_primary_interface_type (computed once per NG), not from
  # an inline ternary.
  network_interfaces {
    network_card_index    = 0
    device_index          = 0
    interface_type        = local.ng_primary_interface_type[each.key]
    delete_on_termination = true
    security_groups       = [aws_security_group.gpu.id, var.cluster_security_group_id]
  }

  # Additional EFA-only NICs (1..efa_only_count for this instance type).
  dynamic "network_interfaces" {
    for_each = range(1, local.ng_layout[each.key].efa_only_count + 1)
    content {
      network_card_index    = network_interfaces.value
      device_index          = 0
      interface_type        = "efa-only"
      delete_on_termination = true
      security_groups       = [aws_security_group.gpu.id, var.cluster_security_group_id]
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name                                        = "${var.cluster_name}-gpu-${replace(each.value.gpu_type, ".", "-")}-node"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
      gpu-instance-type                           = each.value.gpu_type
      purchase-option                             = each.value.purchase_option
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name                                        = "${var.cluster_name}-gpu-${replace(each.value.gpu_type, ".", "-")}-volume"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  }
}

# ===================================================================
# Managed Node Group per NG entry (default; gated off when
# node_management = "self_managed", in which case aws_autoscaling_group.gpu
# below provisions the same set of nodegroups via customer-owned ASGs.)
# ===================================================================
resource "aws_eks_node_group" "gpu" {
  for_each = var.node_management == "managed" ? local.nodegroups_map : {}

  cluster_name    = var.cluster_name
  node_group_name = "gpu-${each.key}"
  node_role_arn   = aws_iam_role.gpu_node.arn
  subnet_ids      = local.ng_subnets[each.key]

  # CB embeds InstanceType in the LT — passing instance_types here would conflict.
  instance_types = each.value.purchase_option == "cb" ? null : [each.value.gpu_type]

  capacity_type = (
    each.value.purchase_option == "spot" ? "SPOT" :
    each.value.purchase_option == "cb" ? "CAPACITY_BLOCK" :
    "ON_DEMAND"
  )

  scaling_config {
    desired_size = each.value.desired_capacity
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  launch_template {
    id      = aws_launch_template.gpu[each.key].id
    version = aws_launch_template.gpu[each.key].latest_version
  }

  labels = {
    workload-type     = "gpu"
    gpu-instance-type = each.value.gpu_type
    purchase-option   = each.value.purchase_option
  }

  taint {
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  # NB: aws_eks_node_group.tags applies to the NG itself (EKS API tags).
  # cluster-autoscaler discovers ASGs by ASG-level tags — see
  # aws_autoscaling_group_tag.gpu_* below for the tags that actually matter
  # to CA.
  tags = {
    gpu-instance-type = each.value.gpu_type
  }

  depends_on = [
    aws_iam_role_policy_attachment.gpu_worker,
    aws_iam_role_policy_attachment.gpu_cni,
    aws_iam_role_policy_attachment.gpu_ecr,
    aws_iam_role_policy_attachment.gpu_ssm,
    aws_eks_access_entry.gpu_node,
  ]
}

# ===================================================================
# cluster-autoscaler ASG discovery tags
#
# CA scans ASGs by tag `k8s.io/cluster-autoscaler/<cluster>=owned` AND
# `k8s.io/cluster-autoscaler/enabled=true`.
#
# Managed mode: EKS owns the ASG; we tag it via aws_autoscaling_group_tag
# after the NG goes ACTIVE (reading the ASG name from .resources output).
# Self-managed mode: tags are inlined directly on the
# aws_autoscaling_group.gpu resource below (this workaround isn't needed).
# ===================================================================
locals {
  gpu_ng_asg_tags = var.node_management == "managed" ? merge([
    for k, ng in aws_eks_node_group.gpu : {
      "${k}-enabled" = {
        asg_name = ng.resources[0].autoscaling_groups[0].name
        key      = "k8s.io/cluster-autoscaler/enabled"
        value    = "true"
      }
      "${k}-owned" = {
        asg_name = ng.resources[0].autoscaling_groups[0].name
        key      = "k8s.io/cluster-autoscaler/${var.cluster_name}"
        value    = "owned"
      }
      "${k}-instance-type" = {
        asg_name = ng.resources[0].autoscaling_groups[0].name
        key      = "k8s.io/cluster-autoscaler/node-template/label/gpu-instance-type"
        value    = ng.labels.gpu-instance-type
      }
    }
  ]...) : {}
}

resource "aws_autoscaling_group_tag" "gpu" {
  for_each               = local.gpu_ng_asg_tags
  autoscaling_group_name = each.value.asg_name

  tag {
    key                 = each.value.key
    value               = each.value.value
    propagate_at_launch = true
  }
}

# ===================================================================
# Self-managed ASGs (one per gpu_nodegroups entry)
#
# Disabled by default — only created when var.node_management = "self_managed".
# All ASG-driven self-healing is off (suspended_processes, no instance_refresh).
# Customers retire instances by id with `aws autoscaling
# terminate-instance-in-auto-scaling-group --instance-id <i-xxx>
# --should-decrement-desired-capacity`.
#
# CA discovery + scale-from-zero hints (label / taint / resource hints)
# are inlined as ASG tags below so an external Cluster Autoscaler can
# pick up the ASGs zero-config.
# ===================================================================
locals {
  # Common per-NG CA / scale-from-zero tag set, computed once per NG.
  # Used both inline on the self-managed ASG resources and (where
  # relevant) referenced from docs.
  gpu_self_managed_asg_tags = {
    for k, ng in(var.node_management == "self_managed" ? local.nodegroups_map : {}) :
    k => merge(
      # CA discovery
      {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      },
      # scale-from-zero label hints
      {
        "k8s.io/cluster-autoscaler/node-template/label/workload-type"     = "gpu"
        "k8s.io/cluster-autoscaler/node-template/label/gpu-instance-type" = ng.gpu_type
        "k8s.io/cluster-autoscaler/node-template/label/purchase-option"   = ng.purchase_option
      },
      # Optional ng-suffix label (only present when suffix is non-empty)
      ng.suffix != "" ? {
        "k8s.io/cluster-autoscaler/node-template/label/ng-suffix" = trimprefix(ng.suffix, "-")
      } : {},
      # Optional capacity-reservation-id label (only for ODCR/CB).
      # Use the pre-coalesced local to avoid null interpolation when
      # capacity_reservation_id is unset in the gpu_nodegroups entry.
      local.ng_capacity_reservation_id[k] != "" ? {
        "k8s.io/cluster-autoscaler/node-template/label/capacity-reservation-id" = local.ng_capacity_reservation_id[k]
      } : {},
      # Taint hint — CA needs this to evaluate scale-from-zero correctly
      {
        "k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu" = "true:NoSchedule"
      },
      # Resource hints — let CA reason about pod fit before launch
      {
        "k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu"        = tostring(local.ng_gpu_count[k])
        "k8s.io/cluster-autoscaler/node-template/resources/vpc.amazonaws.com/efa" = tostring(local.ng_layout[k].efa_only_count + (local.ng_layout[k].primary_efa ? 1 : 0))
      },
      # Always-on instance/cluster tags (mirroring tag_specifications on LT)
      {
        "Name"                                      = "${var.cluster_name}-gpu-${replace(ng.gpu_type, ".", "-")}-node"
        "kubernetes.io/cluster/${var.cluster_name}" = "owned"
        "gpu-instance-type"                         = ng.gpu_type
        "purchase-option"                           = ng.purchase_option
      },
    )
  }

  # GPU count per nodegroup, used as scale-from-zero resource hint.
  # data.aws_ec2_instance_type populates .gpus[*].count for accelerator
  # types; non-GPU types fall back to "0".
  ng_gpu_count = {
    for k, ng in local.nodegroups_map :
    k => try(data.aws_ec2_instance_type.gpu[ng.gpu_type].gpus[0].count, 0)
  }
}

resource "aws_autoscaling_group" "gpu" {
  for_each = var.node_management == "self_managed" ? local.nodegroups_map : {}

  name                = "${var.cluster_name}-gpu-${each.key}"
  vpc_zone_identifier = local.ng_subnets[each.key]
  min_size            = each.value.min_size
  max_size            = each.value.max_size
  desired_capacity    = each.value.desired_capacity

  # No self-healing: ASG never replaces instances, never AZ-rebalances.
  suspended_processes = var.asg_suspended_processes

  # Don't let an ALB target marked unhealthy trigger an EC2 termination.
  health_check_type         = "EC2"
  health_check_grace_period = 600

  launch_template {
    id      = aws_launch_template.gpu[each.key].id
    version = aws_launch_template.gpu[each.key].latest_version
  }

  # CA changes desired_capacity at runtime — terraform must not drift it
  # back on the next apply.
  lifecycle {
    ignore_changes = [desired_capacity]
  }

  # CA discovery + scale-from-zero hints + always-on tags (see local
  # gpu_self_managed_asg_tags for the canonical merged map).
  dynamic "tag" {
    for_each = local.gpu_self_managed_asg_tags[each.key]
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # Customer-supplied governance tags (Owner / CostCenter / Environment etc.)
  dynamic "tag" {
    for_each = var.extra_asg_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.gpu_worker,
    aws_iam_role_policy_attachment.gpu_cni,
    aws_iam_role_policy_attachment.gpu_ecr,
    aws_iam_role_policy_attachment.gpu_ssm,
    aws_eks_access_entry.gpu_node,
    aws_vpc_security_group_ingress_rule.cluster_from_gpu_node,
  ]
}

# Cluster SG must accept traffic from the GPU node SG (kubelet →
# API server, etc.). Managed NG had EKS doing this automatically; in
# self_managed mode we add the rule explicitly.
resource "aws_vpc_security_group_ingress_rule" "cluster_from_gpu_node" {
  count = var.node_management == "self_managed" ? 1 : 0

  security_group_id            = var.cluster_security_group_id
  referenced_security_group_id = aws_security_group.gpu.id
  ip_protocol                  = "-1"
  description                  = "Self-managed GPU nodes to cluster API/control plane"
}

