# Self-Managed Node Groups

This stack defaults to EKS Managed Node Groups (`aws_eks_node_group`).
Setting `node_management = "self_managed"` switches both the system and
GPU NG modules to customer-owned ASGs (`aws_autoscaling_group`) with all
ASG-driven self-healing turned off.

Pick this mode when you need any of:

- **Stable instance IDs** — your CMDB / monitoring / network policies
  track instances by ID and break when ASG terminate-and-replace fires.
- **Targeted retire** — operations needs to pick which exact instance
  comes out, not just "the oldest" or "the largest in this AZ".
- **You bring your own Cluster Autoscaler** — and want a single writer
  on the ASG (`UpdateAutoScalingGroup` not racing with EKS).

If none of these apply, stay on the default. Managed NG is simpler.

## How to enable

```hcl
# terraform.tfvars
node_management = "self_managed"
```

`node_management` is cluster-wide — both system and GPU NGs switch
together. Mixing modes inside one cluster is intentionally not
supported.

Optional knobs:

```hcl
# Default — disables ALL ASG-driven self-healing
asg_suspended_processes = ["ReplaceUnhealthy", "AZRebalance"]

# Cost-allocation / governance tags applied to every self-managed ASG
extra_asg_tags = { Owner = "ml-platform", CostCenter = "1234" }

# Set false to skip our cluster-autoscaler install — needed when you
# deploy your own CA. ASG discovery tags
# (k8s.io/cluster-autoscaler/<cluster>=owned) are inlined either way.
install_cluster_autoscaler = false
```

## What changes versus Managed NG

| Concern | Managed NG | Self-Managed |
|---|---|---|
| Underlying ASG | EKS-owned | `aws_autoscaling_group` in this state |
| Instance ID stability | Replaces on health check fail / AZ rebalance | Stable until you `terminate-instance-in-auto-scaling-group` |
| K8s upgrade | EKS rolling update | Operator-driven cordon → drain → terminate |
| CA discovery tags | Set via `aws_autoscaling_group_tag` workaround | Inlined on the ASG resource |
| Node SG | EKS auto-creates `eks-cluster-sg-*` | Module creates `<cluster>-{system,gpu}-node-sg` |
| Cluster SG ingress | Auto-added by EKS | Module-managed `aws_vpc_security_group_ingress_rule` |
| Labels / taints | Injected via NodeGroup API | `--node-labels` / `--register-with-taints` in nodeadm config |
| IAM instance profile | Implicit from `node_role_arn` | `aws_iam_instance_profile` resource |
| Spot pricing | `aws_eks_node_group.capacity_type = "SPOT"` | LT `instance_market_options { market_type = "spot" }` |
| ODCR / Capacity Block | Same on both paths (LT `capacity_reservation_specification`) | Same |
| EFA multi-NIC LT | Same on both paths | Same |

## ASG self-healing — what's off, what stays on

The default `asg_suspended_processes = ["ReplaceUnhealthy",
"AZRebalance"]` together with `health_check_type = "EC2"` and no
`instance_refresh` block means:

✅ **Off (suspended)**:
- ASG never terminates an instance because of an EC2 status check
- ASG never rebalances across AZs by terminating + relaunching
- LT version bumps never trigger a rolling replace

✅ **On (kept)** — required by the rest of the system:
- `Launch` — Cluster Autoscaler must be able to scale up
- `Terminate` — `terminate-instance-in-auto-scaling-group` for targeted
  retire
- `HealthCheck` — instances are still flagged unhealthy (visibility),
  just not auto-replaced

The validation block on `var.asg_suspended_processes` rejects suspending
`Launch` or `Terminate` (would break CA scale-up or operator retire).

## Day-2 operations

### Retire one specific instance

```bash
NODE=<the K8s node name>
INSTANCE_ID=$(kubectl get node $NODE -o jsonpath='{.spec.providerID}' | sed 's|.*/||')

kubectl cordon $NODE
kubectl drain  $NODE --ignore-daemonsets --delete-emptydir-data --grace-period=300
kubectl delete node $NODE

aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id $INSTANCE_ID \
  --should-decrement-desired-capacity
```

`--should-decrement-desired-capacity` is critical — without it the ASG
sees `desired` short by one and immediately launches a replacement
(with a new instance ID).

### Protect a key instance from CA scale-in

```bash
aws autoscaling set-instance-protection \
  --instance-ids i-xxx \
  --auto-scaling-group-name <asg> \
  --protected-from-scale-in
```

### Acknowledge a manual fix and re-arm health flag

```bash
aws autoscaling set-instance-health \
  --instance-id i-xxx \
  --health-status Healthy
```

### Roll a new AMI / LT version

The ASG will not roll instances on its own (no `instance_refresh`).
Update the LT, then for each instance:

```bash
kubectl cordon <node>
kubectl drain  <node> ...
kubectl delete node <node>
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id <id> --should-decrement-desired-capacity
# Increase desired_capacity (or wait for CA) — new instance comes up on the new LT
```

## Bring-your-own Cluster Autoscaler

Set `install_cluster_autoscaler = false` to skip our install. The ASG
discovery tags
`k8s.io/cluster-autoscaler/<cluster>=owned` and
`k8s.io/cluster-autoscaler/enabled=true` are inlined on every
self-managed ASG, plus per-NG scale-from-zero hints
(`node-template/label/...`, `node-template/taint/...`,
`node-template/resources/...`). Any compatible Cluster Autoscaler picks
them up zero-config.

Minimum IAM your CA pod needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "autoscaling:UpdateAutoScalingGroup"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/k8s.io/cluster-autoscaler/<cluster-name>": "owned"
        }
      }
    }
  ]
}
```

Recommended CA flags:

```
--cloud-provider=aws
--node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/<cluster>,k8s.io/cluster-autoscaler/enabled
--balance-similar-node-groups
--expander=least-waste
--max-node-provision-time=15m
--scale-down-delay-after-add=10m
--scale-down-unneeded-time=10m
--skip-nodes-with-local-storage=false
```

`--max-node-provision-time=15m` is intentionally generous: ODCR and
Capacity Block instances can take longer to launch than the 10-minute
default.

## Switching modes after the cluster is built

Don't. The Managed → Self-Managed flip is a destroy-and-recreate at the
NG level (different terraform resource types). Choose the mode at
cluster creation time. If you must migrate an existing cluster, drain
and decommission the old NGs explicitly before running the apply that
flips the variable.

## Bastion IAM policy

The terraform deploy bastion needs four ASG actions beyond the Managed
NG default set
(`CreateAutoScalingGroup`, `DeleteAutoScalingGroup`, `SuspendProcesses`,
`ResumeProcesses`). These were added in
`terraform/assets/iam/bastion-policy.json` — re-apply that policy to
your `EKS-Terraform-Deploy-Policy` before running a self-managed apply.
