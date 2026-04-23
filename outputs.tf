# ──────────────────────────────────────────────────────────────
# outputs.tf — Useful values printed after `terraform apply`
# ──────────────────────────────────────────────────────────────
# More outputs will be added in later phases (dashboard URL,
# status page URL, etc.)
# ──────────────────────────────────────────────────────────────

output "canary_artifacts_bucket" {
  description = "S3 bucket storing canary screenshots and HAR files"
  value       = aws_s3_bucket.canary_artifacts.id
}

output "sns_topic_arn" {
  description = "SNS topic ARN — CloudWatch Alarms publish here"
  value       = aws_sns_topic.alarm_notifications.arn
}

output "canary_role_arn" {
  description = "IAM role ARN the Synthetics canary will assume"
  value       = aws_iam_role.canary_execution.arn
}

output "monitored_endpoints" {
  description = "List of endpoint names being monitored"
  value       = [for m in var.monitors : m.name]
}

output "canary_name" {
  description = "Name of the Synthetics canary"
  value       = aws_synthetics_canary.monitor.name
}

output "canary_console_url" {
  description = "Direct link to the canary in the AWS console"
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#synthetics:canary/detail/${aws_synthetics_canary.monitor.name}"
}
