data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# =====================================================================
# Discovery tags on subnets + cluster SG
# Karpenter EC2NodeClass selects subnets/SGs by these tags.
# =====================================================================
resource "aws_ec2_tag" "subnet_discovery" {
  for_each    = toset(var.private_subnet_ids)
  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "aws_ec2_tag" "cluster_sg_discovery" {
  resource_id = var.cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# =====================================================================
# Karpenter node IAM role (used by EC2 instances Karpenter launches)
# =====================================================================
resource "aws_iam_role" "karpenter_node" {
  name = "KarpenterNodeRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# =====================================================================
# Karpenter controller IAM role (Pod Identity)
# =====================================================================
resource "aws_iam_role" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# Least-privilege Karpenter controller policy, ported from
# scripts/legacy/option_install_karpenter.sh. Each write action is constrained to
# resources tagged as owned by this cluster (kubernetes.io/cluster/<name>=
# owned plus the per-nodepool / per-ec2nodeclass tags Karpenter attaches).
# Structure follows the upstream Karpenter v1 CloudFormation reference.
resource "aws_iam_role_policy" "karpenter_controller" {
  name = "KarpenterControllerPolicy"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceAccessActions"
        Effect = "Allow"
        Action = ["ec2:RunInstances", "ec2:CreateFleet"]
        Resource = [
          "arn:aws:ec2:${var.region}::image/*",
          "arn:aws:ec2:${var.region}::snapshot/*",
          "arn:aws:ec2:${var.region}:*:security-group/*",
          "arn:aws:ec2:${var.region}:*:subnet/*",
          "arn:aws:ec2:${var.region}:*:capacity-reservation/*",
        ]
      },
      {
        Sid      = "AllowScopedEC2LaunchTemplateAccessActions"
        Effect   = "Allow"
        Action   = ["ec2:RunInstances", "ec2:CreateFleet"]
        Resource = "arn:aws:ec2:${var.region}:*:launch-template/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Action = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
        Resource = [
          "arn:aws:ec2:${var.region}:*:fleet/*",
          "arn:aws:ec2:${var.region}:*:instance/*",
          "arn:aws:ec2:${var.region}:*:volume/*",
          "arn:aws:ec2:${var.region}:*:network-interface/*",
          "arn:aws:ec2:${var.region}:*:launch-template/*",
          "arn:aws:ec2:${var.region}:*:spot-instances-request/*",
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                      = var.cluster_name
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedResourceCreationTagging"
        Effect = "Allow"
        Action = "ec2:CreateTags"
        Resource = [
          "arn:aws:ec2:${var.region}:*:fleet/*",
          "arn:aws:ec2:${var.region}:*:instance/*",
          "arn:aws:ec2:${var.region}:*:volume/*",
          "arn:aws:ec2:${var.region}:*:network-interface/*",
          "arn:aws:ec2:${var.region}:*:launch-template/*",
          "arn:aws:ec2:${var.region}:*:spot-instances-request/*",
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                      = var.cluster_name
            "ec2:CreateAction"                                         = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedResourceTagging"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "arn:aws:ec2:${var.region}:*:instance/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
          "ForAllValues:StringEquals" = {
            "aws:TagKeys" = ["karpenter.sh/nodeclaim", "Name"]
          }
        }
      },
      {
        Sid    = "AllowScopedDeletion"
        Effect = "Allow"
        Action = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate", "ec2:DeleteLaunchTemplateVersions"]
        Resource = [
          "arn:aws:ec2:${var.region}:*:instance/*",
          "arn:aws:ec2:${var.region}:*:launch-template/*",
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowRegionalReadActions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.region }
        }
      },
      {
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.region}::parameter/aws/service/eks/*"
      },
      {
        Sid      = "AllowPricingReadActions"
        Effect   = "Allow"
        Action   = "pricing:GetProducts"
        Resource = "*"
      },
      {
        Sid      = "AllowInterruptionQueueActions"
        Effect   = "Allow"
        Action   = ["sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        Sid      = "AllowAPIServerEndpointDiscovery"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
      },
      {
        Sid      = "AllowPassingInstanceRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileCreationActions"
        Effect   = "Allow"
        Action   = "iam:CreateInstanceProfile"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                      = var.cluster_name
            "aws:RequestTag/topology.kubernetes.io/region"             = var.region
          }
          StringLike = {
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileTagActions"
        Effect   = "Allow"
        Action   = "iam:TagInstanceProfile"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"             = var.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileActions"
        Effect   = "Allow"
        Action   = ["iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"             = var.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid      = "AllowInstanceProfileReadActions"
        Effect   = "Allow"
        Action   = ["iam:GetInstanceProfile", "iam:ListInstanceProfiles", "iam:ListInstanceProfileTags"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
      },
    ]
  })
}

# helm chart sets serviceAccount.create=false (we set it in helm values
# below), so we need to create the SA explicitly. Without it the karpenter
# Deployment fails with: pods "karpenter-..." is forbidden: error looking
# up service account kube-system/karpenter: serviceaccount "karpenter" not
# found. Mirrors scripts/legacy/option_install_karpenter.sh step 7.
resource "kubernetes_service_account_v1" "karpenter" {
  metadata {
    name      = "karpenter"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"      = "karpenter"
      "app.kubernetes.io/component" = "controller"
    }
  }
}

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller.arn

  depends_on = [kubernetes_service_account_v1.karpenter]
}

# =====================================================================
# SQS interruption queue + EventBridge rules (spot/scheduled-change events)
# =====================================================================
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter_interruption.arn
    }]
  })
}

locals {
  karpenter_event_rules = {
    health_event = {
      "source"      = ["aws.health"]
      "detail-type" = ["AWS Health Event"]
    }
    spot_interruption = {
      "source"      = ["aws.ec2"]
      "detail-type" = ["EC2 Spot Instance Interruption Warning"]
    }
    rebalance = {
      "source"      = ["aws.ec2"]
      "detail-type" = ["EC2 Instance Rebalance Recommendation"]
    }
    instance_state_change = {
      "source"      = ["aws.ec2"]
      "detail-type" = ["EC2 Instance State-change Notification"]
    }
  }
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each      = local.karpenter_event_rules
  name          = "${var.cluster_name}-karpenter-${each.key}"
  event_pattern = jsonencode(each.value)
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each  = local.karpenter_event_rules
  rule      = aws_cloudwatch_event_rule.karpenter[each.key].name
  target_id = "karpenter-${each.key}"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# =====================================================================
# Karpenter helm release
# =====================================================================
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  namespace        = "kube-system"
  create_namespace = false
  version          = var.karpenter_version
  timeout          = 600
  wait             = true

  # If apply gets interrupted mid-install, helm leaves the release in
  # 'pending-install', and the next apply hits "cannot re-use a name that
  # is still in use". cleanup_on_fail rolls back partial installs so
  # subsequent applies can proceed; replace lets us re-claim a stale name
  # without manual `helm uninstall`.
  cleanup_on_fail = true
  replace         = var.helm_replace_existing

  values = [yamlencode({
    settings = {
      clusterName       = var.cluster_name
      clusterEndpoint   = var.cluster_endpoint
      interruptionQueue = aws_sqs_queue.karpenter_interruption.name
    }
    serviceAccount = {
      create = false
      name   = "karpenter"
    }
    replicas = 2
    nodeSelector = {
      (var.system_node_label_key) = var.system_node_label_value
    }
    # Don't let Karpenter schedule itself onto nodes Karpenter created —
    # avoids a chicken-and-egg shutdown loop. Mirrors the bash helm flags.
    tolerations = [
      { key = "CriticalAddonsOnly", operator = "Exists" },
      { key = "node.kubernetes.io/not-ready", operator = "Exists", effect = "NoExecute" },
    ]
    affinity = {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [{
            matchExpressions = [{
              key      = "karpenter.sh/nodepool"
              operator = "DoesNotExist"
            }]
          }]
        }
      }
      podAntiAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = [{
          labelSelector = {
            matchLabels = {
              "app.kubernetes.io/name" = "karpenter"
            }
          }
          topologyKey = "kubernetes.io/hostname"
        }]
      }
    }
    podDisruptionBudget = {
      minAvailable = 1
    }
  })]

  depends_on = [
    aws_eks_pod_identity_association.karpenter,
    aws_iam_role_policy.karpenter_controller,
  ]
}

# =====================================================================
# Default NodePool + EC2NodeClass (Graviton + x86)
#
# Delivered as a separate helm_release (a tiny chart-of-templates from the
# upstream incubator/raw chart) instead of `kubernetes_manifest`. Reason:
# kubernetes_manifest performs a live API GET on plan, which fails if the
# cluster is being created in the same `terraform apply` run. Helm doesn't
# touch the API until install/upgrade, so it sequences cleanly after the
# cluster + karpenter helm release.
# =====================================================================
locals {
  ec2nodeclass_template_vars = {
    CLUSTER_NAME   = var.cluster_name
    SSH_PUBLIC_KEY = var.ssh_public_key
  }

  karpenter_pools_manifests = [
    templatefile("${path.module}/../../assets/karpenter/ec2nodeclass-graviton.yaml", local.ec2nodeclass_template_vars),
    templatefile("${path.module}/../../assets/karpenter/ec2nodeclass-x86.yaml", local.ec2nodeclass_template_vars),
    file("${path.module}/../../assets/karpenter/nodepool-graviton.yaml"),
    file("${path.module}/../../assets/karpenter/nodepool-x86.yaml"),
  ]
}

# bedag/raw is a maintained chart-of-templates wrapper for shipping arbitrary
# YAML. Earlier we tried itscontained/raw (TLS cert expired 2023-09).
# Each item in `resources` is rendered verbatim.
resource "helm_release" "karpenter_pools" {
  name             = "karpenter-pools"
  repository       = "https://bedag.github.io/helm-charts/"
  chart            = "raw"
  version          = "2.0.2"
  namespace        = "kube-system"
  create_namespace = false

  cleanup_on_fail = true
  replace         = var.helm_replace_existing

  values = [yamlencode({
    resources = [for m in local.karpenter_pools_manifests : yamldecode(m)]
  })]

  depends_on = [helm_release.karpenter]
}
