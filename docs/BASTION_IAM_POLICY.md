# Bastion IAM Policy for Terraform Deploys

This document explains the IAM permissions required to run `terraform
apply` against this stack from a bastion host (or any other deployment
runner).

## File location

[`terraform/assets/iam/bastion-policy.json`](../terraform/assets/iam/bastion-policy.json)

## Apply

```bash
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
| **EKS** | Cluster / node group / addon / Pod Identity / Access Entry lifecycle | Medium — wildcard, but EKS resources are scoped to this account, and clusters have RBAC as a second layer |
| **EC2** | VPC Endpoints, Security Groups, Launch Templates, Placement Groups, EC2 instance lifecycle | Medium — explicit action list (no wildcard) |
| **IAM** | Cluster / node / Pod Identity roles, OIDC provider | High sensitivity — explicit action list |
| **AutoScaling** | Manage ASG behind managed node groups | Low |
| **S3** | terraform state backend; optional model bucket reads | Low — bucket scope is bounded by what terraform creates |
| **DynamoDB** | terraform state lock table | Low |
| **CloudWatchLogs** | EKS control plane log group + retention | Low |
| **SSMRead** | Resolve EKS optimized AMI from SSM Parameter Store | Low (read-only) |
| **KMSForEksSecretEncryption** | EKS envelope encryption — `DescribeKey` + `CreateGrant` only; deliberately no `Encrypt`/`Decrypt` so the policy holder cannot read encrypted secrets | Medium |
| **STSAndCallerIdentity** | Identity check at terraform startup | Trivial |

## On wildcards

A few Statements use `*`:

- **`eks:*`** — Terraform AWS provider periodically introduces new EKS API
  calls (e.g. `eks:DescribeUpdate` was added when wait-for-update logic
  was introduced). Pinning explicit actions creates upgrade churn.
- **`s3:*` / `dynamodb:*`** — These services' resources in this account
  are scoped to terraform state backend (and an optional model bucket);
  the wildcard's effective blast radius is bounded by what's actually
  present.

The two most sensitive services — `EC2` and `IAM` — are listed
explicitly, not via wildcard.

If your security policy requires further constraint, attach a
**Permission Boundary** alongside this policy rather than enumerating
every service action — the latter creates fragility every time the
Terraform AWS provider adds a new required API.

## What this policy does NOT cover

- **Packer custom AMI builds** — needs additional `ec2:CreateImage`,
  `ec2:DeregisterImage`, `ec2:CreateSnapshot`, `ec2:DeleteSnapshot`,
  `ec2:CreateKeyPair`, `ec2:DeleteKeyPair`. Add a separate Statement if
  operators run packer on the same role.
- **Day-2 in-cluster operations** (`kubectl`, `helm install` of
  application workloads) — those are governed by EKS Access Entries and
  Kubernetes RBAC, not by this IAM policy.

## Verification

This policy has been verified end-to-end against a full `terraform apply`
run, covering:

- `bootstrap` (S3 + DynamoDB)
- VPC Endpoints
- EKS control plane (with KMS envelope encryption)
- System nodegroup
- Addons (CoreDNS, Metrics Server, Cluster Autoscaler, ALB Controller,
  EBS CSI)
- GPU nodegroup (with custom AMI)
- Pod Identity Associations

No `AccessDenied` errors during apply.
