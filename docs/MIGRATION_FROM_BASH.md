# Migration: bash scripts → Terraform

> **Status (2026-05)**: bash deployment pipeline has been moved to `scripts/legacy/` and entered maintenance-only. Terraform is the canonical path for new deployments. This page maps each legacy bash script to its Terraform replacement so existing users can plan a transition.

The `terraform/` directory implements the same end state as the
old `scripts/legacy/` bash pipeline.

## Module map

| Bash script (now in `scripts/legacy/`) | Terraform | Notes |
|---|---|---|
| `0_setup_env.sh` (kept at `scripts/0_setup_env.sh`, shared with ops tools) | `terraform.tfvars` + provider AWS auto-detect | Variables replace env-var sourcing |
| `1_enable_vpc_dns.sh` | `modules/vpc-endpoints` precondition | TF asserts DNS is on; flip via AWS CLI once if it isn't |
| `2_validate_network_environment.sh` | `data` blocks at plan time | TF fails plan if subnets/VPC don't exist |
| `3_create_vpc_endpoints.sh` | `modules/vpc-endpoints` | full/minimal mode preserved |
| `4_install_eks_cluster.sh` | `modules/eks-cluster` | private/public, KMS encryption, OIDC, vpc-cni/kube-proxy/pod-identity-agent |
| `5_check_environment.sh` | (n/a — operator concern) | TF doesn't verify operator's CLI tools |
| `6_create_system_nodegroup.sh` | `modules/eks-system-nodegroup` | LVM userdata templated; arch auto-detected via `aws_ec2_instance_type` |
| `7_install_eks_addon.sh` | `modules/eks-addons` | CoreDNS + Metrics Server (managed addons), CA + ALB (helm releases) |
| `option_install_csi_drivers.sh` | `modules/eks-csi-drivers` | EBS always; EFS/FSx/S3 toggled via vars |
| `option_install_karpenter.sh` | `modules/eks-karpenter` | helm + SQS interruption queue + EventBridge rules + sample NodePool/EC2NodeClass |
| `option_install_gpu_nodegroups.sh` | `modules/eks-gpu-nodegroup` | Multi-NIC EFA via `dynamic network_interfaces`; OD/Spot/ODCR/CB declared per nodegroup |
| `option_install_gpu_stack.sh` | `modules/eks-gpu-stack` | standard / operator mode dispatch |
| `option_create_bastion.sh` (kept at `scripts/`) | also: `terraform/bootstrap-bastion/` | Both maintained — pick one |
| `option_verify_gpu_efa.sh` (kept at `scripts/`) | (no TF equivalent) | NCCL benchmark; runs against an existing cluster |
| `option_show_nodegroup_topology.sh` (kept at `scripts/`) | (no TF equivalent) | Reads `topology.k8s.aws/network-node-layer-N` labels at runtime |
| `option_inspect_eks.sh` (kept at `scripts/`) | (no TF equivalent) | 9-check post-apply health audit |
| `topology_inventory_lib.sh` (kept at `scripts/`) | (kept) | Used by ops tools |
| `instance_arch_lib.sh` | replaced by `data "aws_ec2_instance_type"` | Native TF lookup |
| `disk_detection_lib.sh` | `terraform/modules/eks-{system,gpu}-nodegroup/templates/detect-ebs-disk.sh` | Embedded into userdata via `templatefile()` |
| `pod_identity_helpers.sh` | `aws_eks_pod_identity_association` resources | Native TF resource |

## Variable mapping (.env → terraform.tfvars)

| `.env` | `terraform.tfvars` |
|---|---|
| `CLUSTER_NAME` | `cluster_name` |
| `AWS_REGION` | `aws_region` |
| `VPC_ID` | `vpc_id` |
| `PRIVATE_SUBNET_A/B/C/D` | `private_subnet_ids` (list) |
| `PUBLIC_SUBNET_A/B/C/D` | `public_subnet_ids` (list) |
| `CLUSTER_MODE` | `cluster_mode` |
| `PUBLIC_ACCESS_CIDRS` | `public_access_cidrs` (list) |
| `K8S_VERSION` | `k8s_version` |
| `KMS_KEY_ARN` | `kms_key_arn` |
| `VPC_ENDPOINTS_MODE` | `vpc_endpoints_mode` |
| `SYSTEM_NODE_INSTANCE_TYPE` | `system_node_instance_type` |
| `SYSTEM_NODE_*_VOLUME_SIZE` | `system_node_root_volume_size` / `..._data_volume_size` |
| `SYSTEM_NODE_DESIRED/MIN/MAX` | `system_node_desired_capacity` / `_min_size` / `_max_size` |
| `EC2_KEY_NAME` | `ec2_key_name` |
| `INSTALL_KARPENTER` | `install_karpenter` |
| `KARPENTER_VERSION` | `karpenter_version` |
| `INSTALL_EFS_CSI` / `INSTALL_FSX_CSI` | `install_efs_csi` / `install_fsx_csi` |
| `S3_BUCKET_ARNS` | `s3_csi_bucket_arns` |
| `GPU_INSTANCE_TYPES` + `DEPLOY_GPU_OD/SPOT/ODCR/CB` | `gpu_nodegroups` (list of objects) |
| `ODCR_IDS/AZS` + `CAPACITY_BLOCK_IDS/AZS` | per-entry `capacity_reservation_id` + `subnet_ids` |
| `GPU_PG_STRATEGY` | per-entry `placement_group` (`none`|`cluster`) |
| `GPU_TARGET_AZ` | per-entry `subnet_ids` (single subnet) |
| `GPU_NG_SUFFIX` | per-entry `suffix` |
| `GPU_INSTALL_EFA_USERSPACE` | `gpu_install_efa_userspace` |
| `GPU_ENABLE_LOCAL_LVM` etc. | `gpu_enable_local_lvm` / `gpu_local_lvm_*` |
| `NVIDIA_DEVICE_PLUGIN_VERSION/REPO` | `nvidia_device_plugin_version/repo` |
| `EFA_DEVICE_PLUGIN_VERSION/IMAGE` | `efa_device_plugin_version/image` |
| `GPU_TOPOLOGY_MODE` / `_GATE` / `_GATE_LAYER` | (not ported — use `option_verify_gpu_efa.sh`) |

## Behavioral differences

1. **No "already exists, skipping" loops.** Terraform's state file tracks
   what was created. Re-applying a known-good config is a no-op.
2. **No retry-on-IAM-propagation.** The AWS provider handles it.
3. **No imperative bounce of NVIDIA device plugin pods.** The helm chart
   uses `failOnInitError=true` (upstream default) and self-heals via
   CrashLoopBackOff once the device files are ready.
4. **Topology gate dropped.** The bash `verify_topology` step inspected
   K8s labels post-NG and scaled the NG to 0 on mismatch. This is
   imperative and conflicts with TF's declarative model. Use the
   verifier scripts under `scripts/option_verify_gpu_efa.sh` and
   `scripts/option_show_nodegroup_topology.sh` instead.
5. **Apply must run from a host inside the cluster VPC** when
   `cluster_mode=private`. This matches the bash scripts' constraint;
   TF's kubernetes/helm providers use `aws eks get-token` exec auth
   which still needs API reachability.
6. **No aws-auth ConfigMap manipulation.** Cluster runs in
   `API_AND_CONFIG_MAP` mode but TF uses `aws_eks_access_entry` resources
   (system NG, GPU NG, Karpenter node role) instead of patching the
   legacy `aws-auth` ConfigMap. This is the AWS-recommended path; the
   ConfigMap is left untouched.
7. **Native deletion protection.** TF sets `aws_eks_cluster.deletion_protection`
   directly (provider 5.70+). Bash had to call `aws eks update-cluster-config`
   after the cluster was up.
8. **Karpenter SQS interruption queue is enabled by default in TF.** The
   bash script intentionally skipped this (commented out
   `settings.interruptionQueue`). The TF module creates the SQS queue
   plus 4 EventBridge rules (spot interruption, rebalance, instance
   state-change, AWS Health) so spot capacity is reclaimed gracefully.
   To match the bash behavior, set the helm value `settings.interruptionQueue=""`.
9. **Tagging.** The bash scripts hard-code `business=middleware,resource=eks`
   on every resource. TF uses the provider-level `default_tags` map
   instead — set it once in `terraform.tfvars` and every taggable
   resource picks them up. See `terraform.tfvars.example`.

## Coexistence

You can adopt Terraform incrementally:

- Keep using bash for `option_create_bastion.sh`.
- Use Terraform for the cluster/system NG/addons.
- Use bash for any one-off verification or operational tasks.

The two paths share `manifests/` (IAM JSON, Karpenter sample
manifests). Don't run both for the same module — pick one source of
truth per resource group.
