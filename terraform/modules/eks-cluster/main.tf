data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# =====================================================================
# IAM role for the EKS control plane
# =====================================================================
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSVPCResourceController" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSVPCResourceController"
}

# =====================================================================
# EKS cluster
# =====================================================================
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.k8s_version
  role_arn = aws_iam_role.cluster.arn

  # Native EKS deletion protection (Provider 5.70+, EKS API GA Sep-2024).
  # Equivalent to the bash script's `aws eks update-cluster-config
  # --deletion-protection` follow-up call; unlike Terraform's lifecycle
  # prevent_destroy, this is enforced by AWS itself, not just locally.
  deletion_protection = var.enable_deletion_protection

  enabled_cluster_log_types = var.enabled_cluster_log_types

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = var.cluster_mode == "public"
    public_access_cidrs     = var.cluster_mode == "public" ? var.public_access_cidrs : null
  }

  kubernetes_network_config {
    service_ipv4_cidr = var.service_ipv4_cidr
    ip_family         = "ipv4"
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  dynamic "encryption_config" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      resources = ["secrets"]
      provider {
        key_arn = var.kms_key_arn
      }
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSVPCResourceController,
    aws_cloudwatch_log_group.cluster,
  ]
}

# =====================================================================
# IRSA — opt-in legacy OIDC provider
# =====================================================================
# Default off because every managed component in this stack uses Pod
# Identity (var.enable_irsa). The data.tls_certificate fetch below
# would otherwise touch oidc.eks.<region>.amazonaws.com, which is
# unreachable from a private subnet that has the eks VPC interface
# endpoint enabled (the endpoint's private hosted zone shadows the
# subdomain — see modules/eks-cluster/variables.tf for context).
# =====================================================================
data "tls_certificate" "cluster" {
  count = var.enable_irsa ? 1 : 0
  url   = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  count           = var.enable_irsa ? 1 : 0
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster[0].certificates[0].sha1_fingerprint]
}

# =====================================================================
# Extra API ingress on the cluster security group
# =====================================================================
# EKS auto-creates the cluster security group with one rule: a self-
# reference allowing all traffic between SG members. Anyone outside that
# group — bastion / CI runner / DX-attached operator — must be allowed
# explicitly. We keep the rules separate from the EKS-managed self-ref
# so they survive cluster-config updates and are easy to audit.
#
# SG-vs-CIDR choice: SG references are preferred for in-VPC sources
# (they survive IP renumbering), but only span the same VPC; DX/VPN/
# peering/TGW callers must come in by CIDR. Both lists can be set.
resource "aws_vpc_security_group_ingress_rule" "api_extra_sg" {
  for_each = toset(var.extra_api_ingress_security_group_ids)

  security_group_id            = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = each.key
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Extra SG allowed inbound to cluster API"
}

resource "aws_vpc_security_group_ingress_rule" "api_extra_cidr" {
  for_each = toset(var.extra_api_ingress_cidrs)

  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  cidr_ipv4         = each.key
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Extra CIDR allowed inbound to cluster API"
}

# =====================================================================
# Extra cluster admins
# =====================================================================
# bootstrap_cluster_creator_admin_permissions=true already gives admin
# to the IAM principal that ran `terraform apply`. These resources are
# for *additional* principals — typical case: cluster is applied from a
# dev host or CI runner, but day-2 operators connect through a separate
# bastion / ops IAM role and need cluster-admin level kubectl access.
#
# Listing the apply-time principal here would collide (ResourceInUseException
# on access entry creation). The variable description spells this out.
resource "aws_eks_access_entry" "extra_admin" {
  for_each = toset(var.extra_cluster_admin_role_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.key
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "extra_admin" {
  for_each = toset(var.extra_cluster_admin_role_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.key
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.extra_admin]
}

# =====================================================================
# Core managed addons that must be present before workloads land:
#   - vpc-cni (with Pod ENI configured later via env if needed)
#   - kube-proxy
#   - eks-pod-identity-agent
#
# CoreDNS / metrics-server are deferred to eks-addons module so they can
# be configured to run on the system nodegroup once it exists.
# =====================================================================
data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

data "aws_eks_addon_version" "pod_identity_agent" {
  addon_name         = "eks-pod-identity-agent"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.vpc_cni.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Match the bash defaults from 4_install_eks_cluster.sh:
  #   EXTERNALSNAT=false   nodes still SNAT to the primary ENI's IP
  #   WARM_ENI_TARGET=0    don't pre-attach extra ENIs
  #   WARM_IP_TARGET=5     keep 5 free IPs warmed
  #   MINIMUM_IP_TARGET=3  ensure at least 3 IPs ready before scheduling
  configuration_values = jsonencode({
    env = {
      AWS_VPC_K8S_CNI_EXTERNALSNAT = "false"
      WARM_ENI_TARGET              = "0"
      WARM_IP_TARGET               = "5"
      MINIMUM_IP_TARGET            = "3"
    }
  })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.kube_proxy.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = data.aws_eks_addon_version.pod_identity_agent.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}
