terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Credentials do NOT go here: they come from the environment (~/.aws/credentials or AWS_*
# variables), copied from AWS Learner Lab's "AWS Details -> AWS CLI". They expire with the lab session.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "Almi-Chain"
      ManagedBy = "terraform"
    }
  }
}
