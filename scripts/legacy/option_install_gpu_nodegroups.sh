#!/bin/bash

set -e
set -o pipefail

export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "=== Create GPU Managed Node Groups with EFA Support ==="
echo ""
echo "This script creates GPU node groups using AWS Managed Node Groups"
echo "with pre-configured EFA + EFA-only interfaces in Launch Templates."
echo ""
echo "Supported GPU types:"
echo "  • p5.48xlarge:      1 EFA + 31 EFA-only (NetworkCardIndex 0-31)"
echo "  • p5en.48xlarge:    1 EFA + 15 EFA-only (NetworkCardIndex 0-15)"
echo "  • p6-b200.48xlarge: 1 EFA + 7 EFA-only  (NetworkCardIndex 0-7)"
echo "  • p6-b300.48xlarge: 16 EFA-only on NIC 1-16 (NIC 0 = ENA only; MaxEFA=16)"
echo "  • g6e.8/12/16xlarge: 1 EFA on NIC 0 (single NIC, EFA-capable)"
echo "  • g6e.24xlarge:     1 EFA + 1 EFA-only  (NetworkCardIndex 0-1)"
echo "  • g6e.48xlarge:     1 EFA + 3 EFA-only  (NetworkCardIndex 0-3)"
echo "  • g7e.8/12xlarge:   1 EFA on NIC 0 (single NIC, EFAv4)"
echo "  • g7e.24xlarge:     1 EFA + 1 EFA-only  (NetworkCardIndex 0-1)"
echo "  • g7e.48xlarge:     1 EFA + 3 EFA-only  (NetworkCardIndex 0-3)"
echo ""
echo "Pricing options (mutually exclusive - choose ONE):"
echo "  • On-Demand:      Standard on-demand pricing (DEPLOY_GPU_OD=true)"
echo "  • Spot:           Cost-effective for fault-tolerant workloads (DEPLOY_GPU_SPOT=true)"
echo "  • ODCR:           Guaranteed capacity, on-demand pricing (DEPLOY_GPU_ODCR=true)"
echo "  • Capacity Block: Time-limited reserved capacity (DEPLOY_GPU_CB=true)"
echo ""
echo "EC2 topology awareness (default: inventory mode):"
echo "  After NG is ACTIVE, the topology.k8s.aws/network-node-layer-N labels"
echo "  written by cloud-controller-manager are read and a per-NG inventory"
echo "  is printed, grouped by the bottom-layer network node (the network"
echo "  node connected to each instance, per AWS docs). Multi-node GPU"
echo "  workloads select same-bottom-layer subsets via nodeAffinity on the"
echo "  AWS-native labels. No placement group is created by default —"
echo "  2026-05-03 empirical data (p5/p5en, 3 independent runs, 3 AZs)"
echo "  showed cluster PG does NOT guarantee that all instances share the"
echo "  bottom-layer network node."
echo "  Override: GPU_PG_STRATEGY={cluster|none}, GPU_TOPOLOGY_MODE={inventory|gate|both|off}"
echo ""

# 1. Load environment
source "${SCRIPT_DIR}/../0_setup_env.sh"

# Load topology inventory library (source so print_topology_inventory is
# available after NG creation).
# shellcheck source=topology_inventory_lib.sh
source "${SCRIPT_DIR}/../topology_inventory_lib.sh"

# Load instance architecture detection helpers. Used to pick the correct
# GPU AMI variant (x86_64 vs arm64) instead of hard-coding x86_64.
# shellcheck source=instance_arch_lib.sh
source "${SCRIPT_DIR}/instance_arch_lib.sh"
declare -F detect_instance_arch >/dev/null || {
    echo "ERROR: instance_arch_lib.sh did not export detect_instance_arch()" >&2
    exit 1
}

# Load NVMe data-disk detection snippet (shared with system nodegroup).
# Picks the EBS data disk by device model so we never stripe containerd
# onto ephemeral Instance Store on *d / *gd / i4g-class GPU families.
# shellcheck source=disk_detection_lib.sh
source "${SCRIPT_DIR}/disk_detection_lib.sh"
if [ -z "${EBS_DATA_DISK_DETECT_SNIPPET:-}" ]; then
    echo "ERROR: disk_detection_lib.sh did not export EBS_DATA_DISK_DETECT_SNIPPET" >&2
    echo "       The data-disk detection snippet would be empty in user-data, breaking LVM setup." >&2
    exit 1
fi

export KUBECONFIG="${HOME:-/root}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# Check dependencies
echo ""
echo "Checking required dependencies..."
MISSING_DEPS=()
command -v kubectl >/dev/null 2>&1 || MISSING_DEPS+=("kubectl")
command -v jq >/dev/null 2>&1 || MISSING_DEPS+=("jq")
command -v aws >/dev/null 2>&1 || MISSING_DEPS+=("aws cli")
command -v python3 >/dev/null 2>&1 || MISSING_DEPS+=("python3")
command -v helm >/dev/null 2>&1 || MISSING_DEPS+=("helm")

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "ERROR: Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do
        echo "  - $dep"
    done
    exit 1
fi
echo "All required dependencies are installed"

# 2. Verify cluster exists
echo ""
echo "Verifying EKS cluster exists..."
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "ERROR: EKS cluster '${CLUSTER_NAME}' not found in region '${AWS_REGION}'"
    exit 1
fi

verify_kubectl_context
echo ""

# ===================================================================
# Configuration
# ===================================================================

GPU_INSTANCE_TYPES="${GPU_INSTANCE_TYPES:-p5.48xlarge,p5en.48xlarge,p6-b200.48xlarge,p6-b300.48xlarge,g7e.48xlarge}"
GPU_NODE_DESIRED_CAPACITY="${GPU_NODE_DESIRED_CAPACITY:-0}"
GPU_NODE_MIN_SIZE="${GPU_NODE_MIN_SIZE:-0}"
GPU_NODE_MAX_SIZE="${GPU_NODE_MAX_SIZE:-8}"
GPU_NODE_ROOT_VOLUME_SIZE="${GPU_NODE_ROOT_VOLUME_SIZE:-50}"
GPU_NODE_DATA_VOLUME_SIZE="${GPU_NODE_DATA_VOLUME_SIZE:-100}"

DEPLOY_GPU_OD="${DEPLOY_GPU_OD:-false}"
DEPLOY_GPU_SPOT="${DEPLOY_GPU_SPOT:-true}"
DEPLOY_GPU_ODCR="${DEPLOY_GPU_ODCR:-false}"
DEPLOY_GPU_CB="${DEPLOY_GPU_CB:-false}"

# Install the full EFA userspace (libfabric-aws + openmpi5-aws + utils
# under /opt/amazon/efa/) in the node userdata. The EKS GPU AMI ships
# only kernel-side EFA; this adds `fi_info`, `fi_pingpong`, etc. for
# host-level diagnostics and for workloads that rely on host libfabric.
# Discovered 2026-05-03 on p5 usw2-az1 that the AMI alone gives no
# /opt/amazon/efa/ — same as the long-noted Ohio p5en gap.
GPU_INSTALL_EFA_USERSPACE="${GPU_INSTALL_EFA_USERSPACE:-true}"

# Pin a specific aws-efa-installer tarball so node bringup is reproducible
# across time. Bump after smoke-testing on a fresh node. Empty = "latest"
# (rolls forward — breaks reproducibility, do not use in production).
GPU_EFA_INSTALLER_VERSION="${GPU_EFA_INSTALLER_VERSION:-1.48.0}"

# ------------------------------------------------------------
# Nodegroup suffix + AZ narrowing (for multi-run coexistence)
# ------------------------------------------------------------
# GPU_NG_SUFFIX: optional suffix appended to NG/LT/PG names, e.g. "-az3-p3"
#   Lets multiple NGs of the same (gpu_type, purchase_option) coexist
#   without colliding. ODCR/CB paths already auto-suffix per reservation;
#   OD and Spot paths use this env.
GPU_NG_SUFFIX="${GPU_NG_SUFFIX:-}"

# GPU_TARGET_AZ: optional AZ suffix letter (a|b|c|d) to narrow deployments
#   to a single subnet. When set, OD and Spot paths use ONLY the matching
#   PRIVATE_SUBNET_${AZ}. Example: GPU_TARGET_AZ=c → uses PRIVATE_SUBNET_C.
#   When empty, multi-AZ behavior is preserved (old default).
GPU_TARGET_AZ="${GPU_TARGET_AZ:-}"

# ------------------------------------------------------------
# Placement Group — NOT recommended, default off
# ------------------------------------------------------------
# Empirical finding (2026-05-03, 3 independent runs on p5/p5en in 3
# different AZs): cluster-strategy placement groups do NOT guarantee
# that all instances share the bottom-layer network node. All 3 runs
# placed 2 instances in the same PG but they landed on different
# bottom-layer network nodes. PG only co-locates instances at one layer
# above the bottom in practice — which doesn't give the perf benefit
# that would justify its constraints (tighter capacity, possible
# InsufficientInstanceCapacity even when SPS=9).
#
# We therefore default to NO PG and rely on the topology inventory
# mode (see GPU_TOPOLOGY_MODE) to let workloads pick subsets that share
# the same bottom-layer network node.
#
# GPU_PG_STRATEGY:
#   none      (default) do not create or attach a placement group
#   cluster   try to force all nodes into a per-AZ cluster PG; NG will
#             fail if EC2 cannot fit nodes (rare but documented)
GPU_PG_STRATEGY="${GPU_PG_STRATEGY:-none}"
GPU_PG_NAME_PREFIX="${GPU_PG_NAME_PREFIX:-${CLUSTER_NAME}}"

# ------------------------------------------------------------
# Topology mode — what to do after NG is ACTIVE
# ------------------------------------------------------------
# GPU_TOPOLOGY_MODE:
#   inventory  (default) read AWS-native topology.k8s.aws/network-node-layer-N
#              labels and print a per-NG inventory grouped by bottom-layer
#              network node. Workloads pin themselves directly to those
#              labels via nodeAffinity. No fail.
#   gate       verify all nodes in the NG share the same network node at
#              the requested layer and honor GPU_TOPOLOGY_GATE; fail
#              strictly if mismatch (useful only with GPU_PG_STRATEGY=cluster).
#   both       run gate (in warn mode regardless of GPU_TOPOLOGY_GATE) AND
#              print inventory — diagnostic use.
#   off        skip topology checks entirely.
#
# GPU_TOPOLOGY_GATE:
#   strict  fail and scale NG to 0 on mismatch (only in gate/both modes)
#   warn    log a warning but continue
#
# GPU_TOPOLOGY_GATE_LAYER:
#   auto    (default) verify the bottom layer of each instance — i.e. the
#           AWS-native layer N where N == NetworkNodes length for the
#           instance type (3 for p5/p5en/g7e/etc., 4 for p6-b200/p6-b300).
#   <N>     verify the AWS-native layer N (1-based, top-down). Use this to
#           gate at a higher layer when the bottom layer is too tight.
GPU_TOPOLOGY_MODE="${GPU_TOPOLOGY_MODE:-inventory}"
GPU_TOPOLOGY_GATE="${GPU_TOPOLOGY_GATE:-strict}"
GPU_TOPOLOGY_GATE_LAYER="${GPU_TOPOLOGY_GATE_LAYER:-auto}"

# Reject deprecated GPU_TOPOLOGY_GATE_LEVEL early so old runs surface a
# clear error instead of silently using the wrong gate target.
if [ -n "${GPU_TOPOLOGY_GATE_LEVEL:-}" ]; then
    echo "ERROR: GPU_TOPOLOGY_GATE_LEVEL is deprecated; use GPU_TOPOLOGY_GATE_LAYER instead" >&2
    echo "       (set GPU_TOPOLOGY_GATE_LAYER=auto for the bottom layer of each instance," >&2
    echo "        or GPU_TOPOLOGY_GATE_LAYER=<N> for the top-down AWS-native layer N)" >&2
    exit 1
fi

# NVIDIA Kubernetes device plugin and other K8s GPU stack components are
# installed by option_install_gpu_stack.sh — this script no longer owns
# their version pins or helm releases. See that script for
# NVIDIA_DEVICE_PLUGIN_VERSION / EFA_DEVICE_PLUGIN_VERSION / GPU_STACK_MODE.

# Local NVMe Instance Store LVM configuration.
# When enabled, all Instance Store NVMe disks are striped into one VG/LV
# and mounted at ${GPU_LOCAL_LVM_MOUNT} (default /data) for scratch use
# (training checkpoints, shuffle, dataset cache, etc.).
# Instance Store is ephemeral: state is lost on instance stop/start, so the
# volume is re-initialized via a systemd oneshot on every boot rather than
# via /etc/fstab.
GPU_ENABLE_LOCAL_LVM="${GPU_ENABLE_LOCAL_LVM:-true}"
GPU_LOCAL_LVM_VG_NAME="${GPU_LOCAL_LVM_VG_NAME:-vg_local}"
GPU_LOCAL_LVM_LV_NAME="${GPU_LOCAL_LVM_LV_NAME:-lv_scratch}"
GPU_LOCAL_LVM_MOUNT="${GPU_LOCAL_LVM_MOUNT:-/data}"
GPU_LOCAL_LVM_FS="${GPU_LOCAL_LVM_FS:-xfs}"
GPU_LOCAL_LVM_STRIPE_SIZE_KB="${GPU_LOCAL_LVM_STRIPE_SIZE_KB:-256}"

# Validate: only one pricing option should be enabled (mutually exclusive)
ENABLED_COUNT=0
[ "${DEPLOY_GPU_OD}" = "true" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[ "${DEPLOY_GPU_SPOT}" = "true" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[ "${DEPLOY_GPU_ODCR}" = "true" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[ "${DEPLOY_GPU_CB}" = "true" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))

if [ "${ENABLED_COUNT}" -gt 1 ]; then
    echo "ERROR: Only ONE pricing option can be enabled at a time"
    echo "  DEPLOY_GPU_OD=${DEPLOY_GPU_OD}"
    echo "  DEPLOY_GPU_SPOT=${DEPLOY_GPU_SPOT}"
    echo "  DEPLOY_GPU_ODCR=${DEPLOY_GPU_ODCR}"
    echo "  DEPLOY_GPU_CB=${DEPLOY_GPU_CB}"
    echo ""
    echo "These are mutually exclusive deployment modes. Please enable only one."
    exit 1
fi

if [ "${ENABLED_COUNT}" -eq 0 ]; then
    echo "ERROR: At least one pricing option must be enabled"
    echo "Set one of: DEPLOY_GPU_OD=true, DEPLOY_GPU_SPOT=true, DEPLOY_GPU_ODCR=true, or DEPLOY_GPU_CB=true"
    exit 1
fi

# Get EFA-only network card count (excluding primary EFA card).
# Returns 0 for GPU instance types that don't expose EFA-only NICs (e.g.
# g5/g6/g6e single-GPU shapes, t-series GPU, inf). Those types still get
# a GPU node group — they just won't have multi-NIC EFA scaffolding.
get_efa_only_card_count() {
    local instance_type=$1
    case "$instance_type" in
        p5.48xlarge)      echo 31 ;;   # NetworkCardIndex 1-31
        p5en.48xlarge)    echo 15 ;;   # NetworkCardIndex 1-15
        p6-b200.48xlarge) echo 7 ;;    # NetworkCardIndex 1-7
        p6-b300.48xlarge) echo 16 ;;   # NetworkCardIndex 1-16
        # G6e (L40S) — EFA on 8xlarge+; multi-NIC starts at 24xlarge
        g6e.8xlarge)      echo 0 ;;    # 1 NIC, EFA on NIC0
        g6e.12xlarge)     echo 0 ;;    # 1 NIC, EFA on NIC0
        g6e.16xlarge)     echo 0 ;;    # 1 NIC, EFA on NIC0
        g6e.24xlarge)     echo 1 ;;    # NetworkCardIndex 1
        g6e.48xlarge)     echo 3 ;;    # NetworkCardIndex 1-3
        # G7e (RTX PRO 6000 Blackwell) — EFAv4 on 8xlarge+
        g7e.8xlarge)      echo 0 ;;    # 1 NIC, EFA on NIC0
        g7e.12xlarge)     echo 0 ;;    # 1 NIC, EFA on NIC0
        g7e.24xlarge)     echo 1 ;;    # NetworkCardIndex 1
        g7e.48xlarge)     echo 3 ;;    # NetworkCardIndex 1-3
        *)                echo 0 ;;
    esac
}

# Whether the primary NIC (NetworkCardIndex 0, DeviceIndex 0) supports EFA.
# Most EFA-capable types: yes. Special case: p6-b300 NIC 0 is ENA-only.
# Single-NIC EFA shapes (g6e.8/12/16xlarge, g7e.8/12xlarge) report
# efa_only_count=0 but DO support EFA on the primary NIC — distinguish them
# from truly-non-EFA types like g5.xlarge by checking against this list.
instance_supports_primary_efa() {
    local instance_type=$1
    case "$instance_type" in
        p5.48xlarge|p5en.48xlarge|p6-b200.48xlarge) return 0 ;;
        g6e.8xlarge|g6e.12xlarge|g6e.16xlarge|g6e.24xlarge|g6e.48xlarge) return 0 ;;
        g7e.8xlarge|g7e.12xlarge|g7e.24xlarge|g7e.48xlarge) return 0 ;;
        p6-b300.48xlarge) return 1 ;;   # NIC 0 = ENA only
        *) return 1 ;;
    esac
}

# Sanity-check whether a string looks like a GPU/accelerator instance type.
# Accepts any EC2 family prefix whose vendor uses it for accelerated compute:
#   p/g/trn/inf (NVIDIA GPU, AWS Trainium, AWS Inferentia).
# This is intentionally a loose check — EC2 family names are stable and we
# prefer to let a bad type fail at launch-template creation (clear AWS error)
# rather than silently skip it here.
is_gpu_instance_type() {
    local t=$1
    case "$t" in
        p[0-9]*|p[0-9]-*|g[0-9]*|g[0-9][a-z]*|trn[0-9]*|inf[0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

# Convert instance type to resource-safe name (replace dots with dashes)
get_resource_name() {
    echo "${1//./-}"
}

# ===================================================================
# Placement Group helpers
# ===================================================================
# Idempotently ensure a cluster-strategy placement group exists for
# (gpu_type, AZ, suffix). Echoes the PG name on stdout on success,
# or empty string if GPU_PG_STRATEGY=none.
#
# Args:
#   $1 gpu_type    e.g. p5en.48xlarge
#   $2 az          full zone name, e.g. us-west-2c
#   $3 suffix      optional, e.g. "-1"
ensure_cluster_pg() {
    local gpu_type=$1
    local az=$2
    local suffix=${3:-}

    if [ "${GPU_PG_STRATEGY}" = "none" ]; then
        echo ""
        return 0
    fi

    local resource_name=$(get_resource_name "$gpu_type")
    local pg_name="${GPU_PG_NAME_PREFIX}-${resource_name}-${az}${suffix}-cg"

    if aws ec2 describe-placement-groups \
        --region "${AWS_REGION}" \
        --group-names "${pg_name}" &>/dev/null; then
        echo "Placement group ${pg_name} already exists" >&2
    else
        echo "Creating cluster placement group: ${pg_name}" >&2
        aws ec2 create-placement-group \
            --region "${AWS_REGION}" \
            --group-name "${pg_name}" \
            --strategy cluster \
            --tag-specifications "ResourceType=placement-group,Tags=[{Key=Cluster,Value=${CLUSTER_NAME}},{Key=AZ,Value=${az}},{Key=gpu-instance-type,Value=${gpu_type}},{Key=managed-by,Value=eks-cluster-deployment},{Key=business,Value=middleware},{Key=resource,Value=eks}]" \
            >/dev/null
    fi

    echo "${pg_name}"
}

# Delete placement group if empty (idempotent; AWS will refuse if still used).
# Safe to call in teardown paths.
delete_cluster_pg_if_empty() {
    local pg_name=$1
    if [ -z "${pg_name}" ]; then
        return 0
    fi
    aws ec2 delete-placement-group \
        --region "${AWS_REGION}" \
        --group-name "${pg_name}" 2>/dev/null || \
        echo "  (placement group ${pg_name} still has instances or does not exist; skipped)" >&2
}

# Plan the PG for a nodegroup based on strategy and subnet list.
# Echoes PG name on stdout (empty = no PG).
# Cluster-strategy PGs are AZ-specific, so we only attach one when the
# target subnet list resolves to a single AZ. Multi-AZ calls get no PG
# and a warning — user should narrow subnets to get PG.
#
# Args:
#   $1 gpu_type
#   $2 purchase_option  (od|spot|odcr|cb)
#   $3 suffix
#   $4+ one or more subnet IDs
plan_pg_for_nodegroup() {
    local gpu_type=$1
    local purchase_option=$2
    local suffix=$3
    shift 3
    local subnets=("$@")

    if [ "${GPU_PG_STRATEGY}" = "none" ]; then
        echo ""
        return 0
    fi

    if [ ${#subnets[@]} -eq 0 ]; then
        echo ""
        return 0
    fi

    # Resolve AZ for each subnet; cluster PG only valid if all subnets in same AZ
    local azs=()
    for sn in "${subnets[@]}"; do
        local az
        az=$(aws ec2 describe-subnets \
            --region "${AWS_REGION}" \
            --subnet-ids "${sn}" \
            --query 'Subnets[0].AvailabilityZone' \
            --output text 2>/dev/null)
        if [ -n "${az}" ] && [ "${az}" != "None" ]; then
            azs+=("${az}")
        fi
    done

    local unique_azs
    unique_azs=$(printf '%s\n' "${azs[@]}" | sort -u)
    local unique_count
    # grep -c . counts non-empty lines (wc -l would count 1 for empty input
    # due to trailing newline from echo/printf, falsely triggering PG create
    # when all describe-subnets lookups failed)
    unique_count=$(printf '%s\n' "${azs[@]}" | grep -c . || true)

    if [ "${unique_count}" -eq 0 ]; then
        echo "  plan_pg: could not resolve any subnet to an AZ; skipping PG" >&2
        echo ""
        return 0
    fi
    if [ "${unique_count}" -ne 1 ]; then
        echo "  plan_pg: ${unique_count} distinct AZs in subnet list (${unique_azs//$'\n'/,}) — cluster PG requires single AZ; skipping PG" >&2
        echo ""
        return 0
    fi

    local az="${unique_azs}"
    # Full PG suffix includes purchase_option for uniqueness (od/spot/odcr/cb)
    local full_suffix="-${purchase_option}${suffix}"
    ensure_cluster_pg "${gpu_type}" "${az}" "${full_suffix}"
}

# ===================================================================
# Topology gate
# ===================================================================
# Verify all nodes in an EKS nodegroup share the same AWS-native network
# node at the requested layer. Reads topology.k8s.aws/network-node-layer-N
# labels written by cloud-controller-manager. AWS uses top-down ordering:
# layer-1 is the top, layer-N (N == NetworkNodes length) is the bottom
# layer connected to the instance.
#
# Args:
#   $1 ng_name   EKS nodegroup name
#   $2 gate      strict | warn | off
#   $3 layer     auto (= bottom layer of each instance) | <N> (1-based AWS layer)
verify_topology() {
    local ng_name=$1
    local gate=${2:-strict}
    local layer=${3:-auto}

    if [ "${gate}" = "off" ]; then
        return 0
    fi

    echo "Topology gate: verifying NG=${ng_name} at layer=${layer} (gate=${gate})"

    # cloud-controller-manager writes the topology labels asynchronously
    # after a node becomes Ready. When called right after NG goes ACTIVE
    # the labels may still be missing — wait briefly so the gate has
    # something to verify against.
    if ! _topo_wait_aws_topology_labels "${ng_name}"; then
        echo "  WARN: timed out waiting for AWS topology labels on NG ${ng_name}; skipping gate" >&2
        return 0
    fi

    # Pull every node in the NG that has at least one AWS topology label.
    local nodes_json
    nodes_json=$(kubectl get nodes \
        -l "eks.amazonaws.com/nodegroup=${ng_name},topology.k8s.aws/network-node-layer-1" \
        -o json 2>/dev/null)

    if [ -z "${nodes_json}" ]; then
        echo "  WARN: kubectl get nodes failed; skipping gate"
        return 0
    fi

    local num_nodes
    num_nodes=$(echo "${nodes_json}" | jq '.items | length')

    if [ "${num_nodes}" -eq 0 ]; then
        echo "  WARN: no nodes in NG ${ng_name} have AWS topology labels yet; skipping gate"
        return 0
    fi

    if [ "${num_nodes}" -lt 2 ]; then
        echo "  only ${num_nodes} node(s); topology gate trivially passes"
        return 0
    fi

    # Per-node topology view: top-down layers[] from AWS-native labels.
    local topo_json
    topo_json=$(echo "${nodes_json}" | jq '
      [.items[]
       | . as $node
       | ($node.metadata.labels
          | to_entries
          | map(select(.key | test("^topology\\.k8s\\.aws/network-node-layer-[0-9]+$")))
          | map({
              n: (.key | capture("network-node-layer-(?<n>[0-9]+)$") | .n | tonumber),
              v: .value
            })
          | sort_by(.n)
          | map(.v)) as $layers
       | {
           node:         $node.metadata.name,
           az:           ($node.metadata.labels["topology.kubernetes.io/zone"] // "unknown"),
           layers:       $layers,
           bottom_layer: ($layers | length)
         }
       | select(.bottom_layer > 0)]')

    # All nodes in a single managed NG run the same instance type, so
    # bottom_layer should be uniform — bail with WARN otherwise.
    local layer_counts
    layer_counts=$(echo "${topo_json}" | jq -r '[.[].bottom_layer] | unique | join(",")')
    local distinct_layer_counts
    distinct_layer_counts=$(echo "${layer_counts}" | tr ',' '\n' | wc -l)
    if [ "${distinct_layer_counts}" -ne 1 ]; then
        echo "  WARN: nodes report mixed layer counts (${layer_counts}); skipping gate"
        return 0
    fi

    local bottom_layer
    bottom_layer=$(echo "${topo_json}" | jq -r '.[0].bottom_layer')

    # Resolve `auto` → bottom layer of each instance.
    local layer_n
    if [ "${layer}" = "auto" ]; then
        layer_n=${bottom_layer}
    elif [[ "${layer}" =~ ^[1-9][0-9]*$ ]]; then
        layer_n=${layer}
    else
        echo "ERROR: invalid GPU_TOPOLOGY_GATE_LAYER='${layer}'"
        echo "       Expected: auto | <positive integer>"
        return 1
    fi

    if [ "${layer_n}" -lt 1 ] || [ "${layer_n}" -gt "${bottom_layer}" ]; then
        echo "  WARN: layer=${layer_n} out of range for instance type with ${bottom_layer} layers; skipping gate"
        return 0
    fi

    # Count unique values at AWS layer-N across all nodes.
    # layers[] is 0-indexed in jq; AWS layer-1 = layers[0].
    local unique_nodes
    unique_nodes=$(echo "${topo_json}" \
        | jq -r --argjson idx "$((layer_n - 1))" \
            '.[] | (.layers[$idx] // "__missing__")' \
        | sort -u)
    local unique_count
    unique_count=$(printf '%s\n' "${unique_nodes}" | grep -c . || true)

    if [ "${unique_count}" -eq 0 ]; then
        echo "  WARN: no values found at network-node-layer-${layer_n} across nodes; skipping gate"
        return 0
    fi

    # Operator-friendly map: top-down layer-N layout per node.
    echo "  Topology map (${bottom_layer} layers per instance, top-down):"
    echo "${topo_json}" \
        | jq -r '.[]
                 | "    \(.node)  AZ=\(.az)  "
                   + (.layers | to_entries | map("layer-\(.key + 1)=\(.value)") | join("  "))'

    if [ "${unique_count}" -gt 1 ]; then
        echo ""
        echo "  ❌ Topology gate FAILED: ${num_nodes} nodes spread across ${unique_count} distinct values at network-node-layer-${layer_n}"
        echo "     Unique values:"
        echo "${unique_nodes}" | sed 's/^/       /'
        echo ""

        case "${gate}" in
            strict)
                # Scale desired to 0 to release the misplaced capacity.
                # EKS update-nodegroup-config rejects maxSize=0 (min valid is 1),
                # so we keep maxSize=1 and only zero minSize+desiredSize.
                echo "  strict mode → scaling NG ${ng_name} desired=0 to release bad placement"
                aws eks update-nodegroup-config \
                    --cluster-name "${CLUSTER_NAME}" \
                    --nodegroup-name "${ng_name}" \
                    --region "${AWS_REGION}" \
                    --scaling-config minSize=0,maxSize=1,desiredSize=0 \
                    >/dev/null 2>&1 || \
                    echo "  WARN: failed to scale NG to 0; operator must do it manually"
                return 1
                ;;
            warn)
                echo "  warn mode → continuing despite topology mismatch"
                return 0
                ;;
        esac
    fi

    echo "  ✅ Topology gate PASSED: all ${num_nodes} node(s) share the same network-node-layer-${layer_n}"
    return 0
}

# ===================================================================
# IAM Role Creation
# ===================================================================

create_gpu_node_iam_role() {
    GPU_NODE_ROLE_NAME="GPUNodeRole-${CLUSTER_NAME}"
    GPU_INSTANCE_PROFILE_NAME="${GPU_NODE_ROLE_NAME}"

    if aws iam get-role --role-name "${GPU_NODE_ROLE_NAME}" &>/dev/null; then
        echo "IAM Role ${GPU_NODE_ROLE_NAME} already exists"
    else
        echo "Creating IAM Role: ${GPU_NODE_ROLE_NAME}"

        aws iam create-role \
            --role-name "${GPU_NODE_ROLE_NAME}" \
            --assume-role-policy-document '{
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": "ec2.amazonaws.com"},
                    "Action": "sts:AssumeRole"
                }]
            }' \
            --tags Key=Cluster,Value="${CLUSTER_NAME}" Key=Purpose,Value=gpu-nodes Key=business,Value=middleware Key=resource,Value=eks >/dev/null

        echo "IAM Role created"
    fi

    echo "Attaching required policies..."
    aws iam attach-role-policy --role-name "${GPU_NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" 2>/dev/null || true
    aws iam attach-role-policy --role-name "${GPU_NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" 2>/dev/null || true
    aws iam attach-role-policy --role-name "${GPU_NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" 2>/dev/null || true
    aws iam attach-role-policy --role-name "${GPU_NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true

    # Add ec2:DescribeInstances for nodeadm
    aws iam put-role-policy --role-name "${GPU_NODE_ROLE_NAME}" \
        --policy-name "NodeadmDescribeInstances" \
        --policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": ["ec2:DescribeInstances", "ec2:DescribeTags"],
                "Resource": "*"
            }]
        }'

    echo "IAM policies attached"

    # Add GPU Node Role to EKS access entries (required for nodes to join cluster)
    echo "Adding ${GPU_NODE_ROLE_NAME} to EKS access entries..."
    if aws eks describe-access-entry --cluster-name "${CLUSTER_NAME}" --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/${GPU_NODE_ROLE_NAME}" --region "${AWS_REGION}" &>/dev/null; then
        echo "EKS access entry for ${GPU_NODE_ROLE_NAME} already exists"
    else
        # Wait for IAM role to propagate globally before creating access entry
        echo "Waiting for IAM role to propagate (10 seconds)..."
        sleep 10

        local retry_count=0
        local max_retries=5
        while [ $retry_count -lt $max_retries ]; do
            if aws eks create-access-entry \
                --cluster-name "${CLUSTER_NAME}" \
                --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/${GPU_NODE_ROLE_NAME}" \
                --type EC2_LINUX \
                --region "${AWS_REGION}" 2>/dev/null; then
                echo "EKS access entry created for ${GPU_NODE_ROLE_NAME}"
                break
            fi
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                echo "IAM role not yet propagated, retrying in 10 seconds... ($retry_count/$max_retries)"
                sleep 10
            else
                echo "ERROR: Failed to create EKS access entry after $max_retries retries"
                exit 1
            fi
        done
    fi

    GPU_NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${GPU_NODE_ROLE_NAME}"
    echo "GPU Node Role ARN: ${GPU_NODE_ROLE_ARN}"
}

# ===================================================================
# Security Group
# ===================================================================

create_gpu_security_group() {
    GPU_SG_NAME="${CLUSTER_NAME}-gpu-node-sg"

    GPU_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${GPU_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
        --region "${AWS_REGION}" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null)

    if [ -n "${GPU_SG_ID}" ] && [ "${GPU_SG_ID}" != "None" ]; then
        echo "GPU Security Group already exists: ${GPU_SG_ID}"
    else
        echo "Creating GPU Security Group: ${GPU_SG_NAME}"

        GPU_SG_ID=$(aws ec2 create-security-group \
            --group-name "${GPU_SG_NAME}" \
            --description "Security group for GPU nodes with EFA" \
            --vpc-id "${VPC_ID}" \
            --region "${AWS_REGION}" \
            --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${GPU_SG_NAME}},{Key=Cluster,Value=${CLUSTER_NAME}},{Key=business,Value=middleware},{Key=resource,Value=eks}]" \
            --query 'GroupId' \
            --output text)

        echo "Created GPU Security Group: ${GPU_SG_ID}"
    fi

    # Self-referencing rules for EFA / NCCL cross-node traffic (all protocols).
    #
    # Per AWS EFA docs (https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start.html#efa-start-security):
    #   "An EFA requires a security group that allows all inbound and
    #    outbound traffic to and from the security group itself."
    #
    # New SGs default to 0.0.0.0/0 egress, which keeps EFA working today,
    # but org-level SCPs or compliance scanners often tighten the default
    # egress in production. Explicit self-egress guards against that drift
    # and keeps us aligned with AWS documentation.
    echo "Ensuring security group rules (EFA self-allow ingress + egress)..."

    local sg_result
    if sg_result=$(aws ec2 authorize-security-group-ingress \
        --group-id "${GPU_SG_ID}" \
        --protocol -1 \
        --source-group "${GPU_SG_ID}" \
        --region "${AWS_REGION}" 2>&1); then
        echo "  Self-ingress rule added"
    elif echo "${sg_result}" | grep -q "already exists"; then
        echo "  Self-ingress rule already exists"
    else
        echo "ERROR: Failed to add self-ingress rule to ${GPU_SG_ID}: ${sg_result}"
        exit 1
    fi

    # authorize-security-group-egress does NOT accept --source-group; use
    # --ip-permissions JSON form to express the self-reference.
    local egress_result
    if egress_result=$(aws ec2 authorize-security-group-egress \
        --group-id "${GPU_SG_ID}" \
        --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=${GPU_SG_ID}}]" \
        --region "${AWS_REGION}" 2>&1); then
        echo "  Self-egress rule added"
    elif echo "${egress_result}" | grep -q "already exists"; then
        echo "  Self-egress rule already exists"
    else
        echo "ERROR: Failed to add self-egress rule to ${GPU_SG_ID}: ${egress_result}"
        exit 1
    fi

    echo "GPU Security Group configured: ${GPU_SG_ID}"
}

# ===================================================================
# Launch Template Creation (EFA + EFA-only)
# ===================================================================

create_gpu_launch_template() {
    local gpu_type=$1
    local purchase_option=$2
    local capacity_reservation_id=${3:-}
    local suffix=${4:-}     # Optional suffix for multiple reservations (e.g., "-1", "-2")
    local pg_name=${5:-}    # Optional cluster placement-group name (empty = no PG)

    local instance_type="$gpu_type"
    local resource_name=$(get_resource_name "$gpu_type")
    local efa_only_count=$(get_efa_only_card_count "$gpu_type")
    local primary_efa="false"
    if instance_supports_primary_efa "$gpu_type"; then
        primary_efa="true"
    fi
    local lt_name="${CLUSTER_NAME}-gpu-${resource_name}-${purchase_option}${suffix}-lt"

    # Capacity Block requires InstanceType to be embedded in the Launch Template.
    # For other modes we leave it out so EKS managed node group accepts --instance-types.
    local embed_instance_type="false"
    if [ "${purchase_option}" = "cb" ]; then
        embed_instance_type="true"
    fi

    echo "Creating Launch Template: ${lt_name}"
    echo "  Instance Type: ${instance_type}"
    echo "  Embed InstanceType in LT: ${embed_instance_type}"
    echo "  EFA-only Cards: ${efa_only_count}"
    echo "  Primary NIC EFA: ${primary_efa}"
    if [[ -n "${EC2_KEY_NAME:-}" ]]; then
        echo "  EC2 Key Pair: ${EC2_KEY_NAME}"
    fi

    # Create userdata for node bootstrap (with LVM configuration)
    local userdata_file=$(mktemp /tmp/gpu-userdata.XXXXXX.txt)
    cat > "${userdata_file}" <<EOF_USERDATA
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: text/cloud-boothook; charset="us-ascii"

#!/bin/bash
# LVM Setup + EKS Bootstrap for GPU nodes
set -ex

exec > >(tee /var/log/gpu-node-bootstrap.log)
exec 2>&1

echo "=== Starting GPU Node LVM Setup ==="

# Stop containerd first
systemctl stop containerd || true

# Wait for EBS data disk to be available (max 60 seconds).
# GPU instance families routinely expose both EBS and Instance Store as
# unpartitioned NVMe devices, so we disambiguate by device model inside
# the shared detect_ebs_data_disk helper (see disk_detection_lib.sh).
${EBS_DATA_DISK_DETECT_SNIPPET}

echo "Waiting for EBS data disk..."
DISK=\$(detect_ebs_data_disk 60) || {
  echo "ERROR: No EBS data disk found after 60 seconds"
  echo "Available disks:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
  systemctl start containerd
  exit 1
}
echo "Found EBS data disk: \$DISK"

# Check if LVM already configured
if vgs vg_data &>/dev/null; then
  echo "LVM already configured, mounting..."
  mount /dev/vg_data/lv_containerd /var/lib/containerd || true
  systemctl start containerd
else
  # Install lvm2 and rsync
  echo "Installing lvm2 and rsync..."
  dnf install -y lvm2 rsync

  # Create LVM
  echo "Creating LVM on \$DISK..."
  pvcreate "\$DISK"
  vgcreate vg_data "\$DISK"
  lvcreate -l 100%VG -n lv_containerd vg_data
  mkfs.xfs /dev/vg_data/lv_containerd

  # Mount and migrate data (including pre-cached images from AMI)
  echo "Mounting and migrating containerd data..."
  mkdir -p /mnt/runtime/containerd
  mount /dev/vg_data/lv_containerd /mnt/runtime/containerd

  echo "Copying containerd data (including pre-cached pause image) from AMI..."
  rsync -aHAX /var/lib/containerd/ /mnt/runtime/containerd/ || true

  echo "Unmounting temporary directory"
  umount /mnt/runtime/containerd

  echo "Mounting LV to final destination: /var/lib/containerd"
  mount /dev/vg_data/lv_containerd /var/lib/containerd

  # Add to fstab
  grep -q "lv_containerd" /etc/fstab || \\
    echo "/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2" >> /etc/fstab

  echo "LVM setup completed successfully"
  df -h /var/lib/containerd
  vgs
  lvs

  # Start containerd
  systemctl start containerd
fi

echo "=== LVM Setup Complete ==="

# ============================================================
# Local Instance Store LVM Setup (scratch volume at ${GPU_LOCAL_LVM_MOUNT})
# ============================================================
# Instance Store is ephemeral (data lost on stop/start) so we do NOT
# write /etc/fstab. Instead we install a systemd oneshot that re-runs
# the init-or-remount logic on every boot.
LOCAL_SSD_TOTAL_GB=0
if [ "${GPU_ENABLE_LOCAL_LVM}" = "true" ]; then
  echo "=== Setting up Local Instance Store LVM ==="

  # Ensure lvm2 is present (usually already installed by EBS LVM step above)
  command -v lvcreate >/dev/null || dnf install -y lvm2

  install -m 0755 /dev/stdin /usr/local/sbin/setup-local-lvm.sh <<'SETUP_LOCAL_LVM'
#!/bin/bash
# Initialize or remount the local Instance Store LVM volume.
# Safe to run on every boot: if the VG/LV no longer exists (fresh stop/start),
# it rebuilds from scratch; otherwise it just remounts.
set -e

VG_NAME="__VG_NAME__"
LV_NAME="__LV_NAME__"
MOUNT_POINT="__MOUNT_POINT__"
FS_TYPE="__FS_TYPE__"
STRIPE_KB="__STRIPE_KB__"

log() { echo "[local-lvm] \$*"; }

# Collect Instance Store NVMe disks by model string (reliable across kernels)
LOCAL_DISKS=()
for sys_path in /sys/block/nvme*n1; do
  [ -e "\$sys_path" ] || continue
  model=\$(cat "\$sys_path/device/model" 2>/dev/null | xargs)
  case "\$model" in
    *"Instance Storage"*) LOCAL_DISKS+=("/dev/\$(basename "\$sys_path")") ;;
  esac
done

if [ \${#LOCAL_DISKS[@]} -eq 0 ]; then
  log "No Instance Store NVMe disks detected; skipping"
  exit 0
fi
log "Detected \${#LOCAL_DISKS[@]} local NVMe disk(s): \${LOCAL_DISKS[*]}"

mkdir -p "\$MOUNT_POINT"

# Fast path: already mounted
if mountpoint -q "\$MOUNT_POINT"; then
  log "\$MOUNT_POINT already mounted"
  exit 0
fi

# If VG still exists from a prior activation this boot, just mount
if vgs "\$VG_NAME" >/dev/null 2>&1; then
  log "VG \$VG_NAME already exists, activating and mounting"
  vgchange -ay "\$VG_NAME"
  mount -o noatime,nodiratime,discard "/dev/\$VG_NAME/\$LV_NAME" "\$MOUNT_POINT"
  exit 0
fi

# Fresh build
log "Building \$VG_NAME across \${#LOCAL_DISKS[@]} disk(s)"
for d in "\${LOCAL_DISKS[@]}"; do
  # Wipe any stale signatures (Instance Store carries over FS headers
  # from previous tenants on the same hardware slot in rare cases)
  wipefs -a "\$d" || true
  pvcreate -ff -y "\$d"
done

vgcreate "\$VG_NAME" "\${LOCAL_DISKS[@]}"

if [ \${#LOCAL_DISKS[@]} -gt 1 ]; then
  lvcreate -y -i "\${#LOCAL_DISKS[@]}" -I "\${STRIPE_KB}" -l 100%FREE -n "\$LV_NAME" "\$VG_NAME"
else
  lvcreate -y -l 100%FREE -n "\$LV_NAME" "\$VG_NAME"
fi

case "\$FS_TYPE" in
  xfs)  mkfs.xfs -f "/dev/\$VG_NAME/\$LV_NAME" ;;
  ext4) mkfs.ext4 -F "/dev/\$VG_NAME/\$LV_NAME" ;;
  *)    log "Unsupported FS: \$FS_TYPE"; exit 1 ;;
esac

mount -o noatime,nodiratime,discard "/dev/\$VG_NAME/\$LV_NAME" "\$MOUNT_POINT"
chmod 1777 "\$MOUNT_POINT"
log "Mounted /dev/\$VG_NAME/\$LV_NAME at \$MOUNT_POINT"
df -h "\$MOUNT_POINT"
SETUP_LOCAL_LVM

  # Substitute config into the script
  sed -i \\
    -e "s|__VG_NAME__|${GPU_LOCAL_LVM_VG_NAME}|g" \\
    -e "s|__LV_NAME__|${GPU_LOCAL_LVM_LV_NAME}|g" \\
    -e "s|__MOUNT_POINT__|${GPU_LOCAL_LVM_MOUNT}|g" \\
    -e "s|__FS_TYPE__|${GPU_LOCAL_LVM_FS}|g" \\
    -e "s|__STRIPE_KB__|${GPU_LOCAL_LVM_STRIPE_SIZE_KB}|g" \\
    /usr/local/sbin/setup-local-lvm.sh

  cat > /etc/systemd/system/setup-local-lvm.service <<'UNIT'
[Unit]
Description=Initialize and mount local NVMe Instance Store LVM
DefaultDependencies=no
After=local-fs-pre.target systemd-udev-settle.service
Before=local-fs.target kubelet.service containerd.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-local-lvm.sh
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=local-fs.target
UNIT

  systemctl daemon-reload
  systemctl enable --now setup-local-lvm.service

  # Compute total local SSD size for node label
  if [ -b "/dev/${GPU_LOCAL_LVM_VG_NAME}/${GPU_LOCAL_LVM_LV_NAME}" ]; then
    LOCAL_SSD_TOTAL_BYTES=\$(blockdev --getsize64 "/dev/${GPU_LOCAL_LVM_VG_NAME}/${GPU_LOCAL_LVM_LV_NAME}" 2>/dev/null || echo 0)
    LOCAL_SSD_TOTAL_GB=\$(( LOCAL_SSD_TOTAL_BYTES / 1024 / 1024 / 1024 ))
  fi
  echo "Local SSD total: \${LOCAL_SSD_TOTAL_GB} GB"
  echo "=== Local Instance Store LVM Setup Complete ==="
else
  echo "Local Instance Store LVM disabled (GPU_ENABLE_LOCAL_LVM=${GPU_ENABLE_LOCAL_LVM})"
fi

# Install lustre-client for FSx Lustre support
echo "=== Installing Lustre Client ==="
dnf install -y lustre-client
modprobe lustre || true
echo "Lustre client installed"

echo "=== Starting EKS Node Bootstrap ==="

# Build kubelet node-labels for local SSD awareness.
# NOTE: kubelet under NodeRestriction can only register labels outside the
# reserved kubernetes.io / k8s.io / node.kubernetes.io prefixes (except for a
# small hardcoded whitelist). So we use the unprefixed "local-ssd" namespace.
# Only emitted when local LVM actually materialized a volume.
NODE_LABEL_FLAGS=""
if [ "\${LOCAL_SSD_TOTAL_GB}" -gt 0 ]; then
  NODE_LABEL_FLAGS="--node-labels=local-ssd=true,local-ssd-size-gb=\${LOCAL_SSD_TOTAL_GB}"
fi

# ============================================================
# Create nodeadm config (with SystemdCgroup overlay)
# ============================================================
# nvidia-ctk's "runtime configure" step has been observed to drop
# SystemdCgroup=true from [runtimes.nvidia.options] when overlaying its
# config on top of nodeadm's template. Without it, kubelet (systemd
# cgroup driver) and runc (cgroupfs default) disagree and pod sandbox
# creation fails with:
#   FailedCreatePodSandBox: expected cgroupsPath to be of format
#   "slice:prefix:name" for systemd cgroups
#
# Fix: supply SystemdCgroup=true via NodeConfig.containerd.config so
# nodeadm merges it LAST, after both its own template and any nvidia-ctk
# overlay. Removable when nvidia-container-toolkit ships a fix.
mkdir -p /etc/eks/nodeadm.d
if [ -n "\${NODE_LABEL_FLAGS}" ]; then
cat > /etc/eks/nodeadm.d/nodeconfig.yaml <<NODECONFIG
---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${CLUSTER_NAME}
    apiServerEndpoint: ${CLUSTER_ENDPOINT}
    certificateAuthority: ${CLUSTER_CA}
    cidr: ${SERVICE_IPV4_CIDR}
  kubelet:
    flags:
      - "\${NODE_LABEL_FLAGS}"
  containerd:
    config: |
      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.nvidia.options]
      SystemdCgroup = true
NODECONFIG
else
cat > /etc/eks/nodeadm.d/nodeconfig.yaml <<NODECONFIG
---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${CLUSTER_NAME}
    apiServerEndpoint: ${CLUSTER_ENDPOINT}
    certificateAuthority: ${CLUSTER_CA}
    cidr: ${SERVICE_IPV4_CIDR}
  containerd:
    config: |
      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.nvidia.options]
      SystemdCgroup = true
NODECONFIG
fi

echo "NodeConfig written to /etc/eks/nodeadm.d/nodeconfig.yaml"
cat /etc/eks/nodeadm.d/nodeconfig.yaml

# Run nodeadm init to bootstrap the node
echo "Running nodeadm init..."
nodeadm init --config-source file:///etc/eks/nodeadm.d/nodeconfig.yaml

# ============================================================
# Force containerd + kubelet to reload config
# ============================================================
# nodeadm's EnsureRunning() uses systemd StartUnit which is a no-op when
# containerd is already running (enabled at boot). The freshly-written
# /etc/containerd/config.toml — including the NodeConfig.containerd.config
# overlay above — therefore never gets loaded; the in-memory config
# remains the boot-time default.
#
# Symptom: pod sandboxes are created with cgroupfs-format cgroupsPath
# and fail with the systemd/cgroupfs mismatch above.
#
# Fix landed upstream as awslabs/amazon-eks-ami#2705 (StartDaemon →
# RestartDaemon) but the patched nodeadm only ships in AMIs released
# after 2026-05-13. Until our pinned AMI carries the fix, force the
# reload here. kubelet must follow because its CRI runtime info is
# cached and would otherwise stay tied to the old containerd PID.
systemctl restart containerd
systemctl restart kubelet

# ============================================================
# EFA userspace packages (libfabric-aws, openmpi5-aws, etc.)
# ============================================================
# The EKS GPU AMI ships only the kernel-side EFA driver, which is
# enough for containerized workloads that bring their own libfabric
# (NCCL images usually do). But for host-level diagnostics like
# \`/opt/amazon/efa/bin/fi_info -p efa\`, or for workloads that rely
# on the host's libfabric, we need the full userspace install.
#
# Enable with GPU_INSTALL_EFA_USERSPACE=true (default: true).
# Tarball version pinned via GPU_EFA_INSTALLER_VERSION (e.g. "1.48.0"); empty
# = "latest" (rolls forward, breaks reproducibility).
if [ "${GPU_INSTALL_EFA_USERSPACE}" = "true" ] && [ ! -x /opt/amazon/efa/bin/fi_info ]; then
  EFA_INSTALLER_TARBALL="aws-efa-installer-${GPU_EFA_INSTALLER_VERSION:-latest}.tar.gz"
  echo "=== Installing EFA userspace (libfabric-aws + openmpi5-aws) — \$EFA_INSTALLER_TARBALL ==="
  # --skip-kmod = don't rebuild kernel module (AMI already has it)
  # -y = non-interactive
  # NOTE: do NOT pass --minimal; it excludes libfabric-aws + openmpi5-aws
  # (the whole point — we want /opt/amazon/efa/bin/fi_info and friends)
  ( cd /tmp && \
    curl -fsSLO "https://efa-installer.amazonaws.com/\${EFA_INSTALLER_TARBALL}" && \
    tar -xf "\${EFA_INSTALLER_TARBALL}" && \
    cd aws-efa-installer && \
    ./efa_installer.sh -y --skip-kmod 2>&1 | tail -30 ) || \
    echo "WARN: efa_installer failed; containers with their own libfabric will still work"
  if [ -x /opt/amazon/efa/bin/fi_info ]; then
    echo "EFA userspace installed at /opt/amazon/efa/"
    /opt/amazon/efa/bin/fi_info --version 2>&1 | head -1 || true
  fi
else
  echo "Skipping EFA userspace install (already present or GPU_INSTALL_EFA_USERSPACE!=true)"
fi

# Enable services for reboot persistence
echo "Enabling kubelet and containerd services..."
systemctl enable kubelet containerd

echo "=== GPU Node Bootstrap Complete ==="

--==BOUNDARY==--
EOF_USERDATA

    # Base64 encode the userdata
    local userdata_b64=$(base64 -w 0 < "${userdata_file}")

    # Generate Launch Template data using Python
    local lt_data_file=$(mktemp /tmp/lt-data.XXXXXX.json)

    # shellcheck disable=SC1036,SC1088
    #   This is a Python heredoc, not shell. Shellcheck parses comments
    #   with literal `(...)` and backticks as shell syntax and misfires
    #   (SC1036 "'(' is invalid", SC1088 "Parsing stopped here"). Disable
    #   both for this block — the real Python validation happens when
    #   python3 executes below.
    python3 - <<PYSCRIPT > "${lt_data_file}"
import json
import base64

ami_id = "${GPU_AMI_ID}"
gpu_sg_id = "${GPU_SG_ID}"
cluster_sg_id = "${CLUSTER_SG_ID}"
efa_only_count = ${efa_only_count}
primary_efa = "${primary_efa}" == "true"
capacity_reservation_id = "${capacity_reservation_id}"
userdata_b64 = "${userdata_b64}"
ec2_key_name = "${EC2_KEY_NAME:-}"
instance_type = "${instance_type}"
embed_instance_type = "${embed_instance_type}" == "true"
pg_name = "${pg_name}"

# Network interfaces configuration
# Primary: NetworkCardIndex=0, DeviceIndex=0
#   - primary_efa=True : InterfaceType=efa (EFA + ENA on the same NIC).
#     Covers multi-NIC training shapes (p5/p5en/p6-b200) AND single-NIC
#     EFA shapes (g6e.8/12/16xlarge, g7e.8/12xlarge) where efa_only_count=0
#     but the primary NIC still carries EFA.
#   - primary_efa=False : InterfaceType=interface (pure ENA).
#     - p6-b300.48xlarge: NIC 0 is ENA-only (MaximumEfaInterfaces=16 but
#       MaximumNetworkCards=17; EFA only on NetworkCardIndex 1..16). Using
#       efa here yields AttachmentLimitExceeded on Network Card 0 limit 0.
#     - Truly non-EFA types (g5/g6/g6e.xlarge etc): no EFA support
#       (UnsupportedOperation: "EFA interfaces are not supported on <type>").
# Additional: NetworkCardIndex=1..N, DeviceIndex=0, InterfaceType=efa-only
#   DeviceIndex=0 matches the AWS-recommended layout for all current EFA-capable
#   GPU types (p5/p5e/p5en/p6-b200/p6-b300/g6e/g7e). Reference:
#   https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-acc-inst-types.html
#   DeviceIndex is per-NetworkCard, so DI=0 on secondary NICs does not collide
#   with DI=0 on the primary NIC (which lives on NetworkCard 0).
network_interfaces = []

primary_interface_type = "efa" if primary_efa else "interface"

network_interfaces.append({
    "NetworkCardIndex": 0,
    "DeviceIndex": 0,
    "InterfaceType": primary_interface_type,
    "DeleteOnTermination": True,
    "Groups": [gpu_sg_id, cluster_sg_id],
})

# Additional EFA-only network cards
for nci in range(1, efa_only_count + 1):
    network_interfaces.append({
        "NetworkCardIndex": nci,
        "DeviceIndex": 0,
        "InterfaceType": "efa-only",
        "DeleteOnTermination": True,
        "Groups": [gpu_sg_id, cluster_sg_id],
    })

root_volume_size = ${GPU_NODE_ROOT_VOLUME_SIZE}
data_volume_size = ${GPU_NODE_DATA_VOLUME_SIZE}

lt_data = {
    "ImageId": ami_id,
    "UserData": userdata_b64,
    "NetworkInterfaces": network_interfaces,
    "BlockDeviceMappings": [
        {
            "DeviceName": "/dev/xvda",
            "Ebs": {
                "VolumeSize": root_volume_size,
                "VolumeType": "gp3",
                "Encrypted": True,
                "DeleteOnTermination": True
            }
        },
        {
            "DeviceName": "/dev/xvdb",
            "Ebs": {
                "VolumeSize": data_volume_size,
                "VolumeType": "gp3",
                "Iops": 3000,
                "Throughput": 125,
                "Encrypted": True,
                "DeleteOnTermination": True
            }
        }
    ],
    "MetadataOptions": {
        "HttpTokens": "required",
        "HttpPutResponseHopLimit": 2,
        "HttpEndpoint": "enabled"
    },
    "TagSpecifications": [
        {
            "ResourceType": "instance",
            "Tags": [
                {"Key": "Name", "Value": "${CLUSTER_NAME}-gpu-${resource_name}-node"},
                {"Key": "kubernetes.io/cluster/${CLUSTER_NAME}", "Value": "owned"},
                {"Key": "gpu-instance-type", "Value": "${gpu_type}"},
                {"Key": "purchase-option", "Value": "${purchase_option}"},
                {"Key": "business", "Value": "middleware"},
                {"Key": "resource", "Value": "eks"}
            ]
        },
        {
            "ResourceType": "volume",
            "Tags": [
                {"Key": "Name", "Value": "${CLUSTER_NAME}-gpu-${resource_name}-volume"},
                {"Key": "kubernetes.io/cluster/${CLUSTER_NAME}", "Value": "owned"},
                {"Key": "business", "Value": "middleware"},
                {"Key": "resource", "Value": "eks"}
            ]
        }
    ]
}

# Add capacity reservation if specified
if capacity_reservation_id:
    lt_data["CapacityReservationSpecification"] = {
        "CapacityReservationTarget": {
            "CapacityReservationId": capacity_reservation_id
        }
    }

# Add EC2 Key Pair if specified
if ec2_key_name:
    lt_data["KeyName"] = ec2_key_name

# Capacity Block requires InstanceType and MarketType=capacity-block inside the Launch Template
if embed_instance_type:
    lt_data["InstanceType"] = instance_type
    lt_data["InstanceMarketOptions"] = {
        "MarketType": "capacity-block"
    }

# Cluster placement group (attempts to co-locate instances within a single AZ
# for EFA locality; in practice does not guarantee that all instances share
# the bottom-layer network node — see GPU_PG_STRATEGY notes above).
if pg_name:
    lt_data["Placement"] = {
        "GroupName": pg_name,
        "Tenancy": "default"
    }

print(json.dumps(lt_data, indent=2))
PYSCRIPT

    rm -f "${userdata_file}"

    echo "Launch Template data:"
    cat "${lt_data_file}"
    echo ""

    # Check if launch template exists
    if aws ec2 describe-launch-templates \
        --launch-template-names "${lt_name}" \
        --region "${AWS_REGION}" &>/dev/null; then

        echo "Launch Template ${lt_name} exists, creating new version..."

        LT_ID=$(aws ec2 describe-launch-templates \
            --launch-template-names "${lt_name}" \
            --region "${AWS_REGION}" \
            --query 'LaunchTemplates[0].LaunchTemplateId' \
            --output text)

        LT_VERSION=$(aws ec2 create-launch-template-version \
            --launch-template-id "${LT_ID}" \
            --launch-template-data "file://${lt_data_file}" \
            --region "${AWS_REGION}" \
            --query 'LaunchTemplateVersion.VersionNumber' \
            --output text)

        echo "Created new version: ${LT_VERSION}"
    else
        echo "Creating new Launch Template..."

        local lt_result
        lt_result=$(aws ec2 create-launch-template \
            --launch-template-name "${lt_name}" \
            --launch-template-data "file://${lt_data_file}" \
            --region "${AWS_REGION}" \
            --output json)

        LT_ID=$(echo "${lt_result}" | jq -r '.LaunchTemplate.LaunchTemplateId')
        LT_VERSION=$(echo "${lt_result}" | jq -r '.LaunchTemplate.LatestVersionNumber')

        echo "Created Launch Template: ${LT_ID} (version ${LT_VERSION})"
    fi

    rm -f "${lt_data_file}"

    echo "Launch Template ready:"
    echo "  ID: ${LT_ID}"
    echo "  Version: ${LT_VERSION}"
}

# ===================================================================
# Node Group Creation
# ===================================================================

create_gpu_nodegroup() {
    local gpu_type=$1
    local purchase_option=$2
    local lt_id=$3
    local lt_version=$4
    local suffix=${5:-}  # Optional suffix for multiple reservations (e.g., "-1", "-2")
    shift 5
    local subnets=("$@")

    local instance_type="$gpu_type"
    local resource_name=$(get_resource_name "$gpu_type")
    local ng_name="gpu-${resource_name}-${purchase_option}${suffix}"

    # Check if nodegroup exists
    if aws eks describe-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${ng_name}" \
        --region "${AWS_REGION}" &>/dev/null; then
        echo "Nodegroup ${ng_name} already exists, skipping"
        return 0
    fi

    echo "Creating nodegroup: ${ng_name}"
    echo "  Instance Type: ${instance_type}"
    echo "  Purchase Option: ${purchase_option}"
    echo "  Subnets: ${subnets[*]}"

    local capacity_type="ON_DEMAND"
    if [ "${purchase_option}" = "spot" ]; then
        capacity_type="SPOT"
    elif [ "${purchase_option}" = "cb" ]; then
        capacity_type="CAPACITY_BLOCK"
    fi

    echo "Creating nodegroup via AWS CLI..."

    # For CAPACITY_BLOCK, InstanceType is specified inside the Launch Template.
    # Passing --instance-types here would conflict with the LT, so omit it.
    local instance_types_arg=(--instance-types "${instance_type}")
    if [ "${purchase_option}" = "cb" ]; then
        instance_types_arg=()
    fi

    aws eks create-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${ng_name}" \
        --subnets "${subnets[@]}" \
        --node-role "${GPU_NODE_ROLE_ARN}" \
        --launch-template "id=${lt_id},version=${lt_version}" \
        "${instance_types_arg[@]}" \
        --capacity-type "${capacity_type}" \
        --scaling-config "minSize=${GPU_NODE_MIN_SIZE},maxSize=${GPU_NODE_MAX_SIZE},desiredSize=${GPU_NODE_DESIRED_CAPACITY}" \
        --labels "workload-type=gpu,gpu-instance-type=${gpu_type},purchase-option=${purchase_option}" \
        --taints "key=nvidia.com/gpu,value=true,effect=NO_SCHEDULE" \
        --tags "k8s.io/cluster-autoscaler/enabled=true,k8s.io/cluster-autoscaler/${CLUSTER_NAME}=owned,gpu-instance-type=${gpu_type},business=middleware,resource=eks" \
        --region "${AWS_REGION}"

    echo "Nodegroup ${ng_name} creation initiated"

    echo "Waiting for nodegroup to be active..."
    aws eks wait nodegroup-active \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${ng_name}" \
        --region "${AWS_REGION}"

    echo "Nodegroup ${ng_name} created"

    # Post-ACTIVE topology handling. Dispatched by GPU_TOPOLOGY_MODE.
    #   gate       run verify_topology with GPU_TOPOLOGY_GATE (strict/warn)
    #   inventory  print AWS-native topology inventory (no fail)
    #   both       verify (warn only) + print inventory (diagnostic)
    #   off        skip all topology work
    case "${GPU_TOPOLOGY_MODE}" in
        gate)
            verify_topology "${ng_name}" "${GPU_TOPOLOGY_GATE}" "${GPU_TOPOLOGY_GATE_LAYER}"
            ;;
        inventory)
            print_topology_inventory "${ng_name}"
            ;;
        both)
            verify_topology "${ng_name}" "warn" "${GPU_TOPOLOGY_GATE_LAYER}" || true
            print_topology_inventory "${ng_name}"
            ;;
        off)
            echo "GPU_TOPOLOGY_MODE=off; skipping topology verification and inventory"
            ;;
        *)
            echo "WARN: unknown GPU_TOPOLOGY_MODE='${GPU_TOPOLOGY_MODE}'; defaulting to gate"
            verify_topology "${ng_name}" "${GPU_TOPOLOGY_GATE}" "${GPU_TOPOLOGY_GATE_LAYER}"
            ;;
    esac

    # NOTE on the NVIDIA device-plugin startup race:
    # Earlier revisions of this script ran a "bounce" routine here that
    # detected pods stuck on "No devices found. Waiting indefinitely."
    # and force-deleted them. That mitigation was tied to the legacy
    # hand-written DaemonSet which set FAIL_ON_INIT_ERROR=false (allowing
    # the plugin to silently block on init failure). The Helm chart
    # deployment used above does NOT override failOnInitError, so it
    # inherits the upstream default `true` — when init fails (driver/
    # device not yet ready), the plugin process exits, the container
    # crashes, kubelet enters CrashLoopBackOff, and a few seconds later
    # the next attempt finds the device nodes ready. No external bounce
    # is needed. AWS EKS AL2023 NVIDIA AMI's `nvidia-kmod-load.service`
    # (`Before=containerd.service`) further tightens the race window at
    # the host layer.
    #
    # If you ever observe a pod stuck at the "No devices found" log line
    # despite failOnInitError=true (NVIDIA upstream issue #1080 has hit
    # this in some edge cases), check:
    #   kubectl logs -n kube-system \
    #     -l app.kubernetes.io/name=nvidia-device-plugin --tail=50
    # and report to NVIDIA bug 5129637.
}


# ===================================================================
# Main Execution
# ===================================================================

echo "=== Starting GPU Node Group Installation ==="

# Step 1: Get cluster information
echo ""
echo "Step 1: Gathering cluster information..."

CLUSTER_DESC=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}")
CLUSTER_ENDPOINT=$(echo "${CLUSTER_DESC}" | jq -r '.cluster.endpoint')
CLUSTER_CA=$(echo "${CLUSTER_DESC}" | jq -r '.cluster.certificateAuthority.data')
SERVICE_IPV4_CIDR=$(echo "${CLUSTER_DESC}" | jq -r '.cluster.kubernetesNetworkConfig.serviceIpv4Cidr')
CLUSTER_SG_ID=$(echo "${CLUSTER_DESC}" | jq -r '.cluster.resourcesVpcConfig.clusterSecurityGroupId')

echo "Cluster Endpoint: ${CLUSTER_ENDPOINT}"
echo "Service CIDR: ${SERVICE_IPV4_CIDR}"
echo "Cluster Security Group: ${CLUSTER_SG_ID}"

# Step 2: Create IAM Role
echo ""
echo "Step 2: Creating GPU Node IAM Role..."
create_gpu_node_iam_role

# Step 3: Create Security Group
echo ""
echo "Step 3: Creating GPU Security Group..."
create_gpu_security_group

# Step 4: Get GPU AMI
echo ""
echo "Step 4: Getting GPU-optimized AMI..."

# Detect architecture from the configured GPU instance types rather than
# hard-coding x86_64. All GPU types in GPU_INSTANCE_TYPES must share the
# same architecture (they share one AMI / Launch Template).
#
# Normalize the comma-separated list first: strip whitespace around each
# entry and drop empty elements. This turns accidental leading/trailing
# commas and ", ,"-style typos into a clean list so the architecture
# helper never has to handle empty input.
_gpu_types_clean=()
IFS=',' read -ra _gpu_types_raw <<< "${GPU_INSTANCE_TYPES}"
for _t in "${_gpu_types_raw[@]}"; do
    # Trim leading/trailing whitespace
    _t="${_t#"${_t%%[![:space:]]*}"}"
    _t="${_t%"${_t##*[![:space:]]}"}"
    [ -n "${_t}" ] && _gpu_types_clean+=("${_t}")
done

if [ ${#_gpu_types_clean[@]} -eq 0 ]; then
    echo "ERROR: GPU_INSTANCE_TYPES is empty or contains only whitespace/commas."
    echo "       Set it to a comma-separated list, e.g. 'p5.48xlarge,p5en.48xlarge'."
    exit 1
fi

GPU_AMI_ARCH=$(detect_instance_arch "${_gpu_types_clean[0]}") || {
    echo "ERROR: Could not detect architecture for ${_gpu_types_clean[0]}"
    exit 1
}

# Validate that all GPU instance types agree on architecture, since a
# single AMI is used for the whole group.
for _t in "${_gpu_types_clean[@]:1}"; do
    _a=$(detect_instance_arch "${_t}") || {
        echo "ERROR: Could not detect architecture for GPU type '${_t}'"
        exit 1
    }
    if [ "${_a}" != "${GPU_AMI_ARCH}" ]; then
        echo "ERROR: GPU_INSTANCE_TYPES mixes architectures — ${_gpu_types_clean[0]}=${GPU_AMI_ARCH} but ${_t}=${_a}."
        echo "       Split into separate runs with homogeneous GPU_INSTANCE_TYPES."
        exit 1
    fi
done
unset _gpu_types_raw _gpu_types_clean _t _a

GPU_AMI_ID=$(aws ssm get-parameter \
    --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/${GPU_AMI_ARCH}/nvidia/recommended/image_id" \
    --region "${AWS_REGION}" \
    --query 'Parameter.Value' \
    --output text)

if [ -z "${GPU_AMI_ID}" ] || [ "${GPU_AMI_ID}" = "None" ]; then
    echo "ERROR: Could not retrieve GPU AMI ID for arch=${GPU_AMI_ARCH}, K8S=${K8S_VERSION}"
    exit 1
fi

echo "GPU AMI ID: ${GPU_AMI_ID} (arch=${GPU_AMI_ARCH})"

# Step 5: Create node groups
echo ""
echo "Step 5: Creating GPU node groups..."
echo "GPU Instance Types: ${GPU_INSTANCE_TYPES}"
echo "Pricing Options: OD=${DEPLOY_GPU_OD}, Spot=${DEPLOY_GPU_SPOT}, ODCR=${DEPLOY_GPU_ODCR}, CB=${DEPLOY_GPU_CB}"

IFS=',' read -ra GPU_TYPE_ARRAY <<< "$GPU_INSTANCE_TYPES"

# Build subnet list
# Collect non-empty private subnets and deduplicate (EKS rejects duplicate subnets).
_raw_subnets=()
[ -n "${PRIVATE_SUBNET_A:-}" ] && _raw_subnets+=("${PRIVATE_SUBNET_A}")
[ -n "${PRIVATE_SUBNET_B:-}" ] && _raw_subnets+=("${PRIVATE_SUBNET_B}")
[ -n "${PRIVATE_SUBNET_C:-}" ] && _raw_subnets+=("${PRIVATE_SUBNET_C}")
[ -n "${PRIVATE_SUBNET_D:-}" ] && _raw_subnets+=("${PRIVATE_SUBNET_D}")
mapfile -t ALL_SUBNETS < <(printf '%s\n' "${_raw_subnets[@]}" | awk 'NF && !seen[$0]++')
unset _raw_subnets

# Subnet map for AZ-specific deployments
declare -A SUBNET_MAP
SUBNET_MAP["a"]="${PRIVATE_SUBNET_A}"
SUBNET_MAP["b"]="${PRIVATE_SUBNET_B}"
[ -n "${PRIVATE_SUBNET_C:-}" ] && SUBNET_MAP["c"]="${PRIVATE_SUBNET_C}"
[ -n "${PRIVATE_SUBNET_D:-}" ] && SUBNET_MAP["d"]="${PRIVATE_SUBNET_D}"

# GPU_TARGET_AZ: if set, narrow ALL_SUBNETS to that single AZ's subnet.
# Required for cluster-PG eligibility — cluster PG is single-AZ-only.
if [ -n "${GPU_TARGET_AZ}" ]; then
    _target_subnet="${SUBNET_MAP[${GPU_TARGET_AZ}]:-}"
    if [ -z "${_target_subnet}" ]; then
        echo "ERROR: GPU_TARGET_AZ='${GPU_TARGET_AZ}' set but PRIVATE_SUBNET_${GPU_TARGET_AZ^^} is empty"
        exit 1
    fi
    echo "GPU_TARGET_AZ=${GPU_TARGET_AZ} → narrowing OD/Spot deploys to subnet ${_target_subnet}"
    ALL_SUBNETS=("${_target_subnet}")
    unset _target_subnet
fi

for gpu_type in "${GPU_TYPE_ARRAY[@]}"; do
    # Strip whitespace and skip empty entries. `GPU_INSTANCE_TYPES=",p5.48xlarge,"`
    # would otherwise yield blank iterations and produce misleading
    # "Unknown GPU type:" warnings. The stricter normalizer used during
    # architecture validation (above) already filters these, but the main
    # loop uses GPU_TYPE_ARRAY directly.
    gpu_type=$(echo "$gpu_type" | tr -d '[:space:]')
    [ -z "$gpu_type" ] && continue
    echo ""
    echo "Processing GPU type: ${gpu_type}"

    if ! is_gpu_instance_type "$gpu_type"; then
        echo "WARNING: '${gpu_type}' does not look like a GPU/accelerator instance type (expected p*, g*, trn*, inf*); skipping"
        continue
    fi
    efa_count=$(get_efa_only_card_count "$gpu_type")
    if [ "$efa_count" -eq 0 ]; then
        echo "NOTE: ${gpu_type} has no EFA-only NICs — creating GPU node group without multi-NIC EFA scaffolding"
    fi

    # Deploy On-Demand node group
    if [ "${DEPLOY_GPU_OD}" = "true" ]; then
        echo ""
        echo "Creating On-Demand node group for ${gpu_type}..."
        od_pg_name=$(plan_pg_for_nodegroup "$gpu_type" "od" "${GPU_NG_SUFFIX}" "${ALL_SUBNETS[@]}")
        create_gpu_launch_template "$gpu_type" "od" "" "${GPU_NG_SUFFIX}" "$od_pg_name"
        create_gpu_nodegroup "$gpu_type" "od" "$LT_ID" "$LT_VERSION" "${GPU_NG_SUFFIX}" "${ALL_SUBNETS[@]}"
    fi

    # Deploy Spot node group
    if [ "${DEPLOY_GPU_SPOT}" = "true" ]; then
        echo ""
        echo "Creating Spot node group for ${gpu_type}..."
        spot_pg_name=$(plan_pg_for_nodegroup "$gpu_type" "spot" "${GPU_NG_SUFFIX}" "${ALL_SUBNETS[@]}")
        create_gpu_launch_template "$gpu_type" "spot" "" "${GPU_NG_SUFFIX}" "$spot_pg_name"
        create_gpu_nodegroup "$gpu_type" "spot" "$LT_ID" "$LT_VERSION" "${GPU_NG_SUFFIX}" "${ALL_SUBNETS[@]}"
    fi

    # Deploy ODCR node group(s) - supports multiple reservations
    if [ "${DEPLOY_GPU_ODCR}" = "true" ]; then
        # Support both legacy single value (ODCR_ID/ODCR_AZ) and new multi-value format (ODCR_IDS/ODCR_AZS)
        odcr_ids_str="${ODCR_IDS:-${ODCR_ID:-}}"
        odcr_azs_str="${ODCR_AZS:-${ODCR_AZ:-}}"

        if [ -z "${odcr_ids_str}" ]; then
            echo "WARNING: No ODCR_IDS or ODCR_ID set, skipping ODCR node groups"
        elif [ -z "${odcr_azs_str}" ]; then
            echo "WARNING: No ODCR_AZS or ODCR_AZ set, skipping ODCR node groups"
        else
            IFS=',' read -ra ODCR_ID_ARRAY <<< "$odcr_ids_str"
            IFS=',' read -ra ODCR_AZ_ARRAY <<< "$odcr_azs_str"

            if [ ${#ODCR_ID_ARRAY[@]} -ne ${#ODCR_AZ_ARRAY[@]} ]; then
                echo "ERROR: ODCR_IDS and ODCR_AZS must have the same number of entries"
                exit 1
            fi
            odcr_count=${#ODCR_ID_ARRAY[@]}

            # Pairing rule:
            #   - Multiple GPU types AND multiple ODCRs with matching list length:
            #     pair by index (gpu_type[0] ↔ ODCR[0], gpu_type[1] ↔ ODCR[1], ...).
            #     Each ODCR is attached to EXACTLY one node group that matches
            #     the instance type the ODCR was reserved for.
            #   - Single GPU type (or legacy ODCR_ID/ODCR_AZ): every ODCR
            #     produces a node group for that one type.
            multi_pair_mode="false"
            if [ ${#GPU_TYPE_ARRAY[@]} -gt 1 ] && [ ${#GPU_TYPE_ARRAY[@]} -eq $odcr_count ]; then
                multi_pair_mode="true"
            fi

            # In multi-pair mode, skip ODCRs that don't match the outer gpu_type.
            # In single-type mode, iterate every ODCR.
            for ((i=0; i<odcr_count; i++)); do
                if [ "$multi_pair_mode" = "true" ]; then
                    # Resolve paired gpu type; skip ODCRs whose paired type != current outer loop type
                    paired_gpu=$(echo "${GPU_TYPE_ARRAY[$i]}" | tr -d '[:space:]')
                    [ "$paired_gpu" = "$gpu_type" ] || continue
                fi

                odcr_id=$(echo "${ODCR_ID_ARRAY[$i]}" | tr -d ' ')
                odcr_az=$(echo "${ODCR_AZ_ARRAY[$i]}" | tr -d ' ')
                odcr_az_suffix="${odcr_az: -1}"
                odcr_subnet="${SUBNET_MAP[$odcr_az_suffix]:-}"

                # Create unique suffix: -1, -2, etc. (only if multiple ODCRs)
                suffix=""
                if [ $odcr_count -gt 1 ]; then
                    suffix="-$((i+1))"
                fi

                echo ""
                echo "Creating ODCR node group $((i+1))/${odcr_count} for ${gpu_type}..."
                echo "  ODCR ID: ${odcr_id}"
                echo "  AZ: ${odcr_az}"

                if [ -n "${odcr_subnet}" ]; then
                    odcr_pg_name=$(plan_pg_for_nodegroup "$gpu_type" "odcr" "${suffix}" "$odcr_subnet")
                    create_gpu_launch_template "$gpu_type" "odcr" "${odcr_id}" "${suffix}" "$odcr_pg_name"
                    create_gpu_nodegroup "$gpu_type" "odcr" "$LT_ID" "$LT_VERSION" "${suffix}" "$odcr_subnet"
                else
                    echo "WARNING: No subnet found for ODCR AZ ${odcr_az}"
                fi
            done
        fi
    fi

    # Deploy Capacity Block node group(s) - supports multiple reservations
    if [ "${DEPLOY_GPU_CB}" = "true" ]; then
        # Support both legacy single value (CAPACITY_BLOCK_ID/CAPACITY_BLOCK_AZ) and new multi-value format (CAPACITY_BLOCK_IDS/CAPACITY_BLOCK_AZS)
        cb_ids_str="${CAPACITY_BLOCK_IDS:-${CAPACITY_BLOCK_ID:-}}"
        cb_azs_str="${CAPACITY_BLOCK_AZS:-${CAPACITY_BLOCK_AZ:-}}"

        if [ -z "${cb_ids_str}" ]; then
            echo "WARNING: No CAPACITY_BLOCK_IDS or CAPACITY_BLOCK_ID set, skipping CB node groups"
        elif [ -z "${cb_azs_str}" ]; then
            echo "WARNING: No CAPACITY_BLOCK_AZS or CAPACITY_BLOCK_AZ set, skipping CB node groups"
        else
            IFS=',' read -ra CB_ID_ARRAY <<< "$cb_ids_str"
            IFS=',' read -ra CB_AZ_ARRAY <<< "$cb_azs_str"

            if [ ${#CB_ID_ARRAY[@]} -ne ${#CB_AZ_ARRAY[@]} ]; then
                echo "ERROR: CAPACITY_BLOCK_IDS and CAPACITY_BLOCK_AZS must have the same number of entries"
                exit 1
            fi
            cb_count=${#CB_ID_ARRAY[@]}

            # Pairing rule (same as ODCR): when GPU_TYPE_ARRAY has >1 entry
            # AND its length matches cb_count, pair by index — CB[i] is
            # attached to exactly one node group for GPU_TYPE_ARRAY[i].
            # Otherwise (single gpu_type or legacy CAPACITY_BLOCK_ID/AZ),
            # every CB produces a node group for the current outer gpu_type.
            cb_multi_pair_mode="false"
            if [ ${#GPU_TYPE_ARRAY[@]} -gt 1 ] && [ ${#GPU_TYPE_ARRAY[@]} -eq $cb_count ]; then
                cb_multi_pair_mode="true"
            fi

            for ((i=0; i<cb_count; i++)); do
                if [ "$cb_multi_pair_mode" = "true" ]; then
                    paired_gpu=$(echo "${GPU_TYPE_ARRAY[$i]}" | tr -d '[:space:]')
                    [ "$paired_gpu" = "$gpu_type" ] || continue
                fi

                cb_id=$(echo "${CB_ID_ARRAY[$i]}" | tr -d ' ')
                cb_az=$(echo "${CB_AZ_ARRAY[$i]}" | tr -d ' ')
                cb_az_suffix="${cb_az: -1}"
                cb_subnet="${SUBNET_MAP[$cb_az_suffix]:-}"

                # Create unique suffix: -1, -2, etc. (only if multiple CBs)
                suffix=""
                if [ $cb_count -gt 1 ]; then
                    suffix="-$((i+1))"
                fi

                echo ""
                echo "Creating Capacity Block node group $((i+1))/${cb_count} for ${gpu_type}..."
                echo "  CB ID: ${cb_id}"
                echo "  AZ: ${cb_az}"

                if [ -n "${cb_subnet}" ]; then
                    cb_pg_name=$(plan_pg_for_nodegroup "$gpu_type" "cb" "${suffix}" "$cb_subnet")
                    create_gpu_launch_template "$gpu_type" "cb" "${cb_id}" "${suffix}" "$cb_pg_name"
                    create_gpu_nodegroup "$gpu_type" "cb" "$LT_ID" "$LT_VERSION" "${suffix}" "$cb_subnet"
                else
                    echo "WARNING: No subnet found for Capacity Block AZ ${cb_az}"
                fi
            done
        fi
    fi
done

# ===================================================================
# K8s GPU stack (device-plugin / EFA / DCGM / NPD / health-check / Operator)
# is now a SEPARATE script so that:
#   1. node-level infra (this script) and cluster-level workloads
#      (option_install_gpu_stack.sh) can be iterated independently
#   2. standard vs operator mode mutual-exclusion logic lives in one
#      place and isn't intermixed with EC2/IAM/LT lifecycle
#
# Default behavior preserves the old "one command" UX: this script
# auto-invokes the stack installer at the end. Set
# SKIP_GPU_STACK_AUTO_INSTALL=true to skip and run it yourself.
# ===================================================================
if [ "${SKIP_GPU_STACK_AUTO_INSTALL:-false}" = "true" ]; then
    echo ""
    echo "Step 6: Skipping GPU stack install (SKIP_GPU_STACK_AUTO_INSTALL=true)"
    echo "  Run it manually with: bash ${SCRIPT_DIR}/option_install_gpu_stack.sh"
else
    echo ""
    echo "Step 6: Installing GPU stack (delegating to option_install_gpu_stack.sh)..."
    bash "${SCRIPT_DIR}/option_install_gpu_stack.sh"
fi

# Step 7: Summary
echo ""
echo "=== GPU Node Groups Installation Complete ==="
echo ""
echo "Created resources:"
echo "  • IAM Role: ${GPU_NODE_ROLE_NAME}"
echo "  • Security Group: ${GPU_SG_ID}"
echo "  • GPU AMI: ${GPU_AMI_ID}"
echo "  • K8s GPU stack: see option_install_gpu_stack.sh output above"
if [ "${GPU_ENABLE_LOCAL_LVM}" = "true" ]; then
    echo "  • Local NVMe LVM: ${GPU_LOCAL_LVM_VG_NAME}/${GPU_LOCAL_LVM_LV_NAME} (striped, ${GPU_LOCAL_LVM_FS}) → ${GPU_LOCAL_LVM_MOUNT}"
    echo "  • Node labels:    local-ssd=true, local-ssd-size-gb=<total>"
fi
echo ""
echo "Node groups created for:"
for gpu_type in "${GPU_TYPE_ARRAY[@]}"; do
    gpu_type=$(echo "$gpu_type" | tr -d '[:space:]')
    [ -z "$gpu_type" ] && continue
    echo "  • ${gpu_type}:"
    [ "${DEPLOY_GPU_OD}" = "true" ] && echo "    - On-Demand (all AZs)"
    [ "${DEPLOY_GPU_SPOT}" = "true" ] && echo "    - Spot (all AZs)"

    if [ "${DEPLOY_GPU_ODCR}" = "true" ]; then
        _odcr_ids_str="${ODCR_IDS:-${ODCR_ID:-}}"
        _odcr_azs_str="${ODCR_AZS:-${ODCR_AZ:-}}"
        if [ -n "${_odcr_ids_str}" ]; then
            IFS=',' read -ra ODCR_SUMMARY_IDS <<< "$_odcr_ids_str"
            IFS=',' read -ra ODCR_SUMMARY_AZS <<< "$_odcr_azs_str"
            # Same paired-index rule as the create loop: when gpu_type list
            # length matches ODCR list length and >1, each ODCR pairs with
            # exactly one gpu_type by index. Otherwise all ODCRs apply to
            # every gpu_type in the outer loop.
            _multi_pair="false"
            if [ ${#GPU_TYPE_ARRAY[@]} -gt 1 ] && [ ${#GPU_TYPE_ARRAY[@]} -eq ${#ODCR_SUMMARY_IDS[@]} ]; then
                _multi_pair="true"
            fi
            for ((j=0; j<${#ODCR_SUMMARY_IDS[@]}; j++)); do
                if [ "$_multi_pair" = "true" ]; then
                    _paired=$(echo "${GPU_TYPE_ARRAY[$j]}" | tr -d '[:space:]')
                    [ "$_paired" = "$gpu_type" ] || continue
                fi
                _suffix_label=""
                [ ${#ODCR_SUMMARY_IDS[@]} -gt 1 ] && _suffix_label="-$((j+1))"
                echo "    - ODCR${_suffix_label} (${ODCR_SUMMARY_AZS[$j]})"
            done
        fi
    fi

    if [ "${DEPLOY_GPU_CB}" = "true" ]; then
        _cb_ids_str="${CAPACITY_BLOCK_IDS:-${CAPACITY_BLOCK_ID:-}}"
        _cb_azs_str="${CAPACITY_BLOCK_AZS:-${CAPACITY_BLOCK_AZ:-}}"
        if [ -n "${_cb_ids_str}" ]; then
            IFS=',' read -ra CB_SUMMARY_IDS <<< "$_cb_ids_str"
            IFS=',' read -ra CB_SUMMARY_AZS <<< "$_cb_azs_str"
            # Same paired-index rule as the CB create loop: when gpu_type list
            # length matches CB list length and >1, each CB pairs with
            # exactly one gpu_type by index.
            _cb_multi_pair="false"
            if [ ${#GPU_TYPE_ARRAY[@]} -gt 1 ] && [ ${#GPU_TYPE_ARRAY[@]} -eq ${#CB_SUMMARY_IDS[@]} ]; then
                _cb_multi_pair="true"
            fi
            for ((j=0; j<${#CB_SUMMARY_IDS[@]}; j++)); do
                if [ "$_cb_multi_pair" = "true" ]; then
                    _cb_paired=$(echo "${GPU_TYPE_ARRAY[$j]}" | tr -d '[:space:]')
                    [ "$_cb_paired" = "$gpu_type" ] || continue
                fi
                _suffix_label=""
                [ ${#CB_SUMMARY_IDS[@]} -gt 1 ] && _suffix_label="-$((j+1))"
                echo "    - CB${_suffix_label} (${CB_SUMMARY_AZS[$j]})"
            done
        fi
    fi
done
echo ""
echo "To scale up nodes (replace <nodegroup-name> with actual name from above):"
echo "  aws eks update-nodegroup-config --cluster-name ${CLUSTER_NAME} --nodegroup-name <nodegroup-name> --scaling-config minSize=0,maxSize=8,desiredSize=1"
echo ""
echo "To verify nodes:"
echo "  kubectl get nodes -l workload-type=gpu"
echo ""
if [ "${GPU_ENABLE_LOCAL_LVM}" = "true" ]; then
    echo "To verify local NVMe LVM on a node:"
    echo "  kubectl debug node/\${NODE} -it --image=amazonlinux -- chroot /host sh -c 'vgs; lvs; df -h ${GPU_LOCAL_LVM_MOUNT}'"
    echo "  kubectl get nodes -l local-ssd=true -L local-ssd-size-gb"
    echo ""
fi
echo "To verify EFA on node:"
echo "  kubectl debug node/\${NODE} -it --image=amazonlinux -- chroot /host ls /sys/class/infiniband/"
echo ""
echo "To verify EFA device plugin (resource vpc.amazonaws.com/efa):"
echo "  kubectl -n kube-system get ds aws-efa-k8s-device-plugin-daemonset"
echo "  kubectl describe node \${NODE} | grep 'vpc.amazonaws.com/efa'"
echo ""
