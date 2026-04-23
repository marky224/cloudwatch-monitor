# ──────────────────────────────────────────────────────────────
# canary.tf — Synthetics canary + supporting resources
# ──────────────────────────────────────────────────────────────
# Phase 1: S3 artifacts bucket, IAM role, permissions
# Phase 2: Canary script packaging, Synthetics canary resource
# ──────────────────────────────────────────────────────────────

# ── S3 bucket for canary artifacts ───────────────────────────
# CloudWatch Synthetics stores screenshots and HAR files here
# after every canary run. The 30-day lifecycle rule keeps
# storage costs negligible.

resource "aws_s3_bucket" "canary_artifacts" {
  bucket = "${var.project_name}-canary-artifacts"

  # Prevent Terraform from destroying the bucket if it still
  # has objects in it. Set to true when you want to tear down.
  force_destroy = true

  tags = {
    Project = var.project_name
    Purpose = "CloudWatch Synthetics canary artifacts"
  }
}

# Block all public access — these artifacts are internal only.
resource "aws_s3_bucket_public_access_block" "canary_artifacts" {
  bucket = aws_s3_bucket.canary_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Auto-delete artifacts after 30 days to control storage costs.
resource "aws_s3_bucket_lifecycle_configuration" "canary_artifacts" {
  bucket = aws_s3_bucket.canary_artifacts.id

  rule {
    id     = "expire-artifacts-30-days"
    status = "Enabled"

    # Empty filter = apply to all objects in the bucket.
    filter {}

    expiration {
      days = 30
    }
  }
}

# ── IAM execution role for the Synthetics canary ─────────────
# The canary runs as a Lambda function under the hood.
# This role grants it just enough permissions to:
#   • Write artifacts to S3
#   • Emit CloudWatch metrics
#   • Write CloudWatch Logs

# Trust policy — allows the Synthetics service to assume this role.
data "aws_iam_policy_document" "canary_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "canary_execution" {
  name               = "${var.project_name}-canary-role"
  assume_role_policy = data.aws_iam_policy_document.canary_assume_role.json

  tags = {
    Project = var.project_name
  }
}

# Permission policy — least privilege for what the canary needs.
data "aws_iam_policy_document" "canary_permissions" {
  # Write screenshots and HAR files to the artifacts bucket.
  statement {
    sid    = "ArtifactsBucket"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
    ]
    resources = ["${aws_s3_bucket.canary_artifacts.arn}/*"]
  }

  # Synthetics needs GetBucketLocation to determine the bucket region.
  statement {
    sid    = "ArtifactsBucketLocation"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.canary_artifacts.arn]
  }

  # Synthetics also calls ListAllMyBuckets during setup.
  statement {
    sid       = "ListBuckets"
    effect    = "Allow"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  # Write logs so you can debug canary failures in CloudWatch Logs.
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }

  # Emit per-step SuccessPercent and Duration metrics.
  statement {
    sid       = "CloudWatchMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "canary_permissions" {
  name   = "${var.project_name}-canary-policy"
  role   = aws_iam_role.canary_execution.id
  policy = data.aws_iam_policy_document.canary_permissions.json
}

# ── Phase 2: Canary script packaging ────────────────────────
# The canary script template (index.js.tftpl) has a placeholder
# for the monitors list. Terraform renders it with templatefile()
# and the archive_file data source zips it into the directory
# structure that Synthetics expects:
#   nodejs/node_modules/index.js

data "archive_file" "canary_script" {
  type        = "zip"
  output_path = "${path.module}/canary-script/canary.zip"

  source {
    content = templatefile("${path.module}/canary-script/index.js.tftpl", {
      monitors = var.monitors
    })
    filename = "nodejs/node_modules/index.js"
  }
}

# ── Phase 2: Synthetics canary ───────────────────────────────
# One canary checks all endpoints. Each endpoint is its own
# executeHttpStep() inside the script, so CloudWatch emits a
# separate SuccessPercent metric per endpoint — even though
# there's only one canary (keeping costs at ~$1.73/month).
#
# Runtime syn-nodejs-puppeteer-13.1 is the latest Puppeteer
# runtime (Node.js 22.x, Puppeteer 24.x).

resource "aws_synthetics_canary" "monitor" {
  name                 = "${var.project_name}"
  artifact_s3_location = "s3://${aws_s3_bucket.canary_artifacts.id}/"
  execution_role_arn   = aws_iam_role.canary_execution.arn
  handler              = "index.handler"
  zip_file             = data.archive_file.canary_script.output_path
  runtime_version      = "syn-nodejs-puppeteer-13.1"

  # Start running immediately after creation.
  start_canary = true

  schedule {
    # rate() expression — runs every N minutes.
    expression = "rate(${var.canary_interval_minutes} minutes)"
  }

  run_config {
    # Total timeout for one canary run (all 7 endpoints).
    # HTTP-only checks are fast — 120 seconds is plenty of headroom.
    timeout_in_seconds = 120
    memory_in_mb       = 960
    active_tracing     = false
  }

  tags = {
    Project = var.project_name
  }
}
