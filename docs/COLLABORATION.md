# 协作指南

本项目使用 **Fork + Pull Request** 工作流进行协作。

## 🍴 Fork + Pull Request 工作流

### 为什么使用 PR 工作流？

- ✅ **代码审查** - 所有更改都经过审查
- ✅ **保护主分支** - 防止错误直接进入 master
- ✅ **保留历史** - 完整的讨论和修改记录
- ✅ **适合团队** - 任意规模团队都适用

---

## 👥 协作者入门指南

### 1. Fork 项目

1. 访问项目主页: https://github.com/aws-samples/eks-cluster-deployment
2. 点击右上角的 **"Fork"** 按钮
3. 项目会被复制到你的 GitHub 账号下

### 2. 克隆你的 Fork

```bash
# 克隆你自己的 fork（不是原仓库）
git clone https://github.com/你的用户名/eks-cluster-deployment.git
cd eks-cluster-deployment
```

### 3. 配置 Git

```bash
# 配置身份
git config user.name "你的名字"
git config user.email "你的邮箱"

# 添加原仓库为 upstream（用于同步）
git remote add upstream https://github.com/aws-samples/eks-cluster-deployment.git

# 验证 remotes
git remote -v
# 应该看到:
# origin    你的fork地址 (fetch)
# origin    你的fork地址 (push)
# upstream  原仓库地址 (fetch)
# upstream  原仓库地址 (push)
```

### 4. 开始工作

#### 步骤 1: 同步最新代码

```bash
# 切换到 master 分支
git checkout master

# 从 upstream 拉取最新代码
git fetch upstream
git merge upstream/master

# 推送到你的 fork
git push origin master
```

#### 步骤 2: 创建功能分支

```bash
# 创建新分支
git checkout -b feature/add-monitoring

# 或者修复 bug
git checkout -b fix/resolve-timeout-issue
```

#### 步骤 3: 进行修改

```bash
# 修改文件
vim scripts/legacy/4_install_eks_cluster.sh

# 查看修改
git status
git diff
```

#### 步骤 4: 提交修改

```bash
# 添加文件
git add scripts/legacy/4_install_eks_cluster.sh

# 提交（遵循提交规范）
git commit -m "feat: add custom node labels support"
```

#### 步骤 5: 推送到你的 Fork

```bash
# 推送到你的 fork（不是原仓库）
git push origin feature/add-monitoring
```

#### 步骤 6: 创建 Pull Request

1. 访问你的 fork: `https://github.com/你的用户名/eks-cluster-deployment`
2. 看到黄色提示条 "Compare & pull request"，点击
3. 填写 PR 信息（会自动加载模板）
4. 点击 "Create pull request"

✅ 完成！现在等待维护者审查你的 PR。

---

## 📋 工作流程规范

### 提交前检查

- [ ] 测试你的修改
- [ ] 确保脚本可以正常运行
- [ ] 遵循项目代码风格
- [ ] 写清晰的提交信息

### 提交信息规范

```bash
# 格式
类型: 简短描述

# 类型：
feat:     新功能
fix:      Bug 修复
docs:     文档修改
refactor: 代码重构
test:     测试相关

# 示例
git commit -m "feat: 添加 EFS CSI Driver 支持"
git commit -m "fix: 修复 Pod Identity 超时问题"
git commit -m "docs: 更新 README 安装说明"
```

### 冲突解决

如果推送时遇到冲突：

```bash
# 拉取最新代码
git pull origin master

# 解决冲突（编辑冲突文件）
vim conflicted_file.sh

# 标记冲突已解决
git add conflicted_file.sh

# 完成合并
git commit -m "merge: 解决冲突"

# 推送
git push origin master
```

---

## 🔄 保持代码同步

每次开始工作前，先同步最新代码：

```bash
# 查看当前状态
git status

# 如果有未提交的修改，先提交或暂存
git stash  # 暂存当前修改

# 拉取最新代码
git pull origin master

# 恢复暂存的修改
git stash pop
```

---

## 🚫 注意事项

### 不要提交的文件

- `.env` - 包含敏感配置
- `*.pem` - SSH 密钥
- `*.tfstate` - Terraform 状态文件
- `*_final.yaml` - 临时生成的文件

这些文件已在 `.gitignore` 中配置。

### 敏感信息处理

如果需要配置文件：
1. 使用 `.env.example` 作为模板
2. 创建自己的 `.env` 文件（不提交）
3. 在文档中说明配置方法

---

## 🧪 测试建议

修改脚本后的测试流程：

```bash
# 1. 配置测试环境
cp .env.example .env
vim .env  # 填写测试配置

# 2. 运行脚本
./scripts/legacy/4_install_eks_cluster.sh

# 3. 验证集群
kubectl get nodes
kubectl get pods -A

# 4. 验证 Pod Identity
aws eks list-pod-identity-associations \
  --cluster-name ${CLUSTER_NAME}

# 5. 测试完成后清理
eksctl delete cluster \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION}
```

---

## 📚 项目结构

完整的项目结构见 [README.md](../README.md) 的「项目结构」章节。此处仅列出几个贡献者最常接触的入口：

```
eks-cluster-deployment/
├── terraform/                           # ★ 新部署的入口
│   ├── modules/                         # vpc-endpoints / eks-cluster / 系统&GPU NG / addons / CSI / karpenter / GPU stack
│   ├── assets/{iam,karpenter}/          # 模块引用的静态文件
│   └── bootstrap{,-vpc,-bastion}/       # state backend / 测试 VPC / 堡垒机
├── scripts/
│   ├── 0_setup_env.sh                   # 环境变量加载（ops 与 legacy 共用）
│   ├── topology_inventory_lib.sh        # 共享库：读 AWS 原生拓扑标签
│   ├── option_inspect_eks.sh            # 9 项集群健康检查
│   ├── option_verify_gpu_efa.sh         # 跨节点 NCCL benchmark
│   ├── option_show_nodegroup_topology.sh
│   ├── option_create_bastion.sh
│   └── legacy/                          # 已废弃的 bash 部署管线
│       ├── 1_*.sh ... 7_*.sh
│       ├── option_install_*.sh
│       ├── pod_identity_helpers.sh / instance_arch_lib.sh / disk_detection_lib.sh
│       └── manifests/{addons,storage}/  # 仅 legacy 用的 YAML
├── examples/                            # workload 测试样例与验证脚本
└── docs/
    ├── DEPLOYMENT_SOP.md                # legacy bash 部署 SOP
    ├── MIGRATION_FROM_BASH.md           # bash↔terraform 映射
    ├── DESIGN.md                        # 架构决策
    └── P2_TOPOLOGY_RETRY_PLAN.md        # GPU 拓扑重试方案
```

> **Note**: VPC 资源未托管在主仓库内；可使用 `terraform/bootstrap-vpc/` 生成测试 VPC，或自行准备 VPC 后再运行 terraform/legacy。

---

## ❓ 常见问题

### Q: 推送时提示没有权限？
A: 确认已接受协作邀请，并且使用正确的 GitHub 凭证。

### Q: 如何撤销错误的提交？
```bash
# 撤销最后一次提交（保留修改）
git reset --soft HEAD^

# 撤销最后一次提交（删除修改）
git reset --hard HEAD^

# 如果已经推送，需要强制推送（慎用）
git push -f origin master
```

### Q: 如何查看其他人的修改？
```bash
# 查看最近的提交
git log --oneline -10

# 查看某个提交的详细内容
git show 提交SHA

# 查看某个文件的修改历史
git log -p scripts/legacy/4_install_eks_cluster.sh
```

---

## 📞 联系方式

遇到问题可以：
1. 在 GitHub 创建 Issue
2. 在相关 PR / Issue 上评论说明
3. 查看文档: [README.md](../README.md)

---

## ✅ 快速参考

```bash
# 日常工作流
git pull origin master                    # 1. 拉取最新代码
git checkout -b feature/my-feature        # 2. 创建分支（可选）
# 进行修改...                              # 3. 修改文件
git add .                                 # 4. 添加修改
git commit -m "feat: 添加新功能"           # 5. 提交
git push origin master                    # 6. 推送（或推送分支）
```

**欢迎加入协作！** 🎉
