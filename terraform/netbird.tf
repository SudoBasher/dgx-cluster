# Ubuntu 24.04 ARM64. Canonical's owner id is 099720109477.
data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
}

resource "aws_instance" "netbird" {
  ami           = data.aws_ami.ubuntu_arm64.id
  instance_type = "m7g.large"
  subnet_id     = aws_subnet.public["public_a"].id
  key_name      = aws_key_pair.admin.key_name

  vpc_security_group_ids = [aws_security_group.netbird.id]

  # Mandatory for a NAT router: without this, EC2 drops packets whose source
  # or destination is not this instance.
  source_dest_check = false

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  tags = { Name = "${local.name}-netbird-cp" }
}

resource "aws_eip" "netbird" {
  instance = aws_instance.netbird.id
  domain   = "vpc"
  tags     = { Name = "${local.name}-netbird-cp" }
}

# Private subnet egress. Points at the ENI rather than the instance id so the
# route survives an instance replacement that keeps the interface.
resource "aws_route" "private_egress" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

data "aws_route53_zone" "main" {
  name         = "${var.dns_zone}."
  private_zone = false
}

resource "aws_route53_record" "netbird" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.netbird_hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.netbird.public_ip]
}
