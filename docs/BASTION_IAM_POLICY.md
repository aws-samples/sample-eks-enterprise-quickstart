# Bastion IAM Policy for Terraform Deploys

This document explains the IAM permissions required to run `terraform
apply` against this stack from a bastion host (or any other deployment
runner).

## Deployment Assumptions

This policy is designed under the following threat model. Operators
deploying outside these assumptions should review and constrain
accordingly.

- **Deploy runner only** — intended for a bastion host or CI runner that
  runs `terraform apply`, not for user-facing IAM roles.
- **Stack-dedicated AWS account** — assumes the account hosts one EKS
  stack created by this Terraform. Wildcards (`s3:*`, `dynamodb:*`,
  `eks:*`) rely on the account having no unrelated resources of those
  types.
- **High-trust bastion** — bastion compromise is treated as
  out-of-scope; combine with EC2 IMDSv2, SSM Session Manager (no SSH),
  and short-lived credentials per your standard.
- **Shared-account / multi-tenant** — attach a Permission Boundary that
  scopes resources by tag (e.g. `aws:ResourceTag/managed-by=terraform`)
  rather than enumerating every action.

## File location

[`terraform/assets/iam/bastion-policy.json`](../terraform/assets/iam/bastion-policy.json)

## Apply

```bash
# Run from the repository root so the file:// path resolves correctly.
cd "$(git rev-parse --show-toplevel)"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws iam create-policy \
  --policy-name EKS-Terraform-Deploy-Policy \
  --policy-document file://terraform/assets/iam/bastion-policy.json

# Attach to whichever IAM principal runs `terraform apply`
aws iam attach-role-policy \
  --role-name <bastion-role-name> \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/EKS-Terraform-Deploy-Policy
```

## What each Statement covers

| Sid | Purpose | Risk |
|---|---|---|
| **EKS** | Cluster / node group / addon / Pod Identity / Access Entry lifecycle | Medium — wildcard, but under the dedicated-account assumption the only EKS cluster in the account is the one this stack creates |
| **EC2** | VPC Endpoints, Security Groups, Launch Templates, Placement Groups, EC2 instance lifecycle | Medium — explicit action list (no wildcard) |
| **IAM** | Cluster / node / Pod Identity roles, OIDC provider, instance profiles | High sensitivity — explicit action list (no wildcard, `iam:*` is split out below) |
| **IAMPassRoleScoped** | Pass IAM roles to EKS / EC2 / Pod Identity / ALB only | Reduced — `Condition iam:PassedToService` whitelists the four downstream services this stack uses |
| **ServiceLinkedRoles** | Lazy-create SLRs on first deploy in a fresh account (EKS / EKS-NodeGroup / AutoScaling / ELB / Spot) | Reduced — `Condition iam:AWSServiceName` whitelists the five services |
| **AutoScaling** | Manage ASG behind managed node groups | Low |
| **S3** | terraform state backend; optional model bucket reads | Low — under dedicated-account assumption, bucket scope is bounded by what terraform creates. In shared accounts, scope `Resource` to specific bucket ARNs or attach a Permission Boundary |
| **DynamoDB** | terraform state lock table | Low — same dedicated-account caveat as S3 |
| **CloudWatchLogs** | EKS control plane log group + retention | Low |
| **SSMRead** | Resolve EKS optimized AMI from SSM Parameter Store | Low (read-only) |
| **KMSForEksSecretEncryption** | EKS envelope encryption — `DescribeKey` + `CreateGrant` only. `CreateGrant` is constrained by `Condition kms:GranteePrincipal` to EKS service principals so the policy holder cannot grant Decrypt to itself | Medium |

## On wildcards

A few Statements use `*`:

- **`eks:*`** — Terraform AWS provider periodically introduces new EKS API
  calls (e.g. `eks:DescribeUpdate` was added when wait-for-update logic
  was introduced). Pinning explicit actions creates upgrade churn.
- **`s3:*` / `dynamodb:*`** — These services' resources in this account
  are scoped to terraform state backend (and an optional model bucket);
  the wildcard's effective blast radius is bounded by what's actually
  present **under the dedicated-account assumption**.

The two most sensitive services — `EC2` and `IAM` — are listed
explicitly, not via wildcard, and `iam:PassRole` /
`iam:CreateServiceLinkedRole` are further constrained by Conditions.

If your security policy requires further constraint, attach a
**Permission Boundary** alongside this policy rather than enumerating
every service action — the latter creates fragility every time the
Terraform AWS provider adds a new required API.

## What this policy does NOT cover

- **`bootstrap-vpc/` stack** — creating VPC / subnet / IGW / NAT /
  EIP / route tables requires `ec2:CreateVpc`, `ec2:CreateSubnet`,
  `ec2:AllocateAddress`, `ec2:CreateNatGateway`,
  `ec2:CreateInternetGateway`, `ec2:CreateRouteTable`, etc. These
  actions are intentionally absent because `bootstrap-vpc/` is typically
  run once by the network team out of band.

- **Karpenter** (`install_karpenter = true`) — needs `sqs:*` on the
  interruption queue plus `events:*` on the EventBridge rule and target.
  Add a dedicated Statement if Karpenter is enabled.

- **Optional CSI drivers** — EFS / FSx / S3 CSI drivers each need
  per-service write permissions when terraform creates them. See the
  per-driver IAM policies under
  [`terraform/assets/iam/`](../terraform/assets/iam/) (e.g.
  `fsx-csi-policy.json`).

- **Packer custom AMI builds** — needs additional `ec2:CreateImage`,
  `ec2:DeregisterImage`, `ec2:CreateSnapshot`, `ec2:DeleteSnapshot`,
  `ec2:CreateKeyPair`, `ec2:DeleteKeyPair`. Add a separate Statement if
  operators run packer on the same role.

- **Day-2 in-cluster operations** (`kubectl`, `helm install` of
  application workloads) — governed by EKS Access Entries and
  Kubernetes RBAC, not by this IAM policy.

## Verification

This policy has been verified end-to-end against a `terraform apply` run
covering the **default-on subset** of the stack:

- `bootstrap/` (S3 + DynamoDB)
- VPC Endpoints (assumes VPC already provisioned out of band)
- EKS control plane (with KMS envelope encryption)
- System nodegroup
- Addons (CoreDNS, Metrics Server, Cluster Autoscaler, ALB Controller,
  EBS CSI)
- GPU nodegroup (with custom AMI)
- Pod Identity Associations

No `AccessDenied` errors during apply on the verified subset.

The optional modules listed under "What this policy does NOT cover"
(`bootstrap-vpc/`, Karpenter, EFS / FSx / S3 CSI, Packer) require
additional permissions beyond this policy and were not part of the
verification run.

## Known follow-up hardening

These improvements were identified during review but deferred to keep
the initial PR focused. Acknowledged for follow-up:

- **`iam:AttachRolePolicy` / `iam:DetachRolePolicy` PolicyARN whitelist**
  — currently `Resource:"*"` with no Condition. Combined with
  `iam:CreateRole`, this lets the policy holder create an arbitrary role
  and attach `AdministratorAccess` to it. Hardening requires a
  PolicyARN whitelist that covers both AWS-managed policies (the seven
  EKS-related ones plus `AmazonEC2ContainerRegistryReadOnly` /
  `AmazonSSMManagedInstanceCore` / `AmazonEBSCSIDriverPolicy`) **and**
  customer-managed policies that terraform creates on the fly (Cluster
  Autoscaler, ALB Controller, Pod Identity policies). Needs separate
  end-to-end verification before merging.

- **Cross-region EKS-NVIDIA AMI behavior** — the SSM read works in any
  region where the AMI is published, but the AMI is not in every
  region. Operators should verify availability before pinning a region.
