## Bifrost HTTPS name
# A public record that points at spark1's NetBird overlay address, so the name
# only works for machines on the VPN. HTTPS needs a real name: Google refuses
# OAuth redirect URIs on plain HTTP or a bare IP, and the certificate below
# is issued for this name.
resource "aws_route53_record" "bifrost" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.bifrost_hostname
  type    = "A"
  ttl     = 300
  records = [var.bifrost_overlay_ip]
}

## Certificate renewal credential
# certbot on spark1 proves control of the name with a DNS-01 challenge: it
# writes a TXT record at _acme-challenge.<name>. This user may change only
# that one TXT record, so a leaked key can't touch anything else in the zone.
# The access key is created outside Terraform (RUNBOOK section 26) so the
# secret never lands in the state file.
resource "aws_iam_user" "bifrost_acme" {
  name = "${local.name}-bifrost-acme"
  tags = { Purpose = "certbot DNS-01 for ${local.bifrost_fqdn}" }
}

resource "aws_iam_user_policy" "bifrost_acme" {
  name = "route53-acme-challenge"
  user = aws_iam_user.bifrost_acme.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # certbot-dns-route53 looks the zone up by name and polls the change.
      {
        Sid      = "FindZoneAndPollChange"
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:GetChange"]
        Resource = "*"
      },
      {
        Sid      = "WriteOnlyTheChallengeRecord"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = data.aws_route53_zone.main.arn
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = ["_acme-challenge.${local.bifrost_fqdn}"]
            "route53:ChangeResourceRecordSetsRecordTypes"           = ["TXT"]
          }
        }
      }
    ]
  })
}

locals {
  bifrost_fqdn = "${var.bifrost_hostname}.${var.dns_zone}"
}
