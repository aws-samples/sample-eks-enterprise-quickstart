# EKS 集群自动化部署

生产级 AWS EKS 集群自动化部署方案，支持私有 API 访问、LVM 存储配置、Pod Identity 认证。

[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.35-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-aws)](https://aws.amazon.com/eks/)
[![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A51.6-7B42BC?logo=terraform)](https://www.terraform.io/)
[![License](https://img.shields.io/badge/License-See%20LICENSE-informational)](LICENSE)

---

## 方向声明

**Terraform 是默认推荐路径。** 全部基础设施（VPC endpoints、控制平面、系统/GPU 节点组、addons、CSI、Karpenter、GPU stack）都在 `terraform/` 下有对应模块。新功能仅在 terraform 中实现，bash 部署脚本进入 **maintenance-only**——只接收安全/正确性修复，不再增加新能力。

| 用途 | 走哪条路 |
|---|---|
| 新建集群 / 日常基础设施变更 | **`terraform/`** |
| 已有 bash 部署的集群 | 维持现状；新集群迁 terraform，老集群随业务退役 |
| 运行时校验、benchmark、堡垒机生命周期 | `scripts/` 下保留的 ops 工具（`option_inspect_eks.sh`、`option_verify_gpu_efa.sh`、`option_show_nodegroup_topology.sh`、`option_create_bastion.sh`） |

详见 [`terraform/README.md`](terraform/README.md) 与 [`docs/MIGRATION_FROM_BASH.md`](docs/MIGRATION_FROM_BASH.md)。下文 bash 部署流程保留作为参考，后续会归档到 `scripts/legacy/`。

---

## 🚀 快速开始

### 前置要求

- ✅ 已有 VPC（包含公有/私有子网、NAT Gateway），或使用 `terraform/bootstrap-vpc/` 生成
- ✅ 堡垒机（私有集群必需），或使用 `terraform/bootstrap-bastion/` 创建
- ✅ 安装工具：terraform ≥ 1.6, kubectl, helm, aws-cli, jq

> ⚠️ **重要**：私有 API 模式下 terraform apply 必须从 VPC 内部执行。详见 [terraform/README.md](terraform/README.md)

### Terraform 部署（推荐）

```bash
cd terraform

# 1. 一次性 bootstrap state backend (S3 bucket + DynamoDB lock table)
#    bucket 名称全局唯一，建议带账号 ID 后缀；锁表默认派生为 "${bucket}-lock"。
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="eks-tfstate-${ACCOUNT_ID}-us-west-2"
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply \
  -var="bucket_name=${BUCKET}" -var="region=us-west-2"

# 2. 配置变量
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # 填写 vpc_id / subnet_ids / cluster_name 等

# 3. apply
mv backend.tf.disabled backend.tf
terraform init \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="key=eks-cluster-deployment/dev/terraform.tfstate" \
  -backend-config="region=us-west-2" \
  -backend-config="dynamodb_table=${BUCKET}-lock"
terraform plan
terraform apply

# 4. 验证（需要 kubectl 已配好）
../scripts/option_inspect_eks.sh
kubectl get nodes
```

**总耗时**：约 25-35 分钟（控制平面 8-10m + 系统 NG 8-12m + addons 5-8m）。

> 老的 bash 部署流程仍可在 [docs/DEPLOYMENT_SOP.md](docs/DEPLOYMENT_SOP.md) 找到，对应脚本现在位于 `scripts/legacy/`。

---

## 🏗️ 架构特性

### 核心功能

- ✅ **私有 API 访问** - 高安全性，API Server 不暴露公网
- ✅ **多 AZ 高可用** - 跨 3 个可用区部署
- ✅ **LVM 存储配置** - 系统节点自动配置 100GB LVM 数据卷
- ✅ **Pod Identity** - 使用 EKS Pod Identity 替代 IRSA
- ✅ **自动扩缩容** - Cluster Autoscaler 自动管理节点
- ✅ **完整 CSI 支持** - EBS/EFS/FSx/S3 存储驱动
- ✅ **GPU 节点支持** - P5/P5en/P6/G7e 实例 + EFA 多网卡 + `vpc.amazonaws.com/efa` 设备插件
- ✅ **EC2 拓扑感知调度** - 按节点组打印 cloud-controller-manager 写入的 `topology.k8s.aws/network-node-layer-N` 标签
- ✅ **同 bottom-layer 亲和** - workload 用 nodeAffinity 直接绑定 AWS 原生 label，挑出共享同一 bottom-layer network node 的子集（`GPU_TOPOLOGY_MODE=inventory`）

### 集群架构

```
EKS Cluster (Kubernetes 1.35)
├── Control Plane (AWS 托管)
│   └── 私有 API Endpoint (10.0.x.x)
│
├── 系统节点组 (eks-utils)
│   ├── 实例: m8g.xlarge (默认, Graviton4 ARM64) — 可通过 SYSTEM_NODE_INSTANCE_TYPE 切换为 m7i 等 Intel 机型
│   ├── 存储: 50GB 根卷 + 100GB LVM 数据卷
│   ├── 标签: app=eks-utils
│   └── 运行: CoreDNS, Cluster Autoscaler, LB Controller, CSI Drivers
│
└── 网络
    ├── VPC CNI (v1.18.5)
    ├── 私有子网 (3个 AZ)
    └── VPC Endpoints (13个)
```

---

## 📦 已集成组件

| 组件 | 版本 | 用途 |
|------|------|------|
| Kubernetes | 1.35 | 容器编排 |
| VPC CNI | v1.18.5 | Pod 网络 |
| CoreDNS | v1.11.3 | DNS 解析 |
| Pod Identity Agent | v1.3.4 | IAM 认证 |
| EBS CSI Driver | v1.37.0 | 块存储 |
| Cluster Autoscaler | v1.35.0 | 自动扩缩容 |
| AWS LB Controller | v2.13.0（helm chart 1.16.0） | 负载均衡 |
| Metrics Server | v0.7.2 | 资源指标 |

---

## 📋 部署流程

完整 terraform 流程请参考 **[terraform/README.md](terraform/README.md)**。bash 部署流程（已废弃，保留供已有用户参考）见 [docs/DEPLOYMENT_SOP.md](docs/DEPLOYMENT_SOP.md)。

### 模块/脚本说明

**Terraform 模块（推荐）**：

| 模块 | 用途 | 启用方式 |
|------|------|---------|
| `terraform/modules/vpc-endpoints` | 13 个接口端点 + S3 网关 | 默认 |
| `terraform/modules/eks-cluster` | 控制平面 + 基础 addon | 默认 |
| `terraform/modules/eks-system-nodegroup` | 系统节点组（LVM） | 默认 |
| `terraform/modules/eks-addons` | CoreDNS / Metrics / CA / ALB | 默认 |
| `terraform/modules/eks-csi-drivers` | EBS（默认）/ EFS / FSx / S3 | `install_*_csi=true` |
| `terraform/modules/eks-karpenter` | Karpenter + SQS 中断队列 | `install_karpenter=true` |
| `terraform/modules/eks-gpu-nodegroup` | GPU MNG + EFA 多网卡 | `install_gpu_nodegroups=true` |
| `terraform/modules/eks-gpu-stack` | nvidia 设备插件 / GPU Operator | `install_gpu_stack=true` |

**保留的运维脚本**：

| 脚本 | 用途 | 执行位置 |
|------|------|---------|
| `scripts/option_inspect_eks.sh` | 集群健康 9 项检查 | VPC 内 |
| `scripts/option_verify_gpu_efa.sh` | 跨节点 NCCL benchmark | VPC 内 |
| `scripts/option_show_nodegroup_topology.sh` | 打印 `topology.k8s.aws/...` 标签 | VPC 内 |
| `scripts/option_create_bastion.sh` | 创建 SSM-only 堡垒机 | VPC 外 |
| `examples/option_test_pod_scheduling.sh` | 测试 Pod 调度到系统节点 | VPC 内 |
| `examples/option_test_karpenter_pools.sh` | 测试 Karpenter 节点池 | VPC 内 |

> 旧 bash 部署脚本已迁至 `scripts/legacy/`，详见 [scripts/legacy/README.md](scripts/legacy/README.md)。

---

## 🎯 非交互模式（自动化）

Terraform 路径天然支持非交互（`terraform apply -auto-approve`）。

legacy bash 脚本通过环境变量控制（位于 `scripts/legacy/`）：

```bash
# 创建堡垒机（仍在 scripts/）
REUSE_BASTION=no ./scripts/option_create_bastion.sh

# legacy 部署（不推荐用于新集群）
AUTO_DELETE_NODEGROUP=yes ./scripts/legacy/6_create_system_nodegroup.sh
INSTALL_DRIVERS=efs ./scripts/legacy/option_install_csi_drivers.sh

# 测试脚本
AUTO_RESTART_KARPENTER=yes ./examples/option_test_pod_scheduling.sh
AUTO_CLEANUP_TEST=yes ./examples/option_test_karpenter_pools.sh
```

---

## ✅ 快速验证

```bash
# 1. 查看集群状态
kubectl get nodes -o wide
kubectl get pods -A

# 2. 测试 EBS CSI Driver
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources:
    requests:
      storage: 10Gi
EOF

kubectl get pvc test-pvc  # 应为 Bound 状态
kubectl delete pvc test-pvc

# 3. 测试 Load Balancer Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/examples/2048/2048_full.yaml
kubectl get ingress -n game-2048 -w  # 等待 ALB 创建
kubectl delete namespace game-2048
```

---

## 🔧 故障排查

### 问题 1: kubectl 无法连接集群

**错误**: `dial tcp 10.0.x.x:443: i/o timeout`

**原因**: 集群使用私有 API，必须从 VPC 内部访问

**解决**: 使用堡垒机执行，参考 [DEPLOYMENT_SOP.md - 第一阶段](docs/DEPLOYMENT_SOP.md#第一阶段准备堡垒机)

### 问题 2: Session Manager 无法连接堡垒机

**原因**: VPC 缺少 SSM 相关的 VPC Endpoints

**解决**: 用 terraform 路径时由 `terraform/modules/vpc-endpoints` 自动创建；legacy 路径运行 `./scripts/legacy/3_create_vpc_endpoints.sh`。

### 问题 3: 节点无法加入集群

**排查**:
```bash
# 1. 查看节点状态
kubectl describe node <node-name>

# 2. 检查安全组
aws eks describe-cluster --name ${CLUSTER_NAME} --query 'cluster.resourcesVpcConfig.securityGroupIds'

# 3. 查看节点日志（通过 SSM）
INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${CLUSTER_NAME}-eks-utils-node" --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ssm start-session --target $INSTANCE_ID
```

进入 SSM 会话后，在节点上运行：

```bash
sudo journalctl -u kubelet -f
```

更多故障排查请参考 [DEPLOYMENT_SOP.md - 常见问题](docs/DEPLOYMENT_SOP.md#常见问题)

---

## 🗑️ 清理资源

**Terraform 路径**：使用 `terraform/scripts/safe-destroy.sh`（先 `helm uninstall` 所有 release，再 `terraform destroy`）：

```bash
cd terraform
./scripts/safe-destroy.sh --var-file terraform.tfvars
# 如需也销毁 VPC：terraform -chdir=bootstrap-vpc destroy
```

详见 [terraform/README.md - Tearing down](terraform/README.md#tearing-down--use-scriptssafe-destroysh)。

**Legacy 集群**：

```bash
kubectl delete deployment,ingress,pvc --all -A   # 1. 清测试资源
sleep 60                                          # 2. 等 LB 释放
eksctl delete cluster --name=${CLUSTER_NAME} --region=${AWS_REGION} --wait
aws ec2 terminate-instances --instance-ids $(cat /tmp/eks-bastion-instance-id.txt)
```

---

## 📚 文档

- **[docs/README.md](docs/README.md)** - CSI Drivers 文档索引
- **[docs/DEPLOYMENT_SOP.md](docs/DEPLOYMENT_SOP.md)** - legacy bash 部署标准操作流程
- **[docs/MIGRATION_FROM_BASH.md](docs/MIGRATION_FROM_BASH.md)** - bash ↔ terraform 映射
- **[docs/DESIGN.md](docs/DESIGN.md)** - Pod 磁盘配额设计方案
- **[docs/AMI_VERSIONS.md](docs/AMI_VERSIONS.md)** - 已验证的 EKS AMI 版本
- **[docs/COLLABORATION.md](docs/COLLABORATION.md)** - 协作指南
- **[docs/P2_TOPOLOGY_RETRY_PLAN.md](docs/P2_TOPOLOGY_RETRY_PLAN.md)** - GPU 拓扑重试方案
- **[CONTRIBUTING.md](CONTRIBUTING.md)** / **[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)** - 贡献流程与行为准则

### 外部参考

- [AWS EKS 官方文档](https://docs.aws.amazon.com/eks/)
- [eksctl 文档](https://eksctl.io/)
- [Kubernetes 文档](https://kubernetes.io/docs/)
- [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

---

## 📊 项目结构

```
eks-cluster-deployment/
├── README.md                          # 本文档（快速入门）
├── CLAUDE.md                          # AI 协作上下文
├── CONTRIBUTING.md                    # 贡献指南
├── CODE_OF_CONDUCT.md                 # 行为准则
├── LICENSE                            # 许可证
├── .env.example                       # legacy bash 环境变量模板
│
├── terraform/                              # ★ 推荐路径
│   ├── README.md / main.tf / variables.tf / outputs.tf
│   ├── providers.tf / versions.tf / moved.tf
│   ├── backend.tf.disabled                 # bootstrap 后改名为 backend.tf
│   ├── terraform.tfvars.example
│   ├── bootstrap/                          # state backend (S3+DynamoDB)
│   ├── bootstrap-vpc/                      # 测试 VPC（可选）
│   ├── bootstrap-bastion/                  # 私有集群堡垒机
│   ├── modules/                            # vpc-endpoints / eks-cluster /
│   │                                       # eks-system-nodegroup / eks-addons /
│   │                                       # eks-csi-drivers / eks-karpenter /
│   │                                       # eks-gpu-nodegroup / eks-gpu-stack
│   ├── assets/                             # 模块引用的静态文件
│   │   ├── iam/                            # ALB / FSx IAM 策略 JSON
│   │   └── karpenter/                      # NodePool / EC2NodeClass YAML
│   └── scripts/safe-destroy.sh
│
├── scripts/                                # 运维/校验工具（保留为 bash）
│   ├── 0_setup_env.sh                      # 共享环境变量加载（ops + legacy 都用）
│   ├── topology_inventory_lib.sh           # 共享库：读 AWS 原生拓扑标签
│   ├── option_inspect_eks.sh               # 9 项集群健康检查
│   ├── option_verify_gpu_efa.sh            # 跨节点 NCCL benchmark
│   ├── option_show_nodegroup_topology.sh   # 打印节点组拓扑标签
│   ├── option_create_bastion.sh            # 创建堡垒机
│   └── legacy/                             # ★ 已废弃的 bash 部署管线
│       ├── README.md
│       ├── 1_*.sh ... 7_*.sh               # 旧的核心部署序列
│       ├── option_install_*.sh             # csi / karpenter / gpu / gpu-stack
│       ├── pod_identity_helpers.sh
│       ├── disk_detection_lib.sh
│       ├── instance_arch_lib.sh
│       └── manifests/                      # 仅 legacy 用的 YAML
│
├── examples/                               # 工作负载样例与测试脚本
│   ├── README.md
│   ├── option_test_pod_scheduling.sh
│   ├── option_test_karpenter_pools.sh
│   └── {ebs,efs,fsx,s3,nlb}-app.yaml ...
│
└── docs/                                   # 详细文档
    ├── README.md                           # CSI Driver 文档索引
    ├── DEPLOYMENT_SOP.md                   # legacy bash 部署流程
    ├── MIGRATION_FROM_BASH.md              # bash↔terraform 映射
    ├── DESIGN.md                           # 架构设计
    ├── AMI_VERSIONS.md                     # 已验证的 EKS AMI 版本
    ├── COLLABORATION.md                    # 协作指南
    └── P2_TOPOLOGY_RETRY_PLAN.md           # GPU 拓扑重试方案
```

> **Note**: 本仓库不创建生产 VPC。可使用 `terraform/bootstrap-vpc/` 临时生成测试 VPC，或自行准备 VPC 后再运行 terraform / legacy 流程。

---

## 📝 更新日志

### v2.1 (2026-01-03)
- ✅ Terraform 升为默认推荐路径，bash 部署进入 maintenance-only
- ✅ legacy bash 脚本归档至 `scripts/legacy/`
- ✅ 新增 GPU 节点组 / GPU stack / Karpenter terraform 模块
- ✅ 新增 EC2 拓扑感知调度（`topology.k8s.aws/network-node-layer-N`）
- ✅ 新增 `terraform/scripts/safe-destroy.sh`

### v2.0 (2025-12-29)
- ✅ 重构部署流程，分离控制平面和节点组创建
- ✅ 系统节点组自动配置 LVM（默认 m8g.xlarge + 100GB 数据卷，可切换为 m7i 等 Intel 机型）
- ✅ 所有脚本支持非交互模式（自动化友好）
- ✅ 统一使用 Pod Identity 认证（替代 IRSA）
- ✅ 简化 README，详细流程移至 DEPLOYMENT_SOP.md
- ✅ 删除冗余文件，优化文档结构

### v1.0 (2025-12-05)
- ✅ 初始版本
- ✅ 混合架构（Intel 系统节点）
- ✅ Cluster Autoscaler + AWS Load Balancer Controller
- ✅ EBS/EFS/S3 CSI Driver 支持

---

## 📄 License

本项目采用根目录 [`LICENSE`](LICENSE) 中声明的许可证。使用、修改或分发前请阅读相应条款。

---

**维护者**: Platform Team
**最后更新**: 2026-01-03
**文档版本**: v2.1
**完整部署流程**: [docs/DEPLOYMENT_SOP.md](docs/DEPLOYMENT_SOP.md)
