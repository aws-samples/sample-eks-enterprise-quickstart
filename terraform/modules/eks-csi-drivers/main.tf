data "aws_partition" "current" {}

# Cross-variable validation lives on var.s3_bucket_arns now (Terraform 1.9+).
# See variables.tf for the precondition.

# =====================================================================
# EBS CSI Driver — always installed
# =====================================================================
data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = var.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.ebs_csi.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    controller = {
      replicaCount = 2
      nodeSelector = {
        (var.system_node_label_key) = var.system_node_label_value
      }
    }
  })

  depends_on = [aws_eks_pod_identity_association.ebs_csi]
}

# =====================================================================
# StorageClasses (gp3 default + io2)
# =====================================================================
resource "kubernetes_annotations" "remove_gp2_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata { name = "gp2" }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force = true

  depends_on = [aws_eks_addon.ebs_csi]
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type       = "gp3"
    fsType     = "ext4"
    iops       = "3000"
    throughput = "125"
    encrypted  = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}

resource "kubernetes_storage_class_v1" "io2" {
  metadata {
    name = "io2"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "io2"
    fsType    = "ext4"
    iops      = "10000"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}

# =====================================================================
# EFS CSI Driver (optional)
# =====================================================================
data "aws_eks_addon_version" "efs_csi" {
  count              = var.install_efs ? 1 : 0
  addon_name         = "aws-efs-csi-driver"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

resource "aws_iam_role" "efs_csi" {
  count = var.install_efs ? 1 : 0
  name  = "${var.cluster_name}-efs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  count      = var.install_efs ? 1 : 0
  role       = aws_iam_role.efs_csi[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "efs_csi" {
  count           = var.install_efs ? 1 : 0
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "efs-csi-controller-sa"
  role_arn        = aws_iam_role.efs_csi[0].arn
}

resource "aws_eks_addon" "efs_csi" {
  count                       = var.install_efs ? 1 : 0
  cluster_name                = var.cluster_name
  addon_name                  = "aws-efs-csi-driver"
  addon_version               = data.aws_eks_addon_version.efs_csi[0].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    controller = {
      replicaCount = 2
      nodeSelector = {
        (var.system_node_label_key) = var.system_node_label_value
      }
    }
  })

  depends_on = [aws_eks_pod_identity_association.efs_csi]
}

# =====================================================================
# FSx CSI Driver (optional, EKS Managed Addon — matches the bash path)
# =====================================================================
data "aws_eks_addon_version" "fsx_csi" {
  count              = var.install_fsx ? 1 : 0
  addon_name         = "aws-fsx-csi-driver"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

resource "aws_iam_policy" "fsx_csi" {
  count  = var.install_fsx ? 1 : 0
  name   = "${var.cluster_name}-fsx-csi-policy"
  policy = file("${path.module}/../../assets/iam/fsx-csi-policy.json")
}

resource "aws_iam_role" "fsx_csi" {
  count = var.install_fsx ? 1 : 0
  name  = "${var.cluster_name}-fsx-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fsx_csi" {
  count      = var.install_fsx ? 1 : 0
  role       = aws_iam_role.fsx_csi[0].name
  policy_arn = aws_iam_policy.fsx_csi[0].arn
}

resource "aws_eks_pod_identity_association" "fsx_csi" {
  count           = var.install_fsx ? 1 : 0
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "fsx-csi-controller-sa"
  role_arn        = aws_iam_role.fsx_csi[0].arn
}

resource "aws_eks_addon" "fsx_csi" {
  count                       = var.install_fsx ? 1 : 0
  cluster_name                = var.cluster_name
  addon_name                  = "aws-fsx-csi-driver"
  addon_version               = data.aws_eks_addon_version.fsx_csi[0].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    controller = {
      replicaCount = 2
      nodeSelector = {
        (var.system_node_label_key) = var.system_node_label_value
      }
    }
  })

  depends_on = [aws_eks_pod_identity_association.fsx_csi]
}

# =====================================================================
# S3 CSI Driver (optional)
# =====================================================================
data "aws_eks_addon_version" "s3_csi" {
  count              = var.install_s3 ? 1 : 0
  addon_name         = "aws-mountpoint-s3-csi-driver"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

resource "aws_iam_role" "s3_csi" {
  count = var.install_s3 ? 1 : 0
  name  = "${var.cluster_name}-s3-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

locals {
  # Partition bucket ARNs by type. Standard S3 uses arn:aws:s3:::bucket;
  # S3 Express One Zone uses arn:aws:s3express:region:acct:bucket/<name>--<az>--x-s3.
  s3_standard_arns = [for arn in var.s3_bucket_arns : arn if !can(regex("s3express|--x-s3", arn))]
  s3_express_arns  = [for arn in var.s3_bucket_arns : arn if can(regex("s3express|--x-s3", arn))]
  s3_standard_objs = [for arn in local.s3_standard_arns : "${arn}/*"]
  s3_express_objs  = [for arn in local.s3_express_arns : "${arn}/*"]
}

# S3 bucket-scoped policy. Splits actions per bucket family because:
#   - s3express:CreateSession only applies to s3express ARNs
#   - s3:ListBucket/GetObject/etc apply to standard s3 ARNs
# Mirrors scripts/legacy/pod_identity_helpers.sh setup_s3_csi_pod_identity.
resource "aws_iam_role_policy" "s3_csi" {
  count = var.install_s3 && length(var.s3_bucket_arns) > 0 ? 1 : 0
  name  = "S3MountpointAccess"
  role  = aws_iam_role.s3_csi[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      length(local.s3_standard_arns) > 0 ? [
        {
          Sid      = "MountpointListBuckets"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = local.s3_standard_arns
        },
        {
          Sid      = "MountpointObjectAccess"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
          Resource = local.s3_standard_objs
        },
      ] : [],
      length(local.s3_express_arns) > 0 ? [
        {
          Sid      = "S3ExpressCreateSession"
          Effect   = "Allow"
          Action   = ["s3express:CreateSession"]
          Resource = local.s3_express_arns
        },
        {
          Sid      = "S3ExpressListBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = local.s3_express_arns
        },
        {
          Sid      = "S3ExpressObjectAccess"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
          Resource = local.s3_express_objs
        },
      ] : [],
    )
  })
}

resource "aws_eks_pod_identity_association" "s3_csi" {
  count           = var.install_s3 ? 1 : 0
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "s3-csi-driver-sa"
  role_arn        = aws_iam_role.s3_csi[0].arn
}

resource "aws_eks_addon" "s3_csi" {
  count                       = var.install_s3 ? 1 : 0
  cluster_name                = var.cluster_name
  addon_name                  = "aws-mountpoint-s3-csi-driver"
  addon_version               = data.aws_eks_addon_version.s3_csi[0].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_pod_identity_association.s3_csi]
}
