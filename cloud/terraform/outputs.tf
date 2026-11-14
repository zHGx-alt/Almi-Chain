output "elastic_ip" {
  description = "Fixed public IP of the site (DuckDNS A record)"
  value       = aws_eip.web.public_ip
}

output "url" {
  description = "Site address"
  value       = "https://${var.domain}"
}

output "ssh" {
  description = "How to log in to the instance"
  value       = "ssh -i labsuser.pem ubuntu@${aws_eip.web.public_ip}"
}

output "bucket" {
  description = "Private bucket with the site (used by deploy-aws.yml)"
  value       = data.aws_s3_bucket.web.id
}
