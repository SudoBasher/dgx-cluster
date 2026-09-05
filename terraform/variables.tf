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
