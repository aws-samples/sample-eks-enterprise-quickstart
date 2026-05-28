# EKS 集群部署标准操作流程 (SOP)

- **版本**: v1.3
- **最后更新**: 2026-01-11
- **适用范围**: EKS 1.35 集群自动化部署
- **执行环境**: AWS VPC 内的堡垒机 (Bastion Host)

---

> **方向说明（2026-05）**：本文档描述的是 **bash 部署路径**，目前已进入 maintenance-only。新部署请优先使用 [`terraform/`](../terraform/) 下的等价实现，参考 [`terraform/README.md`](../terraform/README.md) 与 [`docs/MIGRATION_FROM_BASH.md`](MIGRATION_FROM_BASH.md)。本文档保留作为已有 bash 部署集群的参考。

---

## 概述

部署生产级 EKS 集群，包括：私有 API 访问、多 AZ 高可用、LVM 存储隔离、Pod Identity 认证。

**部署架构**：
```
EKS Cluster (K8s 1.35)
├── 控制平面 (AWS 托管，私有 API Endpoint)
├── 系统节点组 (eks-utils): m8g.xlarge × 3（默认 Graviton4，可改 m7i 等 Intel 机型），50GB 根卷 + 100GB LVM 数据卷
└── 核心组件: CoreDNS, Cluster Autoscaler, ALB Controller, EBS CSI Driver
```

**总耗时**: 35-50 分钟

---

## 前置条件

### 1. VPC 网络

**使用已有 VPC**（推荐）：需要 3 个私有子网 + 3 个公有子网 + NAT Gateway

**新建 VPC**：使用 [terraform-aws-modules/vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc)

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = false  # 生产环境：每个 AZ 一个 NAT
  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS 必需标签
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}
```

### 2. 堡垒机

由于集群使用私有 API，**必须**从 VPC 内部执行部署。

| 项目 | 规格 |
|------|------|
| 实例类型 | t3.micro / t3.small |
| 操作系统 | Amazon Linux 2023 |
| IAM 角色 | AdministratorAccess |
| 访问方式 | Session Manager |

### 3. 工具依赖

```bash
# Amazon Linux 2023 一键安装
sudo yum update -y && sudo yum install -y git unzip tar gzip jq

# kubectl — pick the latest patch matching the cluster minor (K8S_VERSION
# in .env, e.g. 1.35). Following the cluster minor keeps kubectl within
# the supported skew window across cluster upgrades.
: "${K8S_VERSION:=1.35}"
KUBECTL_VERSION=$(curl -fsSL "https://dl.k8s.io/release/stable-${K8S_VERSION}.txt") \
    || { echo "ERROR: Failed to resolve stable kubectl version for K8S_VERSION=${K8S_VERSION}" >&2; exit 1; }
curl -fLO --retry 3 --retry-delay 5 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
curl -fLO --retry 3 --retry-delay 5 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl kubectl.sha256

# eksctl
curl -sL "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

## 部署流程

### 第一阶段：准备堡垒机

**执行位置**：VPC 外部（CloudShell / 本地终端）

```bash
# 1. 克隆项目
git clone <your-repository-url> eks-cluster-deployment
cd eks-cluster-deployment

# 2. 设置环境变量
export VPC_ID=vpc-xxxxx
export PRIVATE_SUBNET_A=subnet-xxxxx
export AWS_REGION=eu-central-1
export CLUSTER_NAME=eks-demo-1

# 3. 创建堡垒机
REUSE_BASTION=no ./scripts/option_create_bastion.sh

# 4. 连接到堡垒机
INSTANCE_ID=$(cat /tmp/eks-bastion-instance-id.txt)
aws ssm start-session --target $INSTANCE_ID --region ${AWS_REGION}
```

**在堡垒机上**：

```bash
# 安装工具（参考上面的一键安装命令）

# 克隆项目并配置
cd ~ && git clone <your-repository-url> eks-cluster-deployment
cd eks-cluster-deployment
cp .env.example .env
vim .env  # 填写必填配置

# 验证配置
chmod +x scripts/*.sh
source scripts/0_setup_env.sh
```

**.env 必填配置**：
```bash
CLUSTER_NAME=eks-demo-1
VPC_ID=vpc-xxxxxxxxx
PRIVATE_SUBNET_A/B/C=subnet-xxx  # 3 个私有子网
PUBLIC_SUBNET_A/B/C=subnet-xxx   # 3 个公有子网
AWS_REGION=eu-central-1
```

**.env 可选配置（SSH 访问）**：

| 配置项 | 适用范围 | 说明 |
|--------|----------|------|
| `EC2_KEY_NAME` | 系统节点组 + GPU 节点组 | EC2 密钥对名称（区分大小写） |
| `SSH_PUBLIC_KEY` | Karpenter 节点 | SSH 公钥内容（通过 userData 注入） |

```bash
# 系统节点组 + GPU 节点组 SSH 访问（使用 EC2 密钥对）
# 注意：密钥名称区分大小写，必须与 AWS 控制台中显示的名称完全一致
EC2_KEY_NAME=my-eks-key

# Karpenter 节点 SSH 访问（使用公钥内容）
# 获取公钥：cat ~/.ssh/id_rsa.pub
SSH_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... user@host"
```

> **说明**：如不配置上述选项，所有节点默认通过 SSM Session Manager 访问。

### 第二阶段：选择集群访问模式（重要）

在部署前，根据使用场景在 `.env` 中设置访问模式：

#### Private 模式（默认，生产推荐）

API Server 仅 VPC 内可访问，所有节点流量不出 VPC。

```bash
# .env 中无需额外配置，CLUSTER_MODE 默认为 private
# 自动创建全部 14 个 VPC Endpoints（13 Interface + 1 S3 Gateway）
# 估算成本：~$210/月（2AZ），~$315/月（3AZ）
```

执行环境要求：**所有 kubectl 命令必须在 VPC 内（堡垒机）执行**。

适用场景：生产环境、需满足 PCI-DSS/金融等合规要求。

#### Public 模式（开发 / 测试可选）

API Server 同时开放公网 + VPC 私有访问，可从任意网络执行 kubectl。

```bash
# .env 追加：
CLUSTER_MODE=public

# 强烈建议限制允许访问 API 的 IP 范围（逗号分隔）
PUBLIC_ACCESS_CIDRS=203.0.113.0/24,198.51.100.0/24

# 自动创建最小化 VPC Endpoints（仅 4 Interface + 1 S3 Gateway）
# 估算成本：~$50/月（2AZ），节省约 $160/月
# 其余流量经 NAT Gateway 走公网
```

**两种模式的 VPC Endpoint 对比**：

| Endpoint | Private 模式 | Public 模式 | 说明 |
|----------|:---:|:---:|------|
| `eks` | ✅ | ✅ | 节点注册 API Server，必须 |
| `eks-auth` | ✅ | ✅ | Pod Identity，无公网替代 |
| `sts` | ✅ | ✅ | Pod Identity 凭证，调用量大 |
| `ec2` | ✅ | ✅ | EBS CSI + nodeadm，调用量大 |
| `s3`（Gateway，免费）| ✅ | ✅ | 镜像拉取，降低 NAT 成本 |
| `ecr.api` / `ecr.dkr` | ✅ | ❌ 省略 | 可走 NAT Gateway |
| `logs` | ✅ | ❌ 省略 | CloudWatch 有公网端点 |
| `autoscaling` | ✅ | ❌ 省略 | 可走 NAT Gateway |
| `elasticloadbalancing` | ✅ | ❌ 省略 | 可走 NAT Gateway |
| `elasticfilesystem` | ✅ | ❌ 省略 | 可走 NAT Gateway |
| `ssm` / `ssmmessages` / `ec2messages` | ✅ | ❌ 省略 | 公网 SSM 仍可用 |

> **注意**：Public 模式中，`privateAccess` 始终为 `true`，不支持纯公网（`privateAccess: false`）模式，节点注册必须通过私有通道。

### 第三阶段：配置 VPC 网络

**执行位置**：堡垒机（private 模式）或任意网络（public 模式）

```bash
./scripts/legacy/1_enable_vpc_dns.sh        # 启用 DNS（10秒）
./scripts/legacy/2_validate_network_environment.sh  # 可选：验证网络
./scripts/legacy/3_create_vpc_endpoints.sh  # 创建 VPC Endpoints（2-3分钟）
                                     # private 模式：创建 13+1 个
                                     # public 模式：创建 4+1 个
```

### 第四阶段：创建 EKS 集群

```bash
./scripts/legacy/4_install_eks_cluster.sh   # 创建控制平面（8-10分钟）
```

验证：
```bash
aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.status'
# 应返回: "ACTIVE"
```

### 第五阶段：创建系统节点组

> **注意**: 脚本会先通过 `curl /healthz` 检测集群 API 可达性。Private 模式集群必须从 VPC 内部（堡垒机）执行。

```bash
AUTO_DELETE_NODEGROUP=yes ./scripts/legacy/6_create_system_nodegroup.sh  # 8-12分钟
```

验证：
```bash
kubectl get nodes -o wide  # 应显示 3 个 Ready 节点
```

### 第六阶段：安装集群组件

```bash
./scripts/legacy/7_install_eks_addon.sh     # 5-8分钟
```

验证：
```bash
kubectl get pods -A  # 所有 Pod 应为 Running
aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION}
```

---

## 验证和测试

### 集群状态

```bash
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A
kubectl top nodes
```

### 测试自动扩缩容

```bash
# 部署测试应用
kubectl create deployment autoscaler-test --image=nginx:alpine --replicas=1
kubectl set resources deployment autoscaler-test --requests=cpu=1000m,memory=1Gi

# 扩容触发自动扩容
kubectl scale deployment autoscaler-test --replicas=10
watch kubectl get nodes

# 清理
kubectl delete deployment autoscaler-test
```

### 测试 Load Balancer

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/examples/2048/2048_full.yaml
kubectl get ingress -n game-2048 -w
kubectl delete namespace game-2048
```

### 测试存储

**EBS**：
```bash
kubectl apply -f examples/ebs-app.yaml
kubectl get pvc
kubectl delete -f examples/ebs-app.yaml
```

**EFS**（需先安装驱动）：
```bash
INSTALL_DRIVERS=efs ./scripts/legacy/option_install_csi_drivers.sh
export EFS_ID=fs-xxx
# 参考 examples/ 目录下的测试文件
```

**FSx Lustre**（GPU 场景）：
```bash
INSTALL_DRIVERS=fsx ./scripts/legacy/option_install_csi_drivers.sh
export FSX_ID=fs-xxx
export FSX_DNS=$(aws fsx describe-file-systems --file-system-ids ${FSX_ID} --region ${AWS_REGION} --query 'FileSystems[0].DNSName' --output text)
export FSX_MOUNT_NAME=$(aws fsx describe-file-systems --file-system-ids ${FSX_ID} --region ${AWS_REGION} --query 'FileSystems[0].LustreConfiguration.MountName' --output text)
envsubst < examples/fsx-app.yaml | kubectl apply -f -
```

**S3**：
```bash
INSTALL_DRIVERS=s3 S3_BUCKET_ARNS='arn:aws:s3:::my-bucket' ./scripts/legacy/option_install_csi_drivers.sh
# 参考 examples/ 目录下的测试文件
```

---

## 可选组件

```bash
# Karpenter（更灵活的自动扩缩容）
./scripts/legacy/option_install_karpenter.sh

# GPU 节点组
./scripts/legacy/option_install_gpu_nodegroups.sh

# 测试脚本
./examples/option_test_pod_scheduling.sh
./examples/option_test_karpenter_pools.sh
```

### GPU 节点组定价模式（互斥，仅选一种）

| 模式 | 环境变量 | 适用场景 |
|---|---|---|
| On-Demand | `DEPLOY_GPU_OD=true` | 标准按需价格 |
| Spot | `DEPLOY_GPU_SPOT=true`（默认） | 容错工作负载，成本敏感 |
| ODCR | `DEPLOY_GPU_ODCR=true` + `ODCR_IDS` + `ODCR_AZS` | 固定容量保障 + 按需价格 |
| Capacity Block | `DEPLOY_GPU_CB=true` + `CAPACITY_BLOCK_IDS` + `CAPACITY_BLOCK_AZS` | 短期锁定的 GPU 容量 |

> Capacity Block 模式会自动在 Launch Template 注入 `InstanceType` 和 `InstanceMarketOptions.MarketType=capacity-block`，`create-nodegroup` 省略 `--instance-types` 以规避与 LT 冲突。

### EFA 设备插件（必装）

脚本在创建 GPU 节点组后会自动部署 `aws-efa-k8s-device-plugin` DaemonSet，向集群暴露 `vpc.amazonaws.com/efa` 资源。相关环境变量：

```bash
INSTALL_EFA_DEVICE_PLUGIN=true        # 默认 true，关闭可设为 false
EFA_DEVICE_PLUGIN_VERSION=v0.5.19     # 镜像 tag
EFA_DEVICE_PLUGIN_IMAGE=              # 覆盖完整镜像地址（CN 区域或私有 ECR mirror 使用）
```

验证：
```bash
# 节点内核侧 EFA 设备
NODE=$(kubectl get nodes -l workload-type=gpu -o jsonpath='{.items[0].metadata.name}')
kubectl debug node/$NODE -it --image=amazonlinux:2023 -- \
  chroot /host bash -c 'ls /sys/class/infiniband/ && ls /dev/infiniband/'

# 插件 DaemonSet 状态
kubectl -n kube-system get ds aws-efa-k8s-device-plugin-daemonset

# 节点暴露的 EFA 资源数量（p5 应为 32）
kubectl describe node $NODE | grep 'vpc.amazonaws.com/efa'
```

Pod 请求 EFA 示例：
```yaml
resources:
  limits:
    nvidia.com/gpu: "8"
    vpc.amazonaws.com/efa: "32"
    hugepages-2Mi: 5120Mi
```

---

## 常见问题

### kubectl 无法连接

```bash
# 症状: The connection to the server localhost:8080 was refused
export KUBECONFIG="${HOME:-/root}/.kube/config"
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}
```

### kubectl 超时

```bash
# 症状: dial tcp 10.0.x.x:443: i/o timeout
# 原因: 安全组或 VPC Endpoints 问题
aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" --region ${AWS_REGION}
./scripts/legacy/6_create_system_nodegroup.sh  # 会自动配置安全组
```

### 节点 NotReady

```bash
kubectl describe node <node-name>
kubectl debug node/<node-name> -it --image=amazonlinux -- chroot /host journalctl -u kubelet -n 100

# 如果配置了 EC2_KEY_NAME，也可通过 SSH 访问
ssh -i ~/.ssh/my-key.pem ec2-user@<node-private-ip>
```

### Pod Identity 认证失败

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=eks-pod-identity-agent
aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION}
```

---

## 堡垒机管理

```bash
# 停止（节省成本）
aws ec2 stop-instances --instance-ids $INSTANCE_ID --region ${AWS_REGION}

# 启动
aws ec2 start-instances --instance-ids $INSTANCE_ID --region ${AWS_REGION}
```

---

## 参考文档

- [terraform-aws-modules/vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc)
- [AWS EKS 官方文档](https://docs.aws.amazon.com/eks/)
- [eksctl 文档](https://eksctl.io/)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

---

| 版本 | 日期 | 变更内容 |
|------|------|----------|
| v1.0 | 2025-12-29 | 初始版本 |
| v1.1 | 2026-01-10 | 修复脚本编号引用；简化 FSx 测试步骤 |
| v1.2 | 2026-01-11 | 合并 VPC_SETUP.md（该文件已并入本文件，不再单独存在）；大幅简化文档 |
| v1.3 | 2026-01-11 | 添加 SSH 密钥配置：系统/GPU 节点组 (EC2_KEY_NAME) 和 Karpenter 节点 (SSH_PUBLIC_KEY) |
