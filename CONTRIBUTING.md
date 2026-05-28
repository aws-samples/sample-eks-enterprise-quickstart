# 贡献指南 / Contributing Guide

感谢你对本项目的关注！欢迎任何形式的贡献。

## 📋 目录

- [开始之前](#开始之前)
- [贡献方式](#贡献方式)
- [开发流程](#开发流程)
- [代码规范](#代码规范)
- [提交规范](#提交规范)
- [Pull Request 流程](#pull-request-流程)

---

## 🚀 开始之前

### 前置要求

- GitHub 账号
- Git 基础知识
- 熟悉 Bash 脚本和 Kubernetes
- AWS 账号（用于测试）

### 设置开发环境

```bash
# 1. Fork 本仓库到你的 GitHub 账号

# 2. 克隆你的 fork
git clone https://github.com/你的用户名/eks-cluster-deployment.git
cd eks-cluster-deployment

# 3. 添加原仓库为 upstream
git remote add upstream https://github.com/aws-samples/eks-cluster-deployment.git

# 4. 验证 remotes
git remote -v
# origin    https://github.com/你的用户名/eks-cluster-deployment.git (fetch)
# origin    https://github.com/你的用户名/eks-cluster-deployment.git (push)
# upstream  https://github.com/aws-samples/eks-cluster-deployment.git (fetch)
# upstream  https://github.com/aws-samples/eks-cluster-deployment.git (push)
```

### 安装 pre-commit 钩子（强烈推荐）

本仓库提供 [pre-commit](https://pre-commit.com/) 配置，在本地每次 `git commit` 时自动执行密钥扫描与基础静态检查：**gitleaks** 阻止 AWS Key / Token / `.env.*` 泄漏，**shellcheck** 检查 bash 脚本，`check-yaml` 校验 manifest 语法。

当前仓库没有服务端（CI）层面的强制门禁，所以这套钩子是**每位贡献者自愿 opt-in** 的客户端防线——请在第一次 clone 后立刻启用，避免把密钥意外推到 remote。

```bash
# 安装 pre-commit 本体。AL2023 / 最新 macOS 的系统 Python 启用了 PEP 668
# "externally-managed-environment"，直接 pip install 会被拒绝，推荐 pipx：
pipx install pre-commit
# 或：brew install pre-commit
# 若坚持用 pip，需要先装 pipx 或加 --break-system-packages，不推荐。

# 在仓库根目录启用钩子
cd eks-cluster-deployment
pre-commit install

# 首次对全仓库跑一遍（可选，但强烈建议）
pre-commit run --all-files
```

> ⚠️ **不要使用 `git commit --no-verify`** 绕过检查。如果 gitleaks 报误报，请在 `.gitleaks.toml` 的 `[allowlist]` 中加白名单，而非跳过。

### `.env.*` 文件的私密性

- **任何 `.env.*` 文件（除 `.env.example` 外）都视为机密**，包含真实的 `VPC_ID`、`CLUSTER_NAME`、subnet ID 等部署指纹。
- `.gitignore` 使用 `.env.*` 通配匹配；`!.env.example` 作为白名单允许模板被追踪。
- 本地 `.env.<region>` 文件建议 `chmod 600`，新脚本不要把 region/VPC/账号信息硬编码。

---

## 🤝 贡献方式

### 1. 报告 Bug

如果发现 Bug，请创建 Issue 并包含：
- **描述**：清晰描述问题
- **重现步骤**：详细的重现步骤
- **期望行为**：应该发生什么
- **实际行为**：实际发生了什么
- **环境信息**：
  - AWS 区域
  - Kubernetes 版本
  - 脚本版本
  - 相关错误日志

### 2. 提出功能建议

通过 Issue 提出功能建议，包含：
- **用例**：为什么需要这个功能
- **建议方案**：如何实现
- **替代方案**：其他可能的实现方式

### 3. 改进文档

文档改进包括：
- 修正错别字
- 添加示例
- 改进说明清晰度
- 翻译文档

### 4. 贡献代码

参见下方的[开发流程](#开发流程)。

---

## 💻 开发流程

### 1. 同步最新代码

在开始工作前，先同步 upstream 的最新代码：

```bash
# 切换到主分支
git checkout master

# 拉取 upstream 最新代码
git fetch upstream

# 合并到本地
git merge upstream/master

# 推送到你的 fork
git push origin master
```

### 2. 创建功能分支

```bash
# 创建并切换到新分支
git checkout -b feature/add-new-feature

# 或修复 Bug
git checkout -b fix/fix-bug-description
```

**分支命名规范**:
- `feature/功能描述` - 新功能
- `fix/问题描述` - Bug 修复
- `docs/文档主题` - 文档改进
- `refactor/重构描述` - 代码重构
- `test/测试描述` - 添加测试

### 3. 进行修改

#### 修改脚本

```bash
# 修改文件
vim scripts/legacy/4_install_eks_cluster.sh

# 测试你的修改
./scripts/legacy/4_install_eks_cluster.sh
```

#### 修改文档

```bash
# 修改 README
vim README.md
```

### 4. 测试修改

**重要**: 在提交前务必测试！

```bash
# 运行你修改的脚本
./scripts/your_modified_script.sh

# 验证输出是否正确
kubectl get pods -A

# 检查 Pod Identity Associations
aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME}
```

### 5. 提交修改

```bash
# 查看修改
git status
git diff

# 添加文件
git add scripts/legacy/4_install_eks_cluster.sh

# 提交（参见提交规范）
git commit -m "feat: add support for custom node labels"
```

---

## 📝 代码规范

### Bash 脚本规范

1. **使用 `set -e`**: 脚本开头添加，遇到错误立即退出
   ```bash
   #!/bin/bash
   set -e
   ```

2. **函数命名**: 使用小写字母和下划线
   ```bash
   setup_cluster_autoscaler() {
       # 函数体
   }
   ```

3. **变量命名**:
   - 环境变量: 大写字母 `CLUSTER_NAME`
   - 局部变量: 小写字母 `local role_name`

4. **错误处理**: 使用日志函数
   ```bash
   log "Starting deployment..."
   error "Deployment failed: ${error_message}"
   ```

5. **注释**: 为复杂逻辑添加注释
   ```bash
   # 等待 Pod Identity Agent 就绪后再创建 associations
   wait_for_pod_identity_agent
   ```

6. **幂等性**: 所有操作应该可以重复执行
   ```bash
   # 检查资源是否已存在
   if aws iam get-role --role-name "${role_name}" &>/dev/null; then
       log "Role already exists, skipping"
       return 0
   fi
   ```

### Manifest 规范

1. **使用环境变量**: 便于配置管理
   ```yaml
   clusterName: ${CLUSTER_NAME}
   ```

2. **添加注释**: 说明配置用途
   ```yaml
   # IAM 配置 - 使用 Pod Identity
   iam:
     withOIDC: false
   ```

---

## 📜 提交规范

使用 [Conventional Commits](https://www.conventionalcommits.org/) 规范：

### 格式

```
<类型>: <简短描述>

<详细描述（可选）>

<footer（可选）>
```

### 类型

- `feat`: 新功能
- `fix`: Bug 修复
- `docs`: 文档修改
- `refactor`: 代码重构（不改变功能）
- `test`: 添加或修改测试
- `chore`: 构建过程或辅助工具的变动

### 示例

```bash
# 新功能
git commit -m "feat: add EFS CSI driver support"

# Bug 修复
git commit -m "fix: resolve Pod Identity Agent timeout issue"

# 文档
git commit -m "docs: add troubleshooting section for private API"

# 详细提交
git commit -m "feat: add multi-region support

- Add region validation
- Update scripts to support all AWS regions
- Add region-specific VPC endpoint configuration

Closes #123"
```

---

## 🔄 Pull Request 流程

### 1. 推送分支到你的 fork

```bash
git push origin feature/add-new-feature
```

### 2. 创建 Pull Request

1. 访问你的 fork: `https://github.com/你的用户名/eks-cluster-deployment`
2. 点击 "Compare & pull request" 按钮
3. 填写 PR 模板:

```markdown
## 描述
简要描述这个 PR 做了什么。

## 变更类型
- [ ] Bug 修复
- [ ] 新功能
- [ ] 文档更新
- [ ] 代码重构
- [ ] 其他（请说明）

## 测试
- [ ] 已在本地测试
- [ ] 已在 AWS 环境测试
- [ ] 添加了测试用例

## 相关 Issue
Closes #issue号

## 检查清单
- [ ] 代码遵循项目规范
- [ ] 已添加必要的注释
- [ ] 已更新相关文档
- [ ] 提交信息遵循规范
- [ ] 已测试所有修改
```

### 3. 代码审查

- 维护者会审查你的代码
- 可能会提出修改建议
- 根据反馈进行修改:

```bash
# 在同一分支继续修改
git add .
git commit -m "fix: address review comments"
git push origin feature/add-new-feature
```

### 4. 合并

- 审查通过后，维护者会合并你的 PR
- 你会收到通知

### 5. 清理

```bash
# PR 合并后，删除本地分支
git checkout master
git branch -d feature/add-new-feature

# 同步最新代码
git pull upstream master
git push origin master
```

---

## 🧪 测试指南

### 本地测试

```bash
# 1. 配置测试环境
cp .env.example .env
# 编辑 .env 文件

# 2. 运行脚本
./scripts/legacy/4_install_eks_cluster.sh

# 3. 验证集群
kubectl get nodes
kubectl get pods -A

# 4. 验证 Pod Identity
aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME}

# 5. 清理测试环境
eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_REGION}
```

### 测试检查清单

- [ ] 脚本无错误运行完成
- [ ] 集群成功创建
- [ ] 所有 Pods 运行正常
- [ ] Pod Identity Associations 创建成功
- [ ] Cluster Autoscaler 工作正常
- [ ] EBS CSI Driver 可以创建 PVC
- [ ] AWS Load Balancer Controller 可以创建 ALB

---

## ❓ 获取帮助

如果有疑问：

1. **查看文档**: 阅读 [README.md](README.md)
2. **搜索 Issues**: 查看是否有人遇到类似问题
3. **创建 Issue**: 提出你的问题
4. **联系维护者**: 在 PR 或 Issue 中评论说明

---

## 📄 许可证

通过贡献代码，你同意你的贡献将在与本项目相同的许可证下发布。

---

## 🙏 致谢

感谢所有贡献者！你的贡献让这个项目变得更好。

**贡献者列表**: 查看 [GitHub Contributors](https://github.com/aws-samples/eks-cluster-deployment/graphs/contributors)

---

## 📞 联系方式

- **GitHub Issues**: https://github.com/aws-samples/eks-cluster-deployment/issues

---

**再次感谢你的贡献！** 🎉
