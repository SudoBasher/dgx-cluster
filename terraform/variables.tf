variable "region" {
  type    = string
  default = "us-west-2"
}

variable "aws_profile" {
  type    = string
  default = "isc-eng-hpcresearch-dev"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.200.0.0/16"
  description = "Checked against existing VPCs in this account; no collision."
}

variable "az_primary" {
  type    = string
  default = "us-west-2a"
}

variable "az_secondary" {
  type        = string
  default     = "us-west-2b"
  description = "Public subnet only, held for a future second NetBird node."
}

variable "dns_zone" {
  type    = string
  default = "isc-spectro-sbx.click"
}

variable "netbird_hostname" {
  type    = string
  default = "vpn"
}

variable "netbird_key_obs_write" {
  type      = string
  sensitive = true
}

variable "netbird_key_obs_read" {
  type      = string
  sensitive = true
}

variable "netbird_mgmt_url" {
  type    = string
  default = "https://vpn.isc-spectro-sbx.click"
}

variable "bifrost_hostname" {
  type        = string
  default     = "bifrost"
  description = "Label under dns_zone for the Bifrost gateway's HTTPS name."
}

variable "bifrost_overlay_ip" {
  type        = string
  default     = "100.123.96.149"
  description = "spark1's NetBird overlay address. The record is public, but this address is only reachable over the VPN."
}
