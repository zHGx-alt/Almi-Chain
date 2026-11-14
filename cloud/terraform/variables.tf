variable "region" {
  description = "AWS region (AWS Learner Lab only allows us-east-1 and us-west-2)"
  type        = string
  default     = "us-east-1"
}

variable "bucket" {
  description = "Name of the private S3 bucket holding the site (unique across AWS)"
  type        = string
  default     = "almi-chain-web-2026"
}

variable "domain" {
  description = "Site domain (DuckDNS A record pointing to the elastic IP)"
  type        = string
  default     = "almichain1.duckdns.org"
}

variable "email" {
  description = "Email for Let's Encrypt notices"
  type        = string
}

variable "ssh_cidr" {
  description = "The only network allowed to SSH in (our public IP with /32)"
  type        = string

  validation {
    condition     = can(cidrnetmask(var.ssh_cidr)) && var.ssh_cidr != "0.0.0.0/0"
    error_message = "ssh_cidr must be a specific network (for example 81.0.0.1/32), never 0.0.0.0/0."
  }
}

variable "duckdns_token" {
  description = "DuckDNS token to point the domain at the elastic IP. Empty = update it by hand"
  type        = string
  default     = ""
  sensitive   = true
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "ssh_key_name" {
  description = "EC2 key pair (on AWS Learner Lab, vockey)"
  type        = string
  default     = "vockey"
}

variable "instance_profile" {
  description = "Instance IAM profile (AWS Learner Lab does not allow creating roles: LabInstanceProfile)"
  type        = string
  default     = "LabInstanceProfile"
}
