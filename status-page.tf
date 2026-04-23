# ──────────────────────────────────────────────────────────────
# status-page.tf — Public status page infrastructure
# ──────────────────────────────────────────────────────────────
# Resources:
#   • S3 bucket for static hosting (index.html + status.json)
#   • CloudFront distribution with custom domain + HTTPS
#   • ACM certificate for status.markandrewmarquez.com
#   • Lambda function to generate status.json from CloudWatch
#   • EventBridge rule to trigger the Lambda every 5 minutes
# ──────────────────────────────────────────────────────────────

# ── Data: current AWS account ID ─────────────────────────────
data "aws_caller_identity" "current" {}

# ══════════════════════════════════════════════════════════════
# S3 BUCKET — Static status page hosting
# ══════════════════════════════════════════════════════════════

resource "aws_s3_bucket" "status_page" {
  bucket        = "${var.project_name}-status-page"
  force_destroy = true

  tags = {
    Project = var.project_name
    Purpose = "Public status page static hosting"
  }
}

# Block all public access — CloudFront OAC handles access.
resource "aws_s3_bucket_public_access_block" "status_page" {
  bucket = aws_s3_bucket.status_page.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket policy: allow CloudFront OAC to read objects.
resource "aws_s3_bucket_policy" "status_page" {
  bucket = aws_s3_bucket.status_page.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.status_page.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.status_page.arn
          }
        }
      }
    ]
  })

  # The distribution must exist before the policy references it.
  depends_on = [aws_cloudfront_distribution.status_page]
}

# Upload the static HTML file to S3.
# Terraform re-uploads whenever the file content changes.
resource "aws_s3_object" "status_page_html" {
  bucket       = aws_s3_bucket.status_page.id
  key          = "index.html"
  source       = "${path.module}/status-page/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/status-page/index.html")

  # Short cache — the HTML file changes rarely, but 5 min
  # keeps updates quick when they happen.
  cache_control = "max-age=300, s-maxage=300"
}

# ══════════════════════════════════════════════════════════════
# ACM CERTIFICATE — HTTPS for the custom domain
# ══════════════════════════════════════════════════════════════
# Must be in us-east-1 for CloudFront. Since all our resources
# are already in us-east-1, no aliased provider is needed.

resource "aws_acm_certificate" "status_page" {
  domain_name       = var.status_page_domain
  validation_method = "DNS"

  tags = {
    Project = var.project_name
  }

  # Create the new cert before destroying the old one during
  # replacement. Prevents downtime.
  lifecycle {
    create_before_destroy = true
  }
}

# Wait for the certificate to be validated.
# terraform apply will PAUSE here until you add the DNS record
# in GoDaddy. See the outputs for the exact CNAME to add.
resource "aws_acm_certificate_validation" "status_page" {
  certificate_arn = aws_acm_certificate.status_page.arn

  # No validation_record_fqdns — we can't auto-create DNS
  # records since DNS is on GoDaddy, not Route 53.
  # Terraform will poll until the cert is validated.
}

# ══════════════════════════════════════════════════════════════
# CLOUDFRONT — CDN + custom domain
# ══════════════════════════════════════════════════════════════

# Origin Access Control — the modern way to connect CloudFront → S3.
resource "aws_cloudfront_origin_access_control" "status_page" {
  name                              = "${var.project_name}-status-oac"
  description                       = "OAC for status page S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "status_page" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  comment             = "Status page for ${var.project_name}"
  price_class         = "PriceClass_100" # US, Canada, Europe only — cheapest

  aliases = [var.status_page_domain]

  origin {
    domain_name              = aws_s3_bucket.status_page.bucket_regional_domain_name
    origin_id                = "s3-status-page"
    origin_access_control_id = aws_cloudfront_origin_access_control.status_page.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-status-page"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Use the CachingOptimized managed policy for static content.
    # Override with a short TTL so status.json updates propagate
    # within a few minutes.
    min_ttl     = 0
    default_ttl = 60   # 1 minute default
    max_ttl     = 300  # 5 minutes max

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  # Custom error pages — show the main page for 403/404.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.status_page.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Project = var.project_name
  }
}

# ══════════════════════════════════════════════════════════════
# LAMBDA — Generate status.json from CloudWatch metrics
# ══════════════════════════════════════════════════════════════

# Package the Python script into a zip for Lambda.
data "archive_file" "status_lambda" {
  type        = "zip"
  source_file = "${path.module}/status-page/generate-status.py"
  output_path = "${path.module}/status-page/generate-status.zip"
}

# IAM role for the status page Lambda.
data "aws_iam_policy_document" "status_lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "status_lambda" {
  name               = "${var.project_name}-status-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.status_lambda_assume.json

  tags = {
    Project = var.project_name
  }
}

# Permissions: read CloudWatch metrics + write status.json to S3 + logs.
data "aws_iam_policy_document" "status_lambda_permissions" {
  # Query CloudWatch for canary metrics.
  statement {
    sid    = "CloudWatchRead"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
    ]
    resources = ["*"]
  }

  # Write status.json to the status page S3 bucket.
  statement {
    sid    = "S3WriteStatus"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.status_page.arn}/status.json"]
  }

  # CloudWatch Logs for debugging.
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
}

resource "aws_iam_role_policy" "status_lambda_permissions" {
  name   = "${var.project_name}-status-lambda-policy"
  role   = aws_iam_role.status_lambda.id
  policy = data.aws_iam_policy_document.status_lambda_permissions.json
}

resource "aws_lambda_function" "status_generator" {
  function_name    = "${var.project_name}-status-generator"
  role             = aws_iam_role.status_lambda.arn
  handler          = "generate-status.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.status_lambda.output_path
  source_code_hash = data.archive_file.status_lambda.output_base64sha256

  environment {
    variables = {
      CANARY_NAME = aws_synthetics_canary.monitor.name
      MONITORS    = jsonencode(var.monitors)
      BUCKET_NAME = aws_s3_bucket.status_page.id
    }
  }

  tags = {
    Project = var.project_name
  }
}

# ── EventBridge: trigger the Lambda every 5 minutes ──────────
resource "aws_cloudwatch_event_rule" "status_update" {
  name                = "${var.project_name}-status-update"
  description         = "Trigger status page Lambda every 5 minutes"
  schedule_expression = "rate(5 minutes)"

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_event_target" "status_lambda" {
  rule = aws_cloudwatch_event_rule.status_update.name
  arn  = aws_lambda_function.status_generator.arn
}

# Allow EventBridge to invoke the Lambda.
resource "aws_lambda_permission" "status_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.status_generator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.status_update.arn
}
