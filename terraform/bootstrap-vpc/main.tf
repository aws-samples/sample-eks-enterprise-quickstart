# =====================================================================
# bootstrap-vpc — minimal 3-AZ VPC for testing the EKS stack.
#
# Topology (10.0.0.0/16):
#   3 public  subnets (10.0.0.0/20,  10.0.16.0/20, 10.0.32.0/20) — IGW
#   3 private subnets (10.0.48.0/20, 10.0.64.0/20, 10.0.80.0/20) — NAT
#   1 IGW + 3 NAT GW (one per AZ for HA, eats ~$96/month — destroy when done)
#   1 public route table + 3 private route tables (per-AZ NAT routing)
#
# Tags follow EKS-discovery conventions:
#   public  subnets: kubernetes.io/role/elb=1
#   private subnets: kubernetes.io/role/internal-elb=1
#
# Run separately from the main stack:
#   cd terraform/bootstrap-vpc
#   AWS_PROFILE=temp terraform init
#   AWS_PROFILE=temp terraform apply
#
# Outputs feed straight into terraform.tfvars for the main stack.
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
      stack      = "bootstrap-vpc"
    }
  }
}

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "name" {
  type    = string
  default = "eks-test"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# Pick 3 AZs from the region. Default to the first 3 returned by AWS.
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  public_cidrs  = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
  private_cidrs = ["10.0.48.0/20", "10.0.64.0/20", "10.0.80.0/20"]
}

# =====================================================================
# VPC + IGW
# =====================================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${var.name}-igw"
  }
}

# =====================================================================
# Public subnets + single shared route table
# =====================================================================
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
    tier                     = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${var.name}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# =====================================================================
# NAT gateways (one per AZ for HA)
# =====================================================================
resource "aws_eip" "nat" {
  count  = 3
  domain = "vpc"

  tags = {
    Name = "${var.name}-nat-eip-${local.azs[count.index]}"
  }
}

resource "aws_nat_gateway" "main" {
  count         = 3
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.name}-nat-${local.azs[count.index]}"
  }

  depends_on = [aws_internet_gateway.main]
}

# =====================================================================
# Private subnets + per-AZ route tables (each routed to local NAT)
# =====================================================================
resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                              = "${var.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
    tier                              = "private"
  }
}

resource "aws_route_table" "private" {
  count  = 3
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${var.name}-private-rt-${local.azs[count.index]}"
  }
}

resource "aws_route" "private_nat" {
  count                  = 3
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# =====================================================================
# Outputs — copy into terraform.tfvars of the main stack
# =====================================================================
output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "azs" {
  value = local.azs
}

output "tfvars_snippet" {
  description = "Paste-ready snippet for the main stack's terraform.tfvars"
  value       = <<-EOT
    vpc_id = "${aws_vpc.main.id}"

    private_subnet_ids = [
      ${join(",\n      ", [for s in aws_subnet.private : "\"${s.id}\""])},
    ]

    public_subnet_ids = [
      ${join(",\n      ", [for s in aws_subnet.public : "\"${s.id}\""])},
    ]
  EOT
}
