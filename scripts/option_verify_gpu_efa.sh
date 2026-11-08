#!/bin/bash
# option_verify_gpu_efa.sh — End-to-end GPU + EFA verification
#
# Two modes:
#
#  1) Single-node (default): spawns one verification Pod that exercises
#     the local GPU and EFA stack on a chosen node — nvidia-smi, fi_info,
#     AWS-OFI-NCCL plugin presence, and a single-node NCCL all-reduce.
#
#  2) Multi-node ("--multi N", N >= 2): spawns N pods on N distinct
#     Ready nodes in the nodegroup, and runs an mpirun-driven NCCL
#     all_reduce_perf across them. This is the only test that actually
#     exercises cross-node EFA / GPU SG self-egress / AWS-OFI-NCCL net
#     plugin. Single-node tests cannot detect a missing security-group
#     self-rule because all traffic stays on one host.
#
# The Pod uses public.ecr.aws/hpc-cloud/nccl-tests:latest, an AWS-
# maintained image bundled with EFA installer, AWS-OFI-NCCL, NCCL,
# nccl-tests, sshd and openmpi — the standard combo for EFA NCCL
# benchmarks (also used by SkyPilot, AWS examples, etc.).
#
# Usage:
#   option_verify_gpu_efa.sh <ng_name> [node_name]            # single-node
#   option_verify_gpu_efa.sh <ng_name> --multi [N]            # multi-node, N>=2 (default 2)
#
# Env:
#   CLUSTER_NAME, AWS_REGION, KUBECONFIG (loaded from 0_setup_env.sh)
#   VERIFY_NAMESPACE       default: gpu-verify
#   VERIFY_IMAGE           default: public.ecr.aws/hpc-cloud/nccl-tests:latest
#   VERIFY_TIMEOUT_SEC     default: 600
#   VERIFY_KEEP_POD        default: false (set true to skip Pod cleanup)
#   VERIFY_NCCL_DEBUG      default: INFO (multi-node only; passed through to NCCL)
#   VERIFY_BUSBW_THRESHOLD default: 0 (multi-node only; if >0, FAIL when
#                                       observed busbw GB/s falls below this)
#
# Neuron (trn*/inf*, auto-detected; nccom-test):
#   The vendor is detected from the probe node (the explicit node, else the
#   nodegroup's first node): label workload-type=neuron or allocatable
#   aws.amazon.com/neuron > 0 => Neuron path, otherwise the NVIDIA path above
#   (unchanged). The Neuron path uses an official Neuron DLC
#   (pytorch-training-neuronx) and plain Pods, like the NVIDIA path:
#     single-node: neuron-ls device count == allocatable aws.amazon.com/neuron,
#                  /dev/neuron* count, visible NeuronCores vs allocatable
#                  aws.amazon.com/neuroncore (WARN only — LNC), fi_info -p efa
#                  + uverbs count, single-node nccom-test all-reduce
#                  (--check: results validated, not just timed).
#     multi-node:  nccom-test --check all-reduce across N nodes over EFA
#                  (FI_PROVIDER=efa), Open MPI over ssh on pod port 2222 with
#                  an ephemeral ed25519 key (trn1/trn1n/trn2 only); the
#                  private key lives in a verify-run-labelled Secret mounted
#                  0400 into the launcher only (not in any Pod spec).
#                  A resource-less pre-pull pod (`true`) on the launcher node
#                  pulls the DLC in parallel with the workers.
#   Pods request WHOLE devices (aws.amazon.com/neuron, never neuroncore — the
#   LNC pitfall) + vpc.amazonaws.com/efa, tolerate aws.amazon.com/neuron, add
#   only IPC_LOCK (not privileged, no hostPath, no hostNetwork), and carry
#   activeDeadlineSeconds = VERIFY_NEURON_TIMEOUT_SEC + 300 as a Pod-only leak
#   backstop (the Service / ssh-key Secret rely on the exit cleanup, which
#   prints a WARN + the manual kubectl delete command if it fails).
#   VERIFY_VENDOR             default: auto (auto | nvidia | neuron)
#   VERIFY_NEURON_IMAGE       default: public.ecr.aws/neuron/pytorch-training-neuronx:2.9.0-neuronx-py312-sdk2.30.0-ubuntu24.04
#   VERIFY_NEURON_TIMEOUT_SEC default: 1800 (the DLC is ~15 GB; first pull is slow)
#   VERIFY_NEURON_COMM_PORT   default: 63182 (NEURON_RT_ROOT_COMM_ID port, multi-node)
#   VERIFY_NEURON_RUNTIME_UPGRADE default: true — upgrade aws-neuronx-runtime-lib /
#                             collectives / tools in every verify pod from the Neuron
#                             apt repo before testing (the newest public DLC can lag
#                             the EKS Neuron AMI driver; false = use the image as-is)

set -e
set -o pipefail

export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=0_setup_env.sh
source "${SCRIPT_DIR}/0_setup_env.sh"

export KUBECONFIG="${HOME:-/root}/.kube/config"

VERIFY_NAMESPACE="${VERIFY_NAMESPACE:-gpu-verify}"
VERIFY_IMAGE="${VERIFY_IMAGE:-public.ecr.aws/hpc-cloud/nccl-tests:latest}"
VERIFY_TIMEOUT_SEC="${VERIFY_TIMEOUT_SEC:-600}"
VERIFY_KEEP_POD="${VERIFY_KEEP_POD:-false}"
VERIFY_NCCL_DEBUG="${VERIFY_NCCL_DEBUG:-INFO}"
VERIFY_BUSBW_THRESHOLD="${VERIFY_BUSBW_THRESHOLD:-0}"
VERIFY_VENDOR="${VERIFY_VENDOR:-auto}"
VERIFY_NEURON_IMAGE="${VERIFY_NEURON_IMAGE:-public.ecr.aws/neuron/pytorch-training-neuronx:2.9.0-neuronx-py312-sdk2.30.0-ubuntu24.04}"
VERIFY_NEURON_TIMEOUT_SEC="${VERIFY_NEURON_TIMEOUT_SEC:-1800}"
VERIFY_NEURON_COMM_PORT="${VERIFY_NEURON_COMM_PORT:-63182}"
VERIFY_NEURON_RUNTIME_UPGRADE="${VERIFY_NEURON_RUNTIME_UPGRADE:-true}"

usage() {
    cat <<'EOF'
Usage:
  option_verify_gpu_efa.sh <ng_name> [node_name]   # single-node (default)
  option_verify_gpu_efa.sh <ng_name> --multi [N]   # multi-node NCCL all-reduce, N>=2

  <ng_name>   EKS managed nodegroup name to verify
  [node_name] (single-node) explicit Kubernetes node name; first Ready node picked otherwise
  --multi [N] (multi-node)  number of pods/nodes to use; default 2

Examples:
  ./option_verify_gpu_efa.sh gpu-p5en-48xlarge-spot-az3
  ./option_verify_gpu_efa.sh gpu-p6-b300-48xlarge-spot-az3 ip-10-0-12-145.us-west-2.compute.internal
  ./option_verify_gpu_efa.sh gpu-p6-b300-48xlarge-spot-az3 --multi 2
  ./option_verify_gpu_efa.sh gpu-p6-b300-48xlarge-spot-az3 --multi 4

Env overrides:
  VERIFY_NAMESPACE           target namespace (default: gpu-verify)
  VERIFY_IMAGE               container image (default: public.ecr.aws/hpc-cloud/nccl-tests:latest)
  VERIFY_TIMEOUT_SEC         pod wait timeout (default: 600)
  VERIFY_KEEP_POD            'true' to skip cleanup
  VERIFY_NCCL_DEBUG          NCCL_DEBUG level (default: INFO; multi-node only)
  VERIFY_BUSBW_THRESHOLD     min observed busbw GB/s; <threshold = FAIL (default: 0=disabled)

Neuron (trn*/inf*, auto-detected; nccom-test):
  Nodes labelled workload-type=neuron (or advertising aws.amazon.com/neuron)
  run neuron-ls / fi_info / nccom-test in an official Neuron DLC instead of
  the NCCL checks. Pods request whole aws.amazon.com/neuron devices (never
  neuroncore) + vpc.amazonaws.com/efa. --multi needs trn1/trn1n/trn2 with EFA.
  VERIFY_VENDOR              auto | nvidia | neuron (default: auto)
  VERIFY_NEURON_IMAGE        Neuron DLC (default: public.ecr.aws/neuron/pytorch-training-neuronx:2.9.0-neuronx-py312-sdk2.30.0-ubuntu24.04)
  VERIFY_NEURON_TIMEOUT_SEC  pod wait timeout (default: 1800; ~15 GB first pull)
  VERIFY_NEURON_COMM_PORT    NEURON_RT_ROOT_COMM_ID port, multi-node (default: 63182)
  VERIFY_NEURON_RUNTIME_UPGRADE  true | false (default: true) — apt-upgrade the Neuron
                             runtime/collectives/tools in each pod first (needs egress
                             to apt.repos.neuron.amazonaws.com; failure only WARNs)
  (VERIFY_NAMESPACE, VERIFY_KEEP_POD and VERIFY_BUSBW_THRESHOLD apply too.)
  e.g. ./option_verify_gpu_efa.sh gpu-trn2-48xlarge-od-az1 --multi 2
EOF
    exit 1
}

[ $# -lt 1 ] && usage

NG_NAME="$1"
shift

# Detect mode
MODE="single"
MULTI_N=2
EXPLICIT_NODE=""
if [ $# -gt 0 ]; then
    case "$1" in
        --multi)
            MODE="multi"
            shift
            if [ $# -gt 0 ] && [[ "$1" =~ ^[2-9]$|^[1-9][0-9]+$ ]]; then
                MULTI_N="$1"
                shift
            fi
            ;;
        --help|-h)
            usage
            ;;
        *)
            EXPLICIT_NODE="$1"
            shift
            ;;
    esac
fi

if [ "$MULTI_N" -lt 2 ] 2>/dev/null; then
    echo "ERROR: --multi N must be >= 2 (got '${MULTI_N}')" >&2
    exit 1
fi

case "${VERIFY_VENDOR}" in
    auto|nvidia|neuron) ;;
    *)
        echo "ERROR: VERIFY_VENDOR must be auto, nvidia or neuron (got '${VERIFY_VENDOR}')" >&2
        exit 1
        ;;
esac
if [ "${VERIFY_VENDOR}" != "nvidia" ]; then
    for v in VERIFY_NEURON_TIMEOUT_SEC VERIFY_NEURON_COMM_PORT; do
        if ! [[ "${!v}" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: ${v} must be a positive integer (got '${!v}')" >&2
            exit 1
        fi
    done
    case "${VERIFY_NEURON_RUNTIME_UPGRADE}" in
        true|false) ;;
        *)
            echo "ERROR: VERIFY_NEURON_RUNTIME_UPGRADE must be true or false (got '${VERIFY_NEURON_RUNTIME_UPGRADE}')" >&2
            exit 1
            ;;
    esac
fi

for tool in aws jq kubectl; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "ERROR: missing dependency: ${tool}" >&2; exit 1
    }
done

# Validate cluster + nodegroup exist (cheap pre-flight)
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "ERROR: EKS cluster '${CLUSTER_NAME}' not found in region '${AWS_REGION}'" >&2
    exit 1
fi
if ! aws eks describe-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${NG_NAME}" \
    --region "${AWS_REGION}" &>/dev/null; then
    echo "ERROR: nodegroup '${NG_NAME}' not found in cluster '${CLUSTER_NAME}'" >&2
    exit 1
fi

# Names of the Ready nodes in ${NG_NAME}, one per line. jq, not kubectl
# jsonpath: the nested filter
#   {.items[?(@.status.conditions[?(@.type=="Ready")].status=="True")]}
# is rejected by kubectl ("unterminated filter", seen with kubectl v1.35), so
# the old expression always returned nothing and every run without an
# explicit node failed with "no Ready nodes found".
ready_nodes_in_ng() {
    kubectl get nodes -l "eks.amazonaws.com/nodegroup=${NG_NAME}" -o json 2>/dev/null \
        | jq -r '.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name'
}

# Idempotency: ensure namespace exists
kubectl get ns "${VERIFY_NAMESPACE}" >/dev/null 2>&1 || \
    kubectl create ns "${VERIFY_NAMESPACE}" >/dev/null

# ====================================================================
# Helper: read GPU / EFA allocatable on a node
# ====================================================================
read_node_resources() {
    local node=$1
    local var_prefix=$2
    local gpu efa
    gpu=$(kubectl get node "${node}" \
        -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
    efa=$(kubectl get node "${node}" \
        -o jsonpath='{.status.allocatable.vpc\.amazonaws\.com/efa}' 2>/dev/null)
    eval "${var_prefix}_GPU=\${gpu:-0}"
    eval "${var_prefix}_EFA=\${efa:-0}"
}

# ====================================================================
# Mode 1: SINGLE NODE
# ====================================================================
run_single_node() {
    # Pick target node
    local target_node
    if [ -n "${EXPLICIT_NODE}" ]; then
        target_node="${EXPLICIT_NODE}"
        if ! kubectl get node "${target_node}" &>/dev/null; then
            echo "ERROR: explicit node '${target_node}' not found in cluster" >&2
            exit 1
        fi
    else
        target_node=$(ready_nodes_in_ng | head -1)
        if [ -z "${target_node}" ]; then
            echo "ERROR: no Ready nodes found in nodegroup '${NG_NAME}'" >&2
            echo "       (try: kubectl get nodes -l eks.amazonaws.com/nodegroup=${NG_NAME})" >&2
            exit 1
        fi
    fi

    read_node_resources "${target_node}" N
    local instance_type
    instance_type=$(kubectl get node "${target_node}" \
        -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null)

    echo "=== GPU + EFA Verification (single-node) ==="
    echo "Cluster:    ${CLUSTER_NAME}"
    echo "Nodegroup:  ${NG_NAME}"
    echo "Node:       ${target_node}"
    echo "Instance:   ${instance_type:-<unknown>}"
    echo "GPUs:       ${N_GPU}"
    echo "EFA NICs:   ${N_EFA}"
    echo ""

    if [ "${N_GPU}" -le 0 ] 2>/dev/null; then
        echo "ERROR: node '${target_node}' advertises 0 GPUs in allocatable" >&2
        echo "       Check NVIDIA Device Plugin status:" >&2
        echo "       kubectl get pods -A -l app.kubernetes.io/name=nvidia-device-plugin" >&2
        exit 1
    fi

    local pod_name="gpu-efa-verify-$(date +%s)"

    cleanup() {
        if [ "${VERIFY_KEEP_POD}" = "true" ]; then
            echo ""
            echo "VERIFY_KEEP_POD=true — leaving pod ${VERIFY_NAMESPACE}/${pod_name} for inspection"
            return
        fi
        echo ""
        echo "Cleaning up..."
        kubectl delete pod -n "${VERIFY_NAMESPACE}" "${pod_name}" --wait=false >/dev/null 2>&1 || true
    }
    trap cleanup EXIT

    local efa_resource_limits=""
    if [ "${N_EFA}" -gt 0 ] 2>/dev/null; then
        efa_resource_limits="    vpc.amazonaws.com/efa: ${N_EFA}"
    fi

    echo "Launching verification Pod ${VERIFY_NAMESPACE}/${pod_name}..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${VERIFY_NAMESPACE}
  labels:
    app: gpu-efa-verify
spec:
  restartPolicy: Never
  nodeName: ${target_node}
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: verify
    image: ${VERIFY_IMAGE}
    command: ["/bin/bash", "-c"]
    args:
    - |
      set -uo pipefail

      pass=0
      fail=0
      check() {
          local name="\$1"
          local cmd="\$2"
          echo ""
          echo "----- \$name -----"
          if eval "\$cmd"; then
              echo "RESULT: PASS  \$name"
              pass=\$((pass+1))
          else
              echo "RESULT: FAIL  \$name"
              fail=\$((fail+1))
          fi
      }

      echo "============================================================"
      echo " GPU + EFA Verification on \$(hostname)"
      echo "============================================================"

      check "nvidia-smi reports GPUs" \\
          "nvidia-smi -L && [ \\\$(nvidia-smi -L | wc -l) -eq ${N_GPU} ]"

      check "/dev/nvidia[0-9] device nodes match GPU count" \\
          "ls /dev/nvidia[0-9]* 2>/dev/null && [ \\\$(ls /dev/nvidia[0-9]* 2>/dev/null | wc -l) -eq ${N_GPU} ]"

      if [ ${N_EFA} -gt 0 ]; then
          check "fi_info -p efa lists ${N_EFA} provider entry/entries" \\
              "/opt/amazon/efa/bin/fi_info -p efa 2>/dev/null | grep -c 'provider: efa' | awk -v want=${N_EFA} '{if (\\\$1 >= want) exit 0; else exit 1}'"

          check "/dev/infiniband/uverbs* device count matches EFA count" \\
              "ls /dev/infiniband/uverbs* 2>/dev/null && [ \\\$(ls /dev/infiniband/uverbs* 2>/dev/null | wc -l) -eq ${N_EFA} ]"
      else
          echo ""
          echo "----- EFA checks skipped (vpc.amazonaws.com/efa=0 on this node) -----"
      fi

      check "AWS-OFI-NCCL plugin (libnccl-net.so) present" \\
          "ldconfig -p 2>/dev/null | grep -E 'libnccl-net\\\\.so' || find /opt /usr -name 'libnccl-net.so*' 2>/dev/null | grep -q ."

      check "single-node NCCL all_reduce_perf (8B → 64MB)" \\
          "/opt/nccl-tests/build/all_reduce_perf -b 8 -e 64M -f 2 -g ${N_GPU} -n 5 -w 2 -c 1 2>&1 | tail -20"

      echo ""
      echo "============================================================"
      echo " Summary: \$pass passed, \$fail failed"
      echo "============================================================"
      exit \$fail
  resources:
    limits:
      nvidia.com/gpu: ${N_GPU}
${efa_resource_limits}
EOF

    echo ""
    echo "Waiting for Pod to start (timeout ${VERIFY_TIMEOUT_SEC}s)..."
    kubectl wait --for=condition=Ready=true \
        pod/"${pod_name}" -n "${VERIFY_NAMESPACE}" \
        --timeout="${VERIFY_TIMEOUT_SEC}s" 2>/dev/null || true

    echo ""
    echo "=== Pod logs ==="
    kubectl logs -n "${VERIFY_NAMESPACE}" "${pod_name}" --follow=false 2>&1 || true

    echo ""
    local pod_phase
    pod_phase=$(kubectl get pod -n "${VERIFY_NAMESPACE}" "${pod_name}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    local pod_exit
    pod_exit=$(kubectl get pod -n "${VERIFY_NAMESPACE}" "${pod_name}" \
        -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "")

    echo "${pod_name}: phase=${pod_phase} exit=${pod_exit:-<n/a>}"
    echo ""
    if [ "${pod_phase}" = "Succeeded" ] && [ "${pod_exit}" = "0" ]; then
        echo "✅ Single-node verification PASSED on ${target_node}"
        exit 0
    else
        echo "❌ Single-node verification FAILED on ${target_node}"
        exit 1
    fi
}

# ====================================================================
# Mode 2: MULTI NODE (mpirun NCCL all-reduce across N nodes)
# ====================================================================
run_multi_node() {
    echo "=== GPU + EFA Verification (multi-node, ${MULTI_N} nodes) ==="
    echo "Cluster:    ${CLUSTER_NAME}"
    echo "Nodegroup:  ${NG_NAME}"

    # Pick MULTI_N distinct Ready nodes
    local nodes_arr=()
    while IFS= read -r line; do
        [ -n "$line" ] && nodes_arr+=("$line")
    done < <(ready_nodes_in_ng | head -"${MULTI_N}")

    if [ "${#nodes_arr[@]}" -lt "${MULTI_N}" ]; then
        echo "ERROR: only ${#nodes_arr[@]} Ready node(s) in NG '${NG_NAME}', need ${MULTI_N}" >&2
        echo "       (try: kubectl get nodes -l eks.amazonaws.com/nodegroup=${NG_NAME})" >&2
        exit 1
    fi

    # Read GPU/EFA counts from the first node (assume homogeneous within NG)
    read_node_resources "${nodes_arr[0]}" N
    if [ "${N_GPU}" -le 0 ] 2>/dev/null; then
        echo "ERROR: node '${nodes_arr[0]}' advertises 0 GPUs" >&2
        exit 1
    fi
    echo "Per-node GPUs: ${N_GPU}"
    echo "Per-node EFAs: ${N_EFA}"
    local total_gpus=$(( N_GPU * MULTI_N ))
    echo "Total ranks:   ${total_gpus} (= ${N_GPU} GPUs × ${MULTI_N} nodes)"
    echo ""
    for i in "${!nodes_arr[@]}"; do
        echo "  Node ${i}: ${nodes_arr[$i]}"
    done
    echo ""

    local job_id="$(date +%s)"
    local headless_svc="nccl-mpi-${job_id}"
    local launcher_pod="${headless_svc}-launcher"

    cleanup_multi() {
        if [ "${VERIFY_KEEP_POD}" = "true" ]; then
            echo ""
            echo "VERIFY_KEEP_POD=true — leaving resources for inspection:"
            echo "  kubectl get -n ${VERIFY_NAMESPACE} pod,svc -l job-id=${job_id}"
            return
        fi
        echo ""
        echo "Cleaning up..."
        kubectl delete -n "${VERIFY_NAMESPACE}" pod -l "job-id=${job_id}" --wait=false >/dev/null 2>&1 || true
        kubectl delete -n "${VERIFY_NAMESPACE}" svc "${headless_svc}" --wait=false >/dev/null 2>&1 || true
    }
    trap cleanup_multi EXIT

    # ----- Headless service for stable pod DNS resolution -----
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${headless_svc}
  namespace: ${VERIFY_NAMESPACE}
  labels:
    job-id: "${job_id}"
spec:
  clusterIP: None
  selector:
    job-id: "${job_id}"
  publishNotReadyAddresses: true
  ports:
  - name: ssh
    port: 2222
    targetPort: 2222
EOF

    # Use a static SSH keypair so launcher and workers can authenticate
    # without external secret store. Generated on the fly.
    local tmpdir
    tmpdir=$(mktemp -d)
    ssh-keygen -t ed25519 -N "" -f "${tmpdir}/id_ed25519" -q
    local pub_key
    pub_key=$(cat "${tmpdir}/id_ed25519.pub")
    local priv_key_b64
    priv_key_b64=$(base64 -w 0 < "${tmpdir}/id_ed25519")
    rm -rf "${tmpdir}"

    # Build EFA resource block conditionally
    local efa_resource_yaml=""
    if [ "${N_EFA}" -gt 0 ] 2>/dev/null; then
        efa_resource_yaml="
        vpc.amazonaws.com/efa: ${N_EFA}"
    fi

    # ----- Launch worker pods (rank > 0) -----
    # Workers run sshd on port 2222 and wait. Launcher SSHes in to start
    # the MPI ranks via Open MPI's tree-spawn.
    local hosts_csv=""
    for i in "${!nodes_arr[@]}"; do
        local pod_name="${headless_svc}-pod-${i}"
        hosts_csv+="${pod_name}.${headless_svc}.${VERIFY_NAMESPACE}.svc.cluster.local:${N_GPU},"

        if [ "${i}" -eq 0 ]; then
            continue   # launcher pod created separately below
        fi

        kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${VERIFY_NAMESPACE}
  labels:
    app: gpu-efa-verify-multi
    job-id: "${job_id}"
spec:
  restartPolicy: Never
  hostname: ${pod_name}
  subdomain: ${headless_svc}
  nodeName: ${nodes_arr[$i]}
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: worker
    image: ${VERIFY_IMAGE}
    command: ["/bin/bash", "-c"]
    args:
    - |
      set -e
      mkdir -p /root/.ssh
      echo '${pub_key}' > /root/.ssh/authorized_keys
      chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
      # SSH host key (avoid first-connect prompt)
      ssh-keygen -A -q
      # Run sshd in the foreground on port 2222
      /usr/sbin/sshd -D -e -p 2222
    securityContext:
      capabilities:
        add: ["IPC_LOCK"]
    resources:
      limits:
        nvidia.com/gpu: ${N_GPU}${efa_resource_yaml}
EOF
    done

    # Strip trailing comma
    hosts_csv="${hosts_csv%,}"

    # ----- Launcher pod (rank 0 + driver) -----
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${launcher_pod}
  namespace: ${VERIFY_NAMESPACE}
  labels:
    app: gpu-efa-verify-multi
    job-id: "${job_id}"
spec:
  restartPolicy: Never
  hostname: ${headless_svc}-pod-0
  subdomain: ${headless_svc}
  nodeName: ${nodes_arr[0]}
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: launcher
    image: ${VERIFY_IMAGE}
    command: ["/bin/bash", "-c"]
    args:
    - |
      set -uo pipefail

      # SSH key setup
      mkdir -p /root/.ssh
      echo '${pub_key}' > /root/.ssh/authorized_keys
      cat <<'PRIVKEY_B64' | base64 -d > /root/.ssh/id_ed25519
${priv_key_b64}
PRIVKEY_B64
      chmod 700 /root/.ssh
      chmod 600 /root/.ssh/id_ed25519 /root/.ssh/authorized_keys
      cat <<'SSHCONF' > /root/.ssh/config
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    Port 2222
SSHCONF
      chmod 600 /root/.ssh/config

      # Start local sshd too (so launcher can host its own rank if MPI uses
      # SSH for rank 0 — depends on Open MPI version)
      ssh-keygen -A -q
      /usr/sbin/sshd -p 2222 -e &

      # Wait for all worker pods to be reachable on port 2222
      echo "Waiting for ${MULTI_N} worker(s) to accept SSH..."
      for host in \$(echo "${hosts_csv}" | tr ',' '\n' | awk -F: '{print \$1}'); do
          echo "  probing \$host ..."
          for attempt in \$(seq 1 60); do
              if ssh -o ConnectTimeout=2 -o BatchMode=yes "root@\$host" true 2>/dev/null; then
                  echo "  \$host: reachable"
                  break
              fi
              sleep 5
          done
      done

      echo ""
      echo "============================================================"
      echo " Multi-node NCCL all_reduce_perf"
      echo " Hosts: ${hosts_csv}"
      echo " Total ranks: ${total_gpus}"
      echo "============================================================"

      # Open MPI / NCCL env. The hpc-cloud/nccl-tests image ships with
      # /opt/amazon/openmpi, /opt/amazon/efa, AWS-OFI-NCCL pre-built.
      export PATH=/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:\$PATH
      export LD_LIBRARY_PATH=/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/opt/aws-ofi-nccl/lib:\$LD_LIBRARY_PATH
      export NCCL_DEBUG=${VERIFY_NCCL_DEBUG}
      export FI_PROVIDER=efa
      export FI_EFA_USE_DEVICE_RDMA=1

      mpirun \\
          --allow-run-as-root \\
          --tag-output \\
          --mca plm_rsh_args "-p 2222 -o StrictHostKeyChecking=no" \\
          --mca pml ^cm,ucx \\
          --mca btl tcp,self \\
          --mca btl_tcp_if_exclude lo,docker0,veth_def_agent \\
          -np ${total_gpus} \\
          -N ${N_GPU} \\
          --bind-to none \\
          -H ${hosts_csv} \\
          -x PATH -x LD_LIBRARY_PATH \\
          -x NCCL_DEBUG -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA \\
          /opt/nccl-tests/build/all_reduce_perf \\
              -b 8 -e 1G -f 2 -g 1 -n 20 -w 5 -c 1 2>&1 \\
          | tee /tmp/nccl-output.log

      mpi_exit=\$?
      echo ""
      echo "mpirun exit code: \$mpi_exit"
      [ "\$mpi_exit" -ne 0 ] && exit \$mpi_exit

      # Post-run analysis
      echo ""
      echo "----- post-run checks -----"
      net_plugin_lines=\$(grep -E 'NET/.*Plugin|NET/AWS Libfabric|NET/OFI' /tmp/nccl-output.log | head -3 || true)
      if [ -n "\$net_plugin_lines" ]; then
          echo "PASS  NCCL loaded EFA-aware net plugin:"
          echo "\$net_plugin_lines" | sed 's/^/    /'
      else
          if grep -qE 'NET/Socket' /tmp/nccl-output.log; then
              echo "FAIL  NCCL fell back to NET/Socket (TCP) — EFA not in use"
              echo "      grep NCCL_DEBUG output for clues:"
              grep -E 'NET/' /tmp/nccl-output.log | head -10 | sed 's/^/    /'
              exit 1
          fi
          echo "WARN  no NET/* plugin lines captured (NCCL_DEBUG=${VERIFY_NCCL_DEBUG} may have suppressed them)"
      fi

      # Optional bandwidth threshold check
      if [ "${VERIFY_BUSBW_THRESHOLD}" -gt 0 ] 2>/dev/null; then
          # nccl-tests prints a summary line like:
          # # Avg bus bandwidth    : 12.3456 GB/s
          observed=\$(grep -E 'Avg bus bandwidth' /tmp/nccl-output.log | awk '{print \$NF}' | head -1)
          if [ -n "\$observed" ]; then
              echo ""
              echo "Observed busbw: \$observed (threshold ${VERIFY_BUSBW_THRESHOLD} GB/s)"
              awk -v obs="\$observed" -v thr="${VERIFY_BUSBW_THRESHOLD}" \\
                  'BEGIN { if (obs+0 >= thr+0) {print "PASS  busbw above threshold"; exit 0} else {print "FAIL  busbw below threshold"; exit 1} }' || exit 1
          fi
      fi

      echo ""
      echo "============================================================"
      echo " Multi-node NCCL all-reduce SUCCEEDED"
      echo "============================================================"
    securityContext:
      capabilities:
        add: ["IPC_LOCK"]
    resources:
      limits:
        nvidia.com/gpu: ${N_GPU}${efa_resource_yaml}
EOF

    echo ""
    echo "Waiting for launcher pod to complete (timeout ${VERIFY_TIMEOUT_SEC}s)..."

    # Wait for the launcher to terminate (worker pods stay running until cleanup)
    local deadline=$(( $(date +%s) + VERIFY_TIMEOUT_SEC ))
    local launcher_phase=""
    while [ $(date +%s) -lt ${deadline} ]; do
        launcher_phase=$(kubectl get pod -n "${VERIFY_NAMESPACE}" "${launcher_pod}" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
        case "${launcher_phase}" in
            Succeeded|Failed) break ;;
        esac
        sleep 10
    done

    echo ""
    echo "=== Launcher pod logs ==="
    kubectl logs -n "${VERIFY_NAMESPACE}" "${launcher_pod}" --follow=false 2>&1 || true

    echo ""
    local launcher_exit
    launcher_exit=$(kubectl get pod -n "${VERIFY_NAMESPACE}" "${launcher_pod}" \
        -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "")
    echo "${launcher_pod}: phase=${launcher_phase} exit=${launcher_exit:-<n/a>}"

    echo ""
    if [ "${launcher_phase}" = "Succeeded" ] && [ "${launcher_exit}" = "0" ]; then
        echo "✅ Multi-node verification PASSED across ${MULTI_N} nodes"
        echo "   This confirms cross-node EFA traffic and the GPU SG self-rules work."
        exit 0
    else
        echo "❌ Multi-node verification FAILED"
        echo ""
        echo "Common causes:"
        echo "  • GPU security group missing self-ingress or self-egress (cross-node EFA blocked)"
        echo "    Verify with: aws ec2 describe-security-groups --group-ids \$GPU_SG_ID"
        echo "    Both an ingress and an egress rule with source/destination = self SG ID,"
        echo "    protocol = -1 (all), are required by AWS EFA docs."
        echo "  • EFA Device Plugin missing or NVIDIA Device Plugin claiming uverbs"
        echo "    (helm: nvdp/nvidia-device-plugin --set mofedEnabled=false)"
        echo "  • AWS-OFI-NCCL plugin not loaded — check launcher logs above for"
        echo "    NET/Socket vs NET/AWS Libfabric in NCCL_DEBUG output."
        exit 1
    fi
}

# ====================================================================
# NEURON (Trainium / Inferentia) — vendor detection + nccom-test
# ====================================================================
# Everything below is only reached when the probe node is a Neuron node
# (or VERIFY_VENDOR=neuron). The NVIDIA functions above are unchanged.

# Probe node: the explicit node, else the nodegroup's first node. One
# read-only kubectl call. No node found => nvidia, so the NVIDIA path prints
# its existing "not found" / "no Ready nodes" error.
detect_vendor() {
    local json
    if [ -n "${EXPLICIT_NODE}" ]; then
        json=$(kubectl get node "${EXPLICIT_NODE}" -o json 2>/dev/null || true)
    else
        json=$(kubectl get nodes -l "eks.amazonaws.com/nodegroup=${NG_NAME}" -o json 2>/dev/null \
            | jq -c '.items[0] // empty' 2>/dev/null || true)
    fi
    if [ -z "${json}" ]; then
        echo nvidia
        return 0
    fi
    jq -r '
        if (.metadata.labels["workload-type"] // "") == "neuron"
           or (((.status.allocatable["aws.amazon.com/neuron"] // "0") | tonumber? // 0) > 0)
        then "neuron" else "nvidia" end' <<<"${json}" 2>/dev/null || echo nvidia
}

# read_neuron_resources <node> <prefix> — sets <prefix>_DEV (aws.amazon.com/neuron),
# <prefix>_CORE (aws.amazon.com/neuroncore), <prefix>_EFA, <prefix>_ITYPE.
read_neuron_resources() {
    local node=$1 p=$2 json dev core efa itype
    json=$(kubectl get node "${node}" -o json 2>/dev/null || true)
    [ -n "${json}" ] || json='{}'
    dev=$(jq -r '.status.allocatable["aws.amazon.com/neuron"] // "0"' <<<"${json}" 2>/dev/null || true)
    core=$(jq -r '.status.allocatable["aws.amazon.com/neuroncore"] // "0"' <<<"${json}" 2>/dev/null || true)
    efa=$(jq -r '.status.allocatable["vpc.amazonaws.com/efa"] // "0"' <<<"${json}" 2>/dev/null || true)
    itype=$(jq -r '.metadata.labels["node.kubernetes.io/instance-type"] // ""' <<<"${json}" 2>/dev/null || true)
    [[ "${dev}" =~ ^[0-9]+$ ]] || dev=0
    [[ "${core}" =~ ^[0-9]+$ ]] || core=0
    [[ "${efa}" =~ ^[0-9]+$ ]] || efa=0
    printf -v "${p}_DEV" '%s' "${dev}"
    printf -v "${p}_CORE" '%s' "${core}"
    printf -v "${p}_EFA" '%s' "${efa}"
    printf -v "${p}_ITYPE" '%s' "${itype}"
}

# preflight_neuron <node> <dev> <itype>
preflight_neuron() {
    local node=$1 dev=$2 itype=$3
    if [ "${dev}" -le 0 ]; then
        echo "ERROR: node '${node}' advertises 0 Neuron devices (aws.amazon.com/neuron) in allocatable" >&2
        echo "       Check the Neuron device plugin (install_neuron_stack = true?):" >&2
        echo "       kubectl get pods -n kube-system -o wide | grep neuron-device-plugin" >&2
        exit 1
    fi
    case "${itype}" in
        inf1.*)
            echo "ERROR: ${itype} (first-gen Inferentia) is not covered by the Neuron DLC / nccom-test" >&2
            exit 1
            ;;
    esac
}

# Poll a pod every 10s until it is terminal ("terminal") or Ready ("ready").
# Fails fast on errors that never heal; warns once on image pull errors
# (often transient on a ~15 GB DLC) and keeps waiting.
# A pod that vanishes (node removed / drained, manual delete) fails at once
# instead of looking like a slow image pull; NotFound before the first
# sighting gets a short grace (watch-cache lag right after `kubectl apply`).
# Returns 0 = reached, 1 = failed fast / ended early, 2 = deadline hit.
neuron_wait_pod() {
    local pod=$1 deadline=$2 mode=$3
    local start now json state phase preason wreason ready pull_warned=0 last_note
    local seen=0 api_err=0
    start=$(date +%s)
    last_note=${start}
    while :; do
        # --ignore-not-found: NotFound -> exit 0 with empty output, so a
        # non-zero exit is a real API / connectivity error.
        if json=$(kubectl get pod -n "${VERIFY_NAMESPACE}" "${pod}" \
                    --ignore-not-found -o json 2>/dev/null); then
            api_err=0
            if [ -z "${json}" ]; then
                if [ "${seen}" -eq 1 ] || [ $(( $(date +%s) - start )) -ge 30 ]; then
                    echo "ERROR: ${pod} disappeared (node removed / drained / evicted, or deleted)" >&2
                    return 1
                fi
                json='{}'
            else
                seen=1
            fi
        else
            api_err=$(( api_err + 1 ))
            json='{}'
        fi
        state=$(jq -r '[.status.phase // "Pending", .status.reason // "",
                         .status.containerStatuses[0].state.waiting.reason // "",
                         (.status.containerStatuses[0].ready // false | tostring)] | join("|")' \
                <<<"${json}" 2>/dev/null || echo "Pending|||false")
        IFS='|' read -r phase preason wreason ready <<<"${state}"

        case "${phase}" in
            Succeeded|Failed)
                if [ "${mode}" = "terminal" ]; then return 0; fi
                echo "ERROR: ${pod} ended (phase=${phase}) before becoming Ready" >&2
                return 1
                ;;
        esac
        if [ "${mode}" = "ready" ] && [ "${ready}" = "true" ]; then
            return 0
        fi
        case "${preason}" in
            UnexpectedAdmissionError|OutOf*)
                echo "ERROR: ${pod} rejected by the kubelet: ${preason}" >&2
                return 1
                ;;
        esac
        case "${wreason}" in
            InvalidImageName|CreateContainerConfigError|ErrImageNeverPull)
                echo "ERROR: ${pod} cannot start: ${wreason}" >&2
                return 1
                ;;
            ErrImagePull|ImagePullBackOff)
                if [ "${pull_warned}" -eq 0 ]; then
                    echo "WARN: ${pod}: ${wreason} for ${VERIFY_NEURON_IMAGE} — retrying until the deadline" >&2
                    pull_warned=1
                fi
                ;;
        esac

        now=$(date +%s)
        if [ "${now}" -ge "${deadline}" ]; then
            if [ "${api_err}" -gt 0 ]; then
                echo "ERROR: timed out waiting for ${pod} (${mode}; kubectl get failing for the last ${api_err} polls)" >&2
            else
                echo "ERROR: timed out waiting for ${pod} (${mode}; phase=${phase}${wreason:+, ${wreason}})" >&2
            fi
            return 2
        fi
        if [ $(( now - last_note )) -ge 60 ]; then
            if [ "${api_err}" -gt 0 ]; then
                echo "  ${pod}: kubectl get failing (${api_err} consecutive; $(( now - start ))s) — retrying"
            elif [ "${seen}" -eq 0 ]; then
                echo "  ${pod}: not visible yet ($(( now - start ))s)"
            elif [ "${phase}" = "Pending" ]; then
                echo "  ${pod}: still pulling image ($(( now - start ))s)"
            else
                echo "  ${pod}: still ${phase} ($(( now - start ))s)"
            fi
            last_note=${now}
        fi
        sleep 10
    done
}
wait_pod_terminal() { neuron_wait_pod "$1" "$2" terminal; }
wait_pod_ready()    { neuron_wait_pod "$1" "$2" ready; }

diagnose_pod() {
    local pod=$1
    echo ""
    echo "--- diagnose ${VERIFY_NAMESPACE}/${pod} ---"
    kubectl get pod -n "${VERIFY_NAMESPACE}" "${pod}" -o json 2>/dev/null | jq -r '
        "phase=\(.status.phase // "?") reason=\(.status.reason // "-") message=\(.status.message // "-")",
        ((.status.containerStatuses // [])[] | "container \(.name): \(.state | tojson)")' 2>/dev/null || true
    echo "last events:"
    kubectl get events -n "${VERIFY_NAMESPACE}" \
        --field-selector "involvedObject.name=${pod}" \
        --sort-by=.lastTimestamp 2>/dev/null | tail -10 || true
}

NEURON_RUN_ID=""
# Local tmpdir holding the multi-node ephemeral SSH keypair. Removed by
# cleanup_neuron too, so an interrupt / early failure between ssh-keygen and
# the inline rm never leaves the private key on disk (even with
# VERIFY_KEEP_POD=true).
NEURON_KEY_TMPDIR=""
cleanup_neuron() {
    # Ignore further INT/TERM while cleaning up: neuron_install_traps' 'exit'
    # handlers would otherwise abort the delete on a second Ctrl-C and leave
    # the ssh-key Secret / headless Service behind.
    trap '' INT TERM
    if [ -n "${NEURON_KEY_TMPDIR}" ]; then
        rm -rf "${NEURON_KEY_TMPDIR}"
        NEURON_KEY_TMPDIR=""
    fi
    [ -n "${NEURON_RUN_ID}" ] || return 0
    if [ "${VERIFY_KEEP_POD}" = "true" ]; then
        echo ""
        echo "VERIFY_KEEP_POD=true — leaving resources for inspection:"
        echo "  kubectl get -n ${VERIFY_NAMESPACE} pod,svc,secret -l verify-run=${NEURON_RUN_ID}"
        return 0
    fi
    echo ""
    echo "Cleaning up..."
    # activeDeadlineSeconds only bounds the Pods; the headless Service and the
    # ssh-key Secret have no other cleanup path, so a failed delete (expired
    # credentials, RBAC, API error) must be reported, not swallowed.
    if ! kubectl delete -n "${VERIFY_NAMESPACE}" pod,svc,secret -l "verify-run=${NEURON_RUN_ID}" \
        --wait=false >/dev/null 2>&1; then
        echo "WARN: cleanup failed — leftover Pods / Service / ssh-key Secret remain. Remove them with:" >&2
        echo "  kubectl delete -n ${VERIFY_NAMESPACE} pod,svc,secret -l verify-run=${NEURON_RUN_ID}" >&2
    fi
}
neuron_install_traps() {
    trap cleanup_neuron EXIT
    # INT/TERM exit through the EXIT trap so cleanup runs exactly once.
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# neuron_pod_json <name> <node> <role> <script> <env-json-array> <extra-json>
#   <extra-json> = {"spec": {...}, "container": {...}} merged into the Pod.
# Shared Pod template: restartPolicy Never, nodeName pin, Neuron toleration,
# IPC_LOCK only, whole-device aws.amazon.com/neuron (+ EFA when > 0),
# /dev/shm emptyDir (Memory, 8Gi), no hostPath, activeDeadlineSeconds.
# Prepended to every Neuron verify-pod script (single, worker, launcher).
# Live finding (trn2.48xlarge, EKS AL2023 Neuron AMI v20261031, host driver
# aws-neuronx-dkms 2.31.7): the newest public training DLC
# (pytorch-training-neuronx ...-sdk2.30.0, runtime-lib 2.32.31) fails
# nrt_init on that driver ("TDRV:dmem_buf_copyin Copy from buffer to memory
# failed" -> every nccom-test size "Failure running neuron-bench"), while
# runtime-lib 2.35.30 / collectives 2.35.43 from the Neuron apt repo pass.
# The DLC keeps the MPI + sshd the multi-node path needs, so upgrade only the
# three runtime packages in-pod. Never fatal (workers run under set -e):
# without egress to the repo it WARNs and keeps the image's runtime.
NEURON_RT_UPGRADE_SNIPPET=$(cat <<'NEURON_RT_UPGRADE'
RT_UPGRADED=false
if [ "${RT_UPGRADE:-true}" = "true" ]; then
    echo "=== Upgrading Neuron runtime packages (VERIFY_NEURON_RUNTIME_UPGRADE=false to skip) ==="
    if command -v apt-get >/dev/null 2>&1 && grep -rqs "apt.repos.neuron.amazonaws.com" /etc/apt/sources.list /etc/apt/sources.list.d/; then
        if DEBIAN_FRONTEND=noninteractive timeout 600 bash -c 'apt-get -o Acquire::http::Timeout=20 -o Acquire::Retries=1 update -qq && apt-get -o Acquire::http::Timeout=20 install -y -qq --only-upgrade aws-neuronx-runtime-lib aws-neuronx-collectives aws-neuronx-tools' > /tmp/neuron-rt-upgrade.log 2>&1; then
            RT_UPGRADED=true
            dpkg-query -W aws-neuronx-runtime-lib aws-neuronx-collectives aws-neuronx-tools 2>/dev/null || true
        else
            echo "WARN: Neuron runtime upgrade failed (no egress to apt.repos.neuron.amazonaws.com?); keeping the image's runtime"
            tail -5 /tmp/neuron-rt-upgrade.log 2>/dev/null || true
        fi
    else
        echo "WARN: image has no apt-get / Neuron apt repo; keeping the image's runtime"
    fi
fi
# Multi-node pods only (EFA_UP=true), and only after a successful runtime
# upgrade: the upgraded aws-neuronx-collectives loads libnccom-net.so only
# with a current libfabric — the DLC's EFA 1.48 / libfabric 2.4 is rejected
# ("libnccom-net.so load failed due to unsupported libfabric version"), so
# inter-node collectives fail. Install the userspace from the latest
# aws-efa-installer, signature-verified against the AWS EFA signing key.
#
# Every step is checked explicitly with `|| return 1`: `set -e` is ignored
# for anything evaluated as an `if` condition (even inside a subshell that
# sets it), so a `set -e` + `if ( ... )` form would run the installer after
# a failed download / fingerprint / signature check. The signature must be a
# VALIDSIG whose PRIMARY key fingerprint (last field of the gpg status line)
# is the pinned AWS EFA key — not "any key in the downloaded key file", and
# not a locale-dependent "Good signature" grep. Fingerprint as in
# modules/gpu-instance-catalog/templates/efa-userspace.sh.tpl and
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start.html.
efa_userspace_upgrade() {
    local d base=https://efa-installer.amazonaws.com
    local fpr="4E9091BCBB97A96B26B15E59A05480B1DD2D3CCC"
    local curl_opts=(-fsSL --connect-timeout 10 --max-time 300 --retry 2)
    d=$(mktemp -d) || return 1
    cd "$d" || return 1
    curl "${curl_opts[@]}" -o efa.tgz "$base/aws-efa-installer-latest.tar.gz" || { echo "download failed: tarball"; return 1; }
    curl "${curl_opts[@]}" -o efa.tgz.sig "$base/aws-efa-installer-latest.tar.gz.sig" || { echo "download failed: signature"; return 1; }
    curl "${curl_opts[@]}" -o efa.key "$base/aws-efa-installer.key" || { echo "download failed: signing key"; return 1; }
    command -v gpg >/dev/null 2>&1 || { echo "gpg not in image"; return 1; }
    mkdir -m 700 "$d/gnupg" || return 1
    GNUPGHOME="$d/gnupg" gpg --batch --quiet --import efa.key >/dev/null 2>&1 || { echo "cannot import signing key"; return 1; }
    LC_ALL=C GNUPGHOME="$d/gnupg" gpg --batch --status-fd 1 --verify efa.tgz.sig efa.tgz 2>/dev/null \
        | grep -Eq "^\[GNUPG:\] VALIDSIG .* ${fpr}\$" || { echo "signature is not a valid signature by the AWS EFA key ${fpr}"; return 1; }
    tar xzf efa.tgz || { echo "cannot extract tarball"; return 1; }
    cd aws-efa-installer || return 1
    timeout 900 ./efa_installer.sh -y --skip-kmod --skip-limit-conf --no-verify > /tmp/efa-upgrade.log 2>&1 || { echo "efa_installer.sh failed (see /tmp/efa-upgrade.log)"; return 1; }
}
if [ "${EFA_UP:-false}" = "true" ] && [ "${RT_UPGRADED}" = "true" ]; then
    echo "=== Upgrading EFA userspace (libfabric) from the signature-verified latest aws-efa-installer ==="
    if efa_msg=$(efa_userspace_upgrade 2>&1); then
        echo "libfabric: $(/opt/amazon/efa/bin/fi_info --version 2>/dev/null | head -1)"
    else
        echo "WARN: EFA userspace upgrade skipped: ${efa_msg##*$'\n'}; keeping the image's libfabric"
    fi
elif [ "${EFA_UP:-false}" = "true" ] && [ "${RT_UPGRADE:-true}" = "true" ]; then
    echo "WARN: runtime upgrade did not happen, so the EFA userspace upgrade is skipped too"
fi
NEURON_RT_UPGRADE
)

neuron_pod_json() {
    jq -n \
        --arg name "$1" --arg node "$2" --arg role "$3" --arg script "$4" \
        --argjson env "$5" --argjson extra "$6" \
        --arg ns "${VERIFY_NAMESPACE}" --arg run "${NEURON_RUN_ID}" \
        --arg image "${VERIFY_NEURON_IMAGE}" \
        --arg dev "${N_DEV}" --argjson efa "${N_EFA}" \
        --argjson deadline "$(( VERIFY_NEURON_TIMEOUT_SEC + 300 ))" '
    {
      apiVersion: "v1",
      kind: "Pod",
      metadata: {
        name: $name,
        namespace: $ns,
        labels: {app: "neuron-efa-verify", "verify-run": $run, "verify-role": $role}
      },
      spec: ({
        restartPolicy: "Never",
        nodeName: $node,
        activeDeadlineSeconds: $deadline,
        terminationGracePeriodSeconds: 5,
        tolerations: [{key: "aws.amazon.com/neuron", operator: "Exists", effect: "NoSchedule"}],
        containers: [({
          name: "verify",
          image: $image,
          imagePullPolicy: "IfNotPresent",
          command: ["/bin/bash", "-c", $script],
          env: $env,
          securityContext: {capabilities: {add: ["IPC_LOCK"]}},
          resources: {limits: ({"aws.amazon.com/neuron": $dev}
                               + (if $efa > 0 then {"vpc.amazonaws.com/efa": ($efa | tostring)} else {} end))},
          volumeMounts: [{name: "dshm", mountPath: "/dev/shm"}]
        } + ($extra.container // {}))],
        volumes: [{name: "dshm", emptyDir: {medium: "Memory", sizeLimit: "8Gi"}}]
      } + ($extra.spec // {}))
    }'
}

# Pick the target node with the same logic as run_single_node.
neuron_pick_single_node() {
    local target_node
    if [ -n "${EXPLICIT_NODE}" ]; then
        target_node="${EXPLICIT_NODE}"
        if ! kubectl get node "${target_node}" &>/dev/null; then
            echo "ERROR: explicit node '${target_node}' not found in cluster" >&2
            exit 1
        fi
    else
        target_node=$(ready_nodes_in_ng | head -1)
        if [ -z "${target_node}" ]; then
            echo "ERROR: no Ready nodes found in nodegroup '${NG_NAME}'" >&2
            echo "       (try: kubectl get nodes -l eks.amazonaws.com/nodegroup=${NG_NAME})" >&2
            exit 1
        fi
    fi
    echo "${target_node}"
}

# --------------------------------------------------------------------
# Neuron mode 1: SINGLE NODE
# --------------------------------------------------------------------
run_single_node_neuron() {
    local target_node
    target_node=$(neuron_pick_single_node)
    local N_DEV="" N_CORE="" N_EFA="" N_ITYPE=""
    read_neuron_resources "${target_node}" N
    preflight_neuron "${target_node}" "${N_DEV}" "${N_ITYPE}"

    echo "=== Neuron + EFA Verification (single-node) ==="
    echo "Cluster:        ${CLUSTER_NAME}"
    echo "Nodegroup:      ${NG_NAME}"
    echo "Node:           ${target_node}"
    echo "Instance:       ${N_ITYPE:-<unknown>}"
    echo "Neuron devices: ${N_DEV}"
    echo "NeuronCores:    ${N_CORE} (allocatable)"
    echo "EFA NICs:       ${N_EFA}"
    echo "Image:          ${VERIFY_NEURON_IMAGE}"
    echo ""

    NEURON_RUN_ID="$(date +%s)-${RANDOM}"
    local pod_name="neuron-efa-verify-${NEURON_RUN_ID}"
    neuron_install_traps

    local script
    IFS= read -r -d '' script <<'NEURON_CHECKS' || true
set -uo pipefail
# Keep the image's PATH first; append the usual Neuron / EFA tool dirs.
export PATH="${PATH}:/opt/aws/neuron/bin:/opt/amazon/efa/bin"

pass=0
fail=0
warn=0
check() {
    local name="$1"
    local cmd="$2"
    echo ""
    echo "----- $name -----"
    if eval "$cmd"; then
        echo "RESULT: PASS  $name"
        pass=$((pass+1))
    else
        echo "RESULT: FAIL  $name"
        fail=$((fail+1))
    fi
}
# neuron-ls -j: JSON array of devices, each with nc_count.
neuron_ls_field() {
    neuron-ls -j 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
if isinstance(d, dict):
    d = d.get("neuron_devices", d.get("devices", []))
print(len(d) if sys.argv[1] == "count" else sum(int(x.get("nc_count", 0)) for x in d))
' "$1"
}

echo "============================================================"
echo " Neuron + EFA Verification on $(hostname)"
echo "============================================================"

check "neuron-ls reports ${DEV} Neuron device(s)" \
    'neuron-ls 2>&1 | head -40; [ "$(neuron_ls_field count)" = "${DEV}" ]'

check "/dev/neuron[0-9]* device nodes match device count" \
    'ls -d /dev/neuron[0-9]* && [ "$(ls -d /dev/neuron[0-9]* 2>/dev/null | wc -l)" -eq "${DEV}" ]'

VIS=$(neuron_ls_field cores 2>/dev/null || true)
echo ""
echo "----- visible NeuronCores vs allocatable aws.amazon.com/neuroncore -----"
if [ -n "${VIS}" ] && [ "${VIS}" = "${CORE}" ]; then
    echo "RESULT: PASS  neuron-ls nc_count=${VIS} == allocatable neuroncore=${CORE}"
    pass=$((pass+1))
else
    echo "RESULT: WARN  neuron-ls nc_count=${VIS:-?} vs allocatable neuroncore=${CORE}"
    echo "              (LNC: the device plugin and neuron-ls can count logical cores differently)"
    warn=$((warn+1))
fi

if [ "${EFA}" -gt 0 ]; then
    check "fi_info -p efa lists >= ${EFA} provider entry/entries" \
        '[ "$(fi_info -p efa 2>/dev/null | grep -c "provider: efa")" -ge "${EFA}" ]'
    check "/dev/infiniband/uverbs* device count matches EFA count" \
        'ls /dev/infiniband/uverbs* && [ "$(ls /dev/infiniband/uverbs* 2>/dev/null | wc -l)" -eq "${EFA}" ]'
else
    echo ""
    echo "----- EFA checks skipped (vpc.amazonaws.com/efa=0 on this node) -----"
fi

echo ""
echo "----- info: host driver / DLC runtime -----"
echo "neuron driver (host /sys/module/neuron/version): $(cat /sys/module/neuron/version 2>/dev/null || echo '?')"
dpkg-query -W aws-neuronx-runtime-lib 2>/dev/null || echo "aws-neuronx-runtime-lib: ?"

RANKS="${VIS:-${CORE}}"
# --check: fill with pseudo-random data and validate every result against a
# golden (without it the buffers are zero-filled and never compared). Does
# not change time / algbw / busbw. A mismatch prints "N errors found".
# "--check random" names the mode explicitly: -c/--check is an optional-value
# flag (nargs='?', choices random|all_ones), so a bare "--check allr" would
# swallow the operation as the mode and nccom-test would exit 2.
check "single-node nccom-test all-reduce --check (${RANKS} ranks, 8B -> 64MB)" \
    '[ "${RANKS:-0}" -gt 0 ] && OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1 nccom-test -r "${RANKS}" -b 8 -e 64MB -f 2 -n 5 -w 2 -d fp32 --check random allr > /tmp/nccom-single.log 2>&1; nrc=$?; tail -25 /tmp/nccom-single.log; [ "${nrc}" -eq 0 ] && ! { grep -iE "errors? found" /tmp/nccom-single.log | grep -viqE "(^|[^0-9])0 errors? found|no errors? found"; }'

echo ""
echo "============================================================"
echo " Summary: $pass passed, $fail failed, $warn warning(s)"
echo "============================================================"
exit $fail
NEURON_CHECKS

    script="${NEURON_RT_UPGRADE_SNIPPET}
${script}"

    local env_json
    env_json=$(jq -n --arg dev "${N_DEV}" --arg core "${N_CORE}" --arg efa "${N_EFA}" \
        --arg up "${VERIFY_NEURON_RUNTIME_UPGRADE}" \
        '[{name: "DEV", value: $dev}, {name: "CORE", value: $core}, {name: "EFA", value: $efa},
          {name: "RT_UPGRADE", value: $up}]')

    echo "Launching verification Pod ${VERIFY_NAMESPACE}/${pod_name}..."
    neuron_pod_json "${pod_name}" "${target_node}" single "${script}" "${env_json}" '{}' \
        | kubectl apply -f -

    echo ""
    echo "Waiting for Pod to finish (timeout ${VERIFY_NEURON_TIMEOUT_SEC}s; first DLC pull is slow)..."
    local deadline=$(( $(date +%s) + VERIFY_NEURON_TIMEOUT_SEC ))
    local wrc=0
    wait_pod_terminal "${pod_name}" "${deadline}" || wrc=$?

    echo ""
    echo "=== Pod logs ==="
    kubectl logs -n "${VERIFY_NAMESPACE}" "${pod_name}" --follow=false 2>&1 || true

    echo ""
    local pod_phase pod_exit
    pod_phase=$(kubectl get pod -n "${VERIFY_NAMESPACE}" "${pod_name}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    pod_exit=$(kubectl get pod -n "${VERIFY_NAMESPACE}" "${pod_name}" \
        -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "")
    echo "${pod_name}: phase=${pod_phase} exit=${pod_exit:-<n/a>}"
    echo ""
    if [ "${wrc}" -eq 0 ] && [ "${pod_phase}" = "Succeeded" ] && [ "${pod_exit}" = "0" ]; then
        echo "✅ Single-node Neuron verification PASSED on ${target_node}"
        exit 0
    else
        echo "❌ Single-node Neuron verification FAILED on ${target_node}"
        diagnose_pod "${pod_name}"
        exit 1
    fi
}

# --------------------------------------------------------------------
# Neuron mode 2: MULTI NODE (nccom-test all-reduce across N nodes)
# --------------------------------------------------------------------
run_multi_node_neuron() {
    echo "=== Neuron + EFA Verification (multi-node, ${MULTI_N} nodes) ==="
    echo "Cluster:    ${CLUSTER_NAME}"
    echo "Nodegroup:  ${NG_NAME}"

    command -v ssh-keygen >/dev/null 2>&1 || {
        echo "ERROR: missing dependency: ssh-keygen" >&2; exit 1
    }

    # Pick MULTI_N distinct Ready nodes (same as run_multi_node)
    local nodes_arr=()
    while IFS= read -r line; do
        [ -n "$line" ] && nodes_arr+=("$line")
    done < <(ready_nodes_in_ng | head -"${MULTI_N}")

    if [ "${#nodes_arr[@]}" -lt "${MULTI_N}" ]; then
        echo "ERROR: only ${#nodes_arr[@]} Ready node(s) in NG '${NG_NAME}', need ${MULTI_N}" >&2
        echo "       (try: kubectl get nodes -l eks.amazonaws.com/nodegroup=${NG_NAME})" >&2
        exit 1
    fi

    # Homogeneity guard: every node must match node 0 (type, devices, EFA).
    local N_DEV="" N_CORE="" N_EFA="" N_ITYPE=""
    local T_DEV="" T_CORE="" T_EFA="" T_ITYPE=""
    local i rows=() mismatch=0
    read_neuron_resources "${nodes_arr[0]}" N
    for i in "${!nodes_arr[@]}"; do
        read_neuron_resources "${nodes_arr[$i]}" T
        rows+=("$(printf '  %-3s %-55s %-16s neuron=%-3s neuroncore=%-4s efa=%s' \
            "${i}" "${nodes_arr[$i]}" "${T_ITYPE:-?}" "${T_DEV}" "${T_CORE}" "${T_EFA}")")
        if [ "${T_ITYPE}" != "${N_ITYPE}" ] || [ "${T_DEV}" != "${N_DEV}" ] || [ "${T_EFA}" != "${N_EFA}" ]; then
            mismatch=1
        fi
    done
    if [ "${mismatch}" -ne 0 ]; then
        echo "ERROR: nodes are not homogeneous (instance type / Neuron devices / EFA must match):" >&2
        printf '%s\n' "${rows[@]}" >&2
        exit 1
    fi

    preflight_neuron "${nodes_arr[0]}" "${N_DEV}" "${N_ITYPE}"
    case "${N_ITYPE}" in
        inf*)
            echo "ERROR: ${N_ITYPE}: multi-node nccom-test is Trn1/Trn2-only (Inferentia is single-node only)." >&2
            echo "       Run single-node mode instead: $0 ${NG_NAME}" >&2
            exit 1
            ;;
    esac
    if [ "${N_EFA}" -le 0 ]; then
        echo "ERROR: ${N_ITYPE:-node} advertises 0 EFA (vpc.amazonaws.com/efa) — cross-node nccom-test needs EFA." >&2
        echo "       Check ds/aws-efa-k8s-device-plugin-neuron in kube-system (install_efa_device_plugin = true?)" >&2
        echo "       and that the instance type supports EFA (trn1.32xlarge / trn1n.32xlarge / trn2.48xlarge)." >&2
        exit 1
    fi

    echo "Instance:          ${N_ITYPE}"
    echo "Per-node devices:  ${N_DEV} (aws.amazon.com/neuron)"
    echo "Per-node cores:    ${N_CORE} (allocatable aws.amazon.com/neuroncore)"
    echo "Per-node EFAs:     ${N_EFA}"
    echo "Image:             ${VERIFY_NEURON_IMAGE}"
    echo ""
    printf '%s\n' "${rows[@]}"
    echo ""

    NEURON_RUN_ID="$(date +%s)-${RANDOM}"
    local svc="nccom-mpi-${NEURON_RUN_ID}"
    local launcher_pod="${svc}-launcher"
    neuron_install_traps

    # Headless Service: stable pod DNS (hostname/subdomain). Not a listener
    # by itself; ClusterIP None, in-cluster only.
    jq -n --arg name "${svc}" --arg ns "${VERIFY_NAMESPACE}" --arg run "${NEURON_RUN_ID}" '
    {apiVersion: "v1", kind: "Service",
     metadata: {name: $name, namespace: $ns, labels: {app: "neuron-efa-verify", "verify-run": $run}},
     spec: {clusterIP: "None", publishNotReadyAddresses: true,
            selector: {"verify-run": $run},
            ports: [{name: "ssh", port: 2222, targetPort: 2222, protocol: "TCP"}]}}' \
        | kubectl apply -f -

    # Ephemeral ed25519 keypair (deleted locally right after the Secret
    # apply; cleanup_neuron also removes it on interrupt / failure). The private
    # key goes into a Secret (labelled verify-run, removed by cleanup_neuron)
    # mounted 0400 into the launcher only — never into a Pod spec / env,
    # which `get pods` (e.g. the built-in `view` role) could read. jq reads
    # the key from the file (--rawfile), so it never appears in argv.
    local tmpdir pub_key ssh_secret="${svc}-ssh"
    # Registered in NEURON_KEY_TMPDIR (EXIT trap already installed above)
    # before the key is generated.
    NEURON_KEY_TMPDIR=$(mktemp -d)
    tmpdir="${NEURON_KEY_TMPDIR}"
    ssh-keygen -t ed25519 -N "" -C "neuron-verify-${NEURON_RUN_ID}" -f "${tmpdir}/id_ed25519" -q
    pub_key=$(cat "${tmpdir}/id_ed25519.pub")
    local secret_rc=0
    jq -n --arg name "${ssh_secret}" --arg ns "${VERIFY_NAMESPACE}" --arg run "${NEURON_RUN_ID}" \
        --rawfile key "${tmpdir}/id_ed25519" '
    {apiVersion: "v1", kind: "Secret", type: "Opaque",
     metadata: {name: $name, namespace: $ns, labels: {app: "neuron-efa-verify", "verify-run": $run}},
     data: {id_ed25519: ($key | @base64)}}' \
        | kubectl apply -f - || secret_rc=$?
    rm -rf "${tmpdir}"
    NEURON_KEY_TMPDIR=""
    if [ "${secret_rc}" -ne 0 ]; then
        echo "ERROR: could not create Secret ${VERIFY_NAMESPACE}/${ssh_secret} (needs create secrets in ${VERIFY_NAMESPACE})" >&2
        exit 1
    fi

    # sshd sessions do not inherit the container env: the worker snapshots
    # the relevant variables into ~/.ssh/environment (PermitUserEnvironment)
    # so Open MPI's remote daemons see the image PATH, FI_* and the device
    # plugin's AWS_NEURON_* / NEURON_* settings.
    local worker_script
    IFS= read -r -d '' worker_script <<'NEURON_WORKER' || true
set -e
mkdir -p /run/sshd /root/.ssh
chmod 700 /root/.ssh
echo "${PUB}" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
env | grep -E '^(PATH|LD_LIBRARY_PATH|FI_|CCOM_|NEURON_|AWS_NEURON_|OMPI_)' > /root/.ssh/environment || true
ssh-keygen -A
exec /usr/sbin/sshd -D -e -p 2222 -o PermitUserEnvironment=yes
NEURON_WORKER
    # Upgrade BEFORE sshd starts: the readiness probe (tcp :2222) then only
    # passes once this worker's runtime matches the launcher's.
    worker_script="${NEURON_RT_UPGRADE_SNIPPET}
${worker_script}"

    local common_env
    common_env=$(jq -n --arg pub "${pub_key}" --arg up "${VERIFY_NEURON_RUNTIME_UPGRADE}" '[
        {name: "PUB", value: $pub},
        {name: "RT_UPGRADE", value: $up},
        {name: "EFA_UP", value: $up},
        {name: "FI_PROVIDER", value: "efa"},
        {name: "FI_EFA_USE_DEVICE_RDMA", value: "1"},
        {name: "FI_EFA_FORK_SAFE", value: "1"},
        {name: "CCOM_SOCKET_IFNAME", value: "eth0"}
    ]')

    local deadline=$(( $(date +%s) + VERIFY_NEURON_TIMEOUT_SEC ))

    # ----- Pre-pull on node 0, concurrently with the workers -----
    # The launcher (node 0) is created only after the workers are Ready and
    # their pod IPs are known; without this its ~15 GB DLC pull would start
    # only then, doubling the wall time under the one shared deadline. The
    # pre-pull pod requests no Neuron / EFA resources (it never holds the
    # devices the launcher needs), runs `true` and carries the verify-run
    # label, so cleanup_neuron removes it.
    local prepull_pod="${svc}-prepull"
    neuron_pod_json "${prepull_pod}" "${nodes_arr[0]}" prepull "true" "[]" \
        '{"spec": {"volumes": []}, "container": {"resources": {}, "volumeMounts": [], "securityContext": {}}}' \
        | kubectl apply -f -

    # ----- Workers (index 1..N-1): sshd only -----
    local worker_pods=()
    for i in "${!nodes_arr[@]}"; do
        [ "${i}" -eq 0 ] && continue
        local wpod="${svc}-w${i}"
        worker_pods+=("${wpod}")
        neuron_pod_json "${wpod}" "${nodes_arr[$i]}" worker "${worker_script}" "${common_env}" \
            "$(jq -n --arg h "${wpod}" --arg s "${svc}" '{
                spec: {hostname: $h, subdomain: $s},
                container: {ports: [{name: "ssh", containerPort: 2222, protocol: "TCP"}],
                            readinessProbe: {tcpSocket: {port: 2222}, periodSeconds: 5}}}')" \
            | kubectl apply -f -
    done

    echo ""
    echo "Waiting for ${#worker_pods[@]} worker(s) to be Ready (shared timeout ${VERIFY_NEURON_TIMEOUT_SEC}s; first DLC pull is slow)..."
    local wpod wrc failed=0
    for wpod in "${worker_pods[@]}"; do
        wrc=0
        wait_pod_ready "${wpod}" "${deadline}" || wrc=$?
        if [ "${wrc}" -ne 0 ]; then
            failed=1
            diagnose_pod "${wpod}"
        else
            echo "  ${wpod}: Ready"
        fi
    done
    if [ "${failed}" -ne 0 ]; then
        echo ""
        echo "❌ Multi-node Neuron verification FAILED (worker pods not Ready)"
        exit 1
    fi

    echo "Waiting for the image pre-pull on ${nodes_arr[0]} (launcher node)..."
    local prc=0 prepull_phase
    wait_pod_terminal "${prepull_pod}" "${deadline}" || prc=$?
    prepull_phase=$(kubectl get pod -n "${VERIFY_NAMESPACE}" "${prepull_pod}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "${prc}" -ne 0 ] || [ "${prepull_phase}" != "Succeeded" ]; then
        diagnose_pod "${prepull_pod}"
        echo ""
        echo "❌ Multi-node Neuron verification FAILED (image pre-pull on ${nodes_arr[0]}: phase=${prepull_phase:-unknown})"
        exit 1
    fi
    echo "  ${prepull_pod}: image ready on ${nodes_arr[0]}"

    local worker_ips="" ip
    for wpod in "${worker_pods[@]}"; do
        ip=$(kubectl get pod -n "${VERIFY_NAMESPACE}" "${wpod}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)
        if [ -z "${ip}" ]; then
            echo "ERROR: ${wpod} has no pod IP" >&2
            exit 1
        fi
        worker_ips+="${ip} "
    done
    worker_ips="${worker_ips% }"
    echo "Worker IPs: ${worker_ips}"

    # ----- Launcher (index 0 on node 0): sshd + nccom-test driver -----
    local launcher_script
    IFS= read -r -d '' launcher_script <<'NEURON_LAUNCHER' || true
set -uo pipefail
export PATH="${PATH}:/opt/aws/neuron/bin:/opt/amazon/efa/bin"

mkdir -p /run/sshd /root/.ssh
chmod 700 /root/.ssh
echo "${PUB}" > /root/.ssh/authorized_keys
install -m 600 /etc/verify-ssh/id_ed25519 /root/.ssh/id_ed25519
chmod 600 /root/.ssh/authorized_keys
printf 'Host *\n    Port 2222\n    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null\n    LogLevel ERROR\n' > /root/.ssh/config
chmod 600 /root/.ssh/config
env | grep -E '^(PATH|LD_LIBRARY_PATH|FI_|CCOM_|NEURON_|AWS_NEURON_|OMPI_)' > /root/.ssh/environment || true
ssh-keygen -A >/dev/null 2>&1
# Local sshd too, in case Open MPI does not treat POD_IP as local.
/usr/sbin/sshd -e -p 2222 -o PermitUserEnvironment=yes || echo "WARN: local sshd did not start"

echo "Probing worker sshd on :2222 ..."
for ip in ${WORKER_IPS}; do
    ok=0
    for _ in $(seq 1 12); do
        if ssh -o BatchMode=yes -o ConnectTimeout=3 "root@${ip}" true 2>/dev/null; then
            ok=1
            break
        fi
        sleep 5
    done
    if [ "${ok}" -ne 1 ]; then
        echo "worker ${ip} sshd unreachable"
        exit 2
    fi
    echo "  ${ip}: ssh OK"
done

echo ""
echo "----- pre-flight: fi_info -p efa -----"
n_efa=$(fi_info -p efa 2>/dev/null | grep -c 'provider: efa' || true)
if [ "${n_efa:-0}" -lt 1 ]; then
    echo "FAIL  fi_info -p efa lists no EFA provider in the launcher pod"
    exit 3
fi
echo "PASS  fi_info -p efa: ${n_efa} entries"

CORES=$(neuron-ls -j 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
if isinstance(d, dict):
    d = d.get("neuron_devices", d.get("devices", []))
print(sum(int(x.get("nc_count", 0)) for x in d))
' 2>/dev/null || true)
[[ "${CORES}" =~ ^[1-9][0-9]*$ ]] || CORES="${CORE_ALLOC}"
RANKS=$(( CORES * N ))

echo ""
echo "============================================================"
echo " Multi-node nccom-test all-reduce"
echo " Hosts: ${POD_IP} ${WORKER_IPS}"
echo " Ranks: ${RANKS} (= ${CORES} cores x ${N} nodes)"
echo " NEURON_RT_ROOT_COMM_ID=${NEURON_RT_ROOT_COMM_ID}  FI_PROVIDER=${FI_PROVIDER}"
echo "============================================================"

# FI_PROVIDER=efa pins libfabric to the efa provider: no silent tcp /
# sockets fallback. The "efa" grep below is informational only.
# --check: pseudo-random input, every result validated against a golden and
# across ranks (without it the buffers are zero-filled and never compared,
# so corrupted data would still PASS). Does not change time / algbw / busbw;
# a mismatch prints "N errors found", gated below. The mode is named
# explicitly ("--check random allr"): a bare "--check allr" makes argparse
# take "allr" as the check mode and exit 2 before any collective runs.
# WORKER_IPS is intentionally unquoted (space-separated host list).
# shellcheck disable=SC2086
nccom-test -r "${RANKS}" -N "${N}" -b 8 -e 1GB -f 2 -n 20 -w 5 -d fp32 --check random allr \
    --hosts "${POD_IP}" ${WORKER_IPS} \
    --data-collector-host "${POD_IP}" --data-collector-port 60006 2>&1 \
    | tee /tmp/nccom-output.log
rc=${PIPESTATUS[0]}
echo ""
echo "nccom-test exit code: ${rc}"
[ "${rc}" -ne 0 ] && exit "${rc}"

echo ""
echo "----- post-run checks -----"
if grep -iE 'errors? found' /tmp/nccom-output.log | grep -viqE '(^|[^0-9])0 errors? found|no errors? found'; then
    echo "FAIL  nccom-test reported errors:"
    grep -iE 'errors? found' /tmp/nccom-output.log | head -5 | sed 's/^/    /'
    exit 4
fi
bw_line=$(grep -i 'Avg bus bandwidth' /tmp/nccom-output.log | head -1 || true)
if [ -z "${bw_line}" ]; then
    echo "FAIL  no 'Avg bus bandwidth' line in the nccom-test output"
    exit 5
fi
observed=$(echo "${bw_line##*:}" | tr -d ' \t' | sed -E 's/[^0-9.].*$//')
echo "PASS  ${bw_line}"
echo "INFO  lines mentioning efa (not used for pass/fail):"
grep -iE 'efa' /tmp/nccom-output.log | head -5 | sed 's/^/    /' || true

if [ "${BUSBW_THRESHOLD}" -gt 0 ] 2>/dev/null; then
    echo ""
    echo "Observed busbw: ${observed:-?} (threshold ${BUSBW_THRESHOLD} GB/s)"
    awk -v obs="${observed:-0}" -v thr="${BUSBW_THRESHOLD}" \
        'BEGIN { if (obs+0 >= thr+0) {print "PASS  busbw above threshold"; exit 0} else {print "FAIL  busbw below threshold"; exit 1} }' || exit 1
fi

echo ""
echo "============================================================"
echo " Multi-node nccom-test all-reduce SUCCEEDED"
echo "============================================================"
NEURON_LAUNCHER
    launcher_script="${NEURON_RT_UPGRADE_SNIPPET}
${launcher_script}"

    local launcher_env
    launcher_env=$(jq -n \
        --argjson common "${common_env}" \
        --arg ips "${worker_ips}" --arg n "${MULTI_N}" \
        --arg core "${N_CORE}" --arg port "${VERIFY_NEURON_COMM_PORT}" \
        --arg thr "${VERIFY_BUSBW_THRESHOLD}" '
        [{name: "POD_IP", valueFrom: {fieldRef: {fieldPath: "status.podIP"}}}]
        + $common
        + [
            {name: "WORKER_IPS", value: $ips},
            {name: "N", value: $n},
            {name: "CORE_ALLOC", value: $core},
            {name: "BUSBW_THRESHOLD", value: $thr},
            {name: "NEURON_RT_ROOT_COMM_ID", value: ("$(POD_IP):" + $port)},
            {name: "OMPI_ALLOW_RUN_AS_ROOT", value: "1"},
            {name: "OMPI_ALLOW_RUN_AS_ROOT_CONFIRM", value: "1"},
            {name: "OMPI_MCA_plm_rsh_args", value: "-p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"},
            {name: "OMPI_MCA_plm_rsh_no_tree_spawn", value: "1"}
          ]')
    # No OMPI_MCA_mca_base_env_list: nccom-test's own mpirun forwards its env
    # with -x (FI_*, CCOM_*, NEURON_RT_*), and Open MPI aborts when both
    # methods are used ("passing environment variables ... with both the -x
    # method and ... mca_base_env_list") — seen live as "Failure running
    # neuron-bench" for every size. Workers also get FI_* / CCOM_* / NEURON_*
    # from ~/.ssh/environment (PermitUserEnvironment).

    # The extra spec/container keys replace (not merge) the template's
    # volumes / volumeMounts, so /dev/shm is repeated here next to the
    # launcher-only ssh-key Secret (0400 = 256, read-only).
    neuron_pod_json "${launcher_pod}" "${nodes_arr[0]}" launcher "${launcher_script}" "${launcher_env}" \
        "$(jq -n --arg h "${svc}-w0" --arg s "${svc}" --arg sec "${ssh_secret}" '{
            spec: {hostname: $h, subdomain: $s,
                   volumes: [{name: "dshm", emptyDir: {medium: "Memory", sizeLimit: "8Gi"}},
                             {name: "ssh-key", secret: {secretName: $sec, defaultMode: 256}}]},
            container: {ports: [{name: "ssh", containerPort: 2222, protocol: "TCP"}],
                        volumeMounts: [{name: "dshm", mountPath: "/dev/shm"},
                                       {name: "ssh-key", mountPath: "/etc/verify-ssh", readOnly: true}]}}')" \
        | kubectl apply -f -

    echo ""
    echo "Waiting for launcher pod to complete (shared deadline; ${VERIFY_NEURON_TIMEOUT_SEC}s total)..."
    local lrc=0
    wait_pod_terminal "${launcher_pod}" "${deadline}" || lrc=$?

    echo ""
    echo "=== Launcher pod logs ==="
    kubectl logs -n "${VERIFY_NAMESPACE}" "${launcher_pod}" --follow=false 2>&1 || true

    echo ""
    local launcher_phase launcher_exit
    launcher_phase=$(kubectl get pod -n "${VERIFY_NAMESPACE}" "${launcher_pod}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    launcher_exit=$(kubectl get pod -n "${VERIFY_NAMESPACE}" "${launcher_pod}" \
        -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "")
    echo "${launcher_pod}: phase=${launcher_phase} exit=${launcher_exit:-<n/a>}"

    echo ""
    if [ "${lrc}" -eq 0 ] && [ "${launcher_phase}" = "Succeeded" ] && [ "${launcher_exit}" = "0" ]; then
        echo "✅ Multi-node Neuron verification PASSED across ${MULTI_N} nodes"
        echo "   This confirms cross-node EFA traffic (FI_PROVIDER=efa) and the GPU/Neuron SG self-rules work."
        exit 0
    else
        echo "❌ Multi-node Neuron verification FAILED"
        diagnose_pod "${launcher_pod}"
        echo ""
        echo "Common causes:"
        echo "  • Security group missing self-ingress or self-egress (the GPU SG is shared with"
        echo "    Neuron nodegroups): aws ec2 describe-security-groups --group-ids \$GPU_SG_ID"
        echo "  • Neuron EFA device plugin not running:"
        echo "    kubectl get ds -n kube-system aws-efa-k8s-device-plugin-neuron"
        echo "  • DLC Neuron runtime does not match the host aws-neuronx-dkms driver —"
        echo "    pick a matching DLC with VERIFY_NEURON_IMAGE=..."
        echo "  • LNC: a custom logical NeuronCore config changes the per-node core count"
        echo "  • Pod-to-pod TCP blocked on 2222 (ssh), ${VERIFY_NEURON_COMM_PORT} (comm id),"
        echo "    60006 (data collector) or Open MPI's ephemeral ports (NetworkPolicy / SG)"
        exit 1
    fi
}

# ====================================================================
# Dispatch
# ====================================================================
VENDOR="${VERIFY_VENDOR}"
if [ "${VENDOR}" = "auto" ]; then
    VENDOR=$(detect_vendor)
fi
case "${MODE}/${VENDOR}" in
    single/nvidia) run_single_node ;;
    multi/nvidia)  run_multi_node ;;
    single/neuron) run_single_node_neuron ;;
    multi/neuron)  run_multi_node_neuron ;;
esac
