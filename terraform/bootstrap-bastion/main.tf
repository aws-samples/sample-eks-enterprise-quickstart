# =====================================================================
# bootstrap-bastion — SSM-only bastion in a private subnet for driving
# the root EKS stack against a private API endpoint.
#
# Why a separate stack
# --------------------
# The root stack's `kubernetes` and `helm` providers must reach the EKS
# API; with cluster_mode=private that endpoint is only resolvable from
# inside the VPC. Putting the bastion in its own stack keeps it:
#   - independent of bootstrap-vpc lifecycle (can be torn down without
#     destroying the VPC),
#   - independent of the root stack lifecycle (root stack lives on the
#     bastion's terraform install — bastion outlives it during destroy),
#   - cleanly skippable for users who already have a bastion / VPN.
#
# Run order:
#   1. terraform -chdir=bootstrap-vpc apply
#   2. terraform -chdir=bootstrap-bastion apply \
#        -var "vpc_id=$(terraform -chdir=bootstrap-vpc output -raw vpc_id)" \
#        -var "subnet_id=$(terraform -chdir=bootstrap-vpc output -json private_subnet_ids | jq -r '.[0]')"
#   3. aws ssm start-session --target <bastion_instance_id>
#      then on the bastion: clone repo, run terraform on the root stack.
# =====================================================================

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.9.0, < 7.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Name       = var.name
      managed-by = "terraform"
      stack      = "bootstrap-bastion"
    }
  }
}

# =====================================================================
# Inputs
# =====================================================================

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "name" {
  type        = string
  description = "Resource name prefix; should match bootstrap-vpc's var.name."
  default     = "eks-tf-smoke"
}

variable "vpc_id" {
  type        = string
  description = "VPC to launch the bastion into. Output of bootstrap-vpc."
}

variable "subnet_id" {
  type        = string
  description = "Private subnet to launch the bastion into. Pick the AZ where the GPU NG will land — keeps SSM round-trips short."
}

variable "instance_type" {
  type        = string
  description = "Bastion instance type. ARM64 chosen — matches AL2023 arm64 AMI and is cheaper for control-plane workloads (terraform/kubectl)."
  default     = "t4g.small"
}

variable "k8s_version" {
  type        = string
  description = "Cluster minor version; pinned in user_data so kubectl matches."
  default     = "1.35"
}

variable "kubectl_patch_fallback" {
  type        = string
  description = "If dl.k8s.io/release/stable-{minor}.txt is unreachable, fall back to v{minor}.0."
  default     = "0"
}

variable "terraform_version" {
  type        = string
  description = "Pinned terraform version baked into the bastion. Match the dev-host version (1.14.x) to avoid plan drift."
  default     = "1.14.9"
}

variable "helm_version" {
  type    = string
  default = "v3.17.3"
}

# =====================================================================
# AMI — AL2023 ARM64 (matches t4g.* family)
# =====================================================================

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# =====================================================================
# IAM
# =====================================================================
# Test-scope decision: AdministratorAccess on the bastion role.
# Rationale: this stack is for end-to-end smoke runs that exercise the
# full deploy script, which touches EKS / EC2 / IAM / EBS / FSx / etc.
# Scoping a least-privilege policy here would duplicate work the bash
# script already does at L137-L383 of option_create_bastion.sh and adds
# no real safety on a throwaway test account. For production deploys
# that need a long-lived bastion, swap AdministratorAccess for the
# narrower EKS-Bastion-Deploy-Policy.

resource "aws_iam_role" "bastion" {
  name = "${var.name}-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "bastion_admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.name}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# =====================================================================
# Security group — egress only
# =====================================================================
# No ingress: SSM Session Manager goes via the SSM endpoint, not via
# inbound TCP. Egress-all so the bastion can reach SSM endpoints, NAT
# (for github.com / dl.k8s.io / hashicorp.com), and once the EKS
# cluster exists, its private API endpoint.

resource "aws_security_group" "bastion" {
  name        = "${var.name}-bastion-sg"
  description = "Bastion: egress only; SSM via VPC interface endpoints / NAT"
  vpc_id      = var.vpc_id

  egress {
    description = "all egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =====================================================================
# user_data — install deploy tools at boot
# =====================================================================
# Mirrors what option_create_bastion.sh runs via SSM send-command but
# inline at boot — by the time SSM Session Manager comes online, tools
# are already in /usr/local/bin. Using cloud-init's MIME multipart so
# we can keep #!/bin/bash and structured logging.

locals {
  user_data = <<-USERDATA
    #!/bin/bash
    set -euxo pipefail
    exec > >(tee -a /var/log/bastion-bootstrap.log) 2>&1

    echo "==> wait for background dnf-makecache to release the rpm lock"
    # AL2023's package-cleanup / dnf-makecache fires at boot and competes with
    # us for /var/lib/rpm/.rpm.lock — first dnf install hits "Key import failed"
    # if it loses the race. Don't use `cloud-init status --wait` here: this
    # script IS being run by cloud-init's final stage, so waiting on it
    # deadlocks (the process waits on its own parent).
    for i in {1..60}; do
      if ! pgrep -x dnf >/dev/null && ! fuser /var/lib/rpm/.rpm.lock >/dev/null 2>&1; then
        echo "rpm lock free after $i checks"
        break
      fi
      echo "rpm lock busy, waiting (attempt $i)..."
      sleep 5
    done

    # dnf wrapper with retry on transient lock / network errors
    dnf_install() {
      for attempt in 1 2 3 4 5; do
        if dnf install -y "$@"; then return 0; fi
        echo "dnf install failed (attempt $attempt), retrying in 10s..."
        sleep 10
      done
      return 1
    }

    echo "==> base tools"
    dnf_install git jq gettext unzip tar gzip yum-utils

    echo "==> Terraform ${var.terraform_version}"
    yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
    dnf_install terraform-${var.terraform_version}-1

    echo "==> kubectl (Kubernetes ${var.k8s_version} stable)"
    KUBECTL_VERSION=$(curl -fsSL --max-time 10 \
        "https://dl.k8s.io/release/stable-${var.k8s_version}.txt" \
        || echo "v${var.k8s_version}.${var.kubectl_patch_fallback}")
    curl -fsSL -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/arm64/kubectl"
    curl -fsSL -o /tmp/kubectl.sha256 \
        "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/arm64/kubectl.sha256"
    echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum --check
    chmod 0755 /usr/local/bin/kubectl

    echo "==> helm ${var.helm_version}"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/refs/tags/${var.helm_version}/scripts/get-helm-3 \
        -o /tmp/get-helm-3
    chmod +x /tmp/get-helm-3
    DESIRED_VERSION=${var.helm_version} /tmp/get-helm-3
    rm -f /tmp/get-helm-3

    echo "==> aws cli v2 (AL2023 ships v2 already, but pin ARM64 release)"
    if ! command -v aws >/dev/null; then
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
      unzip -q /tmp/awscliv2.zip -d /tmp
      /tmp/aws/install
      rm -rf /tmp/awscliv2.zip /tmp/aws
    fi

    echo "==> versions"
    terraform version
    kubectl version --client
    helm version --short
    aws --version
    git --version
    jq --version
    echo "==> bootstrap done"
  USERDATA
}

# =====================================================================
# EC2 instance
# =====================================================================

resource "aws_instance" "bastion" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  user_data                   = local.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "${var.name}-bastion"
    Purpose = "EKS-Deployment"
  }

  lifecycle {
    ignore_changes = [
      ami, # Avoid accidental replace on AL2023 SSM param updates
    ]
  }
}

# =====================================================================
# Outputs
# =====================================================================

output "bastion_instance_id" {
  value = aws_instance.bastion.id
}

output "bastion_role_arn" {
  description = "Use this ARN for `aws eks create-access-entry --principal-arn` so the bastion can talk to the API."
  value       = aws_iam_role.bastion.arn
}

output "bastion_role_name" {
  value = aws_iam_role.bastion.name
}

output "bastion_security_group_id" {
  value = aws_security_group.bastion.id
}

output "bastion_private_ip" {
  value = aws_instance.bastion.private_ip
}

output "ssm_start_command" {
  description = "Convenience: connect to the bastion via SSM Session Manager."
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}"
}
