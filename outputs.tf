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
  description = "Public status page URL"
  value       = "https://${var.status_page_domain}"
}

output "status_page_cloudfront_domain" {
  description = "CloudFront domain the Route 53 alias records point at"
  value       = aws_cloudfront_distribution.status_page.domain_name
}

output "status_page_bucket" {
  description = "S3 bucket hosting the status page"
  value       = aws_s3_bucket.status_page.id
}
