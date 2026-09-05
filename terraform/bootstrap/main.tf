# State bucket for the main stack. Runs once with local state, because the
# backend cannot exist before it is created.
#
#   cd terraform/bootstrap
#   tofu init && tofu apply

terraform {
  required_version = "~> 1.12.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      createdBy = "tommy.aldo.sonin"
      project   = "dgx-cluster"
      managedBy = "opentofu"
    }
  }
}

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "aws_profile" {
  type    = string
  default = "isc-eng-hpcresearch-dev"
}

data "aws_caller_identity" "current" {}

locals {
  # Account id keeps the name globally unique without a random suffix, so the
  # bucket is reproducible if this ever needs rebuilding.
  bucket_name = "dgx-cluster-tofu-state-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

# Versioning is the recovery path for a corrupted or truncated state file.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}
