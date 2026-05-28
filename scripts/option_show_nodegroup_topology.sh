#!/bin/bash
# option_show_nodegroup_topology.sh — print AWS-native topology inventory
#
# Reads topology.k8s.aws/network-node-layer-N labels (written by the EKS
# cloud-controller-manager) and prints a human-readable inventory of each
# nodegroup's nodes, grouped by the bottom-layer network node (the
# "network node connected to the instance" per AWS docs).
#
# This script does NOT write any labels of its own. Workloads pin
# themselves directly to the AWS-native labels via nodeAffinity. See the
# inventory output for a copy-pasteable snippet.
#
# Use this tool when:
#   - You want a topology snapshot of an existing nodegroup
#   - You want to identify which bottom-layer network node has enough
#     instances for a given multi-node workload
#   - You are diagnosing why nodes in a placement group did not co-locate
#
# Usage:
#   option_show_nodegroup_topology.sh <ng_name> [min_size]
#   option_show_nodegroup_topology.sh --all-ngs [min_size]
#
#   min_size: highlight groups with at least N nodes (default 2)
#
# Env:
#   CLUSTER_NAME, AWS_REGION, KUBECONFIG  (loaded from 0_setup_env.sh)

set -e
set -o pipefail

export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=0_setup_env.sh
source "${SCRIPT_DIR}/0_setup_env.sh"
# shellcheck source=topology_inventory_lib.sh
source "${SCRIPT_DIR}/topology_inventory_lib.sh"

export KUBECONFIG="${HOME:-/root}/.kube/config"

usage() {
    cat <<'EOF'
Usage:
  option_show_nodegroup_topology.sh <ng_name> [min_size]
  option_show_nodegroup_topology.sh --all-ngs [min_size]

  min_size:  highlight bottom-layer groups with >= N nodes (default 2)

Examples:
  ./option_show_nodegroup_topology.sh gpu-p5en-48xlarge-spot-az3
  ./option_show_nodegroup_topology.sh gpu-p6-b300-48xlarge-spot-az3 4
  ./option_show_nodegroup_topology.sh --all-ngs

The output prints, per nodegroup, the AWS-native top-down layers of each
node (topology.k8s.aws/network-node-layer-1..N) and groups nodes by their
bottom-layer network node. The bottom layer is N == NetworkNodes length:
  - 3 for p3dn / p4d / p4de / p5 / p5e / p5en / p6e-gb200 / g6e / g7e /
    hpc / trn1 / trn1n / trn2 / trn2u
  - 4 for p6-b200.48xlarge / p6-b300.48xlarge
EOF
    exit 1
}

[ $# -lt 1 ] && usage

FIRST_ARG=$1
MIN_SIZE=${2:-2}

if ! [[ "${MIN_SIZE}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: min_size must be a positive integer (got '${MIN_SIZE}')"
    usage
fi

for tool in aws jq kubectl; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "ERROR: missing dependency: ${tool}"; exit 1
    }
done

if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "ERROR: EKS cluster '${CLUSTER_NAME}' not found in region '${AWS_REGION}'"
    exit 1
fi

if [ "${FIRST_ARG}" = "--all-ngs" ]; then
    echo "Iterating over all nodegroups in cluster ${CLUSTER_NAME}..."
    NGS=$(aws eks list-nodegroups \
        --cluster-name "${CLUSTER_NAME}" \
        --region "${AWS_REGION}" \
        --query 'nodegroups[]' --output text)
    if [ -z "${NGS}" ]; then
        echo "No nodegroups found."
        exit 0
    fi

    for ng in ${NGS}; do
        print_topology_inventory "${ng}" "${MIN_SIZE}"
    done
else
    NG_NAME="${FIRST_ARG}"
    if ! aws eks describe-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${NG_NAME}" \
        --region "${AWS_REGION}" &>/dev/null; then
        echo "ERROR: nodegroup '${NG_NAME}' not found in cluster ${CLUSTER_NAME}"
        exit 1
    fi
    print_topology_inventory "${NG_NAME}" "${MIN_SIZE}"
fi

echo ""
echo "Done."
