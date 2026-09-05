variable "admin_cidrs" {
  type        = list(string)
  default     = ["98.248.204.107/32"]
  description = <<-EOT
    Sources allowed to SSH in before the VPN exists. A home or office address
    is likely dynamic; if SSH starts timing out, this is the first thing to
    check. Once NetBird is running this can be narrowed to nothing, because
    administration moves onto the overlay.
  EOT
}

resource "aws_key_pair" "admin" {
  key_name   = "${local.name}-admin"
  public_key = file("${path.module}/../.ssh/aws_dgx.pub")
}

# ---------------------------------------------------------------- netbird --

resource "aws_security_group" "netbird" {
  name        = "${local.name}-netbird"
  description = "NetBird control plane, relay, and NAT router"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-netbird" }
}

resource "aws_vpc_security_group_ingress_rule" "netbird_ssh" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.netbird.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  description       = "Bootstrap SSH; superseded by the VPN"
}

# HTTP is needed for the Let's Encrypt HTTP-01 challenge, not for the app.
resource "aws_vpc_security_group_ingress_rule" "netbird_http" {
  security_group_id = aws_security_group.netbird.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "ACME HTTP-01"
}

resource "aws_vpc_security_group_ingress_rule" "netbird_https" {
  security_group_id = aws_security_group.netbird.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Dashboard, management API, signal"
}

# WireGuard data plane for peers that reach the control plane directly.
resource "aws_vpc_security_group_ingress_rule" "netbird_wireguard" {
  security_group_id = aws_security_group.netbird.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 51820
  to_port           = 51820
  description       = "WireGuard"
}

resource "aws_vpc_security_group_ingress_rule" "netbird_stun" {
  security_group_id = aws_security_group.netbird.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 3478
  to_port           = 3478
  description       = "STUN/TURN control"
}

resource "aws_vpc_security_group_ingress_rule" "netbird_turn_relay" {
  security_group_id = aws_security_group.netbird.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 49152
  to_port           = 65535
  description       = "coturn relay port range"
}

# Everything from the private subnet, because this instance is its NAT router.
resource "aws_vpc_security_group_ingress_rule" "netbird_from_private" {
  security_group_id = aws_security_group.netbird.id
  cidr_ipv4         = local.subnets.private_a.cidr
  ip_protocol       = "-1"
  description       = "NAT for the private subnet"
}

resource "aws_vpc_security_group_egress_rule" "netbird_all" {
  security_group_id = aws_security_group.netbird.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------- observability --
# No internet-facing ingress at all. Access arrives over the NetBird overlay,
# which is WireGuard inside UDP and so is not expressible as a security-group
# rule. Only in-VPC traffic needs allowing here.

resource "aws_security_group" "observability" {
  name        = "${local.name}-observability"
  description = "Thanos, Loki, Grafana. Reachable over the VPN only."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-observability" }
}

resource "aws_vpc_security_group_ingress_rule" "obs_from_vpc" {
  security_group_id = aws_security_group.observability.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
  description       = "In-VPC, including WireGuard from netbird-cp"
}

resource "aws_vpc_security_group_egress_rule" "obs_all" {
  security_group_id = aws_security_group.observability.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# The observability nodes now sit in a public subnet so WireGuard hole punching
# can work. This is the only inbound rule they get: everything else, including
# SSH and Grafana, remains reachable only over the VPN overlay.
resource "aws_vpc_security_group_ingress_rule" "obs_wireguard" {
  security_group_id = aws_security_group.observability.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 51820
  to_port           = 51820
  description       = "WireGuard; required for P2P instead of relay"
}
