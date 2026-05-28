# Note: enabling DNS support / hostnames on an *existing* VPC must be done
# via aws_vpc_dhcp_options or `aws ec2 modify-vpc-attribute` outside Terraform
# if the VPC was not created by this stack. The aws_vpc resource does not
# manage attributes of imported VPCs unless you import it. We expose a
# null_resource trip-wire here that fails apply if the VPC has DNS turned
# off, prompting the operator to flip it once.

data "aws_vpc" "main" {
  id = var.vpc_id
}

resource "null_resource" "verify_vpc_dns" {
  triggers = {
    vpc_id = var.vpc_id
  }
  lifecycle {
    precondition {
      condition     = data.aws_vpc.main.enable_dns_support && data.aws_vpc.main.enable_dns_hostnames
      error_message = "VPC ${var.vpc_id} must have enableDnsSupport AND enableDnsHostnames = true. Run: aws ec2 modify-vpc-attribute --vpc-id ${var.vpc_id} --enable-dns-support && aws ec2 modify-vpc-attribute --vpc-id ${var.vpc_id} --enable-dns-hostnames"
    }
  }
}

# Validate that each private subnet sits in a distinct AZ. VPC Interface
# Endpoints reject duplicate AZs with `DuplicateSubnetsInSameZone`, but
# they only surface this error during create — and they do it once per
# endpoint, so a single misconfigured tfvars produces 13 near-identical
# errors that obscure the root cause. Failing fast at plan time with the
# subnet → AZ mapping makes the fix obvious.
data "aws_subnet" "private" {
  for_each = toset(var.private_subnet_ids)
  id       = each.key
}

resource "null_resource" "verify_subnet_az_uniqueness" {
  triggers = {
    subnets = join(",", var.private_subnet_ids)
  }
  lifecycle {
    precondition {
      condition = length(distinct([
        for s in data.aws_subnet.private : s.availability_zone
      ])) == length(var.private_subnet_ids)
      error_message = "private_subnet_ids must each be in a DIFFERENT availability zone — VPC Interface Endpoints reject duplicate AZs (DuplicateSubnetsInSameZone). For environments with extra subnets in the same AZ (e.g. a dedicated GPU subnet), pass them via gpu_nodegroups[].subnet_ids instead. Subnet → AZ mapping: ${jsonencode({ for s in data.aws_subnet.private : s.id => s.availability_zone })}"
    }
  }
}

# Security group for Interface endpoints — allows 443 from inside the VPC.
resource "aws_security_group" "endpoints" {
  name        = "${var.cluster_name}-vpc-endpoints-sg"
  description = "Security group for VPC Interface endpoints"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.cluster_name}-vpc-endpoints-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS from VPC"
}

resource "aws_vpc_security_group_egress_rule" "endpoints_all" {
  security_group_id = aws_security_group.endpoints.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all egress"
}

# ---------------------------------------------------------------------
# Endpoint sets
#
# Required (always created): eks, eks-auth, sts, ec2 — node registration
#   and Pod Identity have no public-NAT fallback.
# Full-only: ecr.api/dkr, logs, autoscaling, elasticloadbalancing,
#   elasticfilesystem, ssm/ssmmessages/ec2messages — all have NAT fallback.
# ---------------------------------------------------------------------
locals {
  required_services = ["eks", "eks-auth", "sts", "ec2"]
  full_only_services = [
    "ecr.api",
    "ecr.dkr",
    "logs",
    "autoscaling",
    "elasticloadbalancing",
    "elasticfilesystem",
    "ssm",
    "ssmmessages",
    "ec2messages",
  ]

  interface_services = var.endpoints_mode == "full" ? concat(local.required_services, local.full_only_services) : local.required_services
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_services)

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.cluster_name}-${each.key}-endpoint"
  }

  depends_on = [null_resource.verify_vpc_dns]
}

# Look up route tables associated with the private subnets for the S3 Gateway.
data "aws_route_tables" "private" {
  vpc_id = var.vpc_id
  filter {
    name   = "association.subnet-id"
    values = var.private_subnet_ids
  }
}

resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.private.ids

  tags = {
    Name = "${var.cluster_name}-s3-gateway-endpoint"
  }
}
