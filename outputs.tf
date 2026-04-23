# ──────────────────────────────────────────────────────────────
# outputs.tf — Useful values printed after `terraform apply`
# ──────────────────────────────────────────────────────────────

# ── Canary ───────────────────────────────────────────────────

output "canary_name" {
  description = "Name of the Synthetics canary"
  value       = aws_synthetics_canary.monitor.name
}

output "canary_console_url" {
  description = "Direct link to the canary in the AWS console"
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#synthetics:canary/detail/${aws_synthetics_canary.monitor.name}"
}

output "canary_artifacts_bucket" {
  description = "S3 bucket storing canary screenshots and HAR files"
  value       = aws_s3_bucket.canary_artifacts.id
}

output "canary_role_arn" {
  description = "IAM role ARN the Synthetics canary assumes"
  value       = aws_iam_role.canary_execution.arn
}

output "monitored_endpoints" {
  description = "List of endpoint names being monitored"
  value       = [for m in var.monitors : m.name]
}

# ── Alarms ───────────────────────────────────────────────────

output "sns_topic_arn" {
  description = "SNS topic ARN — CloudWatch Alarms publish here"
  value       = aws_sns_topic.alarm_notifications.arn
}

# ── Dashboard ────────────────────────────────────────────────

output "dashboard_url" {
  description = "Direct link to the CloudWatch dashboard"
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${var.project_name}"
}

# ── Status Page ──────────────────────────────────────────────

output "status_page_url" {
  description = "Public status page URL (after DNS is configured)"
  value       = "https://${var.status_page_domain}"
}

output "status_page_cloudfront_domain" {
  description = "CloudFront domain — use this for the GoDaddy CNAME record"
  value       = aws_cloudfront_distribution.status_page.domain_name
}

output "status_page_bucket" {
  description = "S3 bucket hosting the status page"
  value       = aws_s3_bucket.status_page.id
}

# ── DNS INSTRUCTIONS (GoDaddy) ───────────────────────────────
# These outputs tell you exactly what CNAME records to create
# in GoDaddy. Two records are needed:
#
#   1. ACM certificate validation (add this FIRST — terraform
#      apply will wait for it before continuing)
#   2. Status page subdomain (add after apply finishes)

output "dns_1_acm_validation_record" {
  description = "STEP 1: Add this CNAME in GoDaddy to validate the ACM certificate (terraform apply will wait for this)"
  value = {
    for dvo in aws_acm_certificate.status_page.domain_validation_options : dvo.domain_name => {
      type  = "CNAME"
      name  = dvo.resource_record_name
      value = dvo.resource_record_value
    }
  }
}

output "dns_2_status_page_cname" {
  description = "STEP 2: Add this CNAME in GoDaddy after apply completes to point the subdomain to CloudFront"
  value = {
    type  = "CNAME"
    name  = "status"
    value = aws_cloudfront_distribution.status_page.domain_name
  }
}
