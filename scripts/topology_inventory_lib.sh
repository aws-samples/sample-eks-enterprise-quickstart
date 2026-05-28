#!/bin/bash
# topology_inventory_lib.sh — EC2 instance topology inventory helpers
#
# Reads AWS-native topology labels written by the EKS cloud-controller-
# manager and prints a human-readable inventory grouped by the bottom-
# layer network node (the network node connected to each instance).
#
# Source of truth (since EKS 1.31+): the cloud-controller-manager
# automatically writes these labels on every joined node:
#   topology.k8s.aws/network-node-layer-1 = top layer
#   topology.k8s.aws/network-node-layer-2 = ...
#   topology.k8s.aws/network-node-layer-N = bottom layer (connected to instance)
#   topology.k8s.aws/zone-id              = e.g. usw2-az1
#
# AWS uses a top-down ordering:
#   - layer-1 is the top of the hierarchy
#   - the highest-numbered layer present is the bottom layer, which is
#     the network node connected to the instance
#
# Per AWS docs the number of layers is determined by the instance type:
#   - 3 layers: p3dn / p4d / p4de / p5 / p5e / p5en / p6e-gb200 /
#               g6e / g7e / hpc6a / hpc6id / hpc7g / hpc7a / hpc8a /
#               trn1 / trn1n / trn2 / trn2u
#   - 4 layers: p6-b200.48xlarge / p6-b300.48xlarge
#   See: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-topology-prerequisites.html
#
# This library does NOT write any labels of its own. Workloads that need
# topology-aware scheduling pin themselves directly to the AWS-native
# labels via nodeAffinity, e.g. (for a 4-layer p6-b300 nodegroup):
#
#   affinity:
#     nodeAffinity:
#       requiredDuringSchedulingIgnoredDuringExecution:
#         nodeSelectorTerms:
#         - matchExpressions:
#           - { key: topology.k8s.aws/network-node-layer-4, operator: In, values: [<id>] }
#           - { key: topology.k8s.aws/zone-id,              operator: In, values: [<zone-id>] }
#
# Sourced by: option_install_gpu_nodegroups.sh, option_show_nodegroup_topology.sh
#
# Required env:   CLUSTER_NAME, AWS_REGION, KUBECONFIG
# Required tools: kubectl, jq

set -e
set -o pipefail

# ===================================================================
# Internal: wait until at least one node in an NG has AWS topology labels
# ===================================================================
# AWS cloud-controller-manager writes topology.k8s.aws/network-node-layer-1
# on every node when it Initializes. Returns 0 once at least one node in
# the NG carries layer-1, 1 on timeout.
_topo_wait_aws_topology_labels() {
    local ng_name=$1
    local timeout=${TOPO_K8S_JOIN_TIMEOUT_SEC:-300}

    local deadline=$(( $(date +%s) + timeout ))
    while [ $(date +%s) -lt ${deadline} ]; do
        local labeled
        labeled=$(kubectl get nodes \
            -l "eks.amazonaws.com/nodegroup=${ng_name},topology.k8s.aws/network-node-layer-1" \
            -o name 2>/dev/null | wc -l)
        if [ "${labeled}" -gt 0 ]; then
            return 0
        fi

        local total
        total=$(kubectl get nodes \
            -l "eks.amazonaws.com/nodegroup=${ng_name}" \
            -o name 2>/dev/null | wc -l)
        echo "  waiting for AWS topology labels: ${labeled}/${total} nodes have topology.k8s.aws/network-node-layer-1" >&2
        sleep 10
    done
    echo "  HINT: topology labels are written by cloud-controller-manager." \
         "Check 'kubectl get pods -n kube-system -l app=cloud-controller-manager' if labels never appear." >&2
    return 1
}

# ===================================================================
# Internal: read AWS-native topology labels from nodes in a nodegroup
# ===================================================================
# Echoes a JSON array, one entry per node:
#   [{
#     node:         "ip-10-0-12-145.us-west-2.compute.internal",
#     az:           "us-west-2b",
#     zone_id:      "usw2-az2",
#     layers:       ["nn-top", "nn-mid", "nn-bottom"],   # AWS top-down order
#     bottom_layer: 3,                                    # number of layers
#     bottom_node:  "nn-bottom"                           # last entry of layers[]
#   }, ...]
#
# The jq pipeline:
#   1. select nodes that have at least topology.k8s.aws/network-node-layer-1
#   2. for each such node, collect labels matching ^topology.k8s.aws/network-node-layer-([0-9]+)$
#      into a sparse array indexed by N (1-based)
#   3. compact + sort by N → top-down layers[]
_topo_query_from_k8s_labels() {
    local ng_name=$1

    kubectl get nodes \
        -l "eks.amazonaws.com/nodegroup=${ng_name},topology.k8s.aws/network-node-layer-1" \
        -o json 2>/dev/null \
        | jq '
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
               az:           ($node.metadata.labels["topology.kubernetes.io/zone"]
                              // $node.metadata.labels["failure-domain.beta.kubernetes.io/zone"]
                              // "unknown"),
               zone_id:      ($node.metadata.labels["topology.k8s.aws/zone-id"] // "unknown"),
               layers:       $layers,
               bottom_layer: ($layers | length),
               bottom_node:  ($layers | last)
             }
           | select(.bottom_layer > 0)]'
}

# ===================================================================
# Public: print_topology_inventory <ng_name> [min_size]
# ===================================================================
# Prints a per-nodegroup inventory grouped by the bottom-layer network
# node (the AWS-native "network node connected to the instance").
#
# Args:
#   $1 ng_name   EKS nodegroup name (required)
#   $2 min_size  threshold for "multi-node group" highlight (default 2)
#
# Writes:
#   - human-readable inventory to stdout
print_topology_inventory() {
    local ng_name=$1
    local min_size=${2:-2}

    if [ -z "${ng_name}" ]; then
        echo "ERROR: print_topology_inventory requires a nodegroup name" >&2
        return 1
    fi

    # cloud-controller-manager writes the topology labels asynchronously
    # after a node becomes Ready. When called right after NG goes ACTIVE
    # the labels may still be missing — wait briefly so we don't
    # mis-report "no labels" on an otherwise-healthy NG.
    if ! _topo_wait_aws_topology_labels "${ng_name}"; then
        echo "  WARN: timed out waiting for AWS topology labels on NG ${ng_name}; reporting what's available" >&2
    fi

    local topo_json
    topo_json=$(_topo_query_from_k8s_labels "${ng_name}")

    if [ -z "${topo_json}" ] || [ "${topo_json}" = "null" ]; then
        echo ""
        echo "=== Topology inventory for NG ${ng_name}: no nodes with AWS topology labels ==="
        echo "    (cloud-controller-manager writes topology.k8s.aws/network-node-layer-N on Initialize;"
        echo "     check 'kubectl get pods -n kube-system -l app=cloud-controller-manager' if absent)"
        return 0
    fi

    local node_count
    node_count=$(echo "${topo_json}" | jq 'length')
    if [ "${node_count}" -eq 0 ]; then
        echo ""
        echo "=== Topology inventory for NG ${ng_name}: 0 nodes ==="
        return 0
    fi

    # All nodes in a single managed NG run the same instance type, so the
    # number of layers is uniform — but check just in case.
    local layer_counts
    layer_counts=$(echo "${topo_json}" | jq -r '[.[].bottom_layer] | unique | join(",")')
    local distinct_layer_counts
    distinct_layer_counts=$(echo "${layer_counts}" | tr ',' '\n' | wc -l)

    if [ "${distinct_layer_counts}" -ne 1 ]; then
        echo ""
        echo "=== Topology inventory for NG ${ng_name} ==="
        echo "  WARN: nodes report mixed layer counts (${layer_counts}); inventory grouped per node"
        echo "${topo_json}" | jq -r '.[] |
            "    \(.node)  zone-id=\(.zone_id)  bottom-layer=\(.bottom_layer)  bottom-node=\(.bottom_node)  layers=[\(.layers | join(", "))]"'
        return 0
    fi

    local bottom_layer
    bottom_layer=$(echo "${topo_json}" | jq -r '.[0].bottom_layer')

    echo ""
    echo "=== Topology inventory for NG ${ng_name} ==="
    echo "    ${node_count} node(s); ${bottom_layer} layers per instance (AWS top-down)"
    echo "    bottom layer = topology.k8s.aws/network-node-layer-${bottom_layer}"
    echo ""

    printf "    %-46s  %-10s  %s\n" "NODE" "ZONE-ID" "BOTTOM-NODE (network-node-layer-${bottom_layer})"
    echo "${topo_json}" | jq -r '.[] |
        "\(.node)\t\(.zone_id)\t\(.bottom_node)"' \
        | while IFS=$'\t' read -r node zid bnode; do
            printf "    %-46s  %-10s  %s\n" "${node}" "${zid}" "${bnode}"
        done

    # Group by bottom-layer network node
    local groups
    groups=$(echo "${topo_json}" | jq '
        group_by(.bottom_node)
        | map({
            bottom_node: .[0].bottom_node,
            zone_id:     .[0].zone_id,
            count:       length,
            nodes:       [.[].node]
          })
        | sort_by(-.count)')

    echo ""
    echo "=== Multi-node groups in NG ${ng_name} (>= ${min_size} nodes share the same bottom-layer network node) ==="
    local eligible
    eligible=$(echo "${groups}" | jq --arg min "${min_size}" \
        '[.[] | select(.count >= ($min|tonumber))]')
    local eligible_count
    eligible_count=$(echo "${eligible}" | jq 'length')

    if [ "${eligible_count}" -eq 0 ]; then
        echo "  (none — all bottom-layer groups have fewer than ${min_size} nodes)"
        return 0
    fi

    echo "${eligible}" | jq -r '.[] |
        "  bottom-node=\(.bottom_node)  zone-id=\(.zone_id)  count=\(.count)"'

    echo ""
    echo "Workload nodeAffinity snippet (NG ${ng_name} → ${bottom_layer}-layer instance type):"
    local first_bnode first_zid
    first_bnode=$(echo "${eligible}" | jq -r '.[0].bottom_node')
    first_zid=$(echo "${eligible}" | jq -r '.[0].zone_id')
    cat <<YAML
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - { key: topology.k8s.aws/network-node-layer-${bottom_layer}, operator: In, values: [${first_bnode}] }
          - { key: topology.k8s.aws/zone-id,                            operator: In, values: [${first_zid}] }
YAML
}
