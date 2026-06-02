data "aws_partition" "current" {}

# Detect instance architecture (arm64/x86_64) from the EC2 API so we never
# misclassify new families like m8g, hpc7g.
data "aws_ec2_instance_type" "main" {
  instance_type = var.instance_type
}

locals {
  arch = contains(data.aws_ec2_instance_type.main.supported_architectures, "arm64") ? "arm64" : "x86_64"
}

# Latest AL2023 EKS-optimized AMI for the cluster's k8s version.
data "aws_ssm_parameter" "eks_ami" {
  name = "/aws/service/eks/optimized-ami/${var.k8s_version}/amazon-linux-2023/${local.arch}/standard/recommended/image_id"
}

# =====================================================================
# IAM role for nodes (EC2 trust)
# =====================================================================
resource "aws_iam_role" "node" {
  name = "EKSNodeRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# nodeadm (k8s 1.34+) requires ec2:DescribeInstances/DescribeTags.
resource "aws_iam_role_policy" "node_nodeadm" {
  name = "NodeadmDescribeInstances"
  role = aws_iam_role.node.id

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
resource "aws_iam_instance_profile" "node" {
  count = var.node_management == "self_managed" ? 1 : 0

  name = "${var.cluster_name}-eks-utils-instance-profile"
  role = aws_iam_role.node.name
}

# Cluster runs in API_AND_CONFIG_MAP authentication mode. With Access Entry
# (preferred over the legacy aws-auth ConfigMap), nodes using this IAM role
# are authorized to join the cluster. Replaces the bash script's manual
# kubectl-patch of aws-auth in 6_create_system_nodegroup.sh step 2.5.
resource "aws_eks_access_entry" "node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"
}

# =====================================================================
# Launch Template (LVM userdata + 2 EBS volumes)
# =====================================================================
# Userdata template renders kubelet --node-labels only when
# node_management = "self_managed" — in managed mode EKS injects labels
# via the NodeGroup API and writing them again would be redundant.
locals {
  userdata = templatefile("${path.module}/templates/userdata.sh.tpl", {
    cluster_name                 = var.cluster_name
    cluster_endpoint             = var.cluster_endpoint
    cluster_ca                   = var.cluster_ca
    service_ipv4_cidr            = var.service_ipv4_cidr
    node_management              = var.node_management
    node_labels                  = "${var.node_label_key}=${var.node_label_value}"
    ebs_data_disk_detect_snippet = file("${path.module}/templates/detect-ebs-disk.sh")
  })
}

resource "aws_launch_template" "system" {
  name        = "${var.cluster_name}-eks-utils-lt"
  description = "System nodegroup with LVM-managed containerd volume"
  image_id    = data.aws_ssm_parameter.eks_ami.value
  user_data   = base64encode(local.userdata)

  # In self_managed mode the ASG launches instances directly from this LT,
  # so instance_type MUST be set here. In managed mode aws_eks_node_group
  # passes its own .instance_types[*] to the EKS-owned ASG and leaving it
  # null in the LT keeps EKS in charge (specifying both can conflict on
  # mismatch).
  instance_type = var.node_management == "self_managed" ? var.instance_type : null

  # IAM instance profile — only required in self_managed mode (managed NG
  # creates one implicitly from aws_eks_node_group.node_role_arn).
  dynamic "iam_instance_profile" {
    for_each = var.node_management == "self_managed" ? [1] : []
    content {
      name = aws_iam_instance_profile.node[0].name
    }
  }

  key_name = var.ec2_key_name != "" ? var.ec2_key_name : null

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

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name                                        = "${var.cluster_name}-eks-utils-node"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name                                        = "${var.cluster_name}-eks-utils-volume"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  }

  # In self_managed mode, the EKS NG controller no longer injects the
  # cluster SG for us — declare the network interface here so EC2 picks
  # both the cluster SG (for control-plane ↔ node traffic) and our own
  # node SG (for self-allow + cluster SG ingress). In managed mode we
  # leave this block off so EKS can inject its NG SG.
  dynamic "network_interfaces" {
    for_each = var.node_management == "self_managed" ? [1] : []
    content {
      device_index          = 0
      delete_on_termination = true
      security_groups = compact([
        aws_security_group.system_node[0].id,
        var.cluster_security_group_id,
      ])
    }
  }
}

# =====================================================================
# Self-managed mode — own node SG + cluster SG ingress
# =====================================================================
# Managed mode: EKS auto-creates a "ng-shared" SG and adds it to the
# cluster SG ingress on its own. In self_managed mode we have to do that
# work ourselves.
resource "aws_security_group" "system_node" {
  count = var.node_management == "self_managed" ? 1 : 0

  name        = "${var.cluster_name}-system-node-sg"
  description = "Self-managed system node SG (EKS-utils)"
  vpc_id      = var.vpc_id

  tags = {
    Name                                        = "${var.cluster_name}-system-node-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  lifecycle {
    precondition {
      condition     = var.vpc_id != ""
      error_message = "vpc_id is required when node_management = \"self_managed\" — pass module.eks_cluster.vpc_id (or your tfvars vpc_id) through to this module."
    }
  }
}

# Self-allow within the node SG (kube-proxy, CNI, etc.).
resource "aws_vpc_security_group_ingress_rule" "system_node_self" {
  count = var.node_management == "self_managed" ? 1 : 0

  security_group_id            = aws_security_group.system_node[0].id
  referenced_security_group_id = aws_security_group.system_node[0].id
  ip_protocol                  = "-1"
  description                  = "Self-allow within system NG"
}

resource "aws_vpc_security_group_egress_rule" "system_node_egress" {
  count = var.node_management == "self_managed" ? 1 : 0

  security_group_id = aws_security_group.system_node[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all egress"
}

# Cluster SG must accept traffic from the node SG (kubelet → API server,
# etc.). Managed NG had EKS doing this automatically.
resource "aws_vpc_security_group_ingress_rule" "cluster_from_system_node" {
  count = var.node_management == "self_managed" ? 1 : 0

  security_group_id            = var.cluster_security_group_id
  referenced_security_group_id = aws_security_group.system_node[0].id
  ip_protocol                  = "-1"
  description                  = "Self-managed system nodes to cluster API/control plane"
}

# =====================================================================
# Managed node group (default; gated off when node_management = self_managed)
# =====================================================================
resource "aws_eks_node_group" "system" {
  count = var.node_management == "managed" ? 1 : 0

  cluster_name    = var.cluster_name
  node_group_name = "eks-utils"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.instance_type]

  scaling_config {
    desired_size = var.desired_capacity
    min_size     = var.min_size
    max_size     = var.max_size
  }

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  labels = {
    (var.node_label_key) = var.node_label_value
  }

  # NB: aws_eks_node_group.tags applies to the NG itself (EKS API tags).
  # cluster-autoscaler discovers ASGs by ASG-level tags — see
  # aws_autoscaling_group_tag.* below for the tags that actually drive CA.
  tags = {}

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_iam_role_policy_attachment.node_ssm,
    aws_eks_access_entry.node,
  ]
}

# ===================================================================
# cluster-autoscaler ASG discovery tags (managed mode only)
#
# In managed mode EKS owns the ASG; we tag it via aws_autoscaling_group_tag
# after the NG goes ACTIVE (reading the ASG name from .resources output).
# In self_managed mode the ASG is ours, so the tags are inlined directly
# on the aws_autoscaling_group.system resource below — this workaround
# isn't needed.
# ===================================================================
locals {
  # Common CA tag set used by both managed (via aws_autoscaling_group_tag)
  # and self_managed (inlined on the new ASG). Kept as a single source of
  # truth so the two paths stay aligned.
  system_ng_ca_tags = {
    "enabled" = {
      key   = "k8s.io/cluster-autoscaler/enabled"
      value = "true"
    }
    "owned" = {
      key   = "k8s.io/cluster-autoscaler/${var.cluster_name}"
      value = "owned"
    }
    "node-template-label" = {
      key   = "k8s.io/cluster-autoscaler/node-template/label/${var.node_label_key}"
      value = var.node_label_value
    }
  }
}

resource "aws_autoscaling_group_tag" "system" {
  for_each = var.node_management == "managed" ? local.system_ng_ca_tags : {}

  autoscaling_group_name = aws_eks_node_group.system[0].resources[0].autoscaling_groups[0].name

  tag {
    key                 = each.value.key
    value               = each.value.value
    propagate_at_launch = true
  }
}

# =====================================================================
# Self-managed ASG (gated on when node_management = self_managed)
# =====================================================================
# All ASG-driven self-healing is disabled by default (see
# var.asg_suspended_processes). Customers retire instances by id with
# `aws autoscaling terminate-instance-in-auto-scaling-group --instance-id
# <i-xxx> --should-decrement-desired-capacity`. CA discovery tags +
# scale-from-zero hints are inlined here so no aws_autoscaling_group_tag
# workaround is needed.
resource "aws_autoscaling_group" "system" {
  count = var.node_management == "self_managed" ? 1 : 0

  name                = "${var.cluster_name}-eks-utils"
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity

  # No self-healing: ASG never replaces instances, never AZ-rebalances.
  suspended_processes = var.asg_suspended_processes

  # Don't let an ALB target marked unhealthy trigger an EC2 termination.
  health_check_type         = "EC2"
  health_check_grace_period = 600

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  # CA changes desired_capacity at runtime — terraform must not drift it
  # back on the next apply.
  lifecycle {
    ignore_changes = [desired_capacity]
  }

  # CA discovery + scale-from-zero hints (inlined; see local
  # system_ng_ca_tags for the canonical list).
  dynamic "tag" {
    for_each = local.system_ng_ca_tags
    content {
      key                 = tag.value.key
      value               = tag.value.value
      propagate_at_launch = true
    }
  }

  # Always-on tags (kubelet labels also reproduce these for the K8s
  # node, since EKS is no longer injecting via the NG API in self_managed).
  tag {
    key                 = var.node_label_key
    value               = var.node_label_value
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-eks-utils-node"
    propagate_at_launch = true
  }

  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
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
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_iam_role_policy_attachment.node_ssm,
    aws_eks_access_entry.node,
    aws_vpc_security_group_ingress_rule.cluster_from_system_node,
  ]
}
