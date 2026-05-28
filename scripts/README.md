# scripts/

运维与校验工具。**基础设施部署请使用 [`terraform/`](../terraform/)。**

| 脚本 | 用途 |
|---|---|
| `option_inspect_eks.sh` | 集群健康检查（9 项），terraform apply 后或排障时使用 |
| `option_verify_gpu_efa.sh` | 跨节点 NCCL benchmark，验证 EFA 多网卡 + GPUDirect 性能 |
| `option_show_nodegroup_topology.sh` | 按节点组打印 AWS 原生拓扑标签（`topology.k8s.aws/network-node-layer-*`） |
| `option_create_bastion.sh` | 创建 SSM-only 堡垒机（私有集群部署入口）。terraform 等价物：`terraform/bootstrap-bastion/` |
| `0_setup_env.sh` | 加载 `.env`、设置 AWS Region/Account 等共享上下文 |
| `topology_inventory_lib.sh` | `option_show_nodegroup_topology.sh` 与 GPU 校验脚本共享的 lib |

## 为什么不用 terraform

这些都是命令式操作 / 运行时观测：实时读 K8s label、跑 NCCL benchmark、临时实例生命周期、CLI 输出。塞进 terraform 模块只会扭曲两边的语义，没有收益。详见 [`terraform/README.md`](../terraform/README.md) 中 _What is intentionally NOT in Terraform_ 一节。

## legacy/

`legacy/` 子目录下保留着旧的 bash 部署管线（`1_*` ~ `7_*` 与 `option_install_*`），已被 terraform 模块取代，进入 maintenance-only。详情见 [`legacy/README.md`](legacy/README.md)。
