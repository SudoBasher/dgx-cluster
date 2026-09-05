terraform {
  # Pinned deliberately. tenv reads this constraint and selects the matching
  # binary, so anyone cloning the repo gets the same OpenTofu without a
  # version file.
  required_version = "~> 1.12.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.62"
    }
  }

  backend "s3" {
    bucket  = "dgx-cluster-tofu-state-376129860391"
    key     = "main/terraform.tfstate"
    region  = "us-west-2"
    profile = "isc-eng-hpcresearch-dev"
    encrypt = true
    # S3 conditional-write locking. Avoids a DynamoDB lock table entirely.
    use_lockfile = true
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
