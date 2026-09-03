# Object storage for Thanos blocks and Loki chunks. Reached over the S3
# gateway endpoint, so none of this traffic touches the NAT instance.
resource "aws_s3_bucket" "telemetry" {
  bucket = "${local.name}-telemetry-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "telemetry" {
  bucket                  = aws_s3_bucket.telemetry.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "telemetry" {
  bucket = aws_s3_bucket.telemetry.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Raw 1s blocks dominate storage but are only kept 30 days. Downsampled
# rollups are tiny, so lifecycle rules here are about tidying incomplete
# uploads rather than saving meaningful money.
resource "aws_s3_bucket_lifecycle_configuration" "telemetry" {
  bucket = aws_s3_bucket.telemetry.id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "cheaper-storage-for-cold-blocks"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------------- iam --

resource "aws_iam_role" "observability" {
  name = "${local.name}-observability"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "observability_s3" {
  name = "telemetry-bucket"
  role = aws_iam_role.observability.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
      Resource = aws_s3_bucket.telemetry.arn
      }, {
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.telemetry.arn}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "observability" {
  name = "${local.name}-observability"
  role = aws_iam_role.observability.name
}

# ------------------------------------------------------------- instances --

locals {
  # Self-enrolment on first boot. Without this the nodes would be unreachable:
  # they have no public IP, and the VPN is the only way in.
  netbird_bootstrap = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    curl -fsSL https://pkgs.netbird.io/install.sh | sh
    netbird up --management-url %s --setup-key %s --hostname %s
  EOT
}

resource "aws_instance" "obs_write" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = "r7g.xlarge"
  subnet_id              = aws_subnet.private["private_a"].id
  key_name               = aws_key_pair.admin.key_name
  vpc_security_group_ids = [aws_security_group.observability.id]
  iam_instance_profile   = aws_iam_instance_profile.observability.name

  user_data = format(local.netbird_bootstrap, var.netbird_mgmt_url, var.netbird_key_obs_write, "obs-write")

  root_block_device {
    volume_size = 300 # WAL and pre-flush chunks; durable data lives in S3
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "${local.name}-obs-write" }
}

resource "aws_instance" "obs_read" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = "r7g.xlarge"
  subnet_id              = aws_subnet.private["private_a"].id
  key_name               = aws_key_pair.admin.key_name
  vpc_security_group_ids = [aws_security_group.observability.id]
  iam_instance_profile   = aws_iam_instance_profile.observability.name

  user_data = format(local.netbird_bootstrap, var.netbird_mgmt_url, var.netbird_key_obs_read, "obs-read")

  root_block_device {
    volume_size = 150 # caches and index headers only
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "${local.name}-obs-read" }
}
