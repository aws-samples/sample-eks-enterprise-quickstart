# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Direction (read first)

**Terraform is the canonical path** for everything under "infrastructure": VPC endpoints, EKS control plane, system/GPU nodegroups, core addons, CSI drivers, Karpenter, GPU stack. All net-new features land in `terraform/` modules.

**Bash deployment scripts are maintenance-only.** They will be archived to `scripts/legacy/` once the structural reshuffle lands. Do **not** add new capabilities to the bash deployment pipeline. When fixing a bug that exists in both, fix it in terraform; only patch bash if a downstream user explicitly cannot migrate yet.

**Bash kept permanently** for runtime / ops tools that don't fit a declarative model:
- `option_inspect_eks.sh` (post-apply 9-check health audit)
- `option_verify_gpu_efa.sh` (NCCL / nccom-test benchmark)
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

# Cross-node NCCL / nccom-test benchmark (validates EFA + GPUDirect / Neuron; vendor auto-detected)
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
│                           # eks-gpu-nodegroup / eks-gpu-stack / eks-neuron-stack /
│                           # gpu-instance-catalog / eks-addon-ecr-registry
├── assets/                 # static files referenced by modules
│   ├── iam/                # alb-controller / fsx-csi IAM policy JSON
│   └── karpenter/          # EC2NodeClass + NodePool YAML templates
└── scripts/safe-destroy.sh # helm uninstall → terraform destroy wrapper

scripts/                    # Operational tools (kept as bash)
├── 0_setup_env.sh                    # shared by ops tools and legacy
├── topology_inventory_lib.sh         # lib for topology / GPU verify
├── option_inspect_eks.sh             # 9-check post-apply health audit
├── option_verify_gpu_efa.sh          # cross-node NCCL / nccom-test benchmark
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
  - p5e.48xlarge: 32 ENIs (1 primary + 31 EFA-only)
  - p5en.48xlarge: 16 ENIs (1 primary + 15 EFA-only)
  - p6-b200.48xlarge: 8 ENIs (1 primary + 7 EFA-only)
  - p6-b300.48xlarge: 17 ENIs (1 primary + 16 EFA-only)
  - g7e.48xlarge: 4 ENIs (1 primary + 3 EFA-only)
- Pricing options (mutually exclusive — choose ONE): OD / Spot / ODCR / CB
- Alternative: Karpenter GPU NodePools (`karpenter_gpu_nodepools`, needs `install_karpenter`) — one EC2NodeClass+NodePool per instance type; EFA `networkInterfaces` from the shared `modules/gpu-instance-catalog` (also holds the g7 fixup + EFA userspace boothook used by both paths); `instanceStorePolicy: RAID0`; spot interruptions via Karpenter's SQS queue; trn*/inf* pools auto-detected via the catalog (workload-type=neuron, aws.amazon.com/neuron taint + device limit, Neuron AMI via karpenter_neuron_ami_selector chain, EFA boothook only; needs install_neuron_stack)
- containerd storage per NG (`gpu_containerd_storage` / `gpu_nodegroups[].containerd_storage`): `ebs` (default — gp3 data volume + LVM + Instance Store scratch) or `instance_store` (nodeadm localStorage RAID0 over all NVMe; no data volume; mutually exclusive with `gpu_enable_local_lvm`; Terraform only)
- Node labels: `workload-type=gpu`, `gpu-instance-type=<type>`, `purchase-option=<od|spot|odcr|cb>`
- Taints: `nvidia.com/gpu:NoSchedule`
- AWS Neuron (Trainium/Inferentia, Terraform only): `gpu_type` may be `trn*`/`inf*`; vendor detected by NAME in `modules/gpu-instance-catalog` (`neuron_instance_type_regex`, `vendor_by_instance_type`, `accelerator_profiles`; LT precondition cross-checks EC2 `neuron_devices`). Neuron NGs get `workload-type=neuron` + taint `aws.amazon.com/neuron=true:NoSchedule`, the x86_64-only AMI `/aws/service/eks/optimized-ami/<k8s>/amazon-linux-2023/x86_64/neuron/...` (`neuron_ami_release_version` — null inherits `gpu_ami_release_version` — / `neuron_custom_ami_id`), no NVIDIA containerd overlay / g7 fixup, and CA hints `resources/aws.amazon.com/neuron` (devices) + `aws.amazon.com/neuroncore` (LNC-aware: trn2.48xl = 64) + `vpc.amazonaws.com/efa`. EFA: trn2.48xlarge 16, trn1n.32xlarge 16, trn1.32xlarge 8, trn2.3xlarge 1. AMI resolved per NG (vendor × arch) so NVIDIA and Neuron NGs coexist; NVIDIA-only configs must stay zero-diff (golden hashes in `terraform/tests/gpu_containerd_storage`)
- Neuron caveats: `trn2u.48xlarge` is unsupported (EC2 publishes no NeuronInfo → LT precondition rejects it); Capacity Blocks (`cb`) never take a placement group (EC2 rejects it; LT precondition fails a Neuron `cb` NG that would get a cluster PG; for NVIDIA `cb` NGs it is only a `check` warning, since an unchanged NVIDIA entry must keep planning — a pre-existing trn*/inf* entry is re-rendered as Neuron on upgrade anyway and could never launch); trn2 regions vary (e.g. us-east-2, ap-south-2; not us-east-1) — check `describe-instance-type-offerings`; the boothook's containerd + kubelet (re)start is NVIDIA-only — on Neuron it started kubelet before nodeadm-run's `instance_store` RAID0 bind mount and left DaemonSet pods (device plugin) on a stale `/var/lib/kubelet` (`aws.amazon.com/neuron` = 0; found live on trn2, regression run `neuron_instance_store_no_early_kubelet`). NVIDIA `instance_store` NGs still carry that restart (zero-diff) and are likely exposed to the same race — not yet verified live (tracked in issue #27)
- Upgrading an existing deployment to the Neuron change: re-run `terraform init` (same `-backend-config`) to install the new local modules (`eks-neuron-stack`, `eks-addon-ecr-registry`) — otherwise `plan` fails with "Module not installed" even though `eks_neuron_stack` is `count = 0`. No new providers; NVIDIA-only tfvars should then plan to No changes (an NVIDIA `cb` NG with `placement_group = "cluster"` + single subnet additionally warns via `check.cb_nodegroups_without_placement_group`; fixing it with `placement_group = "none"` destroys the PG and creates a new LT version). Existing trn*/inf* `karpenter_gpu_nodepools` entries are re-rendered as Neuron pools (label/taint/limit/userData/EFA NICs/AMI change → Karpenter drift replaces their nodes; set `install_neuron_stack`); a Neuron `ami-` id previously in `karpenter_gpu_ami_selector` no longer reaches them — move it to `karpenter_neuron_ami_selector` / `neuron_custom_ami_id` first; a `trn2u.48xlarge` pool now fails the plan, and Neuron pools need `karpenter_version >= 1.11` for EFA types (`>= 1.1` otherwise) — bump a pinned older Karpenter first. Existing trn*/inf* `gpu_nodegroups` entries (free-form `gpu_type`, previously rendered with the NVIDIA AMI/label/taint) become Neuron NGs: Neuron SSM AMI / `neuron_custom_ami_id` (`gpu_custom_ami_id` no longer applies — move it first), `workload-type=neuron` + `aws.amazon.com/neuron` taint, new CA tags → new LT version, managed NG rolls; set `install_neuron_stack` first; a `trn2u.48xlarge` entry or a `cb` + `placement_group = "cluster"` + single-subnet entry now fails the plan (use `placement_group = "none"`)

**Layer 2 — `terraform/modules/eks-gpu-stack/` (K8s workloads; legacy: `scripts/legacy/option_install_gpu_stack.sh`)**
- Two mutually-exclusive modes via `gpu_stack_mode` (terraform) / `GPU_STACK_MODE` (legacy):
  - `standard` (default): nvidia-device-plugin + EFA plugin + dcgm-exporter + node-problem-detector + gpu-health-check DS
  - `operator`: NVIDIA GPU Operator (driver/toolkit/RDMA disabled) + EFA plugin
- Terraform: switching mode triggers `terraform apply` to retire stale resources from the previous mode
- Legacy: mode-switch protected by `GPU_STACK_FORCE_SWITCH=true` to auto-uninstall conflicting releases; auto-invoked from layer 1 by default; skip with `SKIP_GPU_STACK_AUTO_INSTALL=true`

**Layer 2b — `terraform/modules/eks-neuron-stack/` (K8s workloads for Neuron nodes; Terraform only)**
- Toggle `install_neuron_stack` — orthogonal to `gpu_stack_mode` (not a third mode; both stacks can be installed)
- `neuron-helm-chart` (oci://public.ecr.aws/neuron, release `neuron-helm-chart`): device plugin on (`aws.amazon.com/neuron` / `neuroncore`) — upstream chart RBAC kept as-is: cluster-wide `nodes/proxy` get/list, `pods` update/patch, `nodes/status` patch + host `/run` rw mount (README "Privileges (device plugin)"); NPD / DRA / observer off; optional scheduler extension + `my-scheduler` (`install_neuron_scheduler`; then `neuron_kube_scheduler_image_tag` is required — chart default kube-scheduler v1.31 is out of skew; adds **ClusterIP** `kube-system/k8s-neuron-scheduler:12345`, plain HTTP, no auth, pod network only, called by `my-scheduler` for filter + **bind** — the extender binds pods / patches pods + nodes/status with its own cluster-wide RBAC; README has a NetworkPolicy example restricting ingress to the `my-scheduler` pods); mirror overrides for the chart and every image (device plugin, scheduler extender, kube-scheduler); `helm_replace_existing` does not adopt a deployed manual install — the docs install omits `--namespace` (release usually in `default`), so `helm list -A` to find it and `helm uninstall -n <ns>` before the first apply; `terraform/scripts/safe-destroy.sh` pre-uninstalls `neuron-helm-chart` + the Neuron EFA DS (and the neuron-monitor ServiceMonitor release + DS / Service / RBAC / SA)
- Separate EFA DaemonSet `aws-efa-k8s-device-plugin-neuron` on `workload-type=neuron` nodes (the eks-gpu-stack EFA DS is untouched); EFA image registry map shared via `terraform/modules/eks-addon-ecr-registry`
- Opt-in neuron-monitor exporter (`install_neuron_monitor`, default off; dcgm-exporter parity, no metrics backend): DaemonSet + **ClusterIP** Service `kube-system/neuron-monitor:8000` (plain HTTP, no auth, pod network only — no hostNetwork / hostPort / NodePort / LB), container **privileged** (must read every `/dev/neuron*`), host `/opt/aws` mounted read-only at `/opt-aws` (host LNC config); `neuron_monitor_service_monitor` (needs Prometheus Operator CRDs) and BETA `neuron_monitor_pod_attribution` (`get nodes/pods` only, never `nodes/proxy`) both off. ServiceMonitor uses the dcgm label schema (`honorLabels: false`, `exported_pod` / `exported_namespace` / `exported_container`) and blanks neuron-monitor's literal `"None"` on unattributed series
- Neuron Observer (chart `observer.*`: hostNetwork `0.0.0.0:7001`, unauthenticated API with fault injection) is intentionally **not** managed — README warning
- `scripts/option_verify_gpu_efa.sh` auto-detects Neuron nodes (`workload-type=neuron` / allocatable `aws.amazon.com/neuron`): `neuron-ls`, `fi_info -p efa`, single-node and `--multi` `nccom-test` over EFA in an official Neuron DLC; pods request whole `aws.amazon.com/neuron` devices (never `neuroncore` — LNC pitfall), IPC_LOCK only; `VERIFY_VENDOR` / `VERIFY_NEURON_IMAGE` / `VERIFY_NEURON_TIMEOUT_SEC` / `VERIFY_NEURON_COMM_PORT` / `VERIFY_NEURON_RUNTIME_UPGRADE` (default true: apt-upgrade runtime-lib/collectives/tools in-pod — the newest public training DLC, sdk2.30, fails `nrt_init` on the current EKS Neuron AMI driver 2.31.7). NVIDIA path unchanged. `option_inspect_eks.sh` adds Neuron allocatable / EFA / Trn quota checks only when Neuron nodes exist

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
