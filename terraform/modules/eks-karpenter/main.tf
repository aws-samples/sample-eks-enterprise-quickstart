data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  # Upstream controller permissions (Karpenter cloudformation.yaml) missing
  # from the policy below: ec2:DescribeInstanceStatus is new in 1.13;
  # DescribeCapacityReservations / DescribePlacementGroups / placement-group/*
  # are upstream already for 1.12. All are added ONLY for >= 1.13, so the
  # policy of existing 1.12.1 installs stays byte-identical. Not added: the
  # opt-in arc-zonal-shift:GetManagedResource (settings.enableZonalShift,
  # off) and ec2:RebootInstances (alpha rebootForRepair gate, off).
  # karpenter_version is passed to Helm as-is, and Helm resolves tag
  # constraints, so read the first major.minor after any operator prefix:
  # "1.15", "~1.15", "v1.15.1", ">=1.15.0", "^1.13" -> on; "1.12.1", "~1.12",
  # ">=1.12" -> off (1.12.x policy byte-identical). Strings without a
  # major.minor ("^1", "*") may resolve to the newest release -> on. False
  # positives (e.g. "<1.15") only add read-only permissions. The matrix check
  # in modules/k8s-version deliberately does not check range constraints.
  karpenter_semver = try(regex("^[^0-9]*([0-9]+)\\.([0-9]+)", var.karpenter_version), null)
  karpenter_ge_113 = local.karpenter_semver == null ? true : tonumber(local.karpenter_semver[0]) * 1000 + tonumber(local.karpenter_semver[1]) >= 1013

  karpenter_v113_instance_access_resources = local.karpenter_ge_113 ? ["arn:aws:ec2:${var.region}:*:placement-group/*"] : []
  karpenter_v113_regional_read = local.karpenter_ge_113 ? [
    "ec2:DescribeCapacityReservations",
    "ec2:DescribeInstanceStatus",
    "ec2:DescribePlacementGroups",
  ] : []
}

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
        Resource = concat([
          "arn:aws:ec2:${var.region}::image/*",
          "arn:aws:ec2:${var.region}::snapshot/*",
          "arn:aws:ec2:${var.region}:*:security-group/*",
          "arn:aws:ec2:${var.region}:*:subnet/*",
          "arn:aws:ec2:${var.region}:*:capacity-reservation/*",
        ], local.karpenter_v113_instance_access_resources)
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
        Action = concat([
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
        ], local.karpenter_v113_regional_read)
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

# Pod Identity propagation wait (issue #2). Associations are eventually
# consistent; a Karpenter pod admitted before propagation never gets the
# AWS_CONTAINER_* env and falls back to the node role (AccessDenied). See the
# full rationale on time_sleep.pod_identity_propagation in
# modules/eks-addons/main.tf. Re-runs only when the association is created
# or replaced.
resource "time_sleep" "pod_identity_propagation" {
  create_duration = var.pod_identity_propagation_wait

  triggers = {
    karpenter = aws_eks_pod_identity_association.karpenter.association_id
  }
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
    time_sleep.pod_identity_propagation,
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

# =====================================================================
# GPU NodePools (var.gpu_nodepools) — one EC2NodeClass + NodePool per entry
#
# Each pool pins ONE instance type because the EFA NIC layout is per type
# (EC2NodeClass.spec.networkInterfaces, Karpenter >= 1.11). The layout, the
# g7 open-kmod fixup and the EFA userspace bootstrap all come from
# modules/gpu-instance-catalog — the same source the GPU nodegroups use.
#   - networkInterfaces: (0,0) must be "interface" (CRD rule); EFA goes on
#     efa-only interfaces, at most one per card. Types whose NIC0 carries EFA
#     (primary_efa) get an extra efa-only at (card 0, device 1), so the EFA
#     count matches the nodegroup LT. Types without EFA get no networkInterfaces.
#   - instanceStorePolicy RAID0: Karpenter renders nodeadm localStorage RAID0
#     itself (mounted at /mnt/k8s-disks/0, same as the nodegroups'
#     containerd_storage = "instance_store").
#   - Vendor (nvidia | neuron) comes from the instance type NAME via
#     module.gpu_catalog.vendor_by_instance_type, and the per-vendor node
#     contract from module.gpu_catalog.accelerator_profiles:
#       nvidia -> label workload-type=gpu, taint + limit nvidia.com/gpu —
#                 what the eks-gpu-stack DaemonSets select/tolerate;
#       neuron -> label workload-type=neuron, taint aws.amazon.com/neuron,
#                 limit in whole aws.amazon.com/neuron devices — what the
#                 eks-neuron-stack device plugin and
#                 aws-efa-k8s-device-plugin-neuron select/tolerate.
#     Vendor decisions are name-based so they are known at plan time:
#     data.aws_ec2_instance_type is deferred to apply on a fresh cluster.
#     Neuron pools get the Neuron AMI (var.neuron_ami_selector) and a
#     boothook-only userData (EFA userspace; no NVIDIA containerd overlay,
#     no g7 kmod fixup).
#   - Neuroncore pitfall (NOT guardable here — pod requests are invisible to
#     Terraform): Karpenter counts aws.amazon.com/neuroncore as devices x
#     physical cores and ignores LNC. On trn2 that is devices x 8, while the
#     device plugin advertises devices x 4 at the default LNC=2:
#       trn2.48xlarge 128 vs 64 (requests of 65-128 never fit)
#       trn2.3xlarge    8 vs 4  (requests of 5-8 never fit)
#     Karpenter then launches a node the pod never fits on. trn1 / inf1 /
#     inf2 (no LNC) are unaffected. Limits are therefore never set on
#     neuroncore; workloads should request aws.amazon.com/neuron (whole
#     devices).
#   - Spot interruptions are handled by Karpenter's interruption queue
#     (aws_sqs_queue.karpenter_interruption): the node is cordoned/drained on
#     the 2-minute notice and a replacement is launched immediately.
# =====================================================================
module "gpu_catalog" {
  source                = "../gpu-instance-catalog"
  efa_installer_version = var.gpu_efa_installer_version
  instance_types        = [for p in var.gpu_nodepools : p.instance_type]
}

data "aws_ec2_instance_type" "gpu" {
  for_each      = toset([for p in var.gpu_nodepools : p.instance_type])
  instance_type = each.key
}

locals {
  gpu_pools = { for p in var.gpu_nodepools : p.name => p }

  # `gpus` is a SET in the provider schema — gpus[0] is not a valid index
  # (a try() around it silently yields 0), so sum over the set instead.
  gpu_count_per_type = {
    for t, d in data.aws_ec2_instance_type.gpu : t => (length(d.gpus) > 0 ? sum([for g in d.gpus : g.count]) : 0)
  }

  # Static (name-based) vendor/profile — never derived from data.aws_ec2_instance_type
  # (deferred to apply on a fresh cluster; mocks carry both gpus and neuron_devices).
  gpu_pool_vendor     = { for n, p in local.gpu_pools : n => module.gpu_catalog.vendor_by_instance_type[p.instance_type] }
  gpu_pool_profile    = { for n, v in local.gpu_pool_vendor : n => module.gpu_catalog.accelerator_profiles[v] }
  gpu_has_neuron_pool = contains(values(local.gpu_pool_vendor), "neuron")
  gpu_has_nvidia_pool = contains(values(local.gpu_pool_vendor), "nvidia")

  # neuron_devices is a SET too (same caveat as gpus).
  neuron_count_per_type = {
    for t, d in data.aws_ec2_instance_type.gpu : t => (length(d.neuron_devices) > 0 ? sum([for x in d.neuron_devices : x.count]) : 0)
  }

  # Per-pool AMI: NVIDIA pools keep var.gpu_ami_selector (byte-identical to the
  # pre-Neuron render), Neuron pools use var.neuron_ami_selector.
  gpu_pool_ami_selector = { for n, v in local.gpu_pool_vendor : n => v == "neuron" ? var.neuron_ami_selector : var.gpu_ami_selector }
  gpu_pool_ami_selector_terms = {
    for n, s in local.gpu_pool_ami_selector : n => startswith(s, "ami-") ? [{ id = s }] : [{ alias = s }]
  }

  # Karpenter version floors for Neuron pools (NVIDIA pools have none, as
  # before). Unparseable karpenter_version -> both floors pass.
  #   - >= 1.1  every Neuron pool (conservative minimum): v1.0.x already
  #             advertises aws.amazon.com/neuron for inf1 / inf2 (from EC2
  #             InferenceAcceleratorInfo) and trn1 (hard-coded counts), but
  #             NeuronInfo-based device counts / accelerator labels (needed
  #             for trn2-class and newer types) and the
  #             aws.amazon.com/neuroncore resource arrive in v1.1.0.
  #   - >= 1.11 only Neuron pools that render EC2NodeClass networkInterfaces
  #             (EFA: trn1.32xlarge / trn1n / trn2); the CRD field is new in
  #             v1.11.0. inf1 / inf2 / trn1.2xlarge render none.
  karpenter_version_mm             = try([for x in regex("^v?([0-9]+)\\.([0-9]+)", var.karpenter_version) : tonumber(x)], null)
  karpenter_version_ok_for_neuron  = try(local.karpenter_version_mm[0] > 1 || (local.karpenter_version_mm[0] == 1 && local.karpenter_version_mm[1] >= 1), true)
  karpenter_version_ok_for_efa_nic = try(local.karpenter_version_mm[0] > 1 || (local.karpenter_version_mm[0] == 1 && local.karpenter_version_mm[1] >= 11), true)

  # Neuron AMI selector format: checked by a precondition only when a Neuron
  # pool exists (the root always passes a derived value; see variables.tf).
  neuron_ami_selector_valid = can(regex("^(al2023@(latest|v[0-9]{8})|ami-[0-9a-f]{8,17})$", var.neuron_ami_selector))

  gpu_pool_layout = {
    for n, p in local.gpu_pools : n => lookup(module.gpu_catalog.efa_layout, p.instance_type, module.gpu_catalog.efa_layout_default)
  }

  gpu_pool_network_interfaces = {
    for n, l in local.gpu_pool_layout : n => (
      l.efa_only_count == 0 && !l.primary_efa ? [] : concat(
        [{ networkCardIndex = 0, deviceIndex = 0, interfaceType = "interface" }],
        l.primary_efa ? [{ networkCardIndex = 0, deviceIndex = 1, interfaceType = "efa-only" }] : [],
        [for i in range(1, l.efa_only_count + 1) : { networkCardIndex = i, deviceIndex = 0, interfaceType = "efa-only" }],
      )
    )
  }

  # Karpenter merges this MIME document with its own NodeConfig (cluster
  # details, kubelet flags, localStorage). The boothook re-runs every boot;
  # both fragments are idempotent.
  gpu_userdata = join("", [
    "MIME-Version: 1.0\n",
    "Content-Type: multipart/mixed; boundary=\"==BOUNDARY==\"\n\n",
    "--==BOUNDARY==\n",
    "Content-Type: text/cloud-boothook; charset=\"us-ascii\"\n\n",
    "#!/bin/bash\n",
    "# Karpenter GPU NodePool bootstrap (modules/eks-karpenter)\n",
    "set -ex\n",
    "exec > >(tee -a /var/log/gpu-node-bootstrap.log)\n",
    "exec 2>&1\n\n",
    module.gpu_catalog.nvidia_open_kmod_fixup_snippet,
    "\n",
    var.gpu_install_efa_userspace ? module.gpu_catalog.efa_userspace_snippet : "echo \"EFA userspace install disabled\"\n",
    "\necho \"=== GPU Node Bootstrap Complete ===\"\n\n",
    "--==BOUNDARY==\n",
    "Content-Type: application/node.eks.aws\n\n",
    "---\n",
    "apiVersion: node.eks.aws/v1alpha1\n",
    "kind: NodeConfig\n",
    "spec:\n",
    "  containerd:\n",
    "    config: |\n",
    "      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.nvidia.options]\n",
    "      SystemdCgroup = true\n\n",
    "--==BOUNDARY==--\n",
  ])

  # Neuron: boothook only — no NVIDIA containerd runtime overlay (nodeadm's
  # default runc is what the Neuron AMI expects) and no g7 open-kmod fixup;
  # mirrors eks-gpu-nodegroup (main.tf:394 + userdata.sh.tpl nvidia-only block).
  # Karpenter appends its own NodeConfig part to this MIME document.
  neuron_userdata = join("", [
    "MIME-Version: 1.0\n",
    "Content-Type: multipart/mixed; boundary=\"==BOUNDARY==\"\n\n",
    "--==BOUNDARY==\n",
    "Content-Type: text/cloud-boothook; charset=\"us-ascii\"\n\n",
    "#!/bin/bash\n",
    "# Karpenter Neuron NodePool bootstrap (modules/eks-karpenter)\n",
    "set -ex\n",
    "exec > >(tee -a /var/log/gpu-node-bootstrap.log)\n",
    "exec 2>&1\n\n",
    var.gpu_install_efa_userspace ? module.gpu_catalog.efa_userspace_snippet : "echo \"EFA userspace install disabled\"\n",
    "\necho \"=== Neuron Node Bootstrap Complete ===\"\n\n",
    "--==BOUNDARY==--\n",
  ])

  gpu_ec2nodeclasses = [
    for n, p in local.gpu_pools : {
      apiVersion = "karpenter.k8s.aws/v1"
      kind       = "EC2NodeClass"
      metadata   = { name = "gpu-${n}" }
      spec = merge(
        {
          amiSelectorTerms           = local.gpu_pool_ami_selector_terms[n]
          role                       = aws_iam_role.karpenter_node.name
          subnetSelectorTerms        = [{ tags = { "karpenter.sh/discovery" = var.cluster_name } }]
          securityGroupSelectorTerms = [{ tags = { "karpenter.sh/discovery" = var.cluster_name } }]
          metadataOptions = {
            httpEndpoint            = "enabled"
            httpTokens              = "required"
            httpPutResponseHopLimit = 2
          }
          blockDeviceMappings = [{
            deviceName = "/dev/xvda"
            ebs = {
              volumeSize          = "${p.root_volume_size}Gi"
              volumeType          = "gp3"
              encrypted           = true
              deleteOnTermination = true
            }
          }]
          userData = local.gpu_pool_vendor[n] == "neuron" ? local.neuron_userdata : local.gpu_userdata
          tags     = { "gpu-instance-type" = p.instance_type }
        },
        p.instance_store_policy != "" ? { instanceStorePolicy = p.instance_store_policy } : {},
        startswith(local.gpu_pool_ami_selector[n], "ami-") ? { amiFamily = "AL2023" } : {},
        length(local.gpu_pool_network_interfaces[n]) > 0 ? { networkInterfaces = local.gpu_pool_network_interfaces[n] } : {},
      )
    }
  ]

  gpu_nodepool_objects = [
    for n, p in local.gpu_pools : {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata   = { name = "gpu-${n}" }
      spec = {
        template = {
          metadata = {
            labels = {
              "workload-type"     = local.gpu_pool_profile[n].workload_type
              "gpu-instance-type" = p.instance_type
            }
          }
          spec = {
            nodeClassRef = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "gpu-${n}" }
            requirements = concat(
              [
                { key = "node.kubernetes.io/instance-type", operator = "In", values = [p.instance_type] },
                { key = "karpenter.sh/capacity-type", operator = "In", values = p.capacity_types },
              ],
              length(p.zones) > 0 ? [{ key = "topology.kubernetes.io/zone", operator = "In", values = p.zones }] : [],
            )
            # {key, value, effect} from accelerator_profiles; yamlencode sorts
            # keys, so the NVIDIA bytes equal the pre-Neuron literal.
            taints      = [local.gpu_pool_profile[n].taint]
            expireAfter = p.expire_after
          }
        }
        # NVIDIA: limit in GPUs when the type has them (so max_nodes nodes
        # fit exactly), else in vCPUs.
        # Neuron: whole devices (== accelerator_profiles.neuron.device_resource).
        # Never aws.amazon.com/neuroncore: on trn2 Karpenter counts devices x 8
        # physical cores (128 on trn2.48xlarge, 8 on trn2.3xlarge) while the
        # device plugin advertises devices x 4 at LNC=2 (64 / 4).
        # Branch on the STATIC vendor, not on data (see gpu_pool_vendor).
        limits = (
          local.gpu_pool_vendor[n] == "neuron"
          ? { "aws.amazon.com/neuron" = tostring(p.max_nodes * local.neuron_count_per_type[p.instance_type]) }
          : (
            local.gpu_count_per_type[p.instance_type] > 0
            ? { "nvidia.com/gpu" = tostring(p.max_nodes * local.gpu_count_per_type[p.instance_type]) }
            : { cpu = tostring(p.max_nodes * data.aws_ec2_instance_type.gpu[p.instance_type].default_vcpus) }
          )
        )
        disruption = {
          consolidationPolicy = "WhenEmpty"
          consolidateAfter    = p.consolidate_after
          budgets             = [{ nodes = "1" }]
        }
        weight = 50
      }
    }
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
    resources = concat(
      [for m in local.karpenter_pools_manifests : yamldecode(m)],
      local.gpu_ec2nodeclasses,
      local.gpu_nodepool_objects,
    )
  })]

  lifecycle {
    # Karpenter would otherwise launch the node and leave /var/lib/containerd
    # on the root volume (nodeadm's setup-local-disks exits 0 when there are
    # no Instance Store disks).
    precondition {
      condition = alltrue([for p in var.gpu_nodepools :
        p.instance_store_policy != "RAID0" || data.aws_ec2_instance_type.gpu[p.instance_type].instance_storage_supported
      ])
      error_message = "gpu_nodepools: instance_store_policy = \"RAID0\" requires an instance type with Instance Store. Offending: ${join(", ", [for p in var.gpu_nodepools : "${p.name} (${p.instance_type})" if p.instance_store_policy == "RAID0" && !data.aws_ec2_instance_type.gpu[p.instance_type].instance_storage_supported])}. Set instance_store_policy = \"\" for those pools."
    }
    # Neuron by name but EC2 publishes no NeuronInfo (trn2u.48xlarge in
    # ap-south-2 today; in regions where EC2 does not describe the type at all
    # the data source read fails first with InvalidInstanceType): no
    # aws.amazon.com/neuron limit can be derived, and Karpenter would not
    # advertise aws.amazon.com/neuron capacity for it either.
    precondition {
      condition = alltrue([for n, p in local.gpu_pools :
        local.gpu_pool_vendor[n] != "neuron" || local.neuron_count_per_type[p.instance_type] > 0
      ])
      error_message = "gpu_nodepools: ${join(", ", [for n, p in local.gpu_pools : "${n} (${p.instance_type})" if local.gpu_pool_vendor[n] == "neuron" && local.neuron_count_per_type[p.instance_type] == 0])} are classified as Neuron by name (trn*/inf*) but EC2 reports no Neuron devices (e.g. trn2u.48xlarge publishes no NeuronInfo), so no aws.amazon.com/neuron limit can be derived. Unsupported until EC2 publishes NeuronInfo."
    }
    # Cross-check of the name-based vendor: a Neuron type the regex misses
    # would be rendered with the NVIDIA contract (wrong taint/AMI/userData).
    precondition {
      condition = alltrue([for n, p in local.gpu_pools :
        local.gpu_pool_vendor[n] != "nvidia" || length(data.aws_ec2_instance_type.gpu[p.instance_type].gpus) > 0 || length(data.aws_ec2_instance_type.gpu[p.instance_type].neuron_devices) == 0
      ])
      error_message = "gpu_nodepools: EC2 reports Neuron devices for ${join(", ", [for n, p in local.gpu_pools : "${n} (${p.instance_type})" if local.gpu_pool_vendor[n] == "nvidia" && length(data.aws_ec2_instance_type.gpu[p.instance_type].gpus) == 0 && length(data.aws_ec2_instance_type.gpu[p.instance_type].neuron_devices) > 0])} but the name does not match neuron_instance_type_regex — extend modules/gpu-instance-catalog."
    }
    # Plan-time (variables only). Heuristic: catches one ami- id being shared
    # by NVIDIA and Neuron pools (one of them must be on the wrong AMI); a
    # different NVIDIA-derived id cannot be detected without an AMI lookup.
    # Gated on BOTH vendors being present: with no NVIDIA pool,
    # var.gpu_ami_selector is never rendered, so a leftover equal value (e.g.
    # a Neuron ami- id copied rather than moved to karpenter_neuron_ami_selector)
    # is harmless.
    precondition {
      condition     = !local.gpu_has_neuron_pool || !local.gpu_has_nvidia_pool || !startswith(var.neuron_ami_selector, "ami-") || var.neuron_ami_selector != var.gpu_ami_selector
      error_message = "gpu_nodepools: Neuron pools ${join(", ", [for n, p in local.gpu_pools : "${n} (${p.instance_type})" if local.gpu_pool_vendor[n] == "neuron"])} and NVIDIA pools ${join(", ", [for n, p in local.gpu_pools : "${n} (${p.instance_type})" if local.gpu_pool_vendor[n] == "nvidia"])} would use the same custom AMI (${var.neuron_ami_selector}). NVIDIA and Neuron pools need different AMIs: if it is an NVIDIA AMI, point neuron_ami_selector (root: karpenter_neuron_ami_selector / neuron_custom_ami_id) at an amazon-eks-node-al2023-x86_64-neuron-* derived AMI or an al2023@ alias; if it is a Neuron AMI, change or clear gpu_ami_selector (root: karpenter_gpu_ami_selector / gpu_custom_ami_id) for the NVIDIA pools."
    }
    # Plan-time (variables only), gated on a Neuron pool existing so an
    # NVIDIA-only config never fails on a value derived for Neuron (the root
    # may build it from an ignored, malformed gpu_ami_release_version).
    precondition {
      condition     = !local.gpu_has_neuron_pool || local.neuron_ami_selector_valid
      error_message = "gpu_nodepools: Neuron pools ${join(", ", [for n, p in local.gpu_pools : "${n} (${p.instance_type})" if local.gpu_pool_vendor[n] == "neuron"])} resolve neuron_ami_selector = \"${var.neuron_ami_selector}\", which is not \"al2023@latest\", \"al2023@vYYYYMMDD\" or an \"ami-...\" id. At the root it comes from karpenter_neuron_ami_selector > neuron_custom_ami_id > karpenter_gpu_ami_selector (al2023@ alias only) > neuron_ami_release_version / gpu_ami_release_version (must be \"vYYYYMMDD\") — fix the one you set."
    }
    # Plan-time (variables only); NVIDIA-only configs are not affected.
    precondition {
      condition     = !local.gpu_has_neuron_pool || local.karpenter_version_ok_for_neuron
      error_message = "gpu_nodepools: Neuron pools ${join(", ", [for n, p in local.gpu_pools : "${n} (${p.instance_type})" if local.gpu_pool_vendor[n] == "neuron"])} require karpenter_version >= 1.1 (conservative minimum: NeuronInfo-based Neuron device counts / accelerator labels and the aws.amazon.com/neuroncore resource arrive in v1.1.0) — got ${var.karpenter_version}."
    }
    # Only Neuron pools that render networkInterfaces (EFA types); the catalog
    # layout is static, so this is plan-time too. NVIDIA pools stay unguarded
    # (pre-Neuron behaviour unchanged).
    precondition {
      condition = local.karpenter_version_ok_for_efa_nic || alltrue([for n, p in local.gpu_pools :
        local.gpu_pool_vendor[n] != "neuron" || length(local.gpu_pool_network_interfaces[n]) == 0
      ])
      error_message = "gpu_nodepools: Neuron EFA pools ${join(", ", [for n, p in local.gpu_pools : "${n} (${p.instance_type})" if local.gpu_pool_vendor[n] == "neuron" && length(local.gpu_pool_network_interfaces[n]) > 0])} require karpenter_version >= 1.11 (EC2NodeClass networkInterfaces, new in v1.11.0) — got ${var.karpenter_version}. Neuron pools without EFA (inf1 / inf2 / trn1.2xlarge) are held to the general >= 1.1 Neuron minimum only."
    }
  }

  depends_on = [helm_release.karpenter]
}
