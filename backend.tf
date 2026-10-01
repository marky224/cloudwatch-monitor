# ──────────────────────────────────────────────────────────────
# backend.tf — Remote state in S3
# ──────────────────────────────────────────────────────────────
# State lives in a private, versioned, encrypted S3 bucket that is
# created outside this project. Locking uses S3's native lock file.
#
# The bucket name is NOT in this file. It comes from the gitignored
# .tfbackend at init time (copy .tfbackend.example to start):
#
#   terraform init -backend-config=.tfbackend
#
# Keep it that way — the bucket name contains the AWS account ID,
# and this is a public repo.
# ──────────────────────────────────────────────────────────────

terraform {
  backend "s3" {
    key          = "cloudwatch-monitor/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
