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

# ---------------------------------------------------------------------
# Endpoint sets + brownfield discovery
#
# Required (always wanted): eks, eks-auth, sts, ec2 — node registration
#   and Pod Identity have no public-NAT fallback.
# Full-only: ecr.api/dkr, logs, autoscaling, elasticloadbalancing,
#   elasticfilesystem, ssm/ssmmessages/ec2messages — all have NAT fallback.
#
# Brownfield: many customers run this module against a pre-existing VPC
# that already has a partial set of Interface / Gateway endpoints (e.g.
# created by the network team, or carried over from a previous stack).
# Re-creating an endpoint that already exists with private_dns_enabled =
# true fails with "Could not enable PrivateDNS, the VPC already has an
# endpoint with the same DNS name". We discover existing endpoints up
# front and skip-if-present.
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

  interface_services_wanted = toset(var.endpoints_mode == "full" ? concat(local.required_services, local.full_only_services) : local.required_services)

  endpoint_prefix = "com.amazonaws.${var.region}."
}

# ---------------------------------------------------------------------
# Brownfield discovery — does this VPC already have an endpoint for
# each service we want?
#
# We use an external data source (`aws ec2 describe-vpc-endpoints`) once
# for the whole VPC because:
#   - data.aws_vpc_endpoint (singular) requires a filter that uniquely
#     identifies one endpoint and throws if it matches zero or many,
#     making it unsuitable for "is it there?" checks across many services.
#   - the AWS Terraform provider does not expose a plural data source
#     (aws_vpc_endpoints does not exist).
# Output JSON is parsed into local.existing_* sets used to gate creation.
# ---------------------------------------------------------------------
data "external" "existing_endpoints" {
  program = ["bash", "${path.module}/scripts/list-vpc-endpoints.sh", var.vpc_id, var.region]
}

locals {
  # Comma-separated service shortnames of Interface endpoints already in
  # available/pendingAcceptance state, e.g. "eks,sts,ec2".
  _existing_interface_services_csv = data.external.existing_endpoints.result["interface_services"]
  _existing_s3_gateway_present_str = data.external.existing_endpoints.result["s3_gateway_present"]

  existing_interface_services = local._existing_interface_services_csv == "" ? toset([]) : toset(split(",", local._existing_interface_services_csv))
  s3_gateway_exists           = local._existing_s3_gateway_present_str == "true"

  # Set we still need to create.
  interface_services_to_create = setsubtract(local.interface_services_wanted, local.existing_interface_services)

  # Set we're skipping because the VPC already has them. Surfaced as an
  # output so operators can audit at apply time.
  interface_services_skipped = setintersection(local.interface_services_wanted, local.existing_interface_services)

  s3_service_name = "com.amazonaws.${var.region}.s3"

  # Whether we'll create at least one endpoint of our own. When false,
  # we don't create the endpoint SG either (avoids an orphan SG).
  any_interface_endpoint_to_create = length(local.interface_services_to_create) > 0
}

# Security group for Interface endpoints — only created when we're
# actually creating at least one Interface endpoint of our own (otherwise
# we'd leave an orphan SG behind). Existing endpoints keep whatever SG
# they were originally created with.
resource "aws_security_group" "endpoints" {
  count = local.any_interface_endpoint_to_create ? 1 : 0

  name        = "${var.cluster_name}-vpc-endpoints-sg"
  description = "Security group for VPC Interface endpoints"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.cluster_name}-vpc-endpoints-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count = local.any_interface_endpoint_to_create ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS from VPC"
}

resource "aws_vpc_security_group_egress_rule" "endpoints_all" {
  count = local.any_interface_endpoint_to_create ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all egress"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_services_to_create

  vpc_id              = var.vpc_id
  service_name        = "${local.endpoint_prefix}${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]
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
  count = local.s3_gateway_exists ? 0 : 1

  vpc_id            = var.vpc_id
  service_name      = local.s3_service_name
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.private.ids

  tags = {
    Name = "${var.cluster_name}-s3-gateway-endpoint"
  }
}
