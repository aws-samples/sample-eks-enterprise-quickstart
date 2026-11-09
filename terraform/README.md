# Terraform — EKS Cluster Deployment

Terraform-native equivalent of the bash scripts under `../scripts/`.
Same end state (private/public EKS cluster, system nodegroup with LVM,
core addons, optional CSI drivers, Karpenter, GPU nodegroups with EFA
multi-NIC), expressed declaratively.

## Layout

```
terraform/
├── bootstrap/                     # S3 + DynamoDB for remote state backend (optional)
├── bootstrap-vpc/                 # Standalone 3-AZ VPC for testing the rest of the stack
├── bootstrap-bastion/             # SSM-only t4g.small bastion in a private subnet
├── backend.tf.disabled            # Rename to backend.tf to enable S3 backend (see Quick start)
├── providers.tf                   # aws / kubernetes / helm with EKS exec auth
├── versions.tf
├── variables.tf                   # Mirrors .env.example
├── main.tf                        # Wires modules together
├── outputs.tf
├── terraform.tfvars.example       # Copy to terraform.tfvars
├── scripts/safe-destroy.sh        # Tear-down wrapper (helm uninstall → tf destroy)
└── modules/
    ├── vpc-endpoints/             # Replaces 1_enable_vpc_dns.sh + 3_create_vpc_endpoints.sh
    ├── eks-cluster/               # Replaces 4_install_eks_cluster.sh
    ├── eks-system-nodegroup/      # Replaces 6_create_system_nodegroup.sh (LVM userdata)
    ├── eks-addons/                # Replaces 7_install_eks_addon.sh (CoreDNS/Metrics/CA/ALB)
    ├── eks-csi-drivers/           # Replaces option_install_csi_drivers.sh (EBS/EFS/FSx/S3)
    ├── eks-karpenter/             # Replaces option_install_karpenter.sh
    ├── eks-gpu-nodegroup/         # Replaces option_install_gpu_nodegroups.sh (EFA multi-NIC; NVIDIA + Neuron)
    ├── eks-gpu-stack/             # K8s-side GPU stack (standard / NVIDIA Operator)
    ├── eks-neuron-stack/          # K8s-side AWS Neuron stack (device plugin / scheduler / EFA)
    ├── gpu-instance-catalog/      # Shared per-instance-type facts (EFA layout, vendor, boot snippets)
    ├── eks-addon-ecr-registry/    # Shared region -> EKS add-on ECR registry map (EFA plugin image)
    └── k8s-version/               # Read-only: effective Kubernetes / Karpenter version + upgrade guards
```

## Three-stack layout for private-cluster deploys

For `cluster_mode = "private"`, the API endpoint is only reachable
from inside the VPC. Run terraform from a bastion. Three independent
stacks chain in this order:

```
┌─ dev host ─────────────────────────────────────────────────────────┐
│  1. terraform -chdir=bootstrap-vpc apply                           │
│       → vpc_id + private/public subnet IDs                         │
│  2. terraform -chdir=bootstrap-bastion apply                       │
│       -var "vpc_id=<from step 1>"                                  │
│       -var "subnet_id=<one private subnet from step 1>"            │
│       → bastion_instance_id + bastion_role_arn                     │
└────────────────────────────────────────────────────────────────────┘
                                ↓
                     aws ssm start-session --target …
                                ↓
┌─ bastion ──────────────────────────────────────────────────────────┐
│  3. git clone <repo> + scp/SSM the tfvars (tfvars are gitignored)  │
│  4. terraform -chdir=terraform init                                │
│  5. terraform -chdir=terraform apply                               │
│       → cluster + system NG + addons + GPU (if enabled)            │
└────────────────────────────────────────────────────────────────────┘
```

Each stack has its own state. Tear down in reverse order. The
`bootstrap_cluster_creator_admin_permissions=true` flag automatically
grants cluster-admin to **whichever IAM ran the apply** — when applied
from the bastion, that's the bastion role, so no extra access entry
is needed for the smoke path.

## Public-cluster shortcut

For dev iteration without a bastion: set `cluster_mode = "public"` and
`public_access_cidrs = ["<your IP>/32"]`. Skip `bootstrap-bastion`
entirely. Apply the root stack directly from the dev host.

## Cluster API ingress

The EKS-managed cluster security group only allows traffic between its
own members by default. Anyone outside that group (bastion, CI runner,
DX-attached operator) needs an explicit allow. Two knobs in `terraform.tfvars`:

```hcl
# Same-VPC sources (preferred — survives IP renumbering)
extra_api_ingress_security_group_ids = ["sg-bastion"]

# Cross-VPC sources (DX / VPN / peering / TGW — SG refs can't span)
extra_api_ingress_cidrs = ["10.100.0.0/16"]
```

## Pod Identity vs IRSA

This stack is **Pod Identity-only by default** (`enable_irsa = false`),
matching the bash flow's `withOIDC: false`. Karpenter, Cluster Autoscaler,
ALB Controller, and every CSI driver use `aws_eks_pod_identity_association`
— there is no IAM OIDC provider unless you opt in.

**Association propagation.** Pod Identity associations are eventually
consistent ("may take several seconds to be effective" — EKS API docs).
The credential env (`AWS_CONTAINER_CREDENTIALS_FULL_URI` / `..._TOKEN_FILE`)
is injected at pod admission, so a pod created inside that window falls
back to the node role and gets AccessDenied — for cluster-autoscaler that
is a permanent CrashLoopBackOff until the pod is recreated (issue #2). Each
module that creates associations (`eks-addons`, `eks-csi-drivers`,
`eks-karpenter`) therefore holds its consumers behind a
`time_sleep.pod_identity_propagation` of `pod_identity_propagation_wait`
(default `"30s"`). It only runs when an association is created or
replaced, so steady-state applies don't wait. If a pod still slipped
through, see "Pod Identity 认证失败" in `docs/DEPLOYMENT_SOP.md`.

Enable IRSA only if external systems need to verify cluster-issued
JWTs (e.g. GitHub Actions OIDC federation, cross-account workload
identity). **Important caveat for private clusters**: the `eks` VPC
interface endpoint's auto-created private hosted zone
`eks.<region>.amazonaws.com` shadows the sibling subdomain
`oidc.eks.<region>.amazonaws.com`. The VPC resolver answers NXDOMAIN
authoritatively for that name, so any tool that fetches the OIDC
issuer (terraform's `data.tls_certificate`, IRSA token verifiers)
fails out of the box. Operators who set `enable_irsa = true` on a
private cluster must arrange DNS for that subdomain themselves —
typically via a `/etc/hosts` pin or a systemd-resolved per-domain
forward to public DNS, applied to whatever host fetches the issuer.

## Extra cluster admins

`bootstrap_cluster_creator_admin_permissions=true` gives admin RBAC to
whoever ran `terraform apply`. To grant the same level to other
principals (typical: applied from CI, operated through bastion):

```hcl
extra_cluster_admin_role_arns = [
  "arn:aws:iam::123456789012:role/eks-bastion-role",
]
```

**Never list the apply-time identity here** — it already has admin and
the access entry creation will fail with `ResourceInUseException`.

## Health check

After every apply, run `scripts/option_inspect_eks.sh` from the same
host that has cluster API access. Nine checks: control plane, addons,
system NG, node-internal kubelet/containerd/LVM, helm releases, VPC
endpoints, SG ingress, Pod Identity associations, in-cluster DNS +
spot vCPU quota. Read-only; safe to re-run. Exit 0 on all PASS,
1 on any FAIL.

## Quick start

```bash
# S3 bucket names are globally unique across all AWS accounts — use an
# account-id suffix to avoid collisions with other tenants.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="eks-tfstate-${ACCOUNT_ID}-us-west-2"

# 0. Bootstrap state backend (once per account/region)
cd terraform/bootstrap
terraform init
terraform apply -var="bucket_name=${BUCKET}" -var="region=us-west-2"

# 1. Enable the S3 backend file (it ships as backend.tf.disabled — rename
#    to backend.tf so terraform picks it up; otherwise state writes locally
#    and the next `terraform init` warns "Missing backend configuration").
cd ..
mv backend.tf.disabled backend.tf

# 2. Init root stack with backend config
terraform init \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="key=eks-cluster-deployment/dev/terraform.tfstate" \
  -backend-config="region=us-west-2" \
  -backend-config="dynamodb_table=${BUCKET}-lock"

# 3. Configure variables
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 4. Apply (must be run from inside the cluster's VPC for private mode)
terraform plan
terraform apply
```

> **Upgrading an existing deployment.** After pulling a change that adds
> local modules (e.g. the Neuron support: root `eks-neuron-stack` and
> `eks-gpu-stack`'s nested `eks-addon-ecr-registry`), re-run step 2's
> `terraform init` with the same `-backend-config` flags before `plan`.
> Without it, `plan` stops with `Error: Module not installed` — even for
> module calls gated off with `count = 0`, because module installation is
> checked before `count` is evaluated. The re-init only installs local
> modules (no new providers or provider versions, no `-upgrade` needed);
> afterwards an unchanged NVIDIA-only `terraform.tfvars` should plan to
> **No changes**. If an NVIDIA `cb` nodegroup also sets `placement_group =
> "cluster"` with a single subnet, the plan additionally shows a warning from
> `check.cb_nodegroups_without_placement_group` (still No changes): EC2
> Capacity Blocks reject placement groups, so that nodegroup can never launch
> instances. The fix, `placement_group = "none"`, is a deliberate change: it
> destroys `aws_placement_group.gpu["<key>"]` and creates a new Launch Template
> version without the placement block (the managed nodegroup rolls / the
> self-managed ASG uses it for new instances).
>
> **Existing trn\*/inf\* entries in `karpenter_gpu_nodepools`** (they planned
> before, rendered with the NVIDIA contract) are re-rendered as Neuron pools:
> label `workload-type=neuron`, taint `aws.amazon.com/neuron`, limit in
> `aws.amazon.com/neuron` devices, EFA `networkInterfaces`, boothook-only
> userData, Neuron AMI. Karpenter drift **replaces those nodes**; set
> `install_neuron_stack = true` first. If you had pointed
> `karpenter_gpu_ami_selector` at a baked Neuron `ami-` id for them, it now
> applies to NVIDIA pools only — move it to `karpenter_neuron_ami_selector` (or
> `neuron_custom_ami_id`) **before** applying, otherwise those pools silently
> switch to the stock `al2023@` Neuron AMI. A `trn2u.48xlarge` pool now fails
> the plan (see "Unsupported" under Karpenter GPU NodePools). Neuron pools now
> also require **`karpenter_version >= 1.11`** for EFA types (trn1.32xlarge,
> trn1n.32xlarge, trn2.48xlarge, trn2.3xlarge — they render EC2NodeClass
> `networkInterfaces`) and `>= 1.1` for the rest; if you pin an older
> `karpenter_version`, upgrade Karpenter **first** or the plan fails.
>
> **Existing trn\*/inf\* entries in `gpu_nodegroups`** (`gpu_type` was
> free-form, so they planned before too, rendered with the NVIDIA contract —
> NVIDIA AMI, no Neuron driver) are now classified as Neuron nodegroups: the
> AMI moves to the Neuron SSM path (or `neuron_custom_ami_id`) —
> **`gpu_custom_ami_id` no longer applies to them**, so move a baked Neuron
> `ami-` id to `neuron_custom_ami_id` **before** applying; label
> `workload-type=neuron`, taint `aws.amazon.com/neuron`, new Cluster
> Autoscaler `aws.amazon.com/neuron` / `neuroncore` / EFA hint tags, and
> (with a catalog EFA layout) EFA interfaces. That is a new Launch Template
> version: the managed nodegroup rolls (the self-managed ASG uses it for new
> instances); set `install_neuron_stack = true` first. Two such entries now
> **fail the plan**: a `trn2u.48xlarge` entry (EC2 publishes no NeuronInfo),
> and a `cb` entry with `placement_group = "cluster"` and a single subnet (set
> `placement_group = "none"` — Capacity Blocks reject placement groups).

Total apply time: ~25-35 minutes (control plane 8-10m, system NG 8-12m,
addons 5-8m, optional GPU NG 10-15m).

## Apply order / module dependencies

Terraform handles ordering automatically via `depends_on` and resource
graph edges, but logically:

1. `vpc-endpoints` (verifies VPC DNS, creates SG + 13 endpoints + S3 gateway)
2. `eks-cluster` (control plane + OIDC + base addons: vpc-cni, kube-proxy, pod-identity-agent)
3. `eks-system-nodegroup` (managed NG with LVM userdata)
4. `eks-addons` (CoreDNS + Metrics Server addons; CA + ALB Controller helm releases)
5. `eks-csi-drivers` (EBS always; EFS/FSx/S3 optional)
6. `eks-karpenter` (optional)
7. `eks-gpu-nodegroup` (optional; AWS-side: IAM/SG/LT with multi-NIC EFA + EKS Managed NodeGroup)
8. `eks-gpu-stack` (optional; K8s-side: device-plugin / EFA / monitoring **or** GPU Operator)
9. `eks-neuron-stack` (optional; K8s-side AWS Neuron device plugin + EFA for Trainium/Inferentia nodes, plus the opt-in neuron-monitor exporter; independent of `eks-gpu-stack`). With `neuron_monitor_service_monitor = true` the Prometheus Operator CRDs (`monitoring.coreos.com/v1`) must already be installed — Terraform does not order against them, and the apply fails with `no matches for kind "ServiceMonitor"` otherwise.

## Kubernetes version and upgrades

`k8s_version` defaults to `null`:

- **New cluster** → Kubernetes **1.37** (Karpenter default **1.15.1**).
- **Existing cluster** (same `cluster_name`, found with a read-only
  `eks:ListClusters` + `eks:DescribeCluster` at plan time) → keeps its
  **running** version. A deployment created with the old 1.35 default plans
  with no changes, and the Karpenter default stays **1.12.1**.
- **Explicit** `k8s_version` → used as-is, but on an existing cluster it may
  only stay on the running minor or go **one** minor up. A downgrade or a
  skipped minor fails at plan time.

`karpenter_version = null` resolves to 1.12.1 when the cluster runs (or a new
cluster is created on) Kubernetes ≤ 1.35, and to 1.15.1 for 1.36 / 1.37.
For an existing cluster it follows the **running** version, so raising
`k8s_version` never moves Karpenter in the same apply. The plan fails when
Karpenter is older than its
[compatibility matrix](https://karpenter.sh/docs/upgrading/compatibility/)
allows for the target Kubernetes version (1.35 ≥ 1.9, 1.36 ≥ 1.13,
1.37 ≥ 1.15), so 1.36 with Karpenter 1.12.1 is rejected. An unchanged
deployment running ≤ 1.35 that is already outside the matrix (an old
`karpenter_version` pin) only gets a warning; on 1.36+ it is an error.

A cluster that was raised to 1.36+ on the previous release with
`karpenter_version` omitted runs Karpenter 1.12.1, which 1.36 does not
support. Here the default now resolves to 1.15.1, and Helm will not upgrade
the CRDs. Before the next `terraform apply`, apply the 1.15.1 CRDs (the
`helm show crds` command in step 1 below).

From
Karpenter 1.13 the controller policy also gets `ec2:DescribeInstanceStatus`,
`ec2:DescribeCapacityReservations`, `ec2:DescribePlacementGroups` and
`placement-group/*`. The 1.12.1 policy stays as it is.

With `k8s_version` omitted and a running cluster below 1.37, every plan
prints the warning `k8s_version_behind_default`. Nothing changes. To
silence it, pin the running version (`k8s_version = "1.35"`).

**Upgrade runbook (existing 1.35 cluster)**. Run `terraform init` (same
`-backend-config`) once after pulling this change, because it adds the local
module `modules/k8s-version`. Then do one apply per step:

1. **Karpenter first** (skip without `install_karpenter`). Keep
   `k8s_version = "1.35"` and set `karpenter_version = "1.15.1"`. The
   karpenter chart installs CRDs only on its first install (Helm never
   upgrades them), so apply the 1.15.1 CRDs yourself first. This is the
   chart's own `crds/` content, the same as the `karpenter-crd` chart:

   ```bash
   helm show crds oci://public.ecr.aws/karpenter/karpenter --version 1.15.1 \
     | kubectl apply --server-side --force-conflicts -f -
   terraform apply
   ```

   Keep `karpenter_version = "1.15.1"` from then on (pinned, or omitted
   once the cluster runs 1.36+).
2. `k8s_version = "1.36"`, then `terraform apply`. Wait until the managed
   nodegroups (system / GPU) report v1.36 (`kubectl get nodes`) and
   `aws eks list-insights --cluster-name <name>` is clear. Karpenter CPU
   nodes stay on 1.35 by design, and so do self-managed nodes
   (`node_management = "self_managed"`) until you replace them (see Notes).
3. `k8s_version = "1.37"`, then `terraform apply`.

Notes (not handled by Terraform):

- **Bastion kubectl**: `bootstrap-bastion` installs kubectl for its own
  `k8s_version` (default 1.35, unchanged). kubectl supports ±1 minor, so
  for a 1.37 cluster re-apply `bootstrap-bastion` with
  `-var k8s_version=1.37` (the cluster's minor; this re-creates the
  instance via `user_data_replace_on_change`), or install a matching
  kubectl on the existing bastion.
- **Pinned GPU AMIs**: a pinned `gpu_ami_release_version` (and a
  `karpenter_gpu_ami_selector` / `al2023@vYYYYMMDD` derived from it) must
  exist for the new minor. Check this before each step.
- **Regions without 1.37**: EKS releases new minors in some regions and
  partitions later (`aws eks describe-cluster-versions`). For a new cluster
  there, set `k8s_version` explicitly to a minor the region offers.
- **GPU stack images**: check that the `gpu_operator_version` and the
  gpu-health-check / device-plugin images you use support the new minor.
- **Karpenter CPU EC2NodeClasses**: `assets/karpenter/ec2nodeclass-*.yaml`
  select `...-standard-1.35-*` AMIs, so Karpenter CPU nodes keep kubelet
  1.35. That is inside the supported kubelet skew for 1.36 / 1.37. Edit
  the assets if you want them to follow the control plane.
- **Self-managed nodes** (`node_management = "self_managed"`): the system
  and GPU ASGs have no instance refresh and their processes are suspended,
  so steps 2 and 3 only add a launch-template version and running nodes
  keep their old kubelet (inside the skew for 1.36 / 1.37). Cordon, drain
  and terminate them yourself before the next minor (`aws autoscaling
  terminate-instance-in-auto-scaling-group --instance-id <id>
  --no-should-decrement-desired-capacity`, see `docs/SELF_MANAGED_NG.md`).

## GPU nodegroups

Replaces the bash `DEPLOY_GPU_OD/SPOT/ODCR/CB` toggles with an explicit
list. Each entry produces one EKS managed node group + matching Launch
Template (with the right number of `efa-only` NICs for the instance type).

```hcl
gpu_nodegroups = [
  { gpu_type = "p5.48xlarge",      purchase_option = "od" },
  { gpu_type = "p5en.48xlarge",    purchase_option = "spot",
    subnet_ids = [var.private_subnet_c] },
  { gpu_type = "p6-b200.48xlarge", purchase_option = "odcr",
    suffix = "-1", subnet_ids = [var.private_subnet_c],
    capacity_reservation_id = "cr-xxxx", placement_group = "cluster" },
  { gpu_type = "p5.48xlarge",      purchase_option = "cb",
    subnet_ids = [var.private_subnet_c],
    capacity_reservation_id = "cr-yyyy" },
]
```

EFA NIC layout per instance type lives in `modules/gpu-instance-catalog`
(`local.efa_layout`), shared by the GPU nodegroups and the Karpenter GPU
NodePools below. Currently registered (NVIDIA; the Trainium rows `trn2.48xlarge`
/ `trn2.3xlarge` / `trn1n.32xlarge` / `trn1.32xlarge` are listed under
[Trainium / Inferentia (Neuron) nodegroups](#trainium--inferentia-neuron-nodegroups)
below):

| Instance | NIC0 type | Extra EFA-only NICs | Notes |
|---|---|---|---|
| `p5.48xlarge` | `efa` | 31 | H100, full multi-NIC |
| `p5e.48xlarge` | `efa` | 31 | H200, same 32-NIC layout as p5 |
| `p5en.48xlarge` | `efa` | 15 | H200 |
| `p6-b200.48xlarge` | `efa` | 7 | B200 |
| `p6-b300.48xlarge` | `interface` | 16 | B300; NIC 0 = ENA only |
| `g6e.8xlarge` / `12xlarge` / `16xlarge` | `efa` | 0 | L40S, single NIC |
| `g6e.24xlarge` | `efa` | 1 | L40S, 2 NICs |
| `g6e.48xlarge` | `efa` | 3 | L40S, 4 NICs |
| `g7e.8xlarge` / `12xlarge` | `efa` | 0 | RTX PRO 6000, EFAv4 |
| `g7e.24xlarge` | `efa` | 1 | 2 NICs, EFAv4 |
| `g7e.48xlarge` | `efa` | 3 | 4 NICs, EFAv4, GPUDirect RDMA |

Any instance type not in the catalog (NVIDIA or Neuron) falls back to
`{ efa_only_count = 0, primary_efa = false }` — LT will provision a plain ENA NIC and skip EFA scaffolding.

### Trainium / Inferentia (Neuron) nodegroups

`gpu_nodegroups[].gpu_type` also accepts AWS Neuron instance types. The
accelerator vendor is detected **from the instance-type name** by
`modules/gpu-instance-catalog` (`neuron_instance_type_regex` =
`^(trn|inf)[0-9]+[a-z0-9-]*\.`; everything else is NVIDIA). Name-based
detection keeps every vendor decision known at plan time; a Launch Template
precondition cross-checks it against EC2 (`neuron_devices` / `gpus` from
`aws_ec2_instance_type`) and fails with a clear message on a mismatch.

```hcl
gpu_nodegroups = [
  { gpu_type = "p5.48xlarge",   purchase_option = "od" },       # NVIDIA
  { gpu_type = "trn2.48xlarge", purchase_option = "cb",         # Neuron
    capacity_reservation_id = "cr-xxxx", subnet_ids = ["subnet-az1"] },
]
install_neuron_stack = true
```

No `placement_group` on the Capacity Block entry: EC2 rejects placement
groups for Capacity Block launches, and CB instances are already co-located
in an EC2 UltraCluster. A Launch Template precondition fails the plan if a
Neuron `cb` nodegroup would get a cluster placement group (`placement_group =
"cluster"` with a single subnet). For NVIDIA `cb` nodegroups the same case is
only a plan **warning** (`check.cb_nodegroups_without_placement_group`), because
such entries could be planned before Neuron support and an unchanged tfvars
must keep planning. (A pre-existing trn\*/inf\* `cb` entry is re-rendered as
Neuron on upgrade anyway and could never launch, so it gets the hard failure —
see the upgrade note.) Use `placement_group = "cluster"` only with `od` / `spot` /
`odcr`.

Per Neuron nodegroup:

| | NVIDIA (unchanged) | Neuron |
|---|---|---|
| Label | `workload-type=gpu` | `workload-type=neuron` |
| Taint | `nvidia.com/gpu=true:NoSchedule` | `aws.amazon.com/neuron=true:NoSchedule` |
| AMI | `.../<arch>/nvidia/...` (`gpu_ami_release_version` / `gpu_custom_ami_id`) | `.../x86_64/neuron/...` (`neuron_ami_release_version` / `neuron_custom_ami_id`) |
| containerd overlay | NVIDIA runtime `SystemdCgroup = true` | none (AMI default runc) |
| g7 open-kmod fixup | yes (no-op on non-g7) | no |
| EFA userspace boothook, LVM / Instance Store | same | same |

Because the label and taint differ, the NVIDIA device plugin, DCGM, NPD,
gpu-health-check and GPU Operator DaemonSets never select a Neuron node, and
vice versa. One exception (harmless, labels only): the NVIDIA stack's
**node-feature-discovery worker** has no nodeSelector, and on **managed**
nodegroups EKS applies the `aws.amazon.com/neuron` taint only after the node
registers, so an NFD worker can land on a Neuron node in that window and stay
(NoSchedule does not evict). Self-managed nodegroups and Karpenter register
with the taint and are not affected.

**AMI resolution is per nodegroup**, so NVIDIA and Neuron nodegroups can be
mixed in one apply. The EKS AL2023 Neuron AMI is published for **x86_64
only** (a precondition rejects arm64-only Neuron types):

- `neuron_ami_release_version = null` (default) inherits
  `gpu_ami_release_version` — AWS publishes NVIDIA and Neuron AMIs under the
  same release tags. If a pinned tag was not published for the Neuron
  variant, plan fails with `ParameterNotFound` on
  `.../x86_64/neuron/amazon-eks-node-al2023-x86_64-neuron-<k8s>-<tag>/image_id`
  — set `neuron_ami_release_version` explicitly (`""` = recommended).
- `neuron_custom_ami_id` overrides it; it must derive from
  `amazon-eks-node-al2023-x86_64-neuron-*`. `gpu_custom_ami_id` is **never**
  applied to Neuron nodegroups.

EFA layout (`modules/gpu-instance-catalog`, verified with
`aws ec2 describe-instance-types`):

| Instance | NIC0 type | Extra EFA-only NICs | EFA total |
|---|---|---|---|
| `trn2.48xlarge` | `efa` | 15 | 16 |
| `trn1n.32xlarge` | `efa` | 15 | 16 |
| `trn1.32xlarge` | `efa` | 7 | 8 |
| `trn2.3xlarge` | `efa` | 0 | 1 |

Trainium2 is offered in a few regions only — at the time of writing
trn2.48xlarge in e.g. us-east-2 and ap-south-2, trn2.3xlarge in e.g.
sa-east-1 and ap-south-2, and **not** in us-east-1. Offerings change and can
differ per account; check before picking a region:

```bash
aws ec2 describe-instance-type-offerings --location-type region \
  --filters Name=instance-type,Values=trn2.48xlarge --region <region>
```

`trn1.2xlarge` / `inf1` / `inf2` (no or single EFA v1) get the no-EFA
default. **`trn2u.48xlarge` is not supported**: EC2 describes it (e.g. in
ap-south-2: 16 network cards / 16 EFA) but publishes no `NeuronInfo` for it,
so the Neuron device/core counts for the Cluster Autoscaler tags cannot be
derived and the plan is rejected by the Launch Template precondition
("EC2 reports no Neuron devices").

**Cluster Autoscaler scale-from-zero hints** (ASG tags; managed **and**
self-managed): `node-template/label/workload-type=neuron`,
`node-template/taint/aws.amazon.com/neuron=true:NoSchedule`,
`node-template/resources/aws.amazon.com/neuron=<devices>`,
`node-template/resources/aws.amazon.com/neuroncore=<cores>` and
`node-template/resources/vpc.amazonaws.com/efa=<EFA count>`. NVIDIA managed
nodegroups get no new tags. The `neuroncore` hint is an LNC-aware lower
bound: NeuronCore v3+ (trn2/trn3) default to LNC=2, so trn2.48xlarge
advertises 16 × 8 / 2 = **64**; trn1.32xlarge advertises 16 × 2 = 32.
Workloads should prefer requesting whole devices (`aws.amazon.com/neuron`).

### Karpenter GPU NodePools (spot-friendly alternative to GPU nodegroups)

With `install_karpenter = true`, `karpenter_gpu_nodepools` provisions GPU
capacity through Karpenter instead of (or alongside) `gpu_nodegroups`. One
EC2NodeClass + NodePool per entry, one instance type per pool:

```hcl
install_karpenter      = true
install_gpu_nodegroups = false   # or keep both
karpenter_gpu_nodepools = [
  { name = "p6-b300-spot", instance_type = "p6-b300.48xlarge",
    capacity_types = ["spot"], zones = ["ap-south-2c"], max_nodes = 1 },
]
```

- **NICs / EFA**: `EC2NodeClass.spec.networkInterfaces` (Karpenter ≥ 1.11)
  from the shared `efa_layout` — e.g. p6-b300: NIC0 `interface` + 16
  `efa-only`; NIC0-EFA types (p5, g6e…) get an extra `efa-only` at
  (card 0, device 1). Types not in the table get no EFA.
- **Storage**: `instance_store_policy = "RAID0"` (default) — Karpenter renders
  nodeadm localStorage, mounted at `/mnt/k8s-disks/0` exactly like
  `containerd_storage = "instance_store"`. Checked at plan/apply time
  against the type's Instance Store.
- **AMI**: AL2023 alias (`al2023@<gpu_ami_release_version>` or `latest`;
  Karpenter picks the NVIDIA variant) or `gpu_custom_ami_id`; override with
  `karpenter_gpu_ami_selector`. Neuron pools: see below.
- **Bootstrap**: the same g7 open-kmod fixup + EFA userspace boothook as the
  nodegroups, plus the SystemdCgroup containerd overlay (NVIDIA pools).
- **Scheduling**: labels `workload-type=gpu`, `gpu-instance-type=<type>`; taint
  `nvidia.com/gpu=true:NoSchedule` — the GPU stack DaemonSets land as-is
  (NVIDIA pools; Neuron pools: see below).
- **Spot interruption**: Karpenter's SQS interruption queue cordons/drains the
  node on the 2-minute notice and launches a replacement immediately (no ASG
  backoff, no Cluster Autoscaler involvement).
- **Disruption**: `consolidate_after` (default `1h`, empty nodes only) and
  `expire_after` (default `Never`).

#### Neuron (Trainium / Inferentia) NodePools

The vendor is detected per pool from `instance_type` by
`modules/gpu-instance-catalog` (trn\*/inf\* → Neuron, everything else →
NVIDIA), so NVIDIA and Neuron pools coexist in one `karpenter_gpu_nodepools`
list. The module output `gpu_nodepool_vendors` shows the classification.

| Vendor | AMI selector (variant) | userData parts | `workload-type` | Taint | NodePool limit |
|---|---|---|---|---|---|
| NVIDIA | `karpenter_gpu_ami_selector` chain (AL2023 NVIDIA, x86_64/arm64) | EFA boothook + g7 kmod fixup + NVIDIA containerd overlay | `gpu` | `nvidia.com/gpu=true:NoSchedule` | `nvidia.com/gpu` = max_nodes × GPUs (cpu if EC2 reports none) |
| Neuron | `karpenter_neuron_ami_selector` chain (AL2023 Neuron, x86_64) | EFA boothook only | `neuron` | `aws.amazon.com/neuron=true:NoSchedule` | `aws.amazon.com/neuron` = max_nodes × devices |

```hcl
install_karpenter    = true
install_neuron_stack = true    # required for Neuron pools (advisory check)
karpenter_gpu_nodepools = [
  { name = "p5", instance_type = "p5.48xlarge", capacity_types = ["spot"] },
  { name = "trn2-od", instance_type = "trn2.48xlarge",
    capacity_types = ["on-demand"], max_nodes = 1 },
  { name = "inf2", instance_type = "inf2.48xlarge",
    capacity_types = ["on-demand"], instance_store_policy = "" },  # inf2: no Instance Store
]
```

- **Neuron AMI resolution** (`karpenter_neuron_ami_selector = ""`):
  `neuron_custom_ami_id` if set → `al2023@<neuron_ami_release_version>` when
  that is non-null (`""` = `al2023@latest`) → `karpenter_gpu_ami_selector` if
  it is an `al2023@` alias → `al2023@<gpu_ami_release_version>` →
  `al2023@latest`. An NVIDIA `ami-` id (`gpu_custom_ami_id` /
  `karpenter_gpu_ami_selector`) is never applied to Neuron pools; reusing the
  same `ami-` id for both vendors fails the plan. With an alias, Karpenter
  resolves the x86_64 `neuron` variant itself (`instance-accelerator-count`).
  Pinned-alias caveat: if a release tag is not published for the Neuron
  variant, NodeClaims fail at launch (no plan-time signal) — set
  `neuron_ami_release_version` (or `karpenter_neuron_ami_selector`).
- **EFA**: same `networkInterfaces` rule from the shared catalog —
  trn2.48xlarge / trn1n.32xlarge: 17 interfaces, trn1.32xlarge: 9,
  trn2.3xlarge: 2; trn1.2xlarge / inf1 / inf2 get none (inf1.24xlarge's
  single EFA v1 is not in the catalog).
- **Instance Store**: inf1 / inf2 have none — set `instance_store_policy = ""`
  (the default `"RAID0"` fails the existing Instance Store precondition).
- **Unsupported**: trn2u.48xlarge. EC2 describes it only in ap-south-2, and
  there it publishes no NeuronInfo, so no device limit can be derived and the
  plan/apply fails with the module's precondition message. In every other
  region EC2 does not describe the type at all, so the plan fails earlier in
  `data.aws_ec2_instance_type` with the provider's `InvalidInstanceType` error.
- **Requirements**: `install_neuron_stack = true` (a root `check` warns when
  Neuron pools exist without it — nodes would never advertise
  `aws.amazon.com/neuron` / `vpc.amazonaws.com/efa` while billed) and a
  Karpenter version floor, enforced at plan and only for Neuron pools:
  `>= 1.11` for Neuron pools that render EFA `networkInterfaces`
  (trn1.32xlarge / trn1n / trn2; the CRD field is new in v1.11.0), `>= 1.1`
  for the others (inf1 / inf2 / trn1.2xlarge). The `>= 1.1` floor is a
  conservative minimum: v1.0.x already advertises `aws.amazon.com/neuron` for
  inf1 / inf2 (EC2 `InferenceAcceleratorInfo`) and trn1 (hard-coded counts),
  but NeuronInfo-based device counts / accelerator labels (trn2-class and
  newer) and the `aws.amazon.com/neuroncore` resource arrive in v1.1.0.
  NVIDIA pools have no floor (unchanged).
  The `karpenter_neuron_ami_selector` chain's result is format-checked only
  when a Neuron pool exists, so an ignored, malformed `gpu_ami_release_version`
  never fails an NVIDIA-only plan.
- **Capacity**: trn2 is mostly sold as ODCR / Capacity Blocks and rarely as
  Spot; these pools only offer `spot` / `on-demand` — use `["on-demand"]` or
  the `gpu_nodegroups` `odcr` / `cb` path. Karpenter `reserved` capacity is a
  follow-up.

> **Neuroncore pitfall.** Karpenter computes `aws.amazon.com/neuroncore` as
> devices × physical cores and ignores LNC. On trn2 that is devices × **8**,
> while the Neuron device plugin advertises devices × **4** at the default
> LNC=2 (inferred from the LNC docs):
>
> | Type | Karpenter assumes | Advertised (LNC=2) | Requests that never fit |
> |---|---|---|---|
> | trn2.48xlarge | 128 | 64 | 65–128 |
> | trn2.3xlarge | 8 | 4 | 5–8 |
>
> Such a pod makes Karpenter launch a node it can never fit on; the empty
> node is reclaimed after `consolidate_after` and the loop repeats (bounded
> by `max_nodes`). Terraform cannot guard this (pod requests are invisible
> to it). Request whole devices (`aws.amazon.com/neuron`) instead. trn1 /
> inf1 / inf2 (no LNC) are unaffected.

### containerd storage: EBS or Instance Store

Where `/var/lib/containerd` lives on GPU nodes is selectable — module-wide
via `gpu_containerd_storage`, or per entry via
`gpu_nodegroups[].containerd_storage` (which wins):

| | `"ebs"` (default) | `"instance_store"` |
|---|---|---|
| Backing | dedicated gp3 data volume (`gpu_node_data_volume_size`) + LVM | Instance Store NVMe, RAID0 over **all** local disks |
| Done by | this repo's boothook (mask → wait-for-exit → fail-fast rsync → sync → unmask) | the AMI's nodeadm (`spec.instance.localStorage.strategy: RAID0` → `setup-local-disks` in `nodeadm-run`) |
| Also moved | — | `/var/lib/kubelet` (so `emptyDir`), `/var/log/pods` |
| Data EBS volume | attached | **not** attached |
| Survives stop/start | yes | **no** — images re-pull on the replacement/restarted node |
| Local-LVM scratch (`gpu_enable_local_lvm`) | available | **mutually exclusive** (RAID0 takes every NVMe disk) — use `emptyDir` (already on the NVMe RAID) or `hostPath` under `/mnt/k8s-disks/0/` |
| Instance types | any | must have Instance Store (checked at plan time) |

```hcl
gpu_enable_local_lvm = false                 # required for instance_store
gpu_nodegroups = [
  { gpu_type = "p5.48xlarge", purchase_option = "od", containerd_storage = "instance_store" },
  { gpu_type = "p5.48xlarge", purchase_option = "spot" },   # → gpu_containerd_storage (ebs)
]
```

Switching an existing nodegroup changes its Launch Template (userdata +
block devices), so nodes roll on the next apply. Not supported by the
legacy bash flow (Terraform only). System and Karpenter nodes always use
the EBS path.

## GPU K8s stack (`eks-gpu-stack`)

The K8s-side components live in a separate module so the stack can be
swapped or upgraded without touching nodegroup infra. Two **mutually
exclusive** modes via `gpu_stack_mode`:

| Mode | What it installs |
|---|---|
| `standard` (default) | nvidia-device-plugin · aws-efa-k8s-device-plugin · dcgm-exporter · node-problem-detector · gpu-health-check DS |
| `operator` | NVIDIA GPU Operator (driver/toolkit/RDMA disabled to coexist with EKS GPU AMI + AWS EFA plugin) · aws-efa-k8s-device-plugin |

Why mutual exclusion is enforced:

| Conflict | `standard` provides | `operator` provides |
|---|---|---|
| `nvidia.com/gpu` | helm `nvidia-device-plugin` DS | Operator's plugin DS |
| Port 9400 metrics | helm `dcgm-exporter` | Operator's `nvidia-dcgm-exporter` |
| GFD labels | chart-internal GFD sidecar | Operator's GFD DS |
| `/dev/infiniband/uverbs*` | AWS EFA plugin (sole owner) | AWS EFA plugin; Operator `driver.rdma` / nvidia-peermem forced off |

Decision table:

| Need | Pick |
|---|---|
| Training, integer GPU requests, EFA + NCCL | `standard` |
| `standard` + Prometheus + boot health-check | `standard` (defaults already cover this) |
| MIG slicing, vGPU, GDS, Confidential Computing | `operator` |
| Don't know yet | `standard` (you can switch later) |

Switching modes:

```bash
# bash
GPU_STACK_MODE=operator GPU_STACK_FORCE_SWITCH=true bash scripts/legacy/option_install_gpu_stack.sh

# terraform — flip the variable, plan/apply will retire stale resources of the old mode
gpu_stack_mode = "operator"
```

## Neuron K8s stack (`eks-neuron-stack`)

`install_neuron_stack = true` installs the K8s side for Trainium /
Inferentia nodes. It is **independent of `install_gpu_stack` /
`gpu_stack_mode`** (not a third mode) — NVIDIA and Neuron nodes carry
disjoint labels/taints, so both stacks can be on at once.

| Component | Details |
|---|---|
| `neuron-helm-chart` (`oci://public.ecr.aws/neuron`, default `1.11.2`) | Helm release `neuron-helm-chart` in `kube-system`. The release *name* matches the AWS / Neuron docs install, but the docs command has no `--namespace`, so a manual install usually stores the release in the kubeconfig context namespace (normally `default`) — only its DaemonSet lands in `kube-system`, via the chart's `devicePlugin.namespaceOverride`. If you already installed it by hand, find the release namespace with `helm list -A \| grep neuron-helm-chart` and **`helm uninstall neuron-helm-chart -n <that-namespace>` before the first apply** (e.g. `-n default`; the device plugin is briefly absent, running pods are unaffected). `terraform import 'module.eks_neuron_stack[0].helm_release.neuron' kube-system/neuron-helm-chart` works only if it was installed with `-n kube-system`; importing `default/neuron-helm-chart` just makes the next apply replace (uninstall + reinstall) it, and a plain apply without either step fails Helm's ownership check (`invalid ownership metadata ... release-namespace ... default`). `helm_replace_existing` does **not** adopt a deployed release (Helm `install --replace` only reuses a failed / uninstalled name). Device plugin on → `aws.amazon.com/neuron` + `aws.amazon.com/neuroncore`. Placement uses the chart's own instance-type affinity + `aws.amazon.com/neuron` toleration (not overridden — Helm replaces lists). NPD, DRA driver, observer (see the Neuron Observer warning below) and UltraServer operator **off**. |
| `aws-efa-k8s-device-plugin-neuron` DaemonSet | A **second** EFA device plugin (`vpc.amazonaws.com/efa`) on `workload-type=neuron` nodes, tolerating `aws.amazon.com/neuron`. The `eks-gpu-stack` EFA DaemonSet is untouched. Reuses `install_efa_device_plugin` / `efa_device_plugin_version` / `efa_device_plugin_image`. |
| Scheduler extension (optional) | `install_neuron_scheduler = true` adds the Neuron scheduler extender + a second kube-scheduler named `my-scheduler` on the system nodes. Pods opt in with `schedulerName: my-scheduler`. Only needed when **partial-node** multi-device requests must get contiguous / connected devices — whole-node jobs don't need it. The chart's default kube-scheduler image is v1.31, outside the 1.34/1.35 skew, so `neuron_kube_scheduler_image_tag` is **required** (variable validation) with the scheduler: set it to an eks-distro tag whose minor matches `k8s_version` (e.g. `v1.35.9-eks-1-35-16` for 1.35, `v1.34.12-eks-1-34-25` for 1.34; list at gallery.ecr.aws/eks-distro/kubernetes/kube-scheduler). Adds an unauthenticated plain-HTTP **ClusterIP** listener `kube-system/k8s-neuron-scheduler:12345` with a `bind` verb — see the scheduler Exposure note below. |

**Privileges (device plugin)** — always on with `install_neuron_stack = true`.
The module keeps the upstream chart's device-plugin RBAC and mounts unchanged
(verified with `helm template` on chart 1.11.2): ClusterRole
`neuron-device-plugin` grants cluster-wide `nodes` get/list/watch,
**`nodes/proxy` get/list** (the kubelet API on every node), **`pods`
update/patch**, `nodes/status` patch/update and `events` create/patch; the
pod mounts host `/var/lib/kubelet/device-plugins`, host **`/run`
read-write** (containerd socket) and `/opt/aws` read-only. No listener. Treat
a compromise of a Neuron node's device-plugin pod as reaching the kubelet of
every node — in multi-tenant clusters isolate Neuron nodes, or fork the
chart's RBAC (the module does not override it so the release stays
adoptable from a manual AWS-docs install).

**Exposure (scheduler extension, `install_neuron_scheduler = true` only).**
The chart deploys `Deployment` + **ClusterIP** `Service`
`kube-system/k8s-neuron-scheduler` on TCP **12345** (pod network only — no
hostNetwork / hostPort / NodePort / LoadBalancer / Ingress; the chart only
uses hostNetwork + NodePort 32700 in its `defaultScheduler` mode, which this
module never enables). `my-scheduler` calls it at
`http://k8s-neuron-scheduler.kube-system.svc.cluster.local:12345` for
`filter` **and `bind`** over plain HTTP (`enableHTTPS: false`) with **no
authentication**. The extender performs the bind with its own ServiceAccount,
which the chart grants cluster-wide `create` on `bindings` / `pods/binding`,
`get/patch/update` on `pods` and `patch/update` on `nodes/status`. So
anything that can route to the extender's pod IP — every pod in the cluster,
plus VPC / peered sources as far as the node / cluster security groups allow,
no Kubernetes credentials needed — can ask it to bind still-pending pods (any
namespace) to a node of its choosing and rewrite the Neuron device-accounting
annotations (`NEURON_DEV_USAGE_MAP` / `AWS_NEURON_IDS`, which neuron-monitor's
pod attribution also reads). This is the stock upstream design, and the
toggle is off by default. (`my-scheduler` itself only serves kube-scheduler's
authenticated HTTPS port 10259 for its probes.) If your CNI enforces
NetworkPolicy, allow ingress to the extender only from `my-scheduler`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: neuron-scheduler-extender, namespace: kube-system }
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/component: k8s-neuron-scheduler }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels: { app.kubernetes.io/component: my-scheduler }
      ports: [{ port: 12345, protocol: TCP }]
```

Mirrors for cn-* / isolated / air-gapped regions:
`neuron_helm_chart_repository`, `neuron_device_plugin_image_repository` /
`_tag`, and with the scheduler also `neuron_scheduler_image_repository` /
`_tag` (neuron-scheduler extender) and
`neuron_kube_scheduler_image_repository` (+ `neuron_kube_scheduler_image_tag`,
for `my-scheduler`); with `install_neuron_monitor` also `neuron_monitor_image`
(neuron-monitor DaemonSet, default `public.ecr.aws`); and
`efa_device_plugin_image` for the EFA DaemonSet (default: the per-region EKS
add-on ECR registry, cn-* included; only regions missing from
`modules/eks-addon-ecr-registry`, or air-gapped clusters that cannot reach
it, need to override).
That covers every image the stack pulls; `""` keeps the chart default
(`public.ecr.aws`). **Not mirrorable:** `neuron_monitor_service_monitor = true`
installs a second chart, bedag/raw 2.0.2, from the hardcoded
`https://bedag.github.io/helm-charts/` (no override variable, same as
`eks-karpenter`'s `karpenter-pools`) — in air-gapped regions keep that toggle
off (create the ServiceMonitor by hand) or make that URL reachable. The
releases use `wait = false`, so an unreachable image shows up only as
`ImagePullBackOff`, not as an apply error.
A 403 `authorization token has expired` from `public.ecr.aws` during
plan/apply is a stale cached Helm registry login — run
`helm registry logout public.ecr.aws` (anonymous pulls work).

Whole-node trn2.48xlarge pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: trn2-whole-node
spec:
  tolerations:
    - key: aws.amazon.com/neuron
      operator: Exists
      effect: NoSchedule
  nodeSelector:
    workload-type: neuron
  containers:
    - name: train
      image: public.ecr.aws/neuron/pytorch-training-neuronx:<tag>
      resources:
        limits:
          aws.amazon.com/neuron: 16
          vpc.amazonaws.com/efa: 16
```

Root-level `check` blocks warn at plan time when `gpu_nodegroups` or
`karpenter_gpu_nodepools` contain Neuron types but
`install_neuron_stack = false` (nodes would join without
`aws.amazon.com/neuron` / `vpc.amazonaws.com/efa`).

### Neuron metrics (neuron-monitor)

Opt-in, at parity with how `eks-gpu-stack` ships dcgm-exporter: an exporter
on every Neuron node, **no metrics backend**, ServiceMonitor off by default.

| Variable | Default | Effect |
|---|---|---|
| `install_neuron_monitor` | `false` | neuron-monitor DaemonSet + ClusterIP Service. Requires `install_neuron_stack = true` (validation). |
| `neuron_monitor_image` | `public.ecr.aws/neuron/neuron-monitor:1.13.0` | Same tag the AWS CloudWatch Observability chart ships. amd64-only; mirror it for cn-* / isolated regions. |
| `neuron_monitor_service_monitor` | `false` | Prometheus Operator ServiceMonitor (Helm release `neuron-monitor-servicemonitor`, bedag/raw 2.0.2). Needs the `monitoring.coreos.com/v1` CRDs **before** apply. Requires `install_neuron_monitor`. |
| `neuron_monitor_service_monitor_labels` | `{}` | Extra ServiceMonitor labels for your `serviceMonitorSelector` (e.g. `{ release = "kube-prometheus-stack" }`). |
| `neuron_monitor_pod_attribution` | `false` | **BETA** `--enable-k8s-info` pod / namespace / container labels (caveats below). Requires `install_neuron_monitor`. |

Objects (all in `kube-system`, all count-gated, all off by default):

- `ServiceAccount/neuron-monitor` (token **not** mounted unless pod attribution is on)
- `DaemonSet/neuron-monitor` — `neuron-monitor | neuron-monitor-prometheus.py --port 8000`
  via the image's `/opt/bin/entrypoint.sh`; `nodeSelector workload-type=neuron`,
  tolerates `aws.amazon.com/neuron`, `system-node-critical`, inf1 excluded by
  node affinity (conservatively — untested here; the AWS manifests do schedule
  it on inf1). Root filesystem read-only; `/tmp` and `/root` are emptyDirs;
  host `/opt/aws` mounted **read-only** at `/opt-aws` (`type: Directory`,
  never created on the host) — both the `neuron-monitor` binary and
  `neuron-monitor-k8s-info.py` read the host LNC config
  `neuron/logical_nc_config` from there (same mount as the CloudWatch
  Observability chart and the Neuron device plugin); without it a host with a
  non-default LNC would be reported with default (trn2 = LNC=2) core counts.
- `Service/neuron-monitor` — **ClusterIP** `:8000` (port name `metrics`)
- with pod attribution: `ClusterRole` + `ClusterRoleBinding/neuron-monitor`
- with the ServiceMonitor: Helm release `neuron-monitor-servicemonitor`

**Exposure.** The exporter listens on TCP 8000 inside the pod network
namespace only — no hostNetwork, no hostPort, no NodePort / LoadBalancer /
Ingress / externalIPs. `/metrics` is plain HTTP, read-only, with **no
authentication** (same posture as dcgm-exporter `:9400`). Anything that can
route to the pod IP can scrape it: every pod in the cluster, and VPC /
peered sources as far as the node / cluster / GPU security groups allow
(the GPU SG is self-referencing all-traffic and is shared with Neuron
nodegroups). If your CNI enforces NetworkPolicy, restrict it to the
scraper, e.g.:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: neuron-monitor-scrape, namespace: kube-system }
spec:
  podSelector: { matchLabels: { name: neuron-monitor } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: monitoring } }
      ports: [{ port: 8000, protocol: TCP }]
```

**Why privileged.** Both AWS manifests (aws-neuron-sdk
`k8s-neuron-monitor-daemonset.yml` and the CloudWatch Observability chart)
run neuron-monitor privileged: it enumerates **every** `/dev/neuron*` device
and the driver's sysfs counters regardless of which pod the device plugin
allocated them to, and the device cgroup blocks an unprivileged container
from devices it was not allocated. An unprivileged variant
(`CAP_SYS_ADMIN` + `/dev` hostPath) is untested — follow-up. The only
hostPath mounted by default is `/opt/aws` (read-only, LNC config).

**Metrics** (prefix-less, from `neuron-monitor-prometheus.py`):
`neuroncore_utilization_ratio`, `neuroncore_memory_usage_*`,
`neuron_runtime_memory_used_bytes`, `execution_status_total`,
`execution_errors_total`, `execution_latency_seconds`,
`hardware_ecc_events_total`, `neuron_hardware_info`, `instance_info`,
`system_*` (incl. `system_vcpu_usage_ratio`) — exactly the groups enabled by
the image's `/opt/aws/neuron/bin/neuron-monitor.conf`
(`neuroncore_counters`, `memory_used`, `execution_stats`; `vcpu_usage`,
`memory_info`, `neuron_hw_counters`). The per-runtime
`neuron_runtime_vcpu_usage_ratio` is **not** produced: it needs a
`neuron_runtime_vcpu_usage` group the shipped config does not enable (no
custom-config knob here). Each series carries
`instance_id` / `instance_type` / `availability_zone` / `region` /
`subnet_id`. Capacity comes from kube-state-metrics, e.g.
`kube_node_status_allocatable{resource="aws_amazon_com_neuron"}`.

**Label schema** (ServiceMonitor, `honorLabels: false`, 15s / 10s — the
dcgm-exporter chart defaults): the target's own `pod` / `namespace` are the
exporter pod's; the workload's labels land as `exported_pod`,
`exported_namespace`, `exported_container` (container name unwrapped from
neuron-monitor's `['name']` format) — the same `exported_*` names
dcgm-exporter produces behind its ServiceMonitor. The ServiceMonitor also
adds a `node` label (from `__meta_kubernetes_pod_node_name`); that one is
**Neuron-only** — the dcgm-exporter chart adds no relabelings and identifies
the host by its own `Hostname` label, so a cross-vendor `by (node)` query
needs e.g. `label_replace(<dcgm expr>, "node", "$1", "Hostname", "(.*)")`.

**Pod attribution caveats** (`neuron_monitor_pod_attribution`, BETA):

- Ownership comes from the `AWS_NEURON_IDS` pod annotation, which only the
  Neuron scheduler extension writes (`install_neuron_scheduler = true`, pods
  with `schedulerName: my-scheduler`). **Without it, neuron-monitor attributes
  every device and core on the node to the first Neuron-holding pod** it
  finds (and `container_name` may list containers of several pods): a pod
  requesting 1 of 16 devices shows up on all 16. Attribution is therefore
  correct only when the scheduler extension is used, or when one pod owns all
  of the node's Neuron devices.
- The SA gets `get nodes/pods` only — **never** `nodes/proxy` (kubelet
  exec / run). `nodes/pods` only works where the kubelet runs fine-grained
  authorization (`KubeletFineGrainedAuthz`); otherwise the kubelet returns
  403 and no series is attributed.
- The kubelet `pod-resources` socket directory is mounted **read-only**
  (`/var/lib/kubelet/pod-resources`, the only hostPath besides the read-only
  `/opt/aws`).
- Unattributed series — **all** series when no pod on the node holds a
  Neuron resource, on a 403 / lookup error or before the first lookup, and
  (only with the annotation) devices not listed in it — carry the literal string
  `"None"` in `pod_name` / `namespace` / `container_name` on the raw
  `/metrics`. The ServiceMonitor blanks those values first, so such series
  simply have no `exported_pod` / `exported_namespace` /
  `exported_container` (as with dcgm on an unallocated GPU). A scraper
  without the ServiceMonitor sees the raw `"None"`.

Not covered: EFA host counters (no EFA metrics), the Neuron DRA driver
(neuron-monitor does not support DRA environments), inf1.

> [!WARNING]
> **Neuron Observer — not managed by this repo.** The chart's
> `observer.*` component stays `enabled = false` and is intentionally not
> exposed as a variable. When enabled it runs a **hostNetwork** DaemonSet
> with **hostPort 7001 bound on `0.0.0.0` on every Neuron node**, serving an
> **unauthenticated HTTP API that includes fault-injection endpoints**, and
> auto-creates a PodMonitor whenever the `monitoring.coreos.com` CRDs exist.
> It is beta and validated only on Trn2/Trn3, **but the chart schedules it
> on every Neuron instance type** (trn1/trn1n/trn2/trn3/inf1/inf2, via
> `neuronInstances` + `neuron.amazonaws.com/present=true`). If you install it
> by hand anyway: set
> `observer.monitoring.podMonitor.enabled=false` explicitly unless you want
> that PodMonitor, and restrict TCP 7001 in the node security groups to your
> scraper (the shared GPU SG allows all traffic between its members).

### Verifying Neuron nodes

`scripts/option_verify_gpu_efa.sh` auto-detects Neuron nodes (label
`workload-type=neuron` or allocatable `aws.amazon.com/neuron > 0` on the
probe node) and then runs the Neuron path instead of NCCL; NVIDIA behaviour
is unchanged. Single-node: `neuron-ls` device count == allocatable,
`/dev/neuron*` count, visible NeuronCores vs allocatable `neuroncore`
(WARN only — LNC), `fi_info -p efa` + uverbs count, and a local
`nccom-test` all-reduce. `--multi N`: `nccom-test` all-reduce across N
nodes over EFA (`FI_PROVIDER=efa`). Both runs pass `--check` (random input,
results validated against a golden; a mismatch prints `N errors found` and
FAILs — without it nccom-test only times zero-filled buffers); both also
need exit 0, and multi-node additionally an `Avg bus bandwidth` line.
Multi-node uses Open MPI over ssh on pod port 2222 with an ephemeral ed25519 key (trn1 / trn1n / trn2 with EFA only). The private key
is kept in a `verify-run`-labelled Secret mounted `0400` into the launcher
only — never in a Pod spec, so namespace read-only (`view`) access cannot
copy it; the script therefore needs `create secrets` in `VERIFY_NAMESPACE`. Pods request **whole
devices** (`aws.amazon.com/neuron`, never `neuroncore`) +
`vpc.amazonaws.com/efa`, add only `IPC_LOCK` (not privileged, no hostPath,
no hostNetwork), and are deleted on exit (`pod,svc,secret -l verify-run=<id>`
are removed together; a failed delete prints a WARN with that exact
`kubectl delete` command). `activeDeadlineSeconds` is a backstop for the
**Pods only** — the headless Service and the ssh-key Secret stay until that
delete succeeds.

| Env | Default | Notes |
|---|---|---|
| `VERIFY_VENDOR` | `auto` | `auto` / `nvidia` / `neuron` |
| `VERIFY_NEURON_IMAGE` | `public.ecr.aws/neuron/pytorch-training-neuronx:2.9.0-neuronx-py312-sdk2.30.0-ubuntu24.04` | Pick a DLC whose Neuron runtime matches the host `aws-neuronx-dkms` |
| `VERIFY_NEURON_TIMEOUT_SEC` | `1800` | Independent of `VERIFY_TIMEOUT_SEC`; one shared deadline per run. It must cover the first DLC pull (~15 GB compressed; in `--multi` mode all nodes pull in parallel — a resource-less pre-pull pod on the launcher node runs alongside the workers), the in-pod upgrades from `VERIFY_NEURON_RUNTIME_UPGRADE` (workers, then the launcher again after the workers are Ready: roughly 1-3 min each with egress) and the test. Without egress set `VERIFY_NEURON_RUNTIME_UPGRADE=false` instead of waiting for the downloads to time out |
| `VERIFY_NEURON_COMM_PORT` | `63182` | `NEURON_RT_ROOT_COMM_ID` port on the launcher pod |
| `VERIFY_NEURON_RUNTIME_UPGRADE` | `true` | Before testing, every verify pod upgrades `aws-neuronx-runtime-lib` / `-collectives` / `-tools` from the Neuron apt repo; after a successful upgrade, `--multi` pods also install the latest EFA userspace (libfabric) from `aws-efa-installer`, accepted only if its signature is a `VALIDSIG` by the pinned AWS EFA key `4E9091BCBB97A96B26B15E59A05480B1DD2D3CCC` (every step checked; any failure skips the install). Needed today: the newest public training DLC (sdk2.30, runtime 2.32) fails `nrt_init` on the EKS Neuron AMI driver (`aws-neuronx-dkms` 2.31.7, AMI v20261031), and collectives 2.35 rejects the DLC's libfabric 2.4 for inter-node traffic. Needs egress to `apt.repos.neuron.amazonaws.com` + `efa-installer.amazonaws.com` (each EFA download: 10 s connect / 300 s per attempt, up to 3 attempts — so a stalled-but-reachable endpoint can take ~15 min per file before the WARN; on clusters without reliable egress set `false`); failures only WARN. `false` = run the image as-is (pinned / air-gapped images) |

`VERIFY_NAMESPACE`, `VERIFY_KEEP_POD` and `VERIFY_BUSBW_THRESHOLD` apply to
both paths. Transient listeners while it runs (pod IPs only): sshd 2222,
the comm port, the nccom-test data collector 60006, and Open MPI's
ephemeral TCP ports.

`scripts/option_inspect_eks.sh` adds Neuron checks to `[9/9]` only on
clusters with `workload-type=neuron` nodes: device-plugin allocatable per
Ready node, EFA on the catalog's Neuron EFA types (trn1.32xlarge / trn1n.32xlarge / trn2.48xlarge / trn2.3xlarge), Trn On-Demand / Spot vCPU quotas,
and whether `ds/neuron-monitor` is present.

Known gaps:

- No Neuron health checks (the chart's node-problem-detector / recovery
  agent stays off) and no EFA host counters.
- The Neuron Observer is not managed (see the warning above).
- `aws-efa-k8s-device-plugin-neuron` runs on every `workload-type=neuron`
  node; on types without EFA (inf1 / inf2 / trn1.2xlarge, or a Karpenter
  pool without `networkInterfaces`) the plugin finds no device, exits and is
  restarted by the DaemonSet (same behaviour as the eks-gpu-stack EFA plugin
  on non-EFA GPU types). Harmless, but it shows up as restarts.
- The NVIDIA NFD worker can land on managed-nodegroup Neuron nodes before
  EKS applies the taint (see "Trainium / Inferentia (Neuron) nodegroups").
- The verify script's nodegroup pre-flight (`describe-nodegroup`) excludes
  Karpenter and self-managed Neuron nodes, same as the NVIDIA path.
- LNC host configuration (`/opt/aws/neuron/logical_nc_config`) is not exposed
  (neither for nodegroups nor for Karpenter pools — no LNC knob).
- Karpenter GPU NodePools offer only `spot` / `on-demand`; no `reserved`
  (ODCR) or Capacity Block capacity type yet.

## What is intentionally NOT in Terraform

These remain as bash scripts under `../scripts/` because they are
verification/operational tools, not infrastructure declarations:

| Script | Why |
|---|---|
| `option_verify_gpu_efa.sh` | Live NCCL (NVIDIA) / nccom-test (Neuron) benchmark over EFA, vendor auto-detected; runs after apply (see "Verifying Neuron nodes") |
| `option_show_nodegroup_topology.sh` | Reads K8s labels and prints inventory |
| `option_create_bastion.sh` | Bastion lifecycle is operator-driven |
| `topology gate` from `option_install_gpu_nodegroups.sh` | Post-create assertion + scale-to-0 rollback is imperative by nature |

Run these against the cluster Terraform created.

## Tearing down — use `scripts/safe-destroy.sh`

The `kubernetes` and `helm` providers in `providers.tf` authenticate
against the cluster via `aws eks get-token` exec auth. This creates an
**implicit coupling**: provider configuration depends on
`module.eks_cluster` outputs, but Terraform's dependency graph does not
treat provider config as an ordinary edge. If the cluster is destroyed
or its API becomes unreachable while there are still helm releases /
K8s resources in state, those resources fail to delete (auth error)
and state gets stuck with orphans.

**Always tear down with the wrapper:**

```bash
cd terraform
./scripts/safe-destroy.sh --var-file terraform.tfvars.test --auto-approve
```

The script:

1. `helm uninstall` every managed release in reverse install order
   (karpenter-pools → karpenter → nvidia-device-plugin → dcgm-exporter →
   node-problem-detector → neuron-monitor-servicemonitor → neuron-helm-chart →
   aws-load-balancer-controller → cluster-autoscaler → aws-fsx-csi-driver),
   plus gpu-operator from ns/gpu-operator, the gpu-health-check DaemonSet,
   the Neuron EFA DaemonSet (aws-efa-k8s-device-plugin-neuron) and the
   neuron-monitor DaemonSet / Service / ClusterRole(Binding) / ServiceAccount
   (all `--ignore-not-found`, so they are no-ops when the toggles were off)
2. `kubectl delete serviceaccount` the SAs Terraform created
   (karpenter / cluster-autoscaler / aws-load-balancer-controller /
   fsx-csi-controller-sa) — Pod Identity associations vanish with TF,
   but lingering SAs with stale annotations confuse re-applies
3. `kubectl delete nodepool / ec2nodeclass` (in case the bedag/raw
   helm chart left orphans)
4. `terraform destroy`

**Manual fallback** if the script gets stuck:

```bash
# Find K8s-API-dependent resources still in state
terraform state list | grep -E 'helm_release|kubernetes_'

# If the cluster API is already dead, drop them from state by hand
terraform state rm 'module.eks_addons.helm_release.cluster_autoscaler'
# ...then retry destroy
```

Don't forget the separate `bootstrap-vpc/` stack:
`cd bootstrap-vpc && terraform destroy`.

> **Long-term fix (not in scope for v1)**: split helm/k8s resources
> into a separate Terraform stack that consumes cluster outputs via
> `terraform_remote_state`. This makes destroy ordering explicit (k8s
> stack first, cluster stack second) and decouples plan-time provider
> auth from cluster lifecycle. See the `## What is intentionally NOT
> in Terraform` section for the rationale.

## State and secrets

- All state lives in S3, encrypted, versioned.
- DynamoDB lock prevents concurrent apply.
- KMS key for Secrets envelope-encryption is configured via `kms_key_arn` (recommended).
- Plan/apply must run from a host that can reach the private API endpoint (bastion or VPN).

## Differences vs the bash scripts

The Terraform port deliberately drops a few bash-only features:

- No interactive prompts; all behavior is variable-driven.
- IAM role propagation retries (the `sleep 10` loops) are handled by the AWS provider.
- "Already exists" idempotency hacks disappear — Terraform tracks state.
- Launch Template version management is automatic; bash had to branch on `describe` first.
- The bash topology gate (`verify_topology` with strict scale-to-0 rollback) is not ported.
  Use `option_verify_gpu_efa.sh` after apply instead.
