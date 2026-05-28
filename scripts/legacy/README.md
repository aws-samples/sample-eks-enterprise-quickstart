# scripts/legacy/

> **状态**：maintenance-only。新部署请使用 [`terraform/`](../../terraform/)。

这些是旧的 bash 部署管线，已被 `terraform/modules/` 下的等价模块取代。保留在仓库中是为了：

1. 让已经用 bash 部署的集群仍能用同一份脚本做小修补；
2. 作为 terraform 模块行为的参考实现。

**不要在这里加新功能。** 新能力一律走 terraform。如需修复 bug 且 terraform 已有等价实现，优先在 terraform 端修复，并在这里同步打补丁仅当下游用户暂时无法迁移时才必要。

## 文件清单

| 旧 bash | terraform 等价物 |
|---|---|
| `1_enable_vpc_dns.sh` + `3_create_vpc_endpoints.sh` | `terraform/modules/vpc-endpoints` |
| `2_validate_network_environment.sh` | terraform plan 阶段 `data` 块 |
| `4_install_eks_cluster.sh` | `terraform/modules/eks-cluster` |
| `5_check_environment.sh` | n/a（操作员 CLI 自查） |
| `6_create_system_nodegroup.sh` | `terraform/modules/eks-system-nodegroup` |
| `7_install_eks_addon.sh` | `terraform/modules/eks-addons` |
| `option_install_csi_drivers.sh` | `terraform/modules/eks-csi-drivers` |
| `option_install_karpenter.sh` | `terraform/modules/eks-karpenter` |
| `option_install_gpu_nodegroups.sh` | `terraform/modules/eks-gpu-nodegroup` |
| `option_install_gpu_stack.sh` | `terraform/modules/eks-gpu-stack` |
| `pod_identity_helpers.sh` | `aws_eks_pod_identity_association` 资源 |
| `instance_arch_lib.sh` | `data "aws_ec2_instance_type"` |
| `disk_detection_lib.sh` | `terraform/modules/eks-{system,gpu}-nodegroup/templates/detect-ebs-disk.sh` |

完整映射见 [`docs/MIGRATION_FROM_BASH.md`](../../docs/MIGRATION_FROM_BASH.md)。

## 共享 lib 位于何处

`0_setup_env.sh` 和 `topology_inventory_lib.sh` 留在 `scripts/`（父目录）下，因为运维工具（`option_inspect_eks.sh` 等）也用它们。本目录内的脚本通过 `${SCRIPT_DIR}/../0_setup_env.sh` 引用。

## 退役计划

预计在 terraform 路径稳定 6 个月后（约 2026-12）评估是否完全删除本目录。在此之前 PR 仍可针对 legacy 脚本，但请同步在 PR 描述里说明为何不能直接迁 terraform。
