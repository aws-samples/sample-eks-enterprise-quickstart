#!/bin/bash
#
# =====================================================================
# Install K8s GPU stack on existing GPU nodegroups
# =====================================================================
# Splits cleanly into two mutually-exclusive modes:
#
#   GPU_STACK_MODE=standard  (default)
#     - nvidia-device-plugin (helm; advertises nvidia.com/gpu)
#     - GPU Feature Discovery (sidecar in device-plugin chart)
#     - aws-efa-k8s-device-plugin (advertises vpc.amazonaws.com/efa)
#     - dcgm-exporter (helm; pod-level GPU metrics for Prometheus)
#     - node-problem-detector (helm; node-level GPU XID/kernel events)
#     - gpu-health-check DaemonSet (taints node if nvidia-smi fails at boot)
#
#   GPU_STACK_MODE=operator
#     - NVIDIA GPU Operator (helm; bundles device-plugin/GFD/NFD/dcgm/
#                            validator). driver/toolkit/mofed are DISABLED
#                            because EKS GPU AMI ships them and AWS EFA
#                            owns /dev/infiniband/uverbs*.
#     - aws-efa-k8s-device-plugin (still installed by us, NOT Operator)
#
# The two modes are mutually exclusive: nvidia.com/gpu, GFD labels, dcgm
# port 9400 etc. would collide. This script fails-fast if it detects
# leftover state from the other mode (helm releases, namespaces).
#
# Sources of conflict (verified):
#   - nvidia-device-plugin helm release (standard) vs Operator's
#     nvidia-device-plugin-daemonset → both register nvidia.com/gpu
#   - dcgm-exporter helm release vs Operator's nvidia-dcgm-exporter
#     → both bind port 9400
#   - GFD: standard runs it via gfd.enabled=true on device-plugin chart;
#     Operator runs it as a separate DS. Labels collide.
#
# Required upstream context (not re-derivable from code):
#   - EKS GPU AMI ships driver + nvidia-container-toolkit, so Operator
#     must run with driver.enabled=false and toolkit.enabled=false.
#   - AWS EFA device-plugin requires /dev/infiniband/uverbs*; therefore
#     mofedDriver.enabled=false in Operator AND mofedEnabled=false in
#     standard's device-plugin chart values.
#   - workload-type=gpu nodeSelector + nvidia.com/gpu:NoSchedule
#     toleration must apply to every DS we install.
# =====================================================================

set -e
set -o pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment (cluster name, region, etc.)
source "${SCRIPT_DIR}/../0_setup_env.sh"

export KUBECONFIG="${HOME:-/root}/.kube/config"

echo "=== Install K8s GPU Stack ==="
echo ""

# -----------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------
MISSING_DEPS=()
command -v kubectl >/dev/null 2>&1 || MISSING_DEPS+=("kubectl")
command -v helm    >/dev/null 2>&1 || MISSING_DEPS+=("helm")
if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "ERROR: missing required dependencies: ${MISSING_DEPS[*]}"
    exit 1
fi

# -----------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------
# Mode selection (mutually exclusive)
GPU_STACK_MODE="${GPU_STACK_MODE:-standard}"

case "${GPU_STACK_MODE}" in
    standard|operator) ;;
    *)
        echo "ERROR: invalid GPU_STACK_MODE='${GPU_STACK_MODE}'"
        echo "       Valid: standard | operator"
        exit 1
        ;;
esac

# --- Components shared by both modes ---
INSTALL_EFA_DEVICE_PLUGIN="${INSTALL_EFA_DEVICE_PLUGIN:-true}"
EFA_DEVICE_PLUGIN_VERSION="${EFA_DEVICE_PLUGIN_VERSION:-v0.5.19}"
EFA_DEVICE_PLUGIN_IMAGE="${EFA_DEVICE_PLUGIN_IMAGE:-}"

# --- Standard mode components ---
NVIDIA_DEVICE_PLUGIN_VERSION="${NVIDIA_DEVICE_PLUGIN_VERSION:-v0.19.1}"
NVIDIA_DEVICE_PLUGIN_REPO="${NVIDIA_DEVICE_PLUGIN_REPO:-nvcr.io/nvidia/k8s-device-plugin}"
NVIDIA_DEVICE_PLUGIN_NAMESPACE="${NVIDIA_DEVICE_PLUGIN_NAMESPACE:-kube-system}"
NVIDIA_DEVICE_PLUGIN_RELEASE_NAME="${NVIDIA_DEVICE_PLUGIN_RELEASE_NAME:-nvidia-device-plugin}"

INSTALL_DCGM_EXPORTER="${INSTALL_DCGM_EXPORTER:-true}"
DCGM_EXPORTER_VERSION="${DCGM_EXPORTER_VERSION:-4.8.2}"
DCGM_EXPORTER_NAMESPACE="${DCGM_EXPORTER_NAMESPACE:-kube-system}"
DCGM_EXPORTER_RELEASE_NAME="${DCGM_EXPORTER_RELEASE_NAME:-dcgm-exporter}"

INSTALL_NODE_PROBLEM_DETECTOR="${INSTALL_NODE_PROBLEM_DETECTOR:-true}"
NPD_VERSION="${NPD_VERSION:-2.3.14}"
NPD_NAMESPACE="${NPD_NAMESPACE:-kube-system}"
NPD_RELEASE_NAME="${NPD_RELEASE_NAME:-node-problem-detector}"

INSTALL_GPU_HEALTH_CHECK="${INSTALL_GPU_HEALTH_CHECK:-true}"

# --- Operator mode components ---
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v25.3.4}"
GPU_OPERATOR_NAMESPACE="${GPU_OPERATOR_NAMESPACE:-gpu-operator}"
GPU_OPERATOR_RELEASE_NAME="${GPU_OPERATOR_RELEASE_NAME:-gpu-operator}"
# AMI already ships these — Operator's containerized versions would conflict
GPU_OPERATOR_DRIVER_ENABLED="${GPU_OPERATOR_DRIVER_ENABLED:-false}"
GPU_OPERATOR_TOOLKIT_ENABLED="${GPU_OPERATOR_TOOLKIT_ENABLED:-false}"
# AWS EFA plugin owns /dev/infiniband/uverbs*; Operator must not touch it
GPU_OPERATOR_MOFED_ENABLED="${GPU_OPERATOR_MOFED_ENABLED:-false}"
# MIG strategy (none|single|mixed). Default off — only A100/H100 users need it.
GPU_OPERATOR_MIG_STRATEGY="${GPU_OPERATOR_MIG_STRATEGY:-none}"

# Force-switch: bypass conflict fail-fast and uninstall conflicting releases
GPU_STACK_FORCE_SWITCH="${GPU_STACK_FORCE_SWITCH:-false}"

# -----------------------------------------------------------------
# Cluster preflight: kubectl context + at least one GPU node
# -----------------------------------------------------------------
echo "Verifying kubectl context targets cluster '${CLUSTER_NAME}'..."
if ! kubectl config current-context >/dev/null 2>&1; then
    echo "ERROR: kubectl has no current context — run 'aws eks update-kubeconfig' first"
    exit 1
fi

# Soft check: warn if no GPU nodes exist yet. The install can still proceed
# (DaemonSets become Ready when the first node joins) but the user should
# know — most likely they ran this script before the nodegroup was ACTIVE.
gpu_node_count=$(kubectl get nodes -l workload-type=gpu \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${gpu_node_count}" -eq 0 ]; then
    echo "WARN: no nodes with label workload-type=gpu found"
    echo "      Stack components will install but DaemonSets remain pending"
    echo "      until a GPU node joins the cluster."
fi

# -----------------------------------------------------------------
# Mutual-exclusion guard
# -----------------------------------------------------------------
# Detect state from the OTHER mode and fail-fast (or auto-clean if
# GPU_STACK_FORCE_SWITCH=true). Conflict points:
#   standard mode artifacts: helm releases nvidia-device-plugin, dcgm-exporter,
#     node-problem-detector
#   operator mode artifacts: helm release gpu-operator, namespace gpu-operator
detect_helm_release() {
    local rel=$1
    local ns=$2
    helm status "${rel}" -n "${ns}" >/dev/null 2>&1
}

detect_namespace() {
    kubectl get namespace "$1" >/dev/null 2>&1
}

uninstall_helm_release_if_present() {
    local rel=$1
    local ns=$2
    if detect_helm_release "${rel}" "${ns}"; then
        echo "  Uninstalling helm release ${rel} (ns=${ns})..."
        helm uninstall "${rel}" -n "${ns}" --wait || true
    fi
}

guard_mutual_exclusion() {
    local conflicts=()

    if [ "${GPU_STACK_MODE}" = "standard" ]; then
        if detect_helm_release "${GPU_OPERATOR_RELEASE_NAME}" "${GPU_OPERATOR_NAMESPACE}"; then
            conflicts+=("helm release '${GPU_OPERATOR_RELEASE_NAME}' in ns/${GPU_OPERATOR_NAMESPACE}")
        fi
        if detect_namespace "${GPU_OPERATOR_NAMESPACE}"; then
            # Only flag if it isn't ours (i.e., we'd be reinstalling); presence
            # of release covers the live case. If the namespace exists but no
            # release does, it's a leftover and worth flagging.
            if ! detect_helm_release "${GPU_OPERATOR_RELEASE_NAME}" "${GPU_OPERATOR_NAMESPACE}"; then
                conflicts+=("leftover namespace '${GPU_OPERATOR_NAMESPACE}' (operator mode artifact)")
            fi
        fi
    elif [ "${GPU_STACK_MODE}" = "operator" ]; then
        if detect_helm_release "${NVIDIA_DEVICE_PLUGIN_RELEASE_NAME}" "${NVIDIA_DEVICE_PLUGIN_NAMESPACE}"; then
            conflicts+=("helm release '${NVIDIA_DEVICE_PLUGIN_RELEASE_NAME}' in ns/${NVIDIA_DEVICE_PLUGIN_NAMESPACE}")
        fi
        if detect_helm_release "${DCGM_EXPORTER_RELEASE_NAME}" "${DCGM_EXPORTER_NAMESPACE}"; then
            conflicts+=("helm release '${DCGM_EXPORTER_RELEASE_NAME}' in ns/${DCGM_EXPORTER_NAMESPACE}")
        fi
        if detect_helm_release "${NPD_RELEASE_NAME}" "${NPD_NAMESPACE}"; then
            conflicts+=("helm release '${NPD_RELEASE_NAME}' in ns/${NPD_NAMESPACE}")
        fi
        # gpu-health-check is kubectl-managed, not helm — detect via DS.
        # Symmetry with the force-switch cleanup path: every artifact that
        # gets cleaned must also be reported in fail-fast mode.
        if kubectl get daemonset gpu-health-check -n kube-system >/dev/null 2>&1; then
            conflicts+=("DaemonSet 'gpu-health-check' in ns/kube-system (standard mode artifact)")
        fi
    fi

    if [ ${#conflicts[@]} -eq 0 ]; then
        return 0
    fi

    echo ""
    echo "Detected artifacts from a different GPU_STACK_MODE:"
    for c in "${conflicts[@]}"; do
        echo "  - ${c}"
    done

    if [ "${GPU_STACK_FORCE_SWITCH}" = "true" ]; then
        echo ""
        echo "GPU_STACK_FORCE_SWITCH=true — uninstalling conflicting releases..."
        if [ "${GPU_STACK_MODE}" = "standard" ]; then
            uninstall_helm_release_if_present "${GPU_OPERATOR_RELEASE_NAME}" "${GPU_OPERATOR_NAMESPACE}"
            if detect_namespace "${GPU_OPERATOR_NAMESPACE}"; then
                kubectl delete namespace "${GPU_OPERATOR_NAMESPACE}" --wait=true --timeout=120s || true
            fi
        else
            uninstall_helm_release_if_present "${NVIDIA_DEVICE_PLUGIN_RELEASE_NAME}" "${NVIDIA_DEVICE_PLUGIN_NAMESPACE}"
            uninstall_helm_release_if_present "${DCGM_EXPORTER_RELEASE_NAME}" "${DCGM_EXPORTER_NAMESPACE}"
            uninstall_helm_release_if_present "${NPD_RELEASE_NAME}" "${NPD_NAMESPACE}"
            kubectl delete daemonset gpu-health-check -n kube-system --ignore-not-found
        fi
        echo ""
    else
        echo ""
        echo "ERROR: refusing to install ${GPU_STACK_MODE} mode while the other mode is present"
        echo ""
        echo "Resolve by EITHER:"
        echo "  • Setting GPU_STACK_FORCE_SWITCH=true to auto-uninstall and continue"
        echo "  • Manually:"
        if [ "${GPU_STACK_MODE}" = "standard" ]; then
            echo "      helm uninstall ${GPU_OPERATOR_RELEASE_NAME} -n ${GPU_OPERATOR_NAMESPACE}"
            echo "      kubectl delete namespace ${GPU_OPERATOR_NAMESPACE}"
        else
            echo "      helm uninstall ${NVIDIA_DEVICE_PLUGIN_RELEASE_NAME} -n ${NVIDIA_DEVICE_PLUGIN_NAMESPACE}"
            echo "      helm uninstall ${DCGM_EXPORTER_RELEASE_NAME} -n ${DCGM_EXPORTER_NAMESPACE}"
            echo "      helm uninstall ${NPD_RELEASE_NAME} -n ${NPD_NAMESPACE}"
            echo "      kubectl delete daemonset gpu-health-check -n kube-system"
        fi
        echo ""
        echo "  • Or keep the existing mode and re-run with the matching"
        echo "    GPU_STACK_MODE value."
        exit 1
    fi
}

# =====================================================================
# AWS EFA Kubernetes Device Plugin (shared by both modes)
# =====================================================================
# Identical to the manifest that used to live in
# option_install_gpu_nodegroups.sh — preserved verbatim so existing
# installs are seen as no-op when this script runs idempotently.
install_efa_device_plugin() {
    if [ "${INSTALL_EFA_DEVICE_PLUGIN}" != "true" ]; then
        echo "EFA Device Plugin installation skipped (INSTALL_EFA_DEVICE_PLUGIN=${INSTALL_EFA_DEVICE_PLUGIN})"
        return 0
    fi

    echo "Installing AWS EFA Kubernetes Device Plugin via kubectl..."

    # Always render and `kubectl apply`. The previous early-return on
    # "DaemonSet exists" guarded against duplicate installs but also
    # made image-tag bumps a silent no-op (kubectl get only checks
    # presence, not image version). apply is idempotent server-side
    # and rolls the DS forward when the manifest changes.

    local efa_image
    if [ -n "${EFA_DEVICE_PLUGIN_IMAGE}" ]; then
        efa_image="${EFA_DEVICE_PLUGIN_IMAGE}"
    else
        case "${AWS_REGION}" in
            cn-*) efa_image="961992271922.dkr.ecr.${AWS_REGION}.amazonaws.com.cn/eks/aws-efa-k8s-device-plugin:${EFA_DEVICE_PLUGIN_VERSION}" ;;
            *)    efa_image="602401143452.dkr.ecr.${AWS_REGION}.amazonaws.com/eks/aws-efa-k8s-device-plugin:${EFA_DEVICE_PLUGIN_VERSION}" ;;
        esac
    fi
    echo "  Image: ${efa_image}"

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: aws-efa-k8s-device-plugin-daemonset
  namespace: kube-system
  labels:
    app.kubernetes.io/name: aws-efa-k8s-device-plugin
spec:
  selector:
    matchLabels:
      name: aws-efa-k8s-device-plugin
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: aws-efa-k8s-device-plugin
    spec:
      hostNetwork: true
      nodeSelector:
        workload-type: gpu
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      - key: CriticalAddonsOnly
        operator: Exists
      priorityClassName: system-node-critical
      containers:
      - name: aws-efa-k8s-device-plugin
        image: ${efa_image}
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
        resources:
          requests:
            cpu: 10m
            memory: 20Mi
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
        - name: infiniband-volume
          mountPath: /dev/infiniband/
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/device-plugins
      - name: infiniband-volume
        hostPath:
          path: /dev/infiniband/
EOF

    echo "  Waiting for EFA Device Plugin to be ready..."
    for i in {1..30}; do
        local ready desired
        ready=$(kubectl get daemonset aws-efa-k8s-device-plugin-daemonset -n kube-system \
            -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
        desired=$(kubectl get daemonset aws-efa-k8s-device-plugin-daemonset -n kube-system \
            -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
        echo "    EFA Device Plugin: ${ready}/${desired} ready"

        if [ "${desired}" = "0" ]; then
            echo "  EFA Device Plugin installed (waiting for GPU nodes)"
            return 0
        fi
        if [ "${ready}" = "${desired}" ] && [ "${ready}" != "0" ]; then
            echo "  EFA Device Plugin is ready"
            return 0
        fi
        sleep 10
    done
    echo "  WARNING: EFA Device Plugin may not be fully ready"
}

# =====================================================================
# Standard mode: NVIDIA Device Plugin (helm)
# =====================================================================
# Same chart values as the previous in-tree install. Notes:
#   - mofedEnabled=false: chart 0.19+ default true; would conflict with
#     AWS EFA plugin over /dev/infiniband/uverbs*.
#   - gfd.enabled=true: gives nvidia.com/gpu.product, .memory, .cuda.* labels
#     used by Karpenter NodePool requirements and by user nodeSelectors.
#   - failOnInitError default true: relied upon for startup ordering
#     (driver/device readiness). Documented at length in the original
#     script — see git blame for the rationale.
install_nvidia_device_plugin() {
    echo "Installing NVIDIA Device Plugin via Helm..."

    local plugin_ver="${NVIDIA_DEVICE_PLUGIN_VERSION#v}"

    helm repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true
    helm repo update nvdp >/dev/null

    echo "  Chart:      nvdp/nvidia-device-plugin --version ${plugin_ver}"
    echo "  Repository: ${NVIDIA_DEVICE_PLUGIN_REPO}"
    echo "  Tag:        v${plugin_ver}"
    echo "  Namespace:  ${NVIDIA_DEVICE_PLUGIN_NAMESPACE}"
    echo "  Release:    ${NVIDIA_DEVICE_PLUGIN_RELEASE_NAME}"

    # Explicit toleration matches the Terraform module so chart default
    # changes don't silently diverge between bash and terraform paths.
    helm upgrade --install "${NVIDIA_DEVICE_PLUGIN_RELEASE_NAME}" \
        nvdp/nvidia-device-plugin \
        --namespace "${NVIDIA_DEVICE_PLUGIN_NAMESPACE}" \
        --create-namespace \
        --version "${plugin_ver}" \
        --set image.repository="${NVIDIA_DEVICE_PLUGIN_REPO}" \
        --set image.tag="v${plugin_ver}" \
        --set mofedEnabled=false \
        --set gfd.enabled=true \
        --set nodeSelector."workload-type"=gpu \
        --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]' \
        --wait --timeout 5m || {
            echo "  WARNING: helm upgrade for NVIDIA Device Plugin failed or timed out"
            echo "    (normal if no GPU nodes exist yet; chart will reconcile when one joins)"
            return 0
        }
    echo "  NVIDIA Device Plugin Helm release deployed"
}

# =====================================================================
# Standard mode: dcgm-exporter (helm)
# =====================================================================
# Pod-level GPU metrics → Prometheus. Default labels NVIDIA-managed; we add
# a workload-type=gpu nodeSelector and the standard nvidia.com/gpu toleration.
# Skipped automatically if INSTALL_DCGM_EXPORTER=false.
install_dcgm_exporter() {
    if [ "${INSTALL_DCGM_EXPORTER}" != "true" ]; then
        echo "DCGM exporter installation skipped (INSTALL_DCGM_EXPORTER=false)"
        return 0
    fi

    echo "Installing DCGM Exporter via Helm..."

    # dcgm-exporter chart lives in its own GitHub Pages repo, NOT in
    # nvidia's NGC helm repo (which only hosts gpu-operator and friends).
    # Repo: https://nvidia.github.io/dcgm-exporter/helm-charts
    helm repo add nvidia-dcgm https://nvidia.github.io/dcgm-exporter/helm-charts >/dev/null 2>&1 || true
    helm repo update nvidia-dcgm >/dev/null

    echo "  Chart:     nvidia-dcgm/dcgm-exporter --version ${DCGM_EXPORTER_VERSION#v}"
    echo "  Namespace: ${DCGM_EXPORTER_NAMESPACE}"
    echo "  Release:   ${DCGM_EXPORTER_RELEASE_NAME}"

    helm upgrade --install "${DCGM_EXPORTER_RELEASE_NAME}" \
        nvidia-dcgm/dcgm-exporter \
        --namespace "${DCGM_EXPORTER_NAMESPACE}" \
        --create-namespace \
        --version "${DCGM_EXPORTER_VERSION#v}" \
        --set nodeSelector."workload-type"=gpu \
        --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]' \
        --set serviceMonitor.enabled=false \
        --wait --timeout 5m || {
            echo "  WARNING: helm upgrade for DCGM Exporter failed or timed out"
            echo "    (normal if no GPU nodes exist yet)"
            return 0
        }
    echo "  DCGM Exporter Helm release deployed"
}

# =====================================================================
# Standard mode: node-problem-detector (helm)
# =====================================================================
# Picks up XID errors / kernel hangs / driver failures and surfaces them
# as NodeConditions, so kube-scheduler / Karpenter can avoid bad nodes.
# Default chart from deliveryhero (community) — well maintained, mirrors
# upstream k8s.io/node-problem-detector image.
install_node_problem_detector() {
    if [ "${INSTALL_NODE_PROBLEM_DETECTOR}" != "true" ]; then
        echo "node-problem-detector installation skipped (INSTALL_NODE_PROBLEM_DETECTOR=false)"
        return 0
    fi

    echo "Installing node-problem-detector via Helm..."

    helm repo add deliveryhero https://charts.deliveryhero.io/ >/dev/null 2>&1 || true
    helm repo update deliveryhero >/dev/null

    echo "  Chart:     deliveryhero/node-problem-detector --version ${NPD_VERSION#v}"
    echo "  Namespace: ${NPD_NAMESPACE}"
    echo "  Release:   ${NPD_RELEASE_NAME}"

    # Run on GPU nodes only; tolerate the GPU NoSchedule taint
    helm upgrade --install "${NPD_RELEASE_NAME}" \
        deliveryhero/node-problem-detector \
        --namespace "${NPD_NAMESPACE}" \
        --create-namespace \
        --version "${NPD_VERSION#v}" \
        --set nodeSelector."workload-type"=gpu \
        --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]' \
        --wait --timeout 5m || {
            echo "  WARNING: helm upgrade for node-problem-detector failed or timed out"
            return 0
        }
    echo "  node-problem-detector Helm release deployed"
}

# =====================================================================
# Standard mode: GPU health-check DaemonSet
# =====================================================================
# Lightweight self-test on every GPU node:
#   1. Run `nvidia-smi` once at startup
#   2. If it fails (driver crash, dead GPU, missing toolkit), taint the
#      node with gpu-unhealthy=true:NoSchedule so workloads avoid it
#   3. Sleep forever — actual repair is human-driven
#
# This catches the class of failures that nvidia-device-plugin masks
# (plugin pod CrashLoopBackOff doesn't surface to kube-scheduler in a
# way that prevents scheduling — kubelet just shows nvidia.com/gpu=0,
# but pods with explicit GPU requests fail at admission rather than
# being gracefully deferred).
install_gpu_health_check() {
    if [ "${INSTALL_GPU_HEALTH_CHECK}" != "true" ]; then
        echo "GPU health-check DaemonSet installation skipped (INSTALL_GPU_HEALTH_CHECK=false)"
        return 0
    fi

    echo "Installing GPU health-check DaemonSet..."

    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gpu-health-check
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gpu-health-check
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gpu-health-check
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: gpu-health-check
subjects:
- kind: ServiceAccount
  name: gpu-health-check
  namespace: kube-system
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: gpu-health-check
  namespace: kube-system
  labels:
    app.kubernetes.io/name: gpu-health-check
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: gpu-health-check
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gpu-health-check
    spec:
      hostPID: true
      serviceAccountName: gpu-health-check
      nodeSelector:
        workload-type: gpu
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      - key: CriticalAddonsOnly
        operator: Exists
      priorityClassName: system-node-critical
      # restartPolicy intentionally omitted — DaemonSet pods only support
      # Always (default) and Never, and explicitly setting Always is
      # rejected by some admission controllers.
      containers:
      # alpine/k8s is multi-arch (amd64/arm64), ships kubectl + util-linux
      # (so nsenter is available), and is freely pullable from Docker Hub.
      # We tried amazonlinux:2023 base and it lacks util-linux-core, breaking
      # the nsenter call. We tried bitnami/kubectl:1.31 and it was retired
      # from the public Bitnami catalog in mid-2025.
      - name: probe
        image: docker.io/alpine/k8s:1.31.4
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        command:
        - /bin/sh
        - -c
        - |
          set -u
          # Probe the host's nvidia-smi (driver shipped by the AMI).
          if nsenter -t 1 -m -p -- nvidia-smi -L >/tmp/smi.log 2>&1; then
              echo "[gpu-health-check] PASS: nvidia-smi -L on ${NODE_NAME}"
              cat /tmp/smi.log
              # Remove any stale gpu-unhealthy taint so a recovered node
              # rejoins the schedulable pool.
              kubectl taint node "${NODE_NAME}" gpu-unhealthy- 2>/dev/null || true
          else
              echo "[gpu-health-check] FAIL: nvidia-smi on ${NODE_NAME}"
              cat /tmp/smi.log
              kubectl taint node "${NODE_NAME}" \
                  gpu-unhealthy=true:NoSchedule --overwrite || true
          fi

          # Sleep forever; the DS exists for boot-time check, not a loop.
          # If you want periodic re-checks, switch this to a cron-like loop.
          while true; do sleep 3600; done
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 64Mi
EOF

    echo "  GPU health-check DaemonSet applied"
}

# =====================================================================
# Operator mode: NVIDIA GPU Operator (helm)
# =====================================================================
# Why these flags matter:
#   driver.enabled=false   — EKS GPU AMI ships a tested driver; the
#                            Operator's containerized driver would fight
#                            with the host one and likely fail to load.
#   toolkit.enabled=false  — Same: AMI ships nvidia-container-toolkit
#                            (jit-cdi mode by default in 1.18+).
#   mofedDriver.enabled=false — AWS EFA plugin already binds
#                            /dev/infiniband/uverbs*. Letting the
#                            Operator install MOFED would clash.
#   driver.rdma.enabled=false — Belt-and-suspenders for #3.
#   migManager.enabled is gated by GPU_OPERATOR_MIG_STRATEGY (default off).
#
# We do NOT install AWS EFA via the Operator; install_efa_device_plugin()
# still runs in this mode.
install_gpu_operator() {
    echo "Installing NVIDIA GPU Operator via Helm..."

    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
    helm repo update nvidia >/dev/null

    local op_ver="${GPU_OPERATOR_VERSION#v}"
    echo "  Chart:     nvidia/gpu-operator --version ${op_ver}"
    echo "  Namespace: ${GPU_OPERATOR_NAMESPACE}"
    echo "  Release:   ${GPU_OPERATOR_RELEASE_NAME}"
    echo "  driver.enabled=${GPU_OPERATOR_DRIVER_ENABLED} toolkit.enabled=${GPU_OPERATOR_TOOLKIT_ENABLED} mofed.enabled=${GPU_OPERATOR_MOFED_ENABLED} mig.strategy=${GPU_OPERATOR_MIG_STRATEGY}"

    # mig.strategy=none disables migManager pods entirely; A100/H100 users
    # set this to single|mixed and label nodes with nvidia.com/mig.config.
    local mig_manager_enabled="false"
    if [ "${GPU_OPERATOR_MIG_STRATEGY}" != "none" ]; then
        mig_manager_enabled="true"
    fi

    # Render values via a YAML file rather than dozens of --set flags.
    # Reasons:
    #   - --set passes everything through helm's type-inference, which
    #     coerces "false" / "true" / "none" / "null" to bool/null. The
    #     gpu-operator CRD requires validator.plugin.env[].value to be
    #     a STRING; --set "value=false" was rejected by the API server
    #     even with --set-string after a refactor (see git history).
    #   - YAML preserves types literally — strings stay strings.
    #   - Easier to diff and audit one block of values than 18 --set lines.
    local values_file
    values_file=$(mktemp -t gpu-operator-values.XXXXXX.yaml)
    trap "rm -f '${values_file}'" RETURN
    cat > "${values_file}" <<EOF
driver:
  enabled: ${GPU_OPERATOR_DRIVER_ENABLED}
  rdma:
    enabled: false
toolkit:
  enabled: ${GPU_OPERATOR_TOOLKIT_ENABLED}
mofedDriver:
  enabled: ${GPU_OPERATOR_MOFED_ENABLED}
devicePlugin:
  enabled: true
dcgmExporter:
  enabled: true
gfd:
  enabled: true
nfd:
  enabled: true
validator:
  plugin:
    env:
      - name: WITH_WORKLOAD
        value: "false"
migManager:
  enabled: ${mig_manager_enabled}
mig:
  strategy: ${GPU_OPERATOR_MIG_STRATEGY}
daemonsets:
  nodeSelector:
    workload-type: gpu
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
    - key: CriticalAddonsOnly
      operator: Exists
EOF

    helm upgrade --install "${GPU_OPERATOR_RELEASE_NAME}" \
        nvidia/gpu-operator \
        --namespace "${GPU_OPERATOR_NAMESPACE}" \
        --create-namespace \
        --version "${op_ver}" \
        --values "${values_file}" \
        --wait --timeout 10m || {
            # Intentional asymmetry vs the standard-mode functions:
            #   standard install_*() return 0 on failure because individual
            #   chart timeouts are recoverable (most often "no GPU node ready
            #   yet", auto-heals on next node join).
            #   The Operator is one big release that orchestrates ~6 sub-DS;
            #   a partial failure leaves the cluster in a half-installed
            #   state where workloads can't reliably tell what is or isn't
            #   ready. We hard-fail and let the operator (human) inspect.
            echo "  ERROR: helm upgrade for GPU Operator failed or timed out"
            echo "    Inspect: helm status ${GPU_OPERATOR_RELEASE_NAME} -n ${GPU_OPERATOR_NAMESPACE}"
            echo "             kubectl get pods -n ${GPU_OPERATOR_NAMESPACE}"
            return 1
        }
    echo "  GPU Operator Helm release deployed"
}

# =====================================================================
# Main
# =====================================================================
echo "Mode: GPU_STACK_MODE=${GPU_STACK_MODE}"
echo ""

guard_mutual_exclusion

case "${GPU_STACK_MODE}" in
    standard)
        echo "--- Installing standard stack ---"
        install_efa_device_plugin
        install_nvidia_device_plugin
        install_dcgm_exporter
        install_node_problem_detector
        install_gpu_health_check
        ;;
    operator)
        echo "--- Installing operator stack ---"
        install_efa_device_plugin
        install_gpu_operator
        ;;
esac

# -----------------------------------------------------------------
# Summary
# -----------------------------------------------------------------
echo ""
echo "=== K8s GPU Stack Installation Complete ==="
echo ""
echo "Mode: ${GPU_STACK_MODE}"
echo ""

if [ "${GPU_STACK_MODE}" = "standard" ]; then
    echo "Installed components:"
    echo "  • NVIDIA Device Plugin: helm release ${NVIDIA_DEVICE_PLUGIN_RELEASE_NAME} (${NVIDIA_DEVICE_PLUGIN_VERSION}, GFD enabled)"
    [ "${INSTALL_EFA_DEVICE_PLUGIN}"     = "true" ] && echo "  • AWS EFA Device Plugin: aws-efa-k8s-device-plugin-daemonset (${EFA_DEVICE_PLUGIN_VERSION})"
    [ "${INSTALL_DCGM_EXPORTER}"         = "true" ] && echo "  • DCGM Exporter: helm release ${DCGM_EXPORTER_RELEASE_NAME} (${DCGM_EXPORTER_VERSION})"
    [ "${INSTALL_NODE_PROBLEM_DETECTOR}" = "true" ] && echo "  • node-problem-detector: helm release ${NPD_RELEASE_NAME} (${NPD_VERSION})"
    [ "${INSTALL_GPU_HEALTH_CHECK}"      = "true" ] && echo "  • GPU health-check DaemonSet: kube-system/gpu-health-check"
    echo ""
    echo "Verify:"
    echo "  kubectl describe node -l workload-type=gpu | grep -E 'nvidia.com/gpu|vpc.amazonaws.com/efa'"
    echo "  kubectl -n kube-system get ds | grep -E 'nvidia-device-plugin|aws-efa|dcgm-exporter|node-problem-detector|gpu-health-check'"
elif [ "${GPU_STACK_MODE}" = "operator" ]; then
    echo "Installed components:"
    echo "  • NVIDIA GPU Operator: helm release ${GPU_OPERATOR_RELEASE_NAME} (${GPU_OPERATOR_VERSION})"
    echo "      driver.enabled=${GPU_OPERATOR_DRIVER_ENABLED}"
    echo "      toolkit.enabled=${GPU_OPERATOR_TOOLKIT_ENABLED}"
    echo "      mofedDriver.enabled=${GPU_OPERATOR_MOFED_ENABLED}"
    echo "      mig.strategy=${GPU_OPERATOR_MIG_STRATEGY}"
    [ "${INSTALL_EFA_DEVICE_PLUGIN}" = "true" ] && echo "  • AWS EFA Device Plugin: aws-efa-k8s-device-plugin-daemonset (${EFA_DEVICE_PLUGIN_VERSION})"
    echo ""
    echo "Verify:"
    echo "  kubectl get pods -n ${GPU_OPERATOR_NAMESPACE}"
    echo "  kubectl describe node -l workload-type=gpu | grep -E 'nvidia.com/gpu|vpc.amazonaws.com/efa'"
fi

echo ""
echo "Switch modes later with:"
echo "  GPU_STACK_MODE=<other> GPU_STACK_FORCE_SWITCH=true bash $(basename "$0")"
