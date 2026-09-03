locals {
  name = "dgx-cluster"

  # /24s inside 10.200.0.0/16. Public in two AZs so a second NetBird node can
  # be added later without renumbering; private in one AZ only, because the
  # two observability nodes must share an AZ to avoid cross-AZ transfer
  # charges on the traffic between them.
  subnets = {
    public_a  = { cidr = "10.200.0.0/24", az = var.az_primary }
    public_b  = { cidr = "10.200.1.0/24", az = var.az_secondary }
    private_a = { cidr = "10.200.10.0/24", az = var.az_primary }
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  for_each = { for k, v in local.subnets : k => v if startswith(k, "public") }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name}-${replace(each.key, "_", "-")}" }
}

resource "aws_subnet" "private" {
  for_each = { for k, v in local.subnets : k => v if startswith(k, "private") }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags              = { Name = "${local.name}-${replace(each.key, "_", "-")}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private egress goes through the netbird-cp instance acting as a NAT router.
# The default route is added in netbird.tf once that ENI exists, so this table
# is created empty here.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# Required, not optional. Thanos and Loki write blocks and fetch chunks
# constantly; without this endpoint every byte would traverse the NAT
# instance. The endpoint is free and keeps S3 off that path entirely.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]
  tags              = { Name = "${local.name}-s3" }
}
