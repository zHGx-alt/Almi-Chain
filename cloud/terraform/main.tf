# Web hosting on AWS: private S3 bucket with the site, EC2 with nginx and Let's Encrypt.

locals {
  web_dir = "${path.module}/../../also-built/web"
  # What gets published: all of the web folder except its notes
  web_files = setsubtract(fileset(local.web_dir, "**"), ["README.md", ".gitkeep"])
  content_types = {
    html = "text/html; charset=utf-8"
    css  = "text/css; charset=utf-8"
    js   = "application/javascript; charset=utf-8"
    svg  = "image/svg+xml"
    png  = "image/png"
    jpg  = "image/jpeg"
    webp = "image/webp"
    ico  = "image/x-icon"
    txt  = "text/plain; charset=utf-8"
  }
}

# ---- Private S3 bucket -------------------------------------------------------------
# The bucket is created once with the AWS CLI and read here: AWS Learner Lab forbids
# s3:GetBucketObjectLockConfiguration, which the aws_s3_bucket resource always calls, so apply fails.
# Its configuration (public access, ACLs, encryption) and the files are still managed by Terraform.
data "aws_s3_bucket" "web" {
  bucket = var.bucket
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = data.aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "web" {
  bucket = data.aws_s3_bucket.web.id
  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs disabled
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  bucket = data.aws_s3_bucket.web.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# First upload of the content. Later changes are published by GitHub Actions (deploy-aws.yml).
resource "aws_s3_object" "web" {
  for_each     = local.web_files
  bucket       = data.aws_s3_bucket.web.id
  key          = each.value
  source       = "${local.web_dir}/${each.value}"
  etag         = filemd5("${local.web_dir}/${each.value}")
  content_type = lookup(local.content_types, lower(element(split(".", each.value), length(split(".", each.value)) - 1)), "application/octet-stream")
}

# ---- Security group -----------------------------------------------------------------
resource "aws_security_group" "web" {
  name        = "web-almichain-sg"
  description = "Almi-Chain web: HTTP, HTTPS and SSH"

  ingress {
    description = "HTTP (redirect to HTTPS and Lets Encrypt validation)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH from our IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }
  egress {
    description = "Outbound (packages, S3 and Lets Encrypt)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---- EC2 instance with Ubuntu 24.04 ---------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# Elastic IP, created before the instance so it can be passed to user_data
resource "aws_eip" "web" {
  domain = "vpc"
  tags   = { Name = "web-almichain" }
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  iam_instance_profile   = var.instance_profile
  vpc_security_group_ids = [aws_security_group.web.id]

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  # Waits for the elastic IP, updates DuckDNS (if a token is given) and runs the web server installer
  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    elastic_ip    = aws_eip.web.public_ip
    domain        = var.domain
    duckdns_token = var.duckdns_token
    bucket        = data.aws_s3_bucket.web.id
    region        = var.region
    email         = var.email
    script        = file("${path.module}/../install-web-server.sh")
  })
  user_data_replace_on_change = true

  tags = { Name = "web-almichain" }

  depends_on = [aws_s3_object.web]
}

resource "aws_eip_association" "web" {
  instance_id   = aws_instance.web.id
  allocation_id = aws_eip.web.id
}
