#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Verifying Karpenter Controller Scheduling ==="

# 1. 设置环境变量
source "${PROJECT_ROOT}/scripts/0_setup_env.sh"

# 1.1 验证 kubectl context
verify_kubectl_context
echo ""

# 2. 检查当前 Karpenter Controller 的调度位置
echo ""
echo "Step 1: Checking current Karpenter controller pods..."
echo ""
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o wide

# 3. 检查 Karpenter controller 是否在 system 节点上
echo ""
echo "Step 2: Verifying Karpenter controller node placement..."

KARPENTER_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o json)
TOTAL_PODS=$(echo "$KARPENTER_PODS" | jq '.items | length')

if [ "$TOTAL_PODS" -eq 0 ]; then
    echo "  ✗ ERROR: No Karpenter controller pods found!"
    exit 1
fi

echo "  Found $TOTAL_PODS Karpenter controller pod(s)"

# 检查每个 Pod 的节点
ALL_ON_SYSTEM=true
echo "$KARPENTER_PODS" | jq -r '.items[] | "\(.metadata.name) \(.spec.nodeName)"' | while read POD_NAME NODE_NAME; do
    NODE_TYPE=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.node-group-type}' 2>/dev/null || echo "unknown")
    echo "  Pod: $POD_NAME -> Node: $NODE_NAME (type: $NODE_TYPE)"

    if [ "$NODE_TYPE" != "system" ]; then
        ALL_ON_SYSTEM=false
    fi
done

# 4. 检查 Karpenter Deployment 的 nodeSelector 配置
echo ""
echo "Step 3: Checking Karpenter Deployment nodeSelector..."
NODE_SELECTOR=$(kubectl get deployment karpenter -n kube-system -o jsonpath='{.spec.template.spec.nodeSelector}' 2>/dev/null || echo "{}")

if echo "$NODE_SELECTOR" | grep -q "node-group-type"; then
    echo "  ✓ nodeSelector is configured correctly:"
    kubectl get deployment karpenter -n kube-system -o jsonpath='{.spec.template.spec.nodeSelector}' | jq .
else
    echo "  ✗ nodeSelector is NOT configured or missing node-group-type"
    echo "  Current nodeSelector: $NODE_SELECTOR"
fi

# 5. 如果 Karpenter pods 不在 system 节点上，提供重启建议
echo ""
echo "Step 4: Checking if restart is needed..."

PODS_NOT_ON_SYSTEM=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o json | \
    jq -r '.items[] | select(.spec.nodeName as $node |
    ($node | . as $n |
    (kubectl get node $n -o jsonpath="{.metadata.labels.node-group-type}" |
    if . != "system" then true else false end)))' 2>/dev/null || echo "")

# 检查是否需要重启
NEEDS_RESTART=false
for POD_NAME in $(kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[*].metadata.name}'); do
    NODE_NAME=$(kubectl get pod "$POD_NAME" -n kube-system -o jsonpath='{.spec.nodeName}')
    NODE_TYPE=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.node-group-type}' 2>/dev/null || echo "unknown")

    if [ "$NODE_TYPE" != "system" ]; then
        NEEDS_RESTART=true
        break
    fi
done

if [ "$NEEDS_RESTART" = true ]; then
    echo "  ⚠ Some Karpenter pods are NOT on system nodes"
    echo ""

    # 支持非交互模式: AUTO_RESTART_KARPENTER=yes|no
    RESTART_KARPENTER="${AUTO_RESTART_KARPENTER:-}"

    if [ -z "$RESTART_KARPENTER" ]; then
        echo "Do you want to restart Karpenter pods to reschedule them? (yes/no)"
        echo "For non-interactive mode, set AUTO_RESTART_KARPENTER=yes or AUTO_RESTART_KARPENTER=no"
        read -r RESPONSE
        RESTART_KARPENTER="$RESPONSE"
    else
        echo "AUTO_RESTART_KARPENTER is set to: $RESTART_KARPENTER"
    fi

    if [ "$RESTART_KARPENTER" = "yes" ] || [ "$RESTART_KARPENTER" = "y" ]; then
        echo ""
        echo "Step 5: Restarting Karpenter pods..."
        kubectl rollout restart deployment karpenter -n kube-system
        echo "  ✓ Rollout restart initiated"

        echo ""
        echo "Waiting for rollout to complete..."
        kubectl rollout status deployment karpenter -n kube-system --timeout=300s

        echo ""
        echo "New pod placement:"
        kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o wide
    else
        echo "  Skipping restart"
    fi
else
    echo "  ✓ All Karpenter pods are already on system nodes"
fi

# 6. 显示所有节点信息
echo ""
echo "Step 6: Current cluster nodes:"
kubectl get nodes -L node-group-type,karpenter.sh/nodepool -o wide

# 7. 显示最终状态
echo ""
echo "=== Verification Complete ==="
echo ""
echo "Summary:"
echo "  - Karpenter controller pods: $TOTAL_PODS"
echo "  - Expected node type: system (eks-utils managed node group)"
echo "  - NodeSelector configured: $(echo "$NODE_SELECTOR" | grep -q "node-group-type" && echo "Yes" || echo "No")"
echo ""
echo "Next steps:"
echo "  1. Check Karpenter logs: kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter"
echo "  2. Verify NodePools: kubectl get nodepool"
echo "  3. Verify EC2NodeClasses: kubectl get ec2nodeclass"
echo ""
