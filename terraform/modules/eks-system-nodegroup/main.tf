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
locals {
  userdata = templatefile("${path.module}/templates/userdata.sh.tpl", {
    cluster_name                 = var.cluster_name
    cluster_endpoint             = var.cluster_endpoint
    cluster_ca                   = var.cluster_ca
    service_ipv4_cidr            = var.service_ipv4_cidr
    ebs_data_disk_detect_snippet = file("${path.module}/templates/detect-ebs-disk.sh")
  })
}

resource "aws_launch_template" "system" {
  name        = "${var.cluster_name}-eks-utils-lt"
  description = "System nodegroup with LVM-managed containerd volume"
  image_id    = data.aws_ssm_parameter.eks_ami.value
  user_data   = base64encode(local.userdata)

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
}

# =====================================================================
# Managed node group
# =====================================================================
resource "aws_eks_node_group" "system" {
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
# cluster-autoscaler ASG discovery tags
#
# Set explicitly via aws_autoscaling_group_tag. Reading the ASG name
# from the NG's .resources output (populated after NG ACTIVE).
# ===================================================================
locals {
  system_ng_asg_name = aws_eks_node_group.system.resources[0].autoscaling_groups[0].name

  system_ng_asg_tags = {
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
  for_each               = local.system_ng_asg_tags
  autoscaling_group_name = local.system_ng_asg_name

  tag {
    key                 = each.value.key
    value               = each.value.value
    propagate_at_launch = true
  }
}
