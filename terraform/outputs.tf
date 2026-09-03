output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnet_ids" {
  value = {
    public  = { for k, v in aws_subnet.public : k => v.id }
    private = { for k, v in aws_subnet.private : k => v.id }
  }
}

output "netbird_public_ip" {
  value = aws_eip.netbird.public_ip
}

output "netbird_fqdn" {
  value = aws_route53_record.netbird.fqdn
}

output "ssh_netbird" {
  value = "ssh -i .ssh/aws_dgx ubuntu@${aws_eip.netbird.public_ip}"
}

output "telemetry_bucket" {
  value = aws_s3_bucket.telemetry.id
}

output "obs_private_ips" {
  value = {
    write = aws_instance.obs_write.private_ip
    read  = aws_instance.obs_read.private_ip
  }
}
