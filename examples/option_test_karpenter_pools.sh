#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Testing Karpenter Node Pools (Graviton & x86) ==="

# 1. 设置环境变量
source "${PROJECT_ROOT}/scripts/0_setup_env.sh"

# 1.1 验证 kubectl context
verify_kubectl_context
echo ""

# 2. 检查 NodePools
echo ""
echo "Step 1: Checking existing NodePools..."
echo ""
kubectl get nodepool -o wide

# 3. 检查 EC2NodeClasses
echo ""
echo "Step 2: Checking EC2NodeClasses..."
echo ""
kubectl get ec2nodeclass -o wide

# 4. 显示当前节点
echo ""
echo "Step 3: Current cluster nodes..."
echo ""
kubectl get nodes -L node-group-type,karpenter.sh/nodepool,kubernetes.io/arch -o wide

# 5. 创建测试部署 - Graviton (ARM64)
echo ""
echo "Step 4: Creating test deployment for Graviton pool..."
echo ""

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate-graviton
spec:
  replicas: 0
  selector:
    matchLabels:
      app: inflate-graviton
  template:
    metadata:
      labels:
        app: inflate-graviton
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64
        karpenter.sh/nodepool: graviton
      containers:
      - name: inflate
        image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
        resources:
          requests:
            cpu: 1
            memory: 1.5Gi
EOF

echo "  ✓ Created inflate-graviton deployment (targets Karpenter graviton pool only)"

# 6. 创建测试部署 - x86
echo ""
echo "Step 5: Creating test deployment for x86 pool..."
echo ""

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate-x86
spec:
  replicas: 0
  selector:
    matchLabels:
      app: inflate-x86
  template:
    metadata:
      labels:
        app: inflate-x86
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64
        karpenter.sh/nodepool: x86
      containers:
      - name: inflate
        image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
        resources:
          requests:
            cpu: 1
            memory: 1.5Gi
EOF

echo "  ✓ Created inflate-x86 deployment (targets Karpenter x86 pool only)"

# 7. 测试 Graviton 池子
echo ""
echo "Step 6: Testing Graviton pool provisioning..."
echo ""
echo "Scaling inflate-graviton to 5 replicas..."
kubectl scale deployment inflate-graviton --replicas=5

echo "Waiting 60 seconds for Karpenter to provision nodes..."
sleep 60

echo ""
echo "Checking pod status..."
kubectl get pods -l app=inflate-graviton -o wide

echo ""
echo "Checking new nodes (should see ARM64 nodes)..."
kubectl get nodes -L kubernetes.io/arch,karpenter.sh/nodepool --sort-by=.metadata.creationTimestamp

# 8. 测试 x86 池子
echo ""
echo "Step 7: Testing x86 pool provisioning..."
echo ""
echo "Scaling inflate-x86 to 5 replicas..."
kubectl scale deployment inflate-x86 --replicas=5

echo "Waiting 60 seconds for Karpenter to provision nodes..."
sleep 60

echo ""
echo "Checking pod status..."
kubectl get pods -l app=inflate-x86 -o wide

echo ""
echo "Checking new nodes (should see AMD64 nodes)..."
kubectl get nodes -L kubernetes.io/arch,karpenter.sh/nodepool --sort-by=.metadata.creationTimestamp

# 9. 显示详细的节点分布
echo ""
echo "Step 8: Node distribution summary..."
echo ""
echo "Graviton (ARM64) nodes:"
kubectl get nodes -l kubernetes.io/arch=arm64 --no-headers 2>/dev/null | wc -l || echo "0"
kubectl get nodes -l kubernetes.io/arch=arm64 -o wide 2>/dev/null || echo "  No ARM64 nodes found"

echo ""
echo "x86 (AMD64) nodes:"
kubectl get nodes -l kubernetes.io/arch=amd64,karpenter.sh/nodepool --no-headers 2>/dev/null | wc -l || echo "0"
kubectl get nodes -l kubernetes.io/arch=amd64,karpenter.sh/nodepool -o wide 2>/dev/null || echo "  No AMD64 Karpenter nodes found"

# 10. 检查 Karpenter 事件
echo ""
echo "Step 9: Recent Karpenter events..."
echo ""
kubectl get events -n kube-system --sort-by='.lastTimestamp' | grep -i karpenter | tail -20

# 11. 显示 Pod 到节点的映射
echo ""
echo "Step 10: Pod to Node mapping..."
echo ""
echo "Graviton pods:"
kubectl get pods -l app=inflate-graviton -o json | jq -r '.items[] | "\(.metadata.name) -> Node: \(.spec.nodeName) (\(.status.phase))"' 2>/dev/null || echo "  No pods found"

echo ""
echo "x86 pods:"
kubectl get pods -l app=inflate-x86 -o json | jq -r '.items[] | "\(.metadata.name) -> Node: \(.spec.nodeName) (\(.status.phase))"' 2>/dev/null || echo "  No pods found"

# 12. 清理选项
echo ""
echo "=== Test Complete ==="
echo ""

# 支持非交互模式: AUTO_CLEANUP_TEST=yes|no
CLEANUP_TEST="${AUTO_CLEANUP_TEST:-}"

if [ -z "$CLEANUP_TEST" ]; then
    echo "Do you want to clean up test deployments? (yes/no)"
    echo "For non-interactive mode, set AUTO_CLEANUP_TEST=yes or AUTO_CLEANUP_TEST=no"
    read -r RESPONSE
    CLEANUP_TEST="$RESPONSE"
else
    echo "AUTO_CLEANUP_TEST is set to: $CLEANUP_TEST"
fi

if [ "$CLEANUP_TEST" = "yes" ] || [ "$CLEANUP_TEST" = "y" ]; then
    echo ""
    echo "Cleaning up test deployments..."
    kubectl delete deployment inflate-graviton inflate-x86 --ignore-not-found=true
    echo "  ✓ Test deployments deleted"

    echo ""
    echo "Note: Karpenter will automatically deprovisioning idle nodes after the ttlSecondsAfterEmpty period"
    echo "You can check node status with: kubectl get nodes -w"
else
    echo ""
    echo "Keeping test deployments. To clean up later, run:"
    echo "  kubectl delete deployment inflate-graviton inflate-x86"
    echo ""
    echo "To scale down without deleting:"
    echo "  kubectl scale deployment inflate-graviton --replicas=0"
    echo "  kubectl scale deployment inflate-x86 --replicas=0"
fi

echo ""
echo "Summary:"
echo "  - Graviton test: inflate-graviton deployment (5 replicas on ARM64)"
echo "  - x86 test: inflate-x86 deployment (5 replicas on AMD64)"
echo ""
echo "Useful commands:"
echo "  - Watch nodes: kubectl get nodes -L kubernetes.io/arch,karpenter.sh/nodepool -w"
echo "  - Watch pods: kubectl get pods -l 'app in (inflate-graviton,inflate-x86)' -o wide -w"
echo "  - Karpenter logs: kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f"
echo "  - Check provisioning: kubectl get nodeclaim"
echo ""
