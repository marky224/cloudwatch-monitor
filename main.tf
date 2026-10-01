# ──────────────────────────────────────────────────────────────
# main.tf — Terraform & AWS provider configuration
# ──────────────────────────────────────────────────────────────
# This file sets up:
#   • The Terraform version constraint and required providers
#   • The default AWS provider region
#
# State is stored remotely in S3 — see backend.tf.
# ──────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.11.0" # S3 native locking (use_lockfile)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

# Default provider — us-east-1 keeps things simple because
# CloudFront requires its ACM certificate in us-east-1 anyway.
# By putting everything in the same region we avoid needing an
# aliased provider.
provider "aws" {
  region = var.aws_region
}
