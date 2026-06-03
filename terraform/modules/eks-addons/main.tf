data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# =====================================================================
# CoreDNS + Metrics Server (EKS managed addons, pinned to system nodegroup)
# =====================================================================
data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

data "aws_eks_addon_version" "metrics_server" {
  addon_name         = "metrics-server"
  kubernetes_version = var.k8s_version
  most_recent        = true
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = var.cluster_name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.coredns.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    replicaCount = 2
    nodeSelector = {
      (var.system_node_label_key) = var.system_node_label_value
    }
    affinity = {
      podAntiAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = [{
          labelSelector = {
            matchLabels = { k8s-app = "kube-dns" }
          }
          topologyKey = "kubernetes.io/hostname"
        }]
      }
    }
  })
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name                = var.cluster_name
  addon_name                  = "metrics-server"
  addon_version               = data.aws_eks_addon_version.metrics_server.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    replicas = 2
    nodeSelector = {
      (var.system_node_label_key) = var.system_node_label_value
    }
    affinity = {
      podAntiAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = [{
          labelSelector = {
            matchLabels = { k8s-app = "metrics-server" }
          }
          topologyKey = "kubernetes.io/hostname"
        }]
      }
    }
  })
}

# =====================================================================
# Cluster Autoscaler (Pod Identity)
#
# Gated behind var.install_cluster_autoscaler — set false when an external
# CA (e.g. customer-supplied) is deployed against this cluster.
#
# Chart + image versions auto-align to var.k8s_version via the matrix
# below (overrideable via var.cluster_autoscaler_chart_version /
# var.cluster_autoscaler_version when an explicit pin is needed).
# =====================================================================
locals {
  # K8s version → CA chart + image version pairing. Values are pinned to
  # known-good combos at the time of this commit; bump when a new k8s
  # minor lands. Keep chart 9.x and image v1.X.Y aligned per the chart's
  # README compatibility matrix.
  cluster_autoscaler_version_map = {
    "1.31" = { chart = "9.43.0", image = "v1.31.0" }
    "1.32" = { chart = "9.45.0", image = "v1.32.0" }
    "1.33" = { chart = "9.46.6", image = "v1.33.0" }
    "1.34" = { chart = "9.47.0", image = "v1.34.0" }
    "1.35" = { chart = "9.57.0", image = "v1.35.0" }
  }
  ca_chart_default = lookup(local.cluster_autoscaler_version_map, var.k8s_version, { chart = "" }).chart
  ca_image_default = lookup(local.cluster_autoscaler_version_map, var.k8s_version, { image = "" }).image
  ca_chart_version = var.cluster_autoscaler_chart_version != "" ? var.cluster_autoscaler_chart_version : local.ca_chart_default
  ca_image_version = var.cluster_autoscaler_version != "" ? var.cluster_autoscaler_version : local.ca_image_default
}

resource "aws_iam_role" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler ? 1 : 0

  name = "${var.cluster_name}-cluster-autoscaler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler ? 1 : 0

  name = "ClusterAutoscalerPolicy"
  role = aws_iam_role.cluster_autoscaler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
          }
        }
      },
    ]
  })
}

resource "kubernetes_service_account_v1" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler ? 1 : 0

  metadata {
    name      = "cluster-autoscaler"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name" = "cluster-autoscaler"
    }
  }
}

resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler[0].arn

  depends_on = [kubernetes_service_account_v1.cluster_autoscaler]
}

resource "helm_release" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler ? 1 : 0

  name             = "cluster-autoscaler"
  repository       = "https://kubernetes.github.io/autoscaler"
  chart            = "cluster-autoscaler"
  namespace        = "kube-system"
  create_namespace = false
  version          = local.ca_chart_version

  # Match the resilience semantics of the karpenter helm release: roll back
  # partial installs (cleanup_on_fail) and optionally take over stale
  # releases left by interrupted applies (replace, gated by var).
  cleanup_on_fail = true
  replace         = var.helm_replace_existing

  values = [yamlencode({
    # fullnameOverride pins the deployment + SA name to "cluster-autoscaler"
    # so it matches the SA we created via Pod Identity (chart's default
    # would prepend the release name and break the binding).
    fullnameOverride = "cluster-autoscaler"
    autoDiscovery = {
      clusterName = var.cluster_name
    }
    awsRegion = var.region
    image = {
      tag = local.ca_image_version
    }
    rbac = {
      serviceAccount = {
        create = false
        name   = kubernetes_service_account_v1.cluster_autoscaler[0].metadata[0].name
      }
    }
    replicaCount = 2
    nodeSelector = {
      (var.system_node_label_key) = var.system_node_label_value
    }
    # PDB: use the chart's default (maxUnavailable: 1). Setting minAvailable
    # alongside the chart-default maxUnavailable triggers a Kubernetes
    # validation error ("minAvailable and maxUnavailable cannot both be
    # set") — the chart doesn't unset its default when we override.
    affinity = {
      podAntiAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = [{
          labelSelector = {
            matchLabels = {
              "app.kubernetes.io/name" = "aws-cluster-autoscaler"
            }
          }
          topologyKey = "kubernetes.io/hostname"
        }]
      }
    }
    extraArgs = {
      "balance-similar-node-groups"      = true
      "skip-nodes-with-system-pods"      = false
      "skip-nodes-with-local-storage"    = false
      "expander"                         = "least-waste"
      "scale-down-utilization-threshold" = 0.5
    }
  })]

  depends_on = [aws_eks_pod_identity_association.cluster_autoscaler]
}

# =====================================================================
# AWS Load Balancer Controller (Pod Identity)
# =====================================================================
# Source the IAM policy either from the upstream GitHub release (default,
# guarantees the policy matches alb_controller_app_version exactly) or
# from the repo-bundled JSON (for air-gapped environments / GitHub.com
# blocked). Switch via var.alb_controller_iam_policy_source.
#
# We don't add a postcondition on the http data source: a non-200 fail
# would crash the plan rather than letting the operator switch to 'file'
# mode. Empty/invalid responses surface later as aws_iam_policy validation
# errors with the AWS-side message attached.
data "http" "alb_iam_policy" {
  count = var.alb_controller_iam_policy_source == "http" ? 1 : 0
  url   = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${var.alb_controller_app_version}/docs/install/iam_policy.json"

  retry {
    attempts     = 3
    min_delay_ms = 1000
  }
}

locals {
  alb_iam_policy_body = (
    var.alb_controller_iam_policy_source == "http"
    ? data.http.alb_iam_policy[0].response_body
    : file("${path.module}/../../assets/iam/alb-controller-iam-policy.json")
  )
}

resource "aws_iam_policy" "alb_controller" {
  name   = "${var.cluster_name}-alb-controller-policy"
  policy = local.alb_iam_policy_body
}

resource "aws_iam_role" "alb_controller" {
  name = "${var.cluster_name}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

resource "kubernetes_service_account_v1" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
  }
}

resource "aws_eks_pod_identity_association" "alb_controller" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.alb_controller.arn

  depends_on = [kubernetes_service_account_v1.alb_controller]
}

resource "helm_release" "alb_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  namespace        = "kube-system"
  create_namespace = false
  version          = var.alb_controller_chart_version

  cleanup_on_fail = true
  replace         = var.helm_replace_existing

  values = [yamlencode({
    clusterName = var.cluster_name
    region      = var.region
    vpcId       = var.vpc_id
    serviceAccount = {
      create = false
      name   = kubernetes_service_account_v1.alb_controller.metadata[0].name
    }
    # Pin image tag to the same version we used to fetch the IAM policy —
    # otherwise chart's appVersion default could drift from the policy.
    image = {
      tag = var.alb_controller_app_version
    }
    replicaCount = 2
    nodeSelector = {
      (var.system_node_label_key) = var.system_node_label_value
    }
    podDisruptionBudget = {
      minAvailable = 1
    }
    affinity = {
      podAntiAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = [{
          labelSelector = {
            matchLabels = {
              "app.kubernetes.io/name" = "aws-load-balancer-controller"
            }
          }
          topologyKey = "kubernetes.io/hostname"
        }]
      }
    }
    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
  })]

  depends_on = [aws_eks_pod_identity_association.alb_controller]
}
