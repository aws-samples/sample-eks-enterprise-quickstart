# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Direction (read first)

**Terraform is the canonical path** for everything under "infrastructure": VPC endpoints, EKS control plane, system/GPU nodegroups, core addons, CSI drivers, Karpenter, GPU stack. All net-new features land in `terraform/` modules.

**Bash deployment scripts are maintenance-only.** They will be archived to `scripts/legacy/` once the structural reshuffle lands. Do **not** add new capabilities to the bash deployment pipeline. When fixing a bug that exists in both, fix it in terraform; only patch bash if a downstream user explicitly cannot migrate yet.

**Bash kept permanently** for runtime / ops tools that don't fit a declarative model:
- `option_inspect_eks.sh` (post-apply 9-check health audit)
- `option_verify_gpu_efa.sh` (NCCL benchmark)
- `option_show_nodegroup_topology.sh` (reads `topology.k8s.aws/...` labels at runtime)
- `option_create_bastion.sh` (operator-driven bastion lifecycle)

## Project Overview

Automated deployment system for production-grade AWS EKS clusters with advanced features including LVM-configured system nodes, Pod Identity authentication, and optional components (Karpenter, CSI drivers for EBS/EFS/FSx/S3, GPU nodes).

**Key Characteristics:**
- **Deployment Environment**: Must run from bastion host inside VPC (private API endpoint)
- **Authentication**: Pod Identity (not IRSA/OIDC) for all AWS service integrations
- **Configuration**: terraform via `terraform.tfvars`; legacy bash via `.env` (sourced from `0_setup_env.sh`)
- **Architecture**: terraform modules under `terraform/modules/`; legacy bash scripts use sequential numbered files for core setup and `option_*` for optional features

## Common Commands

### Core Deployment (Terraform — recommended)

```bash
cd terraform

# One-time per account/region: bootstrap state backend
terraform -chdir=bootstrap apply -var="bucket_name=my-eks-tfstate" -var="region=us-west-2"

# Configure variables
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# Apply (must run from inside the cluster's VPC for private mode)
terraform init \
  -backend-config="bucket=my-eks-tfstate" \
  -backend-config="key=eks-cluster-deployment/dev/terraform.tfstate" \
  -backend-config="region=us-west-2" \
  -backend-config="dynamodb_table=my-eks-tfstate-lock"
terraform plan
terraform apply
```

Module-level toggles (`install_karpenter`, `install_efs_csi`, `install_fsx_csi`, `install_s3_csi`, `install_gpu_nodegroups`, `install_gpu_stack`, `gpu_stack_mode`, etc.) live in `terraform.tfvars`. See `terraform/README.md` for the full layout, three-stack split for private deploys, and `safe-destroy.sh` teardown procedure.

### Post-deploy ops tools (kept as bash)

```bash
# 9-check cluster health audit
./scripts/option_inspect_eks.sh

# Cross-node NCCL benchmark (validates EFA + GPUDirect)
./scripts/option_verify_gpu_efa.sh

# Print AWS-native topology labels per nodegroup
./scripts/option_show_nodegroup_topology.sh

# Create SSM-only bastion (alternative to terraform/bootstrap-bastion/)
./scripts/option_create_bastion.sh

# Test Karpenter node provisioning (workload sample)
./examples/option_test_karpenter_pools.sh

# Test pod scheduling on system nodes (workload sample)
./examples/option_test_pod_scheduling.sh
```

### Legacy bash deployment (deprecated)

The old `1_*` ~ `7_*` and `option_install_*` scripts have moved to `scripts/legacy/` and are maintenance-only. See `scripts/legacy/README.md` and `docs/MIGRATION_FROM_BASH.md`.

### Cluster Verification

```bash
# Check cluster status
aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION}

# Verify nodes
kubectl get nodes -o wide

# Check system pods
kubectl get pods -n kube-system

# Verify addons
aws eks list-addons --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION}

# Test storage classes
kubectl get storageclass

# View metrics
kubectl top nodes
kubectl top pods -A
```

## Architecture

### Script Organization

**Numbered Scripts (0-7)**: Core deployment sequence that must run in order
- `0_setup_env.sh`: Environment configuration loader and validation functions (always source this first)
- `1-3`: Network infrastructure setup (VPC DNS, validation, endpoints)
- `4`: EKS cluster control plane creation
- `5`: Local environment check (optional; alternative to bastion)
- `6`: System nodegroup creation (with LVM-backed containerd storage)
- `7`: Core addon installation (CoreDNS, Cluster Autoscaler, ALB Controller, EBS CSI, Metrics Server)

**option_* Scripts**: Optional features that can be installed after core deployment
- Can run independently after core setup completes
- Idempotent and safe to re-run

### Pod Identity Architecture

All AWS integrations use **Pod Identity** (not IRSA/OIDC). Helper functions in `pod_identity_helpers.sh`:

```bash
# Key helper functions
create_pod_identity_role <role_name>               # Create IAM role with Pod Identity trust policy
attach_managed_policy <role_name> <policy_arn>     # Attach AWS managed policy
attach_custom_policy <role_name> <policy_name> <policy_document>  # Attach custom policy
create_pod_identity_association <namespace> <sa> <role_arn>   # Associate role with K8s SA
```

**Pattern for adding new components:**
1. Source `0_setup_env.sh` and `pod_identity_helpers.sh`
2. Create IAM role with `create_pod_identity_role`
3. Attach necessary policies
4. Create Pod Identity association
5. Deploy K8s manifests with ServiceAccount

### Directory Structure

```
terraform/                  # Canonical infra-as-code (use this)
├── main.tf / variables.tf / outputs.tf / providers.tf / versions.tf
├── terraform.tfvars.example
├── bootstrap/              # state backend (S3 + DynamoDB)
├── bootstrap-vpc/          # standalone 3-AZ VPC for testing
├── bootstrap-bastion/      # SSM-only bastion for private deploys
├── modules/                # vpc-endpoints / eks-cluster / eks-system-nodegroup /
│                           # eks-addons / eks-csi-drivers / eks-karpenter /
│                           # eks-gpu-nodegroup / eks-gpu-stack
├── assets/                 # static files referenced by modules
│   ├── iam/                # alb-controller / fsx-csi IAM policy JSON
│   └── karpenter/          # EC2NodeClass + NodePool YAML templates
└── scripts/safe-destroy.sh # helm uninstall → terraform destroy wrapper

scripts/                    # Operational tools (kept as bash)
├── 0_setup_env.sh                    # shared by ops tools and legacy
├── topology_inventory_lib.sh         # lib for topology / GPU verify
├── option_inspect_eks.sh             # 9-check post-apply health audit
├── option_verify_gpu_efa.sh          # cross-node NCCL benchmark
├── option_show_nodegroup_topology.sh # print AWS-native topology labels
├── option_create_bastion.sh          # operator-driven bastion lifecycle
└── legacy/                           # deprecated bash deployment pipeline
    ├── 1_*.sh ... 7_*.sh             # old numbered sequence
    ├── option_install_*.sh           # csi / karpenter / gpu-nodegroups / gpu-stack
    ├── pod_identity_helpers.sh
    ├── disk_detection_lib.sh
    ├── instance_arch_lib.sh
    └── manifests/                    # bash-only YAMLs (autoscaler, storageclass)

examples/                   # Workload samples + sanity test scripts
├── option_test_pod_scheduling.sh
├── option_test_karpenter_pools.sh
└── *.yaml                  # ebs / efs / fsx / s3 / nlb test apps

docs/                       # See MIGRATION_FROM_BASH.md and DEPLOYMENT_SOP.md
```

### Configuration Files

**Terraform (canonical)**: `terraform/terraform.tfvars` (copy from `terraform.tfvars.example`)
- Required: `cluster_name`, `vpc_id`, `private_subnet_ids`, `public_subnet_ids`
- Auto-detected via provider: account ID, region (from AWS CLI / env)
- Toggles: `install_karpenter`, `install_efs_csi`, `install_fsx_csi`, `install_s3_csi`, `install_gpu_nodegroups`, `install_gpu_stack`, `gpu_stack_mode`
- Multi-AZ: `private_subnet_ids` / `public_subnet_ids` are lists, supporting 2-4 AZs
- See `terraform/variables.tf` for the full list and defaults

**Legacy `.env`**: kept for `scripts/legacy/*` callers; full variable list in `.env.example`. Variable mapping to `terraform.tfvars` is documented in `docs/MIGRATION_FROM_BASH.md`.

### System Nodegroup

System nodes (`app=eks-utils` label) run cluster infrastructure:
- CoreDNS, Cluster Autoscaler, AWS Load Balancer Controller
- EBS CSI Driver, Metrics Server
- Uses LVM configuration: 50GB root + 100GB data volume
- containerd data directory on separate LVM volume for performance

**Important**: All addon manifests use node selectors to schedule on system nodes.

### Storage Configuration

All CSI drivers are optional (via `option_install_csi_drivers.sh`):
- **EBS**: Block storage with gp3 (default) and io2 StorageClasses
- **EFS**: Shared filesystem across pods/nodes
- **FSx**: Lustre for HPC/ML workloads (requires PERSISTENT_2 for AL2023 lustre-client 2.15 compatibility)
- **S3**: Object storage mounting (Standard S3 and S3 Express One Zone, single replica - no HA needed)

## Key Development Patterns

### Adding New Optional Components

New components land in **terraform** as a module under `terraform/modules/<component>/`. Follow the existing modules for the shape:

1. `main.tf` — IAM role + `aws_eks_pod_identity_association` for AWS permissions; `helm_release` or `aws_eks_addon` for the workload
2. `variables.tf` / `outputs.tf` / `versions.tf`
3. Wire into `terraform/main.tf` with a `count = var.install_<component> ? 1 : 0` toggle
4. Static assets (YAML templates, IAM JSON) live under `terraform/assets/<component>/`
5. Add the toggle and any tunables to `terraform/variables.tf` and `terraform.tfvars.example`
6. Use `node_selector = { "${var.system_node_label_key}" = var.system_node_label_value }` if the component should run on system nodes

Do **not** add new bash scripts under `scripts/legacy/` for this purpose.

### Validation in terraform

- Resource existence: TF `data` blocks fail at plan time
- IAM propagation retries: AWS provider handles internally
- Pre-deploy CLI tooling check: not done by TF; operator concern (use `option_inspect_eks.sh` after apply)

The legacy bash helpers (`verify_kubectl_context`, `validate_vpc_exists`, etc.) still exist in `scripts/0_setup_env.sh` and are used by the kept ops tools and `examples/option_test_*.sh`.

## Karpenter Node Support (CPU Only)

**CPU Nodes (Graviton/x86):** terraform module `terraform/modules/eks-karpenter/` (legacy: `scripts/legacy/option_install_karpenter.sh`)
- EC2NodeClass: `terraform/assets/karpenter/ec2nodeclass-graviton.yaml`, `ec2nodeclass-x86.yaml`
- Graviton (arm64): r/c/m Graviton3+Graviton4 family, 4-16 vCPU, on-demand (example defaults — see manifest header)
- x86 (amd64):      r/c/m Intel 6th+7th gen family, 4-16 vCPU, on-demand
- LVM configuration for containerd data volume

## GPU Node Support (Managed Node Groups)

GPU support is split across two scripts (and two terraform modules) by
responsibility:

**Layer 1 — `terraform/modules/eks-gpu-nodegroup/` (AWS infra; legacy: `scripts/legacy/option_install_gpu_nodegroups.sh`)**
- Uses AWS Managed Node Groups (not Karpenter) for EFA multi-NIC support
- IAM role + GPU SG (with EFA self-egress) + Launch Template + NodeGroup
- EFA interface counts:
  - p5.48xlarge: 32 ENIs (1 primary + 31 EFA-only)
  - p5en.48xlarge: 16 ENIs (1 primary + 15 EFA-only)
  - p6-b200.48xlarge: 8 ENIs (1 primary + 7 EFA-only)
  - p6-b300.48xlarge: 17 ENIs (1 primary + 16 EFA-only)
  - g7e.48xlarge: 4 ENIs (1 primary + 3 EFA-only)
- Pricing options (mutually exclusive — choose ONE): OD / Spot / ODCR / CB
- LVM configuration for containerd data volume + Instance Store scratch
- Node labels: `workload-type=gpu`, `gpu-instance-type=<type>`, `purchase-option=<od|spot|odcr|cb>`
- Taints: `nvidia.com/gpu:NoSchedule`

**Layer 2 — `terraform/modules/eks-gpu-stack/` (K8s workloads; legacy: `scripts/legacy/option_install_gpu_stack.sh`)**
- Two mutually-exclusive modes via `gpu_stack_mode` (terraform) / `GPU_STACK_MODE` (legacy):
  - `standard` (default): nvidia-device-plugin + EFA plugin + dcgm-exporter + node-problem-detector + gpu-health-check DS
  - `operator`: NVIDIA GPU Operator (driver/toolkit/mofed disabled) + EFA plugin
- Terraform: switching mode triggers `terraform apply` to retire stale resources from the previous mode
- Legacy: mode-switch protected by `GPU_STACK_FORCE_SWITCH=true` to auto-uninstall conflicting releases; auto-invoked from layer 1 by default; skip with `SKIP_GPU_STACK_AUTO_INSTALL=true`

## Testing and Validation

Test manifests in `examples/`:
- Test pod scheduling (Graviton/x86)
- Various storage test pods (EBS, EFS, S3)
- Karpenter scaling tests

## Important Notes

- **Always run from bastion**: Cluster uses private API endpoint, requires VPC internal access
- **System node labels**: `app=eks-utils` label critical for addon scheduling
- **Multi-AZ support**: Supports 2-4 availability zones (minimum: A/B, optional: C, D)
- **Terraform is canonical**: full deployment lives in `terraform/`; legacy bash under `scripts/legacy/` is maintenance-only
- **Documentation**: See `terraform/README.md` for the terraform path, `docs/MIGRATION_FROM_BASH.md` for bash↔terraform mapping, `docs/DEPLOYMENT_SOP.md` for the legacy step-by-step (still applicable to bash-deployed clusters), `docs/DESIGN.md` for future features
- **Bash quirks (when working in `scripts/legacy/`)**:
  - Source `scripts/0_setup_env.sh` first; legacy scripts reference it via `${SCRIPT_DIR}/../0_setup_env.sh`
  - Use `verify_kubectl_context` before kubectl operations
