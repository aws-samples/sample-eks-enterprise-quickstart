# =====================================================================
# One-time bootstrap of the S3 backend bucket and DynamoDB lock table.
#
# Run this stack with local state ONCE per AWS account / region pair,
# then point the root stack's backend.tf at the resources it creates.
#
# S3 bucket names are global, so suffix with the account ID to avoid
# collisions (the literal "my-eks-tfstate" is almost certainly taken).
#
# Usage:
#   cd terraform/bootstrap
#   terraform init
#   ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
#   terraform apply \
#     -var="bucket_name=eks-tfstate-${ACCOUNT_ID}-us-west-2" \
#     -var="region=us-west-2"
#
# After apply, init the root stack:
#   cd ../
#   mv backend.tf.disabled backend.tf
#   terraform init \
#     -backend-config="bucket=eks-tfstate-${ACCOUNT_ID}-us-west-2" \
#     -backend-config="key=eks-cluster-deployment/<env>/terraform.tfstate" \
#     -backend-config="region=us-west-2" \
#     -backend-config="dynamodb_table=eks-tfstate-${ACCOUNT_ID}-us-west-2-lock"
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
}

variable "bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket name for Terraform state."
}

variable "region" {
  type = string
}

variable "lock_table_name" {
  type    = string
  default = ""
}

locals {
  table_name = var.lock_table_name != "" ? var.lock_table_name : "${var.bucket_name}-lock"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}

output "backend_config" {
  value = <<-EOT
    -backend-config="bucket=${aws_s3_bucket.tfstate.bucket}"
    -backend-config="region=${var.region}"
    -backend-config="dynamodb_table=${aws_dynamodb_table.lock.name}"
  EOT
}
