# EKS 集群部署文档

## 文档目录

| 文档 | 描述 |
|------|------|
| [../terraform/README.md](../terraform/README.md) | **推荐路径**：terraform 部署完整流程 |
| [BASTION_IAM_POLICY.md](BASTION_IAM_POLICY.md) | terraform 部署运行账号所需 IAM 策略与威胁模型 |
| [MIGRATION_FROM_BASH.md](MIGRATION_FROM_BASH.md) | bash 脚本 ↔ terraform 模块映射、变量对照 |
| [DEPLOYMENT_SOP.md](DEPLOYMENT_SOP.md) | legacy bash 部署流程（已废弃，仅供存量参考） |
| [DESIGN.md](DESIGN.md) | 架构设计和技术决策 |
| [COLLABORATION.md](COLLABORATION.md) | 协作和贡献指南 |

## CSI 驱动配置

### Terraform 模块（推荐）

| 模块 | 启用变量 |
|------|---------|
| `terraform/modules/eks-csi-drivers` | `install_efs_csi` / `install_fsx_csi` / `install_s3_csi` |

### Legacy 脚本

| 脚本 | 功能 |
|------|------|
| `scripts/legacy/option_install_csi_drivers.sh` | CSI Drivers 统一安装脚本 |
| `scripts/legacy/pod_identity_helpers.sh` | Pod Identity 配置函数库 |

### 配置文件

| 文件 | 用途 |
|------|------|
| `terraform/assets/iam/bastion-policy.json` | terraform 运行账号 IAM 策略（详见 [BASTION_IAM_POLICY.md](BASTION_IAM_POLICY.md)） |
| `terraform/assets/iam/fsx-csi-policy.json` | FSx IAM 策略模板（terraform + legacy 共用） |
| `scripts/legacy/manifests/storage/storageclass.yaml` | StorageClass 定义（仅 legacy 用） |

> **Note**: EFS/FSx/S3 CSI Drivers 通过 EKS Managed Addon 安装，无需本地 manifest 文件。

## CSI Drivers 概述

| Driver | 用途 | 访问模式 |
|--------|------|----------|
| **EBS CSI** | 块存储 | RWO |
| **EFS CSI** | 文件系统 | RWX |
| **FSx Lustre CSI** | 高性能文件系统 | RWX |
| **S3 Mountpoint CSI** | 对象存储 | RWX |

## 外部资源

- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [EBS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [EFS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html)
- [FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/)
- [S3 Express One Zone](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-one-zone.html)
