# modules/eks-neuron-stack: neuron-helm-chart values + the Neuron-node EFA
# device-plugin DaemonSet.
#   - Helm release name / repo / chart match the AWS + Neuron docs install
#     command, so a manual install can be `terraform import`ed (helm
#     replace=true does not adopt a deployed release).
#   - Only the device plugin is on by default (npd / DRA / observer /
#     ultraserverOperator off; scheduler opt-in).
#   - The EFA DaemonSet is SEPARATE from eks-gpu-stack's (distinct name +
#     selector), confined to workload-type=neuron, tolerates
#     aws.amazon.com/neuron, and resolves its image from the same
#     modules/eks-addon-ecr-registry map as eks-gpu-stack (parity runs below
#     mirror tests/efa_device_plugin_image).
#   - neuron-monitor (install_monitor) is opt-in: off by default (zero-diff),
#     pod network only (no hostNetwork / hostPort), ClusterIP Service only,
#     ServiceMonitor + pod attribution separately opt-in, Observer never on,
#     and turning it on leaves the neuron-helm-chart values byte-identical.

mock_provider "kubernetes" {}
mock_provider "helm" {}

variables {
  region                  = "us-east-2"
  system_node_label_key   = "app"
  system_node_label_value = "eks-utils"
}

run "defaults" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }

  assert {
    condition     = helm_release.neuron.name == "neuron-helm-chart"
    error_message = "Helm release must be named neuron-helm-chart (matches the documented manual install)."
  }
  assert {
    condition     = helm_release.neuron.repository == "oci://public.ecr.aws/neuron"
    error_message = "Default chart repository must be oci://public.ecr.aws/neuron."
  }
  assert {
    condition     = helm_release.neuron.chart == "neuron-helm-chart"
    error_message = "Chart must be neuron-helm-chart."
  }
  assert {
    condition     = helm_release.neuron.version == "1.11.2"
    error_message = "Default chart version must be 1.11.2."
  }
  assert {
    condition     = helm_release.neuron.namespace == "kube-system"
    error_message = "Neuron chart must install into kube-system."
  }
  assert {
    condition     = yamldecode(helm_release.neuron.values[0]).devicePlugin.enabled
    error_message = "Device plugin must be enabled."
  }
  assert {
    condition     = !can(yamldecode(helm_release.neuron.values[0]).devicePlugin.image)
    error_message = "devicePlugin.image must be omitted by default (chart default applies)."
  }
  assert {
    condition     = !can(yamldecode(helm_release.neuron.values[0]).scheduler.image) && !can(yamldecode(helm_release.neuron.values[0]).scheduler.customScheduler.image)
    error_message = "Scheduler images must be omitted by default (chart defaults apply)."
  }
  assert {
    condition     = !can(yamldecode(helm_release.neuron.values[0]).devicePlugin.nodeSelector) && !can(yamldecode(helm_release.neuron.values[0]).devicePlugin.tolerations)
    error_message = "devicePlugin placement must not be overridden (helm replaces lists — chart affinity + aws.amazon.com/neuron toleration would be lost)."
  }
  assert {
    condition     = !yamldecode(helm_release.neuron.values[0]).scheduler.enabled
    error_message = "Scheduler extension must be off by default."
  }
  assert {
    condition     = !yamldecode(helm_release.neuron.values[0]).npd.enabled
    error_message = "Neuron NPD must be off (needs the neuron-healthcheck-system namespace + recovery-agent IAM; not managed — see README Known gaps)."
  }
  assert {
    condition     = !yamldecode(helm_release.neuron.values[0]).draDriver.enabled
    error_message = "Neuron DRA driver must be off (conflicts with the device plugin)."
  }
  assert {
    condition     = !yamldecode(helm_release.neuron.values[0]).observer.enabled
    error_message = "Neuron observer must be off."
  }
  assert {
    condition     = !yamldecode(helm_release.neuron.values[0]).ultraserverOperator.enabled
    error_message = "ultraserverOperator must be off."
  }

  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name == "aws-efa-k8s-device-plugin-neuron"
    error_message = "Neuron EFA DaemonSet must be named aws-efa-k8s-device-plugin-neuron (distinct from eks-gpu-stack's)."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].node_selector == tomap({ "workload-type" = "neuron" })
    error_message = "Neuron EFA DaemonSet must select workload-type=neuron only."
  }
  assert {
    condition     = [for t in kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].toleration : t.key] == ["aws.amazon.com/neuron", "CriticalAddonsOnly"]
    error_message = "Neuron EFA DaemonSet must tolerate aws.amazon.com/neuron + CriticalAddonsOnly only."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].selector[0].match_labels["name"] == "aws-efa-k8s-device-plugin-neuron"
    error_message = "Neuron EFA DaemonSet selector must not overlap the NVIDIA EFA DaemonSet's (name=aws-efa-k8s-device-plugin)."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image == "602401143452.dkr.ecr.us-east-2.amazonaws.com/eks/aws-efa-k8s-device-plugin:v0.5.19"
    error_message = "us-east-2 must use the 602401143452 EKS add-on registry."
  }

  # neuron-monitor is opt-in: nothing is planned by default (zero-diff for
  # existing Neuron configs).
  assert {
    condition = (
      length(kubernetes_daemon_set_v1.neuron_monitor) == 0 &&
      length(kubernetes_service_v1.neuron_monitor) == 0 &&
      length(kubernetes_service_account_v1.neuron_monitor) == 0 &&
      length(kubernetes_cluster_role_v1.neuron_monitor) == 0 &&
      length(kubernetes_cluster_role_binding_v1.neuron_monitor) == 0 &&
      length(helm_release.neuron_monitor_service_monitor) == 0
    )
    error_message = "neuron-monitor objects (DaemonSet / Service / SA / RBAC / ServiceMonitor release) must not be created by default."
  }
  # Byte-identical neuron-helm-chart values: pins that the observability
  # change did not touch the release (the same literal is asserted with
  # install_monitor = true in run "monitor_enabled").
  assert {
    condition = helm_release.neuron.values[0] == yamlencode({
      devicePlugin = { enabled = true }
      scheduler = {
        enabled      = false
        nodeSelector = { app = "eks-utils" }
        tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
        customScheduler = {
          enabled      = true
          nodeSelector = { app = "eks-utils" }
          tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
        }
      }
      npd                 = { enabled = false }
      draDriver           = { enabled = false }
      observer            = { enabled = false }
      ultraserverOperator = { enabled = false }
    })
    error_message = "neuron-helm-chart values changed — must stay byte-identical for existing Neuron configs."
  }
}

run "scheduler_enabled" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    install_scheduler        = true
    kube_scheduler_image_tag = "v1.35.9-eks-1-35-16"
  }

  assert {
    condition     = yamldecode(helm_release.neuron.values[0]).scheduler.enabled
    error_message = "install_scheduler must enable the scheduler extension."
  }
  assert {
    condition     = yamldecode(helm_release.neuron.values[0]).scheduler.nodeSelector == { app = "eks-utils" }
    error_message = "Scheduler extension must run on the system nodegroup."
  }
  assert {
    condition     = yamldecode(helm_release.neuron.values[0]).scheduler.customScheduler.nodeSelector == { app = "eks-utils" }
    error_message = "my-scheduler must run on the system nodegroup."
  }
  assert {
    condition     = yamldecode(helm_release.neuron.values[0]).scheduler.customScheduler.enabled
    error_message = "customScheduler (my-scheduler) must be on — the defaultScheduler mode is unusable on EKS."
  }
  assert {
    condition     = yamldecode(helm_release.neuron.values[0]).scheduler.customScheduler.image == { tag = "v1.35.9-eks-1-35-16" }
    error_message = "kube_scheduler_image_tag must override only the my-scheduler image tag (repository stays chart default)."
  }
  assert {
    condition     = !can(yamldecode(helm_release.neuron.values[0]).scheduler.image)
    error_message = "scheduler.image must not be emitted when no scheduler image override is set (chart default applies)."
  }
  # Exposure: the chart only switches the extender to hostNetwork + NodePort
  # 32700 in defaultScheduler mode. Keep it at the chart default (off) so the
  # extender stays a ClusterIP-only :12345 listener, and keep that listener
  # (plain HTTP, no auth, bind verb) documented with a NetworkPolicy example.
  assert {
    condition     = !try(yamldecode(helm_release.neuron.values[0]).scheduler.defaultScheduler.enabled, false)
    error_message = "scheduler.defaultScheduler must stay off (it puts the extender on hostNetwork + NodePort 32700)."
  }
  assert {
    condition = alltrue([
      yamldecode(helm_release.neuron.values[0]).scheduler.enabled,
      strcontains(file("../../README.md"), "`kube-system/k8s-neuron-scheduler` on TCP **12345**"),
      strcontains(file("../../README.md"), "name: neuron-scheduler-extender, namespace: kube-system"),
      strcontains(file("../../README.md"), "matchLabels: { app.kubernetes.io/component: my-scheduler }"),
      strcontains(file("../../modules/eks-neuron-stack/variables.tf"), "k8s-neuron-scheduler on TCP 12345"),
      strcontains(file("../../variables.tf"), "k8s-neuron-scheduler on TCP 12345"),
    ])
    error_message = "The scheduler extender's :12345 listener (plain HTTP, no auth, bind) must stay documented in README (with the NetworkPolicy example) and both install_*scheduler descriptions."
  }
}

# The chart's default my-scheduler image (v1.31.x in 1.11.2) is outside the
# kube-scheduler/apiserver skew of current clusters: enabling the scheduler
# without an explicit tag must be rejected, not silently deployed.
run "scheduler_requires_kube_scheduler_tag" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    install_scheduler = true
  }

  expect_failures = [var.kube_scheduler_image_tag]
}

# Mirrors for cn-* / isolated / air-gapped regions must cover BOTH scheduler
# images (neuron-scheduler extender + my-scheduler), not just the device plugin.
run "scheduler_image_mirrors" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    install_scheduler               = true
    scheduler_image_repository      = "111122223333.dkr.ecr.cn-north-1.amazonaws.com.cn/neuron/neuron-scheduler"
    scheduler_image_tag             = "2.33.1.0"
    kube_scheduler_image_repository = "111122223333.dkr.ecr.cn-north-1.amazonaws.com.cn/eks-distro/kubernetes/kube-scheduler"
    kube_scheduler_image_tag        = "v1.35.9-eks-1-35-16"
  }

  assert {
    condition = yamldecode(helm_release.neuron.values[0]).scheduler.image == {
      repository = "111122223333.dkr.ecr.cn-north-1.amazonaws.com.cn/neuron/neuron-scheduler"
      tag        = "2.33.1.0"
    }
    error_message = "scheduler_image_repository / _tag must override scheduler.image."
  }
  assert {
    condition = yamldecode(helm_release.neuron.values[0]).scheduler.customScheduler.image == {
      repository = "111122223333.dkr.ecr.cn-north-1.amazonaws.com.cn/eks-distro/kubernetes/kube-scheduler"
      tag        = "v1.35.9-eks-1-35-16"
    }
    error_message = "kube_scheduler_image_repository / _tag must override scheduler.customScheduler.image."
  }
}

run "device_plugin_override" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    device_plugin_image_repository = "mirror.example.com/neuron/neuron-device-plugin"
    device_plugin_image_tag        = "2.33.1.0"
  }

  assert {
    condition = yamldecode(helm_release.neuron.values[0]).devicePlugin.image == {
      repository = "mirror.example.com/neuron/neuron-device-plugin"
      tag        = "2.33.1.0"
    }
    error_message = "device_plugin_image_repository / _tag must set devicePlugin.image."
  }
}

run "ecr_parity_ap_south_2" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    region = "ap-south-2"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image == "900889452093.dkr.ecr.ap-south-2.amazonaws.com/eks/aws-efa-k8s-device-plugin:v0.5.19"
    error_message = "ap-south-2 must resolve to the same EKS add-on registry as eks-gpu-stack (900889452093.dkr.ecr.ap-south-2.amazonaws.com)."
  }
}

run "ecr_parity_cn_north_1" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    region = "cn-north-1"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image == "918309763551.dkr.ecr.cn-north-1.amazonaws.com.cn/eks/aws-efa-k8s-device-plugin:v0.5.19"
    error_message = "cn-north-1 must resolve to the same EKS add-on registry as eks-gpu-stack (918309763551.dkr.ecr.cn-north-1.amazonaws.com.cn)."
  }
}

run "ecr_parity_cn_northwest_1" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    region = "cn-northwest-1"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image == "961992271922.dkr.ecr.cn-northwest-1.amazonaws.com.cn/eks/aws-efa-k8s-device-plugin:v0.5.19"
    error_message = "cn-northwest-1 must resolve to the same EKS add-on registry as eks-gpu-stack (961992271922.dkr.ecr.cn-northwest-1.amazonaws.com.cn)."
  }
}

run "ecr_parity_eusc_de_east_1" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    region = "eusc-de-east-1"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image == "877088126301.dkr.ecr.eusc-de-east-1.amazonaws.eu/eks/aws-efa-k8s-device-plugin:v0.5.19"
    error_message = "eusc-de-east-1 must resolve to the same EKS add-on registry as eks-gpu-stack (877088126301.dkr.ecr.eusc-de-east-1.amazonaws.eu)."
  }
}

run "explicit_override_wins" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    region                  = "ap-south-2"
    efa_device_plugin_image = "mirror.example.com/eks/aws-efa-k8s-device-plugin:v0.5.19"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image == "mirror.example.com/eks/aws-efa-k8s-device-plugin:v0.5.19"
    error_message = "efa_device_plugin_image must override the registry map."
  }
}

run "efa_disabled" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    install_efa_device_plugin = false
  }
  assert {
    condition     = length(kubernetes_daemon_set_v1.efa_device_plugin) == 0
    error_message = "install_efa_device_plugin = false must skip the Neuron EFA DaemonSet."
  }
}

run "unknown_region_fails" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    region = "xx-nowhere-1"
  }
  expect_failures = [kubernetes_daemon_set_v1.efa_device_plugin]
}

run "bad_chart_version_rejected" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    chart_version = "latest"
  }
  expect_failures = [var.chart_version]
}

# =====================================================================
# neuron-monitor (install_monitor) — exposure policy + parity with dcgm
# =====================================================================
run "monitor_enabled" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    install_monitor = true
  }

  assert {
    condition     = kubernetes_daemon_set_v1.neuron_monitor[0].metadata[0].name == "neuron-monitor" && kubernetes_daemon_set_v1.neuron_monitor[0].metadata[0].namespace == "kube-system"
    error_message = "neuron-monitor DaemonSet must be kube-system/neuron-monitor."
  }
  assert {
    condition     = !kubernetes_daemon_set_v1.neuron_monitor[0].wait_for_rollout
    error_message = "neuron-monitor must not wait for rollout (dcgm-exporter parity: helm wait = false)."
  }
  assert {
    condition = (
      !kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].host_network &&
      !kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].host_pid &&
      !kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].host_ipc
    )
    error_message = "neuron-monitor must not use hostNetwork / hostPID / hostIPC (exposure policy)."
  }
  assert {
    condition     = alltrue([for p in kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].port : try(p.host_port, null) == null || try(p.host_port, 0) == 0])
    error_message = "neuron-monitor must not bind a hostPort."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].port[0].container_port == 8000 && kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].port[0].name == "metrics"
    error_message = "neuron-monitor must expose container port 8000 named metrics."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].node_selector == tomap({ "workload-type" = "neuron" })
    error_message = "neuron-monitor must select workload-type=neuron only."
  }
  assert {
    condition     = [for t in kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].toleration : t.key] == ["aws.amazon.com/neuron"]
    error_message = "neuron-monitor must tolerate aws.amazon.com/neuron only."
  }
  assert {
    condition = anytrue([
      for e in kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].affinity[0].node_affinity[0].required_during_scheduling_ignored_during_execution[0].node_selector_term[0].match_expressions :
      e.key == "node.kubernetes.io/instance-type" && e.operator == "NotIn" && contains(tolist(e.values), "inf1.24xlarge") && contains(tolist(e.values), "inf1.xlarge")
    ])
    error_message = "neuron-monitor must exclude inf1 via a required NotIn node affinity."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].image == "public.ecr.aws/neuron/neuron-monitor:1.13.0"
    error_message = "Default neuron-monitor image must be public.ecr.aws/neuron/neuron-monitor:1.13.0."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].command == tolist(["/opt/bin/entrypoint.sh"])
    error_message = "neuron-monitor must run /opt/bin/entrypoint.sh (image Cmd is /bin/bash)."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].args == tolist(["--port", "8000", "--neuron-monitor-config", "/opt/aws/neuron/bin/neuron-monitor.conf"])
    error_message = "neuron-monitor args must match the AWS DaemonSet and omit --enable-k8s-info by default."
  }
  assert {
    condition     = !contains(kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].args, "--enable-k8s-info")
    error_message = "Pod attribution (--enable-k8s-info) must be off by default."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].automount_service_account_token == false
    error_message = "neuron-monitor must not mount a SA token unless pod attribution is on."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].service_account_name == "neuron-monitor"
    error_message = "neuron-monitor must run as its own ServiceAccount."
  }
  assert {
    condition     = [for v in kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].volume : v.host_path[0].path if length(v.host_path) > 0] == ["/opt/aws"]
    error_message = "Without pod attribution, neuron-monitor must mount exactly one hostPath: /opt/aws (LNC config)."
  }
  assert {
    condition = alltrue([
      for v in kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].volume :
      v.host_path[0].type == "Directory" if length(v.host_path) > 0
    ])
    error_message = "neuron-monitor hostPath volumes must be type Directory (never created on the host)."
  }
  assert {
    condition = [
      for m in kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].volume_mount :
      "${m.mount_path}:${m.read_only}" if m.name == "opt-aws"
    ] == ["/opt-aws:true"]
    error_message = "Host /opt/aws must be mounted read-only at /opt-aws (where neuron-monitor reads logical_nc_config)."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].security_context[0].read_only_root_filesystem == true
    error_message = "neuron-monitor root filesystem must be read-only."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].security_context[0].privileged == true
    error_message = "neuron-monitor runs privileged (documented: reads every /dev/neuron*); flip this assertion only together with the README / variable docs."
  }

  assert {
    condition     = kubernetes_service_v1.neuron_monitor[0].spec[0].type == "ClusterIP"
    error_message = "neuron-monitor Service must be ClusterIP only."
  }
  assert {
    condition     = kubernetes_service_v1.neuron_monitor[0].spec[0].port[0].port == 8000 && kubernetes_service_v1.neuron_monitor[0].spec[0].port[0].target_port == "metrics"
    error_message = "neuron-monitor Service must map 8000 -> metrics."
  }
  assert {
    condition     = kubernetes_service_v1.neuron_monitor[0].spec[0].port[0].name == "metrics"
    error_message = "neuron-monitor Service port must be named metrics (the ServiceMonitor endpoint selects it by name)."
  }
  assert {
    condition = (
      kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].resources[0].limits["memory"] == "500Mi" &&
      kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].resources[0].limits["cpu"] == "500m" &&
      kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].resources[0].requests["memory"] == "128Mi" &&
      kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].resources[0].requests["cpu"] == "256m"
    )
    error_message = "neuron-monitor resources must match the CloudWatch Observability chart's neuronMonitor for image 1.13.0 (limits 500m/500Mi, requests 256m/128Mi)."
  }
  assert {
    condition     = one([for e in kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].env : e.value if e.name == "GOMEMLIMIT"]) == "320MiB"
    error_message = "GOMEMLIMIT must be 320MiB (CloudWatch Observability chart, neuron-monitor 1.13.0)."
  }
  assert {
    condition     = kubernetes_service_v1.neuron_monitor[0].spec[0].selector == tomap({ name = kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].metadata[0].labels["name"] })
    error_message = "neuron-monitor Service selector must equal the pod's name label."
  }
  assert {
    condition     = try(length(kubernetes_service_v1.neuron_monitor[0].spec[0].external_ips), 0) == 0
    error_message = "neuron-monitor Service must not set externalIPs."
  }
  assert {
    condition = (
      kubernetes_service_v1.neuron_monitor[0].spec[0].load_balancer_class == null &&
      kubernetes_service_v1.neuron_monitor[0].spec[0].load_balancer_ip == null &&
      try(length(kubernetes_service_v1.neuron_monitor[0].spec[0].load_balancer_source_ranges), 0) == 0
    )
    error_message = "neuron-monitor Service must not carry any load_balancer_* settings."
  }
  assert {
    condition     = length(helm_release.neuron_monitor_service_monitor) == 0 && length(kubernetes_cluster_role_v1.neuron_monitor) == 0 && length(kubernetes_cluster_role_binding_v1.neuron_monitor) == 0
    error_message = "ServiceMonitor and pod-attribution RBAC must stay off unless separately enabled."
  }
  assert {
    condition     = kubernetes_service_account_v1.neuron_monitor[0].automount_service_account_token == false
    error_message = "neuron-monitor ServiceAccount must not auto-mount its token."
  }

  # Observer stays off and the chart values are byte-identical to defaults.
  assert {
    condition     = yamldecode(helm_release.neuron.values[0]).observer == { enabled = false }
    error_message = "Neuron Observer must stay off when neuron-monitor is enabled."
  }
  assert {
    condition = helm_release.neuron.values[0] == yamlencode({
      devicePlugin = { enabled = true }
      scheduler = {
        enabled      = false
        nodeSelector = { app = "eks-utils" }
        tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
        customScheduler = {
          enabled      = true
          nodeSelector = { app = "eks-utils" }
          tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
        }
      }
      npd                 = { enabled = false }
      draDriver           = { enabled = false }
      observer            = { enabled = false }
      ultraserverOperator = { enabled = false }
    })
    error_message = "install_monitor must not change the neuron-helm-chart values."
  }
}

run "monitor_service_monitor" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    install_monitor                = true
    monitor_service_monitor        = true
    monitor_service_monitor_labels = { release = "kube-prometheus-stack" }
  }

  assert {
    condition     = length(helm_release.neuron_monitor_service_monitor) == 1
    error_message = "monitor_service_monitor must create the ServiceMonitor release."
  }
  assert {
    condition = (
      helm_release.neuron_monitor_service_monitor[0].name == "neuron-monitor-servicemonitor" &&
      helm_release.neuron_monitor_service_monitor[0].repository == "https://bedag.github.io/helm-charts/" &&
      helm_release.neuron_monitor_service_monitor[0].chart == "raw" &&
      helm_release.neuron_monitor_service_monitor[0].version == "2.0.2" &&
      helm_release.neuron_monitor_service_monitor[0].namespace == "kube-system"
    )
    error_message = "ServiceMonitor must ship as kube-system/neuron-monitor-servicemonitor via bedag/raw 2.0.2 (same pin as eks-karpenter)."
  }
  assert {
    condition     = yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].kind == "ServiceMonitor" && yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].apiVersion == "monitoring.coreos.com/v1"
    error_message = "bedag/raw must render a monitoring.coreos.com/v1 ServiceMonitor."
  }
  assert {
    condition = (
      yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].port == "metrics" &&
      yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].honorLabels == false &&
      yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].interval == "15s" &&
      yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].scrapeTimeout == "10s" &&
      yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].scheme == "http"
    )
    error_message = "ServiceMonitor endpoint must scrape port metrics over http every 15s (10s timeout) with honorLabels false (dcgm-exporter parity)."
  }
  assert {
    condition     = yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].port == kubernetes_service_v1.neuron_monitor[0].spec[0].port[0].name
    error_message = "ServiceMonitor endpoint port must equal the Service port NAME (Prometheus Operator resolves endpoints[].port by name; a mismatch silently finds zero targets)."
  }
  assert {
    condition = alltrue([
      for k, v in yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.selector.matchLabels :
      lookup(kubernetes_service_v1.neuron_monitor[0].metadata[0].labels, k, null) == v
    ])
    error_message = "ServiceMonitor selector labels must be a subset of the neuron-monitor Service labels."
  }
  assert {
    condition     = yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.namespaceSelector.matchNames == ["kube-system"]
    error_message = "ServiceMonitor must select kube-system only."
  }
  assert {
    condition     = yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].metadata.labels["release"] == "kube-prometheus-stack" && yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].metadata.labels["app.kubernetes.io/name"] == "neuron-monitor"
    error_message = "monitor_service_monitor_labels must be merged onto the ServiceMonitor labels."
  }
  assert {
    condition = anytrue([
      for r in yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].metricRelabelings :
      try(r.targetLabel, "") == "exported_pod" && try(r.sourceLabels, []) == ["pod_name"]
    ])
    error_message = "ServiceMonitor must map pod_name -> exported_pod (dcgm-exporter label schema)."
  }
  assert {
    condition = anytrue([
      for r in yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].metricRelabelings :
      r.action == "labeldrop" && try(r.regex, "") == "pod_name|container_name"
    ])
    error_message = "ServiceMonitor must drop the raw pod_name / container_name labels."
  }
  assert {
    condition     = yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].relabelings[0].targetLabel == "node"
    error_message = "ServiceMonitor must label targets with node."
  }
  # Unattributed series carry the literal "None" (Python None via
  # prometheus_client str()); it must be blanked BEFORE the exported_*
  # mappings / labeldrop, or a phantom pod / namespace "None" appears.
  assert {
    condition = alltrue([
      for l in ["pod_name", "container_name", "exported_namespace"] :
      min(concat([999], [
        for i, r in yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].metricRelabelings :
        i if try(r.sourceLabels, []) == [l] && try(r.regex, "") == "None" && try(r.targetLabel, "") == l && try(r.replacement, "x") == "" && try(r.action, "") == "replace"
      ])...) < 999
    ])
    error_message = "ServiceMonitor must blank the literal \"None\" in pod_name, container_name and exported_namespace (unattributed neuron-monitor series)."
  }
  assert {
    condition = (
      min(concat([999], [
        for i, r in yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].metricRelabelings :
        i if try(r.regex, "") == "None" && try(r.sourceLabels, []) == ["pod_name"]
      ])...) <
      min(concat([998], [
        for i, r in yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].metricRelabelings :
        i if try(r.targetLabel, "") == "exported_pod"
      ])...)
    )
    error_message = "The pod_name \"None\" blanking rule must come before the pod_name -> exported_pod mapping."
  }
  assert {
    condition = (
      min(concat([999], [
        for i, r in yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].metricRelabelings :
        i if try(r.regex, "") == "None" && try(r.sourceLabels, []) == ["container_name"]
      ])...) <
      min(concat([998], [
        for i, r in yamldecode(helm_release.neuron_monitor_service_monitor[0].values[0]).resources[0].spec.endpoints[0].metricRelabelings :
        i if try(r.targetLabel, "") == "exported_container"
      ])...)
    )
    error_message = "The container_name \"None\" blanking rule must come before the container_name -> exported_container mapping."
  }

  # Docs: the air-gapped mirror paragraph must name the one artifact that
  # cannot be mirrored (this release's hardcoded chart repo) plus the
  # neuron-monitor / EFA image overrides, and helm_replace_existing must list
  # this release among those it applies to.
  assert {
    condition = alltrue([
      strcontains(replace(file("../../README.md"), "\n", " "), "installs a second chart, bedag/raw ${helm_release.neuron_monitor_service_monitor[0].version}, from the hardcoded `${helm_release.neuron_monitor_service_monitor[0].repository}`"),
      strcontains(replace(file("../../README.md"), "\n", " "), "with `install_neuron_monitor` also `neuron_monitor_image`"),
      strcontains(file("../../terraform.tfvars.example"), "pulls bedag/raw ${helm_release.neuron_monitor_service_monitor[0].version} from ${helm_release.neuron_monitor_service_monitor[0].repository}"),
      strcontains(file("../../variables.tf"), helm_release.neuron_monitor_service_monitor[0].name),
      strcontains(file("../../modules/eks-neuron-stack/variables.tf"), helm_release.neuron_monitor_service_monitor[0].name),
    ])
    error_message = "README/tfvars.example mirror notes must flag the hardcoded bedag/raw ServiceMonitor chart repo, and helm_replace_existing descriptions must list neuron-monitor-servicemonitor."
  }
}

run "monitor_service_monitor_requires_monitor" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    monitor_service_monitor = true
  }
  expect_failures = [var.monitor_service_monitor]
}

run "pod_attribution_requires_monitor" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    monitor_pod_attribution = true
  }
  expect_failures = [var.monitor_pod_attribution]
}

run "monitor_pod_attribution" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    install_monitor         = true
    monitor_pod_attribution = true
  }

  assert {
    condition     = length(kubernetes_cluster_role_v1.neuron_monitor) == 1 && length(kubernetes_cluster_role_binding_v1.neuron_monitor) == 1
    error_message = "Pod attribution must create the neuron-monitor ClusterRole + binding."
  }
  assert {
    condition = (
      length(kubernetes_cluster_role_v1.neuron_monitor[0].rule) == 1 &&
      kubernetes_cluster_role_v1.neuron_monitor[0].rule[0].api_groups == tolist([""]) &&
      kubernetes_cluster_role_v1.neuron_monitor[0].rule[0].resources == tolist(["nodes/pods"]) &&
      kubernetes_cluster_role_v1.neuron_monitor[0].rule[0].verbs == tolist(["get"])
    )
    error_message = "Pod attribution RBAC must be exactly get nodes/pods."
  }
  assert {
    condition     = !contains(flatten(kubernetes_cluster_role_v1.neuron_monitor[0].rule[*].resources), "nodes/proxy")
    error_message = "neuron-monitor must never be granted nodes/proxy."
  }
  assert {
    condition = (
      kubernetes_cluster_role_binding_v1.neuron_monitor[0].subject[0].kind == "ServiceAccount" &&
      kubernetes_cluster_role_binding_v1.neuron_monitor[0].subject[0].name == "neuron-monitor" &&
      kubernetes_cluster_role_binding_v1.neuron_monitor[0].subject[0].namespace == "kube-system"
    )
    error_message = "ClusterRoleBinding must bind kube-system/neuron-monitor."
  }
  assert {
    condition     = [for m in kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].volume_mount : m.read_only if m.name == "pod-resources"] == [true]
    error_message = "The kubelet pod-resources mount must be read-only."
  }
  assert {
    condition     = [for v in kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].volume : v.host_path[0].path if length(v.host_path) > 0] == ["/opt/aws", "/var/lib/kubelet/pod-resources"]
    error_message = "Pod attribution must add only the /var/lib/kubelet/pod-resources hostPath (besides /opt/aws)."
  }
  assert {
    condition     = [for e in kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].env : e.value_from[0].field_ref[0].field_path if e.name == "NODE_NAME"] == ["spec.nodeName"]
    error_message = "NODE_NAME must come from the downward API (spec.nodeName)."
  }
  assert {
    condition     = contains(kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].args, "--enable-k8s-info")
    error_message = "Pod attribution must pass --enable-k8s-info."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].automount_service_account_token == true
    error_message = "Pod attribution needs the SA token mounted (kubelet /pods)."
  }
  assert {
    condition     = !kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].host_network
    error_message = "Pod attribution must not switch to hostNetwork."
  }
}

run "monitor_image_override" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    install_monitor = true
    monitor_image   = "111122223333.dkr.ecr.cn-north-1.amazonaws.com.cn/neuron/neuron-monitor:1.13.0"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.neuron_monitor[0].spec[0].template[0].spec[0].container[0].image == "111122223333.dkr.ecr.cn-north-1.amazonaws.com.cn/neuron/neuron-monitor:1.13.0"
    error_message = "monitor_image must override the neuron-monitor image."
  }
}

run "monitor_empty_image_rejected" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  variables {
    install_monitor = true
    monitor_image   = " "
  }
  expect_failures = [var.monitor_image]
}

# Teardown coverage: terraform/scripts/safe-destroy.sh must pre-uninstall the
# Neuron release (in its kube-system `for release in ...` loop) and pre-delete
# the Neuron EFA DaemonSet before `terraform destroy`; otherwise they are the
# helm/kubernetes resources left in state when the cluster API goes away.
# Reads the script from disk (path relative to this fixture dir) and checks
# it against the names the module actually renders.
run "safe_destroy_covers_neuron" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }
  # Everything on, so every name below comes from a rendered resource.
  variables {
    install_monitor         = true
    monitor_service_monitor = true
    monitor_pod_attribution = true
  }

  assert {
    condition = anytrue([
      for l in split("\n", file("../../scripts/safe-destroy.sh")) :
      can(regex("^\\s*for release in ", l)) && contains(split(" ", trimspace(replace(replace(l, "/^\\s*for release in /", ""), "/;.*$/", ""))), helm_release.neuron.name)
    ])
    error_message = "terraform/scripts/safe-destroy.sh must list ${helm_release.neuron.name} in its kube-system `for release in ...` helm-uninstall loop."
  }
  assert {
    condition     = helm_release.neuron.namespace == "kube-system"
    error_message = "safe-destroy.sh uninstalls the Neuron release from kube-system (NS); update the script if the namespace changes."
  }
  assert {
    condition     = length(regexall("(?m)^\\s*kdelete \"[^\"]*\" daemonset ${kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name}( |$)", file("../../scripts/safe-destroy.sh"))) > 0
    error_message = "terraform/scripts/safe-destroy.sh must pre-delete the Neuron EFA DaemonSet (${kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name})."
  }
  assert {
    condition = anytrue([
      for l in split("\n", file("../../scripts/safe-destroy.sh")) :
      can(regex("^\\s*for release in ", l)) && contains(split(" ", trimspace(replace(replace(l, "/^\\s*for release in /", ""), "/;.*$/", ""))), helm_release.neuron_monitor_service_monitor[0].name)
    ])
    error_message = "terraform/scripts/safe-destroy.sh must list ${helm_release.neuron_monitor_service_monitor[0].name} in its kube-system `for release in ...` helm-uninstall loop."
  }
  assert {
    condition = alltrue([
      length(regexall("(?m)^\\s*kdelete \"[^\"]*\" daemonset ${kubernetes_daemon_set_v1.neuron_monitor[0].metadata[0].name}( |$)", file("../../scripts/safe-destroy.sh"))) > 0,
      length(regexall("(?m)^\\s*kdelete \"[^\"]*\" service ${kubernetes_service_v1.neuron_monitor[0].metadata[0].name}( |$)", file("../../scripts/safe-destroy.sh"))) > 0,
      length(regexall("(?m)^\\s*kdelete \"[^\"]*\" clusterrolebinding ${kubernetes_cluster_role_binding_v1.neuron_monitor[0].metadata[0].name}( |$)", file("../../scripts/safe-destroy.sh"))) > 0,
      length(regexall("(?m)^\\s*kdelete \"[^\"]*\" clusterrole ${kubernetes_cluster_role_v1.neuron_monitor[0].metadata[0].name}( |$)", file("../../scripts/safe-destroy.sh"))) > 0,
      length(regexall("(?m)^\\s*kdelete \"[^\"]*\" serviceaccount ${kubernetes_service_account_v1.neuron_monitor[0].metadata[0].name}( |$)", file("../../scripts/safe-destroy.sh"))) > 0,
    ])
    error_message = "terraform/scripts/safe-destroy.sh must pre-delete the neuron-monitor DaemonSet / Service / ClusterRoleBinding / ClusterRole / ServiceAccount."
  }
}

# Ops-script regressions (kept bash tools; checked as text, like
# safe_destroy_covers_neuron above).
run "ops_scripts_neuron_hygiene" {
  command = plan
  module {
    source = "../../modules/eks-neuron-stack"
  }

  # option_verify_gpu_efa.sh: the multi-node Neuron ssh private key must not
  # sit in a Pod spec (env / args are readable with `get pods`, e.g. the
  # built-in `view` role). It lives in a verify-run-labelled Secret mounted
  # 0400 into the launcher, and cleanup deletes Secrets with the pods.
  assert {
    condition = alltrue([
      # Tie to the plan: the script's EFA hint names this module's DaemonSet.
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "ds/${kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name}"),
      !strcontains(element(split("cleanup_neuron() {", file("../../../scripts/option_verify_gpu_efa.sh")), 1), "PRIV_B64"),
      !strcontains(element(split("cleanup_neuron() {", file("../../../scripts/option_verify_gpu_efa.sh")), 1), "priv_key_b64"),
    ])
    error_message = "Neuron verify path must not pass the ssh private key through the Pod spec (PRIV_B64 env)."
  }
  assert {
    condition = alltrue([
      # Tie to the plan: the script's EFA hint names this module's DaemonSet.
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "ds/${kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name}"),
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "kind: \"Secret\""),
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "secret: {secretName: $sec, defaultMode: 256}"),
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "{name: \"ssh-key\", mountPath: \"/etc/verify-ssh\", readOnly: true}"),
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "install -m 600 /etc/verify-ssh/id_ed25519 /root/.ssh/id_ed25519"),
    ])
    error_message = "Neuron verify launcher must read the ssh key from a 0400 read-only Secret mount."
  }
  assert {
    condition = alltrue([
      # Tie to the plan: the script's EFA hint names this module's DaemonSet.
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "ds/${kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name}"),
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "kubectl delete -n \"$${VERIFY_NAMESPACE}\" pod,svc,secret -l \"verify-run=$${NEURON_RUN_ID}\""),
    ])
    error_message = "cleanup_neuron must delete pod,svc,secret by the verify-run label (else the ssh-key Secret leaks)."
  }
  # The local keypair tmpdir must be registered with the EXIT trap before
  # ssh-keygen, and cleanup_neuron must remove it BEFORE its NEURON_RUN_ID /
  # VERIFY_KEEP_POD early returns — else an interrupt or early failure leaves
  # the passphrase-less private key on the bastion.
  assert {
    condition = alltrue([
      # Tie to the plan: the script's EFA hint names this module's DaemonSet.
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "ds/${kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name}"),
      # cleanup_neuron body, up to the first early return, removes the tmpdir.
      strcontains(
        element(split("[ -n \"$${NEURON_RUN_ID}\" ] || return 0", element(split("cleanup_neuron() {", file("../../../scripts/option_verify_gpu_efa.sh")), 1)), 0),
        "rm -rf \"$${NEURON_KEY_TMPDIR}\""
      ),
      # The keypair is generated into the registered tmpdir.
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "NEURON_KEY_TMPDIR=$(mktemp -d)\n    tmpdir=\"$${NEURON_KEY_TMPDIR}\"\n    ssh-keygen -t ed25519"),
    ])
    error_message = "Neuron multi-node ssh keypair tmpdir must be tracked in NEURON_KEY_TMPDIR before ssh-keygen and removed first thing in cleanup_neuron."
  }

  # option_verify_gpu_efa.sh: every nccom-test run must pass --check.
  # Without it the buffers are zero-filled and results are never compared,
  # so the "errors found" gate cannot catch corrupted all-reduce data.
  assert {
    condition = alltrue([
      # Tie to the plan: the script's EFA hint names this module's DaemonSet.
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "ds/${kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name}"),
      # Both invocations (single-node + multi-node launcher) carry --check
      # with the mode named explicitly. -c/--check is argparse nargs='?'
      # (choices random|all_ones), so a bare "--check allr" consumes the
      # operation as the mode and nccom-test exits 2 before any collective.
      length(regexall("nccom-test -r \"\\$\\{RANKS\\}\"[^\n]* --check random allr", file("../../../scripts/option_verify_gpu_efa.sh"))) == 2,
      # ... and no nccom-test invocation puts the operation right after --check.
      length(regexall("nccom-test [^\\n]*--check (allr|all_reduce|allg|all_gather|redsct|reduce_scatter|sendrecv|alltoall|permute)", file("../../../scripts/option_verify_gpu_efa.sh"))) == 0,
      # ... and no invocation runs allr without it.
      length(regexall("nccom-test -r [^\n]*-d fp32 allr", file("../../../scripts/option_verify_gpu_efa.sh"))) == 0,
      # The single-node check gates on "errors found", like the launcher.
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "grep -iE \"errors? found\" /tmp/nccom-single.log"),
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "grep -iE 'errors? found' /tmp/nccom-output.log"),
    ])
    error_message = "option_verify_gpu_efa.sh: both nccom-test runs must use --check (else results are never validated) and gate on 'errors found'."
  }

  # option_verify_gpu_efa.sh: cleanup_neuron must not swallow a failed
  # delete (the headless Service + ssh-key Secret are NOT bounded by
  # activeDeadlineSeconds) and must not be aborted by a second Ctrl-C.
  assert {
    condition = alltrue([
      # Tie to the plan: the script's EFA hint names this module's DaemonSet.
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "ds/${kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name}"),
      # INT/TERM ignored first thing in cleanup_neuron (leading comments skipped).
      startswith(trimspace(replace(element(split("cleanup_neuron() {", file("../../../scripts/option_verify_gpu_efa.sh")), 1), "/(?m)^[ ]*#[^\n]*\n/", "")), "trap '' INT TERM"),
      # The delete's status is checked and a WARN with the manual command printed.
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "if ! kubectl delete -n \"$${VERIFY_NAMESPACE}\" pod,svc,secret -l \"verify-run=$${NEURON_RUN_ID}\""),
      strcontains(file("../../../scripts/option_verify_gpu_efa.sh"), "echo \"  kubectl delete -n $${VERIFY_NAMESPACE} pod,svc,secret -l verify-run=$${NEURON_RUN_ID}\" >&2"),
      # ... and the old swallow-everything form is gone from cleanup_neuron.
      !strcontains(element(split("neuron_install_traps() {", element(split("cleanup_neuron() {", file("../../../scripts/option_verify_gpu_efa.sh")), 1)), 0), "|| true"),
    ])
    error_message = "cleanup_neuron must ignore INT/TERM, check the kubectl delete status and print a WARN with the manual delete command on failure."
  }

  # option_inspect_eks.sh: Trn vCPU quotas only apply to trn* nodes; an
  # Inferentia-only cluster must not get Trn quota WARNs.
  assert {
    condition = alltrue([
      # Tie to the plan: the script's EFA hint names this module's DaemonSet.
      strcontains(file("../../../scripts/option_inspect_eks.sh"), "ds/${kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name}"),
      strcontains(file("../../../scripts/option_inspect_eks.sh"), "  if [ \"$HAS_TRN\" -eq 1 ]; then\n    for q in \"On-Demand:L-2C3B7624\" \"Spot:L-6B0D517C\"; do"),
      strcontains(file("../../../scripts/option_inspect_eks.sh"), "case \"$N_IT\" in trn*) HAS_TRN=1 ;; esac"),
    ])
    error_message = "option_inspect_eks.sh must set HAS_TRN from the Neuron nodes' instance types and gate the Trn quota checks on it."
  }
}
