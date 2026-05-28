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
        target_node=$(kubectl get nodes \
            -l "eks.amazonaws.com/nodegroup=${NG_NAME}" \
            -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status=="True")]}{.metadata.name}{"\n"}{end}' \
            2>/dev/null | head -1)
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
    done < <(kubectl get nodes \
        -l "eks.amazonaws.com/nodegroup=${NG_NAME}" \
        -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status=="True")]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null | head -"${MULTI_N}")

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
# Dispatch
# ====================================================================
case "${MODE}" in
    single) run_single_node ;;
    multi)  run_multi_node ;;
esac
