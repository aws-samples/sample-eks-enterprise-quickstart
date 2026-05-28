# =====================================================================
# eks-gpu-stack — K8s GPU components
# =====================================================================
# Mode dispatch happens via count = (mode == X) ? 1 : 0 on each resource
# so that stale resources from the OTHER mode become tombstones the
# next `terraform apply` removes.
#
# Conflict points the mode selector prevents:
#   - nvidia.com/gpu registration (both nvidia-device-plugin and
#     gpu-operator's plugin DS would advertise it)
#   - port 9400 (helm dcgm-exporter vs Operator's nvidia-dcgm-exporter)
#   - GFD labels (chart-internal GFD vs Operator's nvidia-gpu-feature-discovery)
#   - /dev/infiniband/uverbs* (mofedDriver vs AWS EFA plugin)
# =====================================================================

locals {
  is_standard = var.stack_mode == "standard"
  is_operator = var.stack_mode == "operator"

  # nvidia-device-plugin chart version is the image tag without leading 'v'
  nvidia_plugin_chart_version = trimprefix(var.nvidia_device_plugin_version, "v")
  nvidia_plugin_image_tag     = var.nvidia_device_plugin_version

  gpu_operator_chart_version = trimprefix(var.gpu_operator_version, "v")
  dcgm_chart_version         = trimprefix(var.dcgm_exporter_version, "v")
  npd_chart_version          = trimprefix(var.node_problem_detector_version, "v")

  # AWS EFA device-plugin image — pick correct ECR for cn-* vs commercial
  efa_image = (
    var.efa_device_plugin_image != "" ? var.efa_device_plugin_image :
    startswith(var.region, "cn-") ?
    "961992271922.dkr.ecr.${var.region}.amazonaws.com.cn/eks/aws-efa-k8s-device-plugin:${var.efa_device_plugin_version}" :
    "602401143452.dkr.ecr.${var.region}.amazonaws.com/eks/aws-efa-k8s-device-plugin:${var.efa_device_plugin_version}"
  )

  # Standard tolerations applied to every GPU-targeting workload we install
  gpu_tolerations = [
    {
      key      = "nvidia.com/gpu"
      operator = "Exists"
      effect   = "NoSchedule"
    },
  ]

  gpu_node_selector = {
    "workload-type" = "gpu"
  }
}

# =====================================================================
# AWS EFA Kubernetes Device Plugin (shared by both modes)
# =====================================================================
# Identical manifest to the in-tree version that lived in the
# eks-gpu-nodegroup module. Same name/namespace so terraform state
# move keeps existing installs continuous.
resource "kubernetes_daemon_set_v1" "efa_device_plugin" {
  count = var.install_efa_device_plugin ? 1 : 0

  metadata {
    name      = "aws-efa-k8s-device-plugin-daemonset"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name" = "aws-efa-k8s-device-plugin"
    }
  }

  spec {
    selector {
      match_labels = {
        name = "aws-efa-k8s-device-plugin"
      }
    }

    strategy {
      type = "RollingUpdate"
    }

    template {
      metadata {
        labels = {
          name = "aws-efa-k8s-device-plugin"
        }
      }
      spec {
        host_network = true
        node_selector = {
          "workload-type" = "gpu"
        }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }
        toleration {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        }
        priority_class_name = "system-node-critical"
        container {
          name              = "aws-efa-k8s-device-plugin"
          image             = local.efa_image
          image_pull_policy = "IfNotPresent"
          security_context {
            privileged = true
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "20Mi"
            }
          }
          volume_mount {
            name       = "device-plugin"
            mount_path = "/var/lib/kubelet/device-plugins"
          }
          volume_mount {
            name       = "infiniband-volume"
            mount_path = "/dev/infiniband/"
          }
        }
        volume {
          name = "device-plugin"
          host_path {
            path = "/var/lib/kubelet/device-plugins"
          }
        }
        volume {
          name = "infiniband-volume"
          host_path {
            path = "/dev/infiniband/"
          }
        }
      }
    }
  }
}

# =====================================================================
# Standard mode resources
# =====================================================================

# NVIDIA Device Plugin (helm)
# Notes:
#   gfd.enabled=true     → GPU Feature Discovery sidecar (nvidia.com/gpu.product etc.)
#   mofedEnabled=false   → AWS EFA plugin owns /dev/infiniband/uverbs*
resource "helm_release" "nvidia_device_plugin" {
  count = local.is_standard ? 1 : 0

  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  namespace        = "kube-system"
  create_namespace = false
  version          = local.nvidia_plugin_chart_version

  cleanup_on_fail = true
  replace         = var.helm_replace_existing
  values = [yamlencode({
    image = {
      repository = var.nvidia_device_plugin_repo
      tag        = local.nvidia_plugin_image_tag
    }
    mofedEnabled = false
    gfd = {
      enabled = true
    }
    nodeSelector = local.gpu_node_selector
    tolerations  = local.gpu_tolerations
  })]

  wait    = false
  timeout = 300
}

# DCGM exporter (helm) — pod-level GPU metrics for Prometheus
# NOTE: chart repo is https://nvidia.github.io/dcgm-exporter/helm-charts,
# not the NVIDIA NGC repo (which doesn't host dcgm-exporter as a chart).
resource "helm_release" "dcgm_exporter" {
  count = local.is_standard && var.install_dcgm_exporter ? 1 : 0

  name             = "dcgm-exporter"
  repository       = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart            = "dcgm-exporter"
  namespace        = "kube-system"
  create_namespace = false
  version          = local.dcgm_chart_version

  cleanup_on_fail = true
  replace         = var.helm_replace_existing
  values = [yamlencode({
    nodeSelector = local.gpu_node_selector
    tolerations  = local.gpu_tolerations
    serviceMonitor = {
      enabled = false
    }
  })]

  wait    = false
  timeout = 300
}

# node-problem-detector (helm) — surfaces GPU XID errors / kernel hangs
resource "helm_release" "node_problem_detector" {
  count = local.is_standard && var.install_node_problem_detector ? 1 : 0

  name             = "node-problem-detector"
  repository       = "https://charts.deliveryhero.io/"
  chart            = "node-problem-detector"
  namespace        = "kube-system"
  create_namespace = false
  version          = local.npd_chart_version

  cleanup_on_fail = true
  replace         = var.helm_replace_existing
  values = [yamlencode({
    nodeSelector = local.gpu_node_selector
    tolerations  = local.gpu_tolerations
  })]

  wait    = false
  timeout = 300
}

# GPU health-check DaemonSet — boot-time nvidia-smi probe
# Taints node with gpu-unhealthy=true:NoSchedule on failure.
resource "kubernetes_service_account_v1" "gpu_health_check" {
  count = local.is_standard && var.install_gpu_health_check ? 1 : 0

  metadata {
    name      = "gpu-health-check"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_v1" "gpu_health_check" {
  count = local.is_standard && var.install_gpu_health_check ? 1 : 0

  metadata {
    name = "gpu-health-check"
  }
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "patch", "update"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "gpu_health_check" {
  count = local.is_standard && var.install_gpu_health_check ? 1 : 0

  metadata {
    name = "gpu-health-check"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "gpu-health-check"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "gpu-health-check"
    namespace = "kube-system"
  }

  depends_on = [
    kubernetes_service_account_v1.gpu_health_check,
    kubernetes_cluster_role_v1.gpu_health_check,
  ]
}

resource "kubernetes_daemon_set_v1" "gpu_health_check" {
  count = local.is_standard && var.install_gpu_health_check ? 1 : 0

  metadata {
    name      = "gpu-health-check"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name" = "gpu-health-check"
    }
  }
  spec {
    selector {
      match_labels = {
        "app.kubernetes.io/name" = "gpu-health-check"
      }
    }
    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "gpu-health-check"
        }
      }
      spec {
        host_pid             = true
        service_account_name = "gpu-health-check"
        node_selector        = local.gpu_node_selector
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }
        toleration {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        }
        priority_class_name = "system-node-critical"
        # alpine/k8s is multi-arch (amd64/arm64), ships kubectl + util-linux
        # (nsenter), and is freely pullable. We tried amazonlinux:2023 base
        # and bitnami/kubectl:1.31 — both broken; see commit history.
        container {
          name              = "probe"
          image             = "docker.io/alpine/k8s:1.31.4"
          image_pull_policy = "IfNotPresent"
          security_context {
            privileged = true
          }
          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
          command = [
            "/bin/sh",
            "-c",
            <<-EOT
              set -u
              if nsenter -t 1 -m -p -- nvidia-smi -L >/tmp/smi.log 2>&1; then
                  echo "[gpu-health-check] PASS: nvidia-smi -L on $${NODE_NAME}"
                  cat /tmp/smi.log
                  kubectl taint node "$${NODE_NAME}" gpu-unhealthy- 2>/dev/null || true
              else
                  echo "[gpu-health-check] FAIL: nvidia-smi on $${NODE_NAME}"
                  cat /tmp/smi.log
                  kubectl taint node "$${NODE_NAME}" gpu-unhealthy=true:NoSchedule --overwrite || true
              fi

              while true; do sleep 3600; done
            EOT
          ]
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_cluster_role_binding_v1.gpu_health_check,
  ]
}

# =====================================================================
# Operator mode resources
# =====================================================================

# NVIDIA GPU Operator (helm)
# Critical flags:
#   driver.enabled=false   — AMI ships the driver
#   toolkit.enabled=false  — AMI ships nvidia-container-toolkit
#   mofedDriver.enabled=false / driver.rdma.enabled=false — AWS EFA plugin
#                            owns /dev/infiniband/uverbs*
#   migManager.enabled is on iff mig.strategy != none
#   daemonsets.nodeSelector.workload-type=gpu — confine all Operator DS
#                            to the same GPU nodes the rest of the stack uses
resource "helm_release" "gpu_operator" {
  count = local.is_operator ? 1 : 0

  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  namespace        = var.gpu_operator_namespace
  create_namespace = true
  version          = local.gpu_operator_chart_version

  cleanup_on_fail = true
  replace         = var.helm_replace_existing
  values = [yamlencode({
    driver = {
      enabled = var.gpu_operator_driver_enabled
      rdma = {
        enabled = false
      }
    }
    toolkit = {
      enabled = var.gpu_operator_toolkit_enabled
    }
    mofedDriver = {
      enabled = var.gpu_operator_mofed_enabled
    }
    devicePlugin = {
      enabled = true
    }
    dcgmExporter = {
      enabled = true
    }
    gfd = {
      enabled = true
    }
    nfd = {
      enabled = true
    }
    validator = {
      plugin = {
        env = [
          {
            name  = "WITH_WORKLOAD"
            value = "false"
          },
        ]
      }
    }
    migManager = {
      enabled = var.gpu_operator_mig_strategy != "none"
    }
    mig = {
      strategy = var.gpu_operator_mig_strategy
    }
    daemonsets = {
      nodeSelector = local.gpu_node_selector
      tolerations = [
        {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        },
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        },
      ]
    }
  })]

  wait    = false
  timeout = 600
}
