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
#   - Labels workload-type=gpu + taint nvidia.com/gpu match what the GPU stack
#     DaemonSets (device plugins, DCGM, health check) select/tolerate.
#   - Spot interruptions are handled by Karpenter's interruption queue
#     (aws_sqs_queue.karpenter_interruption): the node is cordoned/drained on
#     the 2-minute notice and a replacement is launched immediately.
# =====================================================================
module "gpu_catalog" {
  source                = "../gpu-instance-catalog"
  efa_installer_version = var.gpu_efa_installer_version
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

  gpu_ami_selector_terms = (
    startswith(var.gpu_ami_selector, "ami-") ? [{ id = var.gpu_ami_selector }] : [{ alias = var.gpu_ami_selector }]
  )

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

  gpu_ec2nodeclasses = [
    for n, p in local.gpu_pools : {
      apiVersion = "karpenter.k8s.aws/v1"
      kind       = "EC2NodeClass"
      metadata   = { name = "gpu-${n}" }
      spec = merge(
        {
          amiSelectorTerms           = local.gpu_ami_selector_terms
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
          userData = local.gpu_userdata
          tags     = { "gpu-instance-type" = p.instance_type }
        },
        p.instance_store_policy != "" ? { instanceStorePolicy = p.instance_store_policy } : {},
        startswith(var.gpu_ami_selector, "ami-") ? { amiFamily = "AL2023" } : {},
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
              "workload-type"     = "gpu"
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
            taints      = [{ key = "nvidia.com/gpu", value = "true", effect = "NoSchedule" }]
            expireAfter = p.expire_after
          }
        }
        # Limit in GPUs when the type has them (so max_nodes nodes fit
        # exactly), else in vCPUs.
        limits = (
          local.gpu_count_per_type[p.instance_type] > 0
          ? { "nvidia.com/gpu" = tostring(p.max_nodes * local.gpu_count_per_type[p.instance_type]) }
          : { cpu = tostring(p.max_nodes * data.aws_ec2_instance_type.gpu[p.instance_type].default_vcpus) }
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
  }

  depends_on = [helm_release.karpenter]
}
