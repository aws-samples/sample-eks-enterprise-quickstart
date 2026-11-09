# =====================================================================
# eks-neuron-stack — AWS Neuron device plugin (+ optional scheduler), an
# EFA device plugin for Neuron nodes and an optional neuron-monitor metrics
# exporter. See variables.tf header.
#
# Node contract (set by modules/eks-gpu-nodegroup for trn*/inf* types):
#   label  workload-type=neuron
#   taint  aws.amazon.com/neuron=true:NoSchedule
# =====================================================================

# Region -> EKS add-on ECR registry (same source as eks-gpu-stack).
module "ecr_registry" {
  source = "../eks-addon-ecr-registry"
  region = var.region
}

locals {
  efa_image = (
    var.efa_device_plugin_image != "" ? var.efa_device_plugin_image :
    module.ecr_registry.registry == "" ? "" :
    "${module.ecr_registry.registry}/eks/aws-efa-k8s-device-plugin:${var.efa_device_plugin_version}"
  )

  # Scheduler-extension / my-scheduler pods run on the system nodegroup,
  # like every other cluster addon in this stack.
  system_node_selector = { (var.system_node_label_key) = var.system_node_label_value }
  system_tolerations   = [{ key = "CriticalAddonsOnly", operator = "Exists" }]

  # Only emit devicePlugin.image when overridden, so the chart default
  # (image pinned per chart version) applies otherwise.
  device_plugin_image = merge(
    var.device_plugin_image_repository != "" ? { repository = var.device_plugin_image_repository } : {},
    var.device_plugin_image_tag != "" ? { tag = var.device_plugin_image_tag } : {},
  )

  # Same pattern for the scheduler-extension and my-scheduler images (mirrors
  # for cn-* / isolated / air-gapped regions). Helm deep-merges maps, so the
  # chart's other image fields (pullPolicy, ...) are kept.
  scheduler_image = merge(
    var.scheduler_image_repository != "" ? { repository = var.scheduler_image_repository } : {},
    var.scheduler_image_tag != "" ? { tag = var.scheduler_image_tag } : {},
  )
  kube_scheduler_image = merge(
    var.kube_scheduler_image_repository != "" ? { repository = var.kube_scheduler_image_repository } : {},
    var.kube_scheduler_image_tag != "" ? { tag = var.kube_scheduler_image_tag } : {},
  )

  # neuron-monitor (install_monitor). Selector label is separate from the
  # app.kubernetes.io/* set so the selector never changes if labels are
  # extended later (DaemonSet / Service selectors are immutable in practice).
  nm_labels = {
    "app.kubernetes.io/name"      = "neuron-monitor"
    "app.kubernetes.io/component" = "metrics"
    "app.kubernetes.io/part-of"   = "eks-neuron-stack"
  }
  nm_selector = { name = "neuron-monitor" }
  nm_port     = 8000

  # bedag/raw chart version — same pin as modules/eks-karpenter
  # (helm_release.karpenter_pools). Only used for the optional ServiceMonitor.
  raw_chart_version = "2.0.2"
}

# =====================================================================
# Neuron Helm chart (oci://public.ecr.aws/neuron/neuron-helm-chart)
# =====================================================================
# Release NAME matches the AWS EKS / Neuron docs install command
# (`helm upgrade --install neuron-helm-chart oci://public.ecr.aws/neuron/neuron-helm-chart`),
# but its NAMESPACE usually does not: that command has no --namespace, so Helm
# stores the release in the kubeconfig context namespace (normally `default`);
# only the DaemonSet lands in kube-system, via the chart's
# devicePlugin.namespaceOverride. For an existing manual install:
#   helm list -A | grep neuron-helm-chart          # find <ns>
#   helm uninstall neuron-helm-chart -n <ns>       # then apply (preferred)
# `terraform import 'module.eks_neuron_stack[0].helm_release.neuron' kube-system/neuron-helm-chart`
# is clean only when <ns> = kube-system; importing <ns>=default makes the next
# apply replace the release (namespace forces new), and applying without
# either step fails Helm's ownership check (release-namespace=default).
# helm_replace_existing = true (helm install --replace) does NOT adopt a
# deployed release — Helm only reuses a name whose latest revision is
# failed / uninstalled.
#
# Teardown: scripts/safe-destroy.sh pre-uninstalls this release (and the
# Neuron EFA DaemonSet below) — keep that list in sync if the name changes
# (pinned by tests/neuron_stack run "safe_destroy_covers_neuron").
#
# devicePlugin: deliberately NO nodeSelector / tolerations override. The
#   chart's default node affinity (node.kubernetes.io/instance-type In its
#   neuronInstances list) and its aws.amazon.com/neuron toleration already
#   cover managed, self-managed and Karpenter Neuron nodes. Helm
#   REPLACES lists on override, so setting tolerations here would drop the
#   chart defaults.
# npd: off. The chart's Neuron node-problem-detector needs the
#   neuron-healthcheck-system namespace (not created by the chart) plus IAM
#   for the recovery agent — not managed (no Neuron health checks; see the
#   README "Known gaps"). The AWS EKS and Neuron install guides also pass
#   npd.enabled=false.
# draDriver / ultraserverOperator: off — the DRA driver cannot coexist with
#   the device plugin on a node and is not supported with Karpenter.
# observer: off — intentionally not managed (README warning); metrics via neuron-monitor below
#
# 403 "authorization token has expired" from public.ecr.aws on plan/apply is
# a stale cached helm registry login: `helm registry logout public.ecr.aws`.
resource "helm_release" "neuron" {
  name             = "neuron-helm-chart"
  repository       = var.chart_repository
  chart            = "neuron-helm-chart"
  namespace        = "kube-system"
  create_namespace = false
  version          = var.chart_version

  cleanup_on_fail = true
  replace         = var.helm_replace_existing
  values = [yamlencode({
    devicePlugin = merge(
      { enabled = true },
      length(local.device_plugin_image) > 0 ? { image = local.device_plugin_image } : {},
    )
    # Scheduler extension + "my-scheduler" (customScheduler). The chart's
    # defaultScheduler mode targets control-plane nodes and is unusable on
    # EKS, so customScheduler is the only mode. Pods opt in with
    # schedulerName: my-scheduler.
    scheduler = merge(
      {
        enabled      = var.install_scheduler
        nodeSelector = local.system_node_selector
        tolerations  = local.system_tolerations
        customScheduler = merge(
          {
            enabled      = true
            nodeSelector = local.system_node_selector
            tolerations  = local.system_tolerations
          },
          length(local.kube_scheduler_image) > 0 ? { image = local.kube_scheduler_image } : {},
        )
      },
      length(local.scheduler_image) > 0 ? { image = local.scheduler_image } : {},
    )
    npd                 = { enabled = false }
    draDriver           = { enabled = false }
    observer            = { enabled = false }
    ultraserverOperator = { enabled = false }
  })]

  wait    = false
  timeout = 300
}

# =====================================================================
# AWS EFA Kubernetes Device Plugin — Neuron nodes
# =====================================================================
# Same manifest as eks-gpu-stack's aws-efa-k8s-device-plugin-daemonset, but a
# SEPARATE DaemonSet (distinct name + selector labels, so the two never
# fight over pods) confined to workload-type=neuron and tolerating the
# aws.amazon.com/neuron taint. Keeping it separate means NVIDIA-only clusters
# see zero change to the existing EFA DaemonSet.
resource "kubernetes_daemon_set_v1" "efa_device_plugin" {
  count = var.install_efa_device_plugin ? 1 : 0

  metadata {
    name      = "aws-efa-k8s-device-plugin-neuron"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name" = "aws-efa-k8s-device-plugin-neuron"
    }
  }

  spec {
    selector {
      match_labels = {
        name = "aws-efa-k8s-device-plugin-neuron"
      }
    }

    strategy {
      type = "RollingUpdate"
    }

    template {
      metadata {
        labels = {
          name = "aws-efa-k8s-device-plugin-neuron"
        }
      }
      spec {
        host_network = true
        node_selector = {
          "workload-type" = "neuron"
        }
        toleration {
          key      = "aws.amazon.com/neuron"
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

  lifecycle {
    precondition {
      condition     = local.efa_image != ""
      error_message = "No known EKS add-on ECR registry for region '${var.region}' (see eks_addon_ecr_account_by_region in modules/eks-addon-ecr-registry/main.tf, sourced from https://docs.aws.amazon.com/eks/latest/userguide/add-ons-images.html). Add the region there, or set efa_device_plugin_image to a full image reference."
    }
  }
}

# =====================================================================
# Neuron metrics — neuron-monitor + neuron-monitor-prometheus.py
# (install_monitor; opt-in parity with eks-gpu-stack's dcgm-exporter)
# =====================================================================
# Why neuron-monitor and not the chart's Neuron Observer: the Observer
# (observer.enabled) runs on hostNetwork with hostPort 7001 bound on every
# Neuron node and serves an unauthenticated HTTP API that includes fault-
# injection endpoints; it is beta and validated only on Trn2/Trn3, but if
# enabled the chart schedules it on EVERY Neuron instance type
# (trn1/trn1n/trn2/trn3/inf1/inf2 via neuronInstances +
# neuron.amazonaws.com/present=true). neuron-monitor is the
# long-standing exporter (aws-neuronx-tools) whose official DaemonSet
# (aws-neuron-sdk src/k8/k8s-neuron-monitor-daemonset.yml) runs in the pod
# network: read-only /metrics on :8000, no control API. helm_release.neuron
# keeps observer = { enabled = false } unchanged.
#
# Image: public.ecr.aws/neuron/neuron-monitor (Cmd /bin/bash, WorkingDir
# /root, amd64 only). /opt/bin/entrypoint.sh pipes `neuron-monitor` into
# `neuron-monitor-prometheus.py --port <port>` through a FIFO it creates
# under /tmp (mktemp), and with --enable-k8s-info also starts
# neuron-monitor-k8s-info.py (writes k8s_info.json in the working dir).
#
# Exposure: container port 8000 in the POD network namespace only — no
# hostNetwork, no hostPort; the Service is ClusterIP (literal, not a
# variable). Plain HTTP, no auth, read-only. Restrict with a NetworkPolicy if
# your CNI enforces one (README).
#
# Teardown: scripts/safe-destroy.sh pre-deletes these objects (pinned by
# tests/neuron_stack run "safe_destroy_covers_neuron").

resource "kubernetes_service_account_v1" "neuron_monitor" {
  count = var.install_monitor ? 1 : 0

  metadata {
    name      = "neuron-monitor"
    namespace = "kube-system"
    labels    = local.nm_labels
  }

  # The token is only mounted into the pod when pod attribution is on
  # (pod spec automount below); the SA itself never auto-mounts.
  automount_service_account_token = false
}

resource "kubernetes_daemon_set_v1" "neuron_monitor" {
  count = var.install_monitor ? 1 : 0

  metadata {
    name      = "neuron-monitor"
    namespace = "kube-system"
    labels    = local.nm_labels
  }

  # Same semantics as dcgm-exporter's helm wait = false: a slow image pull on
  # a fresh node must not block / fail the apply.
  wait_for_rollout = false

  spec {
    selector {
      match_labels = local.nm_selector
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "1"
      }
    }

    template {
      metadata {
        labels = merge(local.nm_selector, local.nm_labels)
      }

      spec {
        service_account_name            = kubernetes_service_account_v1.neuron_monitor[0].metadata[0].name
        automount_service_account_token = var.monitor_pod_attribution

        # Pod network only (exposure policy) — set explicitly so plans /
        # tests show the value rather than relying on provider defaults.
        host_network = false
        host_pid     = false
        host_ipc     = false
        dns_policy   = "ClusterFirst"

        node_selector = {
          "workload-type" = "neuron"
        }

        # inf1 (first-gen Inferentia) is excluded conservatively: it is
        # untested in this repo, and the Neuron AMI downgrades inf1 to the
        # legacy aws-neuronx-dkms 2.21 driver at boot. Note the AWS manifests
        # (aws-neuron-sdk k8s-neuron-monitor-daemonset.yml and the CloudWatch
        # Observability chart with neuron-monitor:1.13.0) DO schedule onto
        # inf1; drop this NotIn once inf1 has been verified live.
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "node.kubernetes.io/instance-type"
                  operator = "NotIn"
                  values   = ["inf1.xlarge", "inf1.2xlarge", "inf1.6xlarge", "inf1.24xlarge"]
                }
              }
            }
          }
        }

        toleration {
          key      = "aws.amazon.com/neuron"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        priority_class_name              = "system-node-critical"
        termination_grace_period_seconds = 15

        container {
          name              = "neuron-monitor"
          image             = var.monitor_image
          image_pull_policy = "IfNotPresent"
          # The image's Cmd is /bin/bash; the entrypoint must be explicit.
          command = ["/opt/bin/entrypoint.sh"]
          args = concat(
            ["--port", tostring(local.nm_port), "--neuron-monitor-config", "/opt/aws/neuron/bin/neuron-monitor.conf"],
            var.monitor_pod_attribution ? ["--enable-k8s-info"] : [],
          )

          port {
            name           = "metrics"
            container_port = local.nm_port
            protocol       = "TCP"
          }

          env {
            name  = "GOMEMLIMIT"
            value = "320MiB"
          }
          dynamic "env" {
            for_each = var.monitor_pod_attribution ? [1] : []
            content {
              name = "NODE_NAME"
              value_from {
                field_ref {
                  field_path = "spec.nodeName"
                }
              }
            }
          }

          # Values from the AWS CloudWatch Observability chart's neuronMonitor
          # (same image tag 1.13.0, trn2 in its affinity): limits 500m / 500Mi,
          # requests 256m / 128Mi, GOMEMLIMIT 320MiB. The aws-neuron-sdk
          # k8s-neuron-monitor-daemonset.yml's 256Mi / 160MiB were sized for
          # neuron-monitor 1.3.0 (no trn2). GOMEMLIMIT caps only the Go
          # neuron-monitor; the Python exporter (and k8s-info, with
          # attribution) share the same container limit.
          resources {
            requests = {
              cpu    = "256m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "500Mi"
            }
          }

          readiness_probe {
            tcp_socket {
              port = tostring(local.nm_port)
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          # privileged: both AWS manifests (aws-neuron-sdk
          # k8s-neuron-monitor-daemonset.yml and the CloudWatch Observability
          # chart) require it. neuron-monitor enumerates EVERY /dev/neuron*
          # device and the driver's sysfs counters regardless of which pod the
          # device plugin allocated them to; an unprivileged container only
          # gets the devices allocated to it, and the device cgroup blocks
          # the rest. An unprivileged variant (CAP_SYS_ADMIN + /dev hostPath)
          # is untested — follow-up. The root filesystem stays read-only:
          # the entrypoint only writes /tmp (FIFO) and the working dir /root,
          # both emptyDirs below.
          security_context {
            privileged                = true
            read_only_root_filesystem = true
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
          volume_mount {
            name       = "workdir"
            mount_path = "/root"
          }
          volume_mount {
            name       = "opt-aws"
            mount_path = "/opt-aws"
            read_only  = true
          }
          dynamic "volume_mount" {
            for_each = var.monitor_pod_attribution ? [1] : []
            content {
              name       = "pod-resources"
              mount_path = "/var/lib/kubelet/pod-resources"
              read_only  = true
            }
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
        volume {
          name = "workdir"
          empty_dir {}
        }
        # Host /opt/aws, read-only at /opt-aws (same mount as the AWS
        # CloudWatch Observability chart, which ships this image tag). Both
        # the Go neuron-monitor binary (tools/pkg/discovery) and
        # neuron-monitor-k8s-info.py read /opt-aws/neuron/logical_nc_config;
        # without it they silently assume the default LNC (trn2 = 2) and
        # misreport core counts / indices on a host configured with another
        # LNC. The Neuron device plugin in this chart mounts /opt/aws
        # read-only too. type = Directory: never created on the host — the
        # pod fails to start instead if the path is missing. Mounting at
        # /opt-aws (not /opt/aws) keeps the image's /opt/aws/neuron/bin.
        volume {
          name = "opt-aws"
          host_path {
            path = "/opt/aws"
            type = "Directory"
          }
        }
        # Only with pod attribution: the kubelet pod-resources gRPC socket
        # (read-only). No other hostPath.
        dynamic "volume" {
          for_each = var.monitor_pod_attribution ? [1] : []
          content {
            name = "pod-resources"
            host_path {
              path = "/var/lib/kubelet/pod-resources"
              type = "Directory"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "neuron_monitor" {
  count = var.install_monitor ? 1 : 0

  metadata {
    name      = "neuron-monitor"
    namespace = "kube-system"
    labels    = local.nm_labels
  }

  spec {
    # Literal ClusterIP (exposure policy): never NodePort / LoadBalancer, no
    # externalIPs. In-cluster scrapers only.
    type                    = "ClusterIP"
    selector                = local.nm_selector
    internal_traffic_policy = "Cluster"

    port {
      name        = "metrics"
      port        = local.nm_port
      target_port = "metrics"
      protocol    = "TCP"
    }
  }
}

# Pod attribution (BETA --enable-k8s-info): neuron-monitor-k8s-info.py reads
# the kubelet pod list (https://$NODE_NAME:10250/pods) with the SA token.
# `get nodes/pods` is the narrowest kubelet permission for that (kubelet
# fine-grained authz); nodes/proxy (kubelet exec/run) is never granted.
resource "kubernetes_cluster_role_v1" "neuron_monitor" {
  count = var.install_monitor && var.monitor_pod_attribution ? 1 : 0

  metadata {
    name   = "neuron-monitor"
    labels = local.nm_labels
  }

  rule {
    api_groups = [""]
    resources  = ["nodes/pods"]
    verbs      = ["get"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "neuron_monitor" {
  count = var.install_monitor && var.monitor_pod_attribution ? 1 : 0

  metadata {
    name   = "neuron-monitor"
    labels = local.nm_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.neuron_monitor[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.neuron_monitor[0].metadata[0].name
    namespace = "kube-system"
  }
}

# Optional Prometheus Operator ServiceMonitor (monitor_service_monitor).
# Shipped through bedag/raw (same chart + pin as eks-karpenter) so a cluster
# without the monitoring.coreos.com CRDs never needs them unless this is on.
# Scrape settings and exported_* names match dcgm-exporter behind its
# ServiceMonitor (chart 4.8.2 defaults: honorLabels false, 15s / 10s): the
# exporter's own workload labels land as exported_pod / exported_namespace /
# exported_container. The `node` label (from __meta_kubernetes_pod_node_name)
# is Neuron-only: dcgm's chart adds no relabelings and identifies the host by
# its own `Hostname` label, so a cross-vendor join needs label_replace.
resource "helm_release" "neuron_monitor_service_monitor" {
  count = var.install_monitor && var.monitor_service_monitor ? 1 : 0

  name             = "neuron-monitor-servicemonitor"
  repository       = "https://bedag.github.io/helm-charts/"
  chart            = "raw"
  version          = local.raw_chart_version
  namespace        = "kube-system"
  create_namespace = false

  cleanup_on_fail = true
  replace         = var.helm_replace_existing
  values = [yamlencode({
    resources = [{
      apiVersion = "monitoring.coreos.com/v1"
      kind       = "ServiceMonitor"
      metadata = {
        name      = "neuron-monitor"
        namespace = "kube-system"
        labels    = merge(local.nm_labels, var.monitor_service_monitor_labels)
      }
      spec = {
        selector = {
          matchLabels = {
            "app.kubernetes.io/name"      = local.nm_labels["app.kubernetes.io/name"]
            "app.kubernetes.io/component" = local.nm_labels["app.kubernetes.io/component"]
          }
        }
        namespaceSelector = { matchNames = ["kube-system"] }
        endpoints = [{
          port          = "metrics"
          interval      = "15s"
          scrapeTimeout = "10s"
          scheme        = "http"
          honorLabels   = false
          relabelings = [{
            sourceLabels = ["__meta_kubernetes_pod_node_name"]
            targetLabel  = "node"
            action       = "replace"
          }]
          # --enable-k8s-info emits pod_name / container_name (the latter
          # formatted like ['name']); map them onto dcgm's exported_* names.
          #
          # Ownership comes from the AWS_NEURON_IDS pod annotation, which
          # only the Neuron scheduler extension (install_scheduler, pods with
          # schedulerName: my-scheduler) writes. Without it,
          # neuron-monitor-k8s-info.py attributes EVERY device and core on
          # the node to the first Neuron-holding pod/container it finds
          # (container_name may list containers of several pods) — correct
          # only when one pod owns all of the node's Neuron devices.
          #
          # Series with no owner (no pod on the node holds a Neuron resource,
          # the kubelet lookup fails e.g. 403, before the first k8s_info.json
          # write, or — annotation present — devices not listed in it) get
          # Python None, which prometheus_client exports as the literal
          # string "None" (neuron-monitor-prometheus.py). The first three
          # rules blank it so no phantom pod / namespace "None" appears;
          # an empty value removes the label (dcgm leaves unallocated GPUs
          # without exported_pod too). Regexes are fully anchored, and no
          # real pod / namespace can be "None" (DNS-1123 is lowercase).
          # exported_namespace already exists here: the honorLabels: false
          # conflict rename happens before metricRelabelings.
          metricRelabelings = [
            {
              sourceLabels = ["pod_name"]
              regex        = "None"
              targetLabel  = "pod_name"
              replacement  = ""
              action       = "replace"
            },
            {
              sourceLabels = ["container_name"]
              regex        = "None"
              targetLabel  = "container_name"
              replacement  = ""
              action       = "replace"
            },
            {
              sourceLabels = ["exported_namespace"]
              regex        = "None"
              targetLabel  = "exported_namespace"
              replacement  = ""
              action       = "replace"
            },
            {
              sourceLabels = ["pod_name"]
              regex        = "(.+)"
              targetLabel  = "exported_pod"
              replacement  = "$1"
              action       = "replace"
            },
            {
              sourceLabels = ["container_name"]
              regex        = "^\\['([^']*)'.*$"
              targetLabel  = "exported_container"
              replacement  = "$1"
              action       = "replace"
            },
            {
              regex  = "pod_name|container_name"
              action = "labeldrop"
            },
          ]
        }]
      }
    }]
  })]

  wait    = false
  timeout = 300

  depends_on = [kubernetes_service_v1.neuron_monitor]
}
