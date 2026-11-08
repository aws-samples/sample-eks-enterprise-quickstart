# =====================================================================
# eks-neuron-stack — K8s-side AWS Neuron (Trainium / Inferentia) components
# =====================================================================
# Independent of eks-gpu-stack / gpu_stack_mode (NOT a third mode): NVIDIA
# and Neuron nodes carry disjoint labels + taints, so both stacks can be
# installed side by side.
#   - neuron-helm-chart (oci://public.ecr.aws/neuron): Neuron device plugin
#     (aws.amazon.com/neuron + aws.amazon.com/neuroncore), optional Neuron
#     scheduler extension + "my-scheduler"
#   - aws-efa-k8s-device-plugin-neuron (kubernetes_daemon_set): a SECOND EFA
#     device-plugin DaemonSet confined to workload-type=neuron nodes, so the
#     eks-gpu-stack one stays byte-identical on NVIDIA-only clusters
#   - neuron-monitor (opt-in, install_monitor): Prometheus exporter
#     DaemonSet + ClusterIP Service (+ optional ServiceMonitor); the chart's
#     Neuron Observer is intentionally not offered
# =====================================================================

variable "region" {
  type        = string
  description = "AWS region (used to derive the EFA device-plugin EKS add-on ECR image)."
}

variable "helm_replace_existing" {
  type        = bool
  default     = false
  description = "Pass helm replace=true (helm install --replace): applies to both releases in this module (neuron-helm-chart and, when enabled, neuron-monitor-servicemonitor); lets terraform reuse the release name neuron-helm-chart ONLY when its latest revision is failed or uninstalled (e.g. after an interrupted apply). It does NOT adopt a deployed release — a manual `helm install neuron-helm-chart ...` still fails with \"cannot re-use a name that is still in use\". The docs install omits --namespace, so the release usually lives in the context namespace (normally default), not kube-system: find it with `helm list -A | grep neuron-helm-chart` and `helm uninstall neuron-helm-chart -n <that-namespace>` before the first apply. `terraform import 'module.eks_neuron_stack[0].helm_release.neuron' kube-system/neuron-helm-chart` only fits a release installed with -n kube-system (importing default/neuron-helm-chart forces a replace on the next apply)."
}

# -------------------- Neuron Helm chart --------------------
variable "chart_repository" {
  type        = string
  default     = "oci://public.ecr.aws/neuron"
  description = "Helm repository for neuron-helm-chart. Override with a private OCI mirror for cn-* / isolated / air-gapped regions (mirror the images too: device_plugin_image_repository, and when install_scheduler = true also scheduler_image_repository + kube_scheduler_image_repository). A 403 \"authorization token has expired\" from public.ecr.aws is a stale cached login — run `helm registry logout public.ecr.aws` (anonymous pulls work)."
}

variable "chart_version" {
  type        = string
  default     = "1.11.2"
  description = "neuron-helm-chart version (X.Y.Z). Each version pins the Neuron device-plugin / scheduler images and the list of Neuron instance types the device plugin's node affinity covers — new instance types need a chart bump."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.chart_version))
    error_message = "chart_version must be an X.Y.Z chart version such as \"1.11.2\"."
  }
}

variable "device_plugin_image_repository" {
  type        = string
  default     = ""
  description = "Override the Neuron device-plugin image repository (default \"\" = chart default public.ecr.aws/neuron/neuron-device-plugin). For private mirrors."
}

variable "device_plugin_image_tag" {
  type        = string
  default     = ""
  description = "Override the Neuron device-plugin image tag (default \"\" = chart default)."
}

variable "install_scheduler" {
  type        = bool
  default     = false
  description = "Install the Neuron scheduler extension + a second kube-scheduler named \"my-scheduler\" (EKS cannot reconfigure the default scheduler). Pods must set schedulerName: my-scheduler to use it. Only needed for partial-node multi-device requests that must land on contiguous / connected Neuron devices; whole-node jobs (all devices) don't need it. Exposure: adds ClusterIP Service kube-system/k8s-neuron-scheduler on TCP 12345 (pod network only; no hostNetwork / NodePort) serving plain HTTP with NO authentication; my-scheduler calls it for filter AND bind, and the extender binds pods with its own cluster-wide pods/binding + patch pods / nodes/status RBAC, so any client that can reach its pod IP can bind pending pods and rewrite the Neuron device annotations. Restrict ingress to the my-scheduler pods with a NetworkPolicy where the CNI enforces it (example in terraform/README.md)."
}

variable "kube_scheduler_image_tag" {
  type        = string
  default     = ""
  description = "eks-distro kube-scheduler image tag used by \"my-scheduler\" (e.g. \"v1.35.9-eks-1-35-16\"). REQUIRED when install_scheduler = true: the chart default (v1.31.x in chart 1.11.2) is outside the kube-scheduler/kube-apiserver version skew (scheduler at most one minor older) of current EKS clusters. Ignored when install_scheduler = false."

  validation {
    condition     = var.kube_scheduler_image_tag == "" || can(regex("^v[0-9]", var.kube_scheduler_image_tag))
    error_message = "kube_scheduler_image_tag must be empty or an image tag starting with \"v<digit>\" (e.g. \"v1.35.9-eks-1-35-16\")."
  }

  # Cross-variable validation (Terraform/OpenTofu >= 1.9, see versions.tf).
  # The tag can't be derived from the cluster version: eks-distro tags carry a
  # build suffix (-eks-1-35-16), so the operator must pick it.
  validation {
    condition     = !var.install_scheduler || var.kube_scheduler_image_tag != ""
    error_message = "kube_scheduler_image_tag is required when install_scheduler = true: the chart default (v1.31.x in neuron-helm-chart 1.11.2) is outside the kube-scheduler/kube-apiserver version skew. Pick the eks-distro tag matching the cluster minor from gallery.ecr.aws/eks-distro/kubernetes/kube-scheduler (e.g. \"v1.35.9-eks-1-35-16\")."
  }
}

# Scheduler image mirrors (only used when install_scheduler = true). The
# chart has no global registry override, so each image is overridden on its
# own; "" keeps the chart default (rendered helm values unchanged).
variable "scheduler_image_repository" {
  type        = string
  default     = ""
  description = "Override the Neuron scheduler-extension image repository (\"\" = chart default public.ecr.aws/neuron/neuron-scheduler). For private mirrors."
}

variable "scheduler_image_tag" {
  type        = string
  default     = ""
  description = "Override the Neuron scheduler-extension image tag (\"\" = chart default, pinned per chart version)."
}

variable "kube_scheduler_image_repository" {
  type        = string
  default     = ""
  description = "Override the \"my-scheduler\" kube-scheduler image repository (\"\" = chart default public.ecr.aws/eks-distro/kubernetes/kube-scheduler). For private mirrors."
}

# -------------------- system node placement (scheduler pods) --------------------
variable "system_node_label_key" {
  type        = string
  description = "Label key selecting the system nodegroup (scheduler extension + my-scheduler run there)."
}

variable "system_node_label_value" {
  type        = string
  description = "Label value selecting the system nodegroup."
}

# -------------------- EFA device plugin (Neuron nodes) --------------------
variable "install_efa_device_plugin" {
  type        = bool
  default     = true
  description = "Install the aws-efa-k8s-device-plugin-neuron DaemonSet on workload-type=neuron nodes (advertises vpc.amazonaws.com/efa)."
}

variable "efa_device_plugin_version" {
  type    = string
  default = "v0.5.19"
}

variable "efa_device_plugin_image" {
  type        = string
  default     = ""
  description = "Override the full EFA device-plugin image (e.g. private mirror in CN regions)."
}

# -------------------- Neuron metrics (neuron-monitor) --------------------
# Opt-in parity with eks-gpu-stack's dcgm-exporter: an exporter on every
# Neuron node, no metrics backend, ServiceMonitor off by default. The Neuron
# Observer (chart observer.*: hostNetwork + unauthenticated HTTP API incl.
# fault injection on :7001) is intentionally NOT offered — see README.
variable "install_monitor" {
  type        = bool
  default     = false
  description = "Install the neuron-monitor DaemonSet (neuron-monitor | neuron-monitor-prometheus.py) on workload-type=neuron nodes (inf1 excluded) plus a ClusterIP Service kube-system/neuron-monitor. Exposure: pod-IP TCP 8000, plain HTTP, read-only /metrics, NO authentication; no hostNetwork / hostPort / NodePort / LoadBalancer. The container runs privileged (it must read every /dev/neuron* and the driver sysfs counters regardless of device-plugin allocation) and mounts host /opt/aws read-only at /opt-aws (the host LNC config, neuron/logical_nc_config). No EFA metrics; not supported with the Neuron DRA driver."
}

variable "monitor_image" {
  type        = string
  default     = "public.ecr.aws/neuron/neuron-monitor:1.13.0"
  description = "neuron-monitor image (full reference). amd64-only; mirror it for cn-* / isolated / air-gapped regions."

  validation {
    condition     = length(trimspace(var.monitor_image)) > 0
    error_message = "monitor_image must be a non-empty image reference (e.g. \"public.ecr.aws/neuron/neuron-monitor:1.13.0\")."
  }
}

variable "monitor_service_monitor" {
  type        = bool
  default     = false
  description = "Also create a Prometheus Operator ServiceMonitor kube-system/neuron-monitor (bedag/raw Helm release neuron-monitor-servicemonitor). Requires the monitoring.coreos.com/v1 CRDs already installed — otherwise apply fails with \"no matches for kind ServiceMonitor\". Requires install_monitor = true."

  validation {
    condition     = !var.monitor_service_monitor || var.install_monitor
    error_message = "monitor_service_monitor = true requires install_monitor = true."
  }
}

variable "monitor_service_monitor_labels" {
  type        = map(string)
  default     = {}
  description = "Extra labels on the ServiceMonitor (e.g. { release = \"kube-prometheus-stack\" }) so the Prometheus serviceMonitorSelector picks it up."
}

variable "monitor_pod_attribution" {
  type        = bool
  default     = false
  description = "BETA: pass --enable-k8s-info so metrics carry pod/namespace/container labels. Grants the neuron-monitor ServiceAccount `get` on nodes/pods only (never nodes/proxy), mounts its token, and mounts /var/lib/kubelet/pod-resources read-only. Attribution comes from the AWS_NEURON_IDS pod annotation, which only the Neuron scheduler extension (install_scheduler, pods with schedulerName: my-scheduler) writes; without it every device and core on the node is attributed to the first Neuron-holding pod (container_name may mix pods), so it is correct only when one pod owns all of the node's Neuron devices. nodes/pods needs kubelet fine-grained authz (KubeletFineGrainedAuthz), otherwise the kubelet returns 403. Unattributed series (no pod on the node holds a Neuron resource, a 403 / lookup error, before the first lookup, or — with the annotation — devices not listed in it) carry the literal value \"None\" in pod_name / namespace / container_name on the raw /metrics; the ServiceMonitor (monitor_service_monitor) blanks those, so they end up without exported_pod / exported_namespace / exported_container. Requires install_monitor = true."

  validation {
    condition     = !var.monitor_pod_attribution || var.install_monitor
    error_message = "monitor_pod_attribution = true requires install_monitor = true."
  }
}
