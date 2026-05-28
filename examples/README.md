# Karpenter NodePool 测试

本目录包含用于测试 Karpenter NodePool 自动扩缩容的测试清单。

## 测试文件

### 单个Pod测试
- `test-graviton-pod.yaml` - 测试 Graviton NodePool（Karpenter 从 `r/c/m` Graviton family 的 4-16 vCPU 实例中选择）
- `test-x86-pod.yaml` - 测试 x86 NodePool（Karpenter 从 `r/c/m` Intel 6/7 代 family 的 4-16 vCPU 实例中选择）

### Deployment测试
- `test-deployment-graviton.yaml` - 3副本测试 Graviton NodePool
- `test-deployment-x86.yaml` - 3副本测试 x86 NodePool

## 使用方法

### 测试 Graviton NodePool

1. **部署单个Pod**:
```bash
kubectl apply -f examples/test-graviton-pod.yaml
```

2. **查看Pod状态**:
```bash
kubectl get pod test-graviton -o wide
```

3. **查看Karpenter日志**:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50 -f
```

4. **查看新创建的节点**:
```bash
kubectl get nodes -l node-type=graviton
```

5. **验证节点类型**:
```bash
kubectl get node <node-name> -o json | jq '.metadata.labels'
```

6. **清理**:
```bash
kubectl delete -f examples/test-graviton-pod.yaml
```

### 测试 x86 NodePool

1. **部署单个Pod**:
```bash
kubectl apply -f examples/test-x86-pod.yaml
```

2. **查看Pod状态**:
```bash
kubectl get pod test-x86 -o wide
```

3. **查看Karpenter日志**:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50 -f
```

4. **查看新创建的节点**:
```bash
kubectl get nodes -l node-type=x86
```

5. **验证节点类型**:
```bash
kubectl get node <node-name> -o json | jq '.metadata.labels'
```

6. **清理**:
```bash
kubectl delete -f examples/test-x86-pod.yaml
```

### 测试自动扩缩容 (Deployment)

#### 测试 Graviton 扩容

1. **部署Deployment (3副本)**:
```bash
kubectl apply -f examples/test-deployment-graviton.yaml
```

2. **观察节点创建**:
```bash
watch kubectl get nodes -l node-type=graviton
```

3. **扩容到10个副本**:
```bash
kubectl scale deployment test-graviton-deployment --replicas=10
```

4. **观察Karpenter自动创建节点**:
```bash
kubectl get pods -l app=test-graviton -o wide
kubectl get nodes -l node-type=graviton
```

5. **测试缩容 - 减少到1个副本**:
```bash
kubectl scale deployment test-graviton-deployment --replicas=1
```

6. **观察节点自动删除**（NodePool 默认 `consolidateAfter: 1h`，可在 `terraform/assets/karpenter/nodepool-graviton.yaml` 中按需调小）:
```bash
watch kubectl get nodes -l node-type=graviton
```

7. **清理**:
```bash
kubectl delete -f examples/test-deployment-graviton.yaml
```

#### 测试 x86 扩缩容

1. **部署Deployment (3副本)**:
```bash
kubectl apply -f examples/test-deployment-x86.yaml
```

2. **观察节点创建**:
```bash
watch kubectl get nodes -l node-type=x86
```

3. **扩容到10个副本**:
```bash
kubectl scale deployment test-x86-deployment --replicas=10
```

4. **观察Karpenter自动创建节点**:
```bash
kubectl get pods -l app=test-x86 -o wide
kubectl get nodes -l node-type=x86
```

5. **测试缩容 - 减少到1个副本**:
```bash
kubectl scale deployment test-x86-deployment --replicas=1
```

6. **观察节点自动删除**（NodePool 默认 `consolidateAfter: 1h`，可在 `terraform/assets/karpenter/nodepool-x86.yaml` 中按需调小）:
```bash
watch kubectl get nodes -l node-type=x86
```

7. **清理**:
```bash
kubectl delete -f examples/test-deployment-x86.yaml
```

## 预期行为

### 节点创建
- Karpenter 会根据 Pod 的资源请求和 nodeSelector 自动选择合适的 NodePool
- Graviton Pod 只会调度到 Graviton NodePool 的节点 (arm64, r/c/m family, 4-16 vCPU)
- x86 Pod 只会调度到 x86 NodePool 的节点 (amd64, r/c/m Intel family, 4-16 vCPU)
- 具体实例由 Karpenter 按成本/容量选择；memory 敏感的 Pod 请在 resources.requests 里显式声明 memory，避免被调度到 c-family 实例上 OOM

### 节点缩容
- 节点空闲后等待 `consolidateAfter`（NodePool 默认 1 小时）
- Karpenter 会自动删除空闲节点
- 每次最多删除 10% 的节点（budget 配置）

## 监控命令

### 查看所有 Karpenter 管理的节点
```bash
kubectl get nodes -l karpenter.sh/nodepool
```

### 查看 NodePool 状态
```bash
kubectl get nodepool
```

### 查看 EC2NodeClass 状态
```bash
kubectl get ec2nodeclass
```

### 查看 Karpenter 事件
```bash
kubectl get events -n kube-system --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp'
```

### 实时查看 Karpenter 日志
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f
```

## 注意事项

1. **Taints 和 Tolerations**:
   - 当前 NodePool **没有**设置 taint（manifest 里已注释掉）
   - 如需专用节点，请在 NodePool.spec.template.spec.taints 下启用，并给测试 Pod 加对应 toleration

2. **节点选择器**:
   - 使用 `node-type=graviton` / `node-type=x86` 标签确保 Pod 调度到正确的 NodePool

3. **缩容时间**:
   - consolidateAfter 默认 1 小时
   - 删除 Pod 后，需要等待至少 1 小时才会触发缩容（可在 NodePool.spec.disruption 下调整）

4. **资源限制**:
   - 每个 NodePool 默认 1000 vCPU / 1000Gi 内存上限（`spec.limits`）
   - 具体节点数取决于 Karpenter 实际选到的实例规格，按实例的 vCPU × 实例数量加总 ≤ limits

5. **成本控制**:
   - NodePool 当前仅允许 on-demand；若可接受中断可在 `capacity-type` 加入 `spot`
   - 测试完成后请及时清理资源
