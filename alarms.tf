# ──────────────────────────────────────────────────────────────
# alarms.tf — SNS topic + per-endpoint CloudWatch Alarms
# ──────────────────────────────────────────────────────────────
# Phase 1: SNS topic and email subscription
# Phase 2: One CloudWatch Alarm per monitored endpoint
# ──────────────────────────────────────────────────────────────

# ── SNS topic for alarm notifications ────────────────────────
resource "aws_sns_topic" "alarm_notifications" {
  name = "${var.project_name}-alarms"

  tags = {
    Project = var.project_name
    Purpose = "Canary failure alarm notifications"
  }
}

# ── Email subscription ──────────────────────────────────────
# IMPORTANT: After `terraform apply`, AWS sends a confirmation
# email to this address. You MUST click the confirmation link
# in that email or you won't receive any alarm notifications.
resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.alarm_notifications.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── Phase 2: Per-endpoint CloudWatch Alarms ──────────────────
# Each alarm watches the SuccessPercent metric for one specific
# step (endpoint) within the canary. If SuccessPercent drops
# below 100 for 2 consecutive evaluation periods, the alarm
# fires and sends an email via SNS.
#
# for_each loops over the monitors list, creating one alarm per
# endpoint automatically. Add or remove an endpoint in
# variables.tf and the alarms update to match.

resource "aws_cloudwatch_metric_alarm" "endpoint_alarms" {
  for_each = { for m in var.monitors : m.name => m }

  alarm_name          = "${var.project_name}-${each.key}-failed"
  alarm_description   = "ALARM: ${each.key} failed health check (${each.value.url})"
  comparison_operator = "LessThanThreshold"
  threshold           = 100

  # Evaluate over 2 consecutive periods. With a 30-min canary
  # interval, this means the endpoint must fail twice in a row
  # (1 hour) before the alarm fires — avoids false positives
  # from a single transient failure.
  evaluation_periods = 2
  datapoints_to_alarm = 2

  metric_name = "SuccessPercent"
  namespace   = "CloudWatchSynthetics"
  statistic   = "Average"

  # Period must match the canary interval (in seconds).
  period = var.canary_interval_minutes * 60

  # Dimensions filter to this specific canary + step name.
  # The step name matches the name passed to executeHttpStep()
  # in the canary script, which comes from the monitors list.
  dimensions = {
    CanaryName = aws_synthetics_canary.monitor.name
    StepName   = each.key
  }

  # If the canary stops running entirely (no data), treat it
  # as a failure — something is wrong.
  treat_missing_data = "breaching"

  # Send email on both failure AND recovery so you know when
  # things are back to normal.
  alarm_actions = [aws_sns_topic.alarm_notifications.arn]
  ok_actions    = [aws_sns_topic.alarm_notifications.arn]

  tags = {
    Project  = var.project_name
    Endpoint = each.key
  }
}
