# ──────────────────────────────────────────────────────────────
# dashboard.tf — CloudWatch dashboard (private, in-console)
# ──────────────────────────────────────────────────────────────
# A single dashboard with per-endpoint SuccessPercent and
# Duration widgets. Free tier includes 3 dashboards, so this
# costs nothing extra.
# ──────────────────────────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "monitor" {
  dashboard_name = var.project_name
  dashboard_body = jsonencode({
    widgets = concat(
      # ── Row 1: Overall success rate (all endpoints) ────────
      [
        {
          type   = "metric"
          x      = 0
          y      = 0
          width  = 24
          height = 4
          properties = {
            title  = "Overall Canary Success Rate"
            view   = "timeSeries"
            region = var.aws_region
            period = var.canary_interval_minutes * 60
            stat   = "Average"
            metrics = [
              for m in var.monitors : [
                "CloudWatchSynthetics",
                "SuccessPercent",
                "CanaryName", aws_synthetics_canary.monitor.name,
                "StepName", m.name,
                { label = m.name }
              ]
            ]
            yAxis = {
              left = { min = 0, max = 100, label = "%" }
            }
          }
        }
      ],

      # ── Row 2: Per-endpoint success (individual widgets) ───
      [
        for i, m in var.monitors : {
          type   = "metric"
          x      = (i % 3) * 8
          y      = 5 + floor(i / 3) * 5
          width  = 8
          height = 5
          properties = {
            title  = "${m.name} — Uptime"
            view   = "timeSeries"
            region = var.aws_region
            period = var.canary_interval_minutes * 60
            stat   = "Average"
            metrics = [
              [
                "CloudWatchSynthetics",
                "SuccessPercent",
                "CanaryName", aws_synthetics_canary.monitor.name,
                "StepName", m.name,
                { label = "Success %" }
              ]
            ]
            yAxis = {
              left = { min = 0, max = 100 }
            }
            annotations = {
              horizontal = [
                { label = "Alarm threshold", value = 100, color = "#d62728" }
              ]
            }
          }
        }
      ],

      # ── Row 3: Response duration per endpoint ──────────────
      [
        {
          type   = "metric"
          x      = 0
          y      = 5 + (ceil(length(var.monitors) / 3) * 5) + 1
          width  = 24
          height = 5
          properties = {
            title  = "Response Duration (ms)"
            view   = "timeSeries"
            region = var.aws_region
            period = var.canary_interval_minutes * 60
            stat   = "Average"
            metrics = [
              for m in var.monitors : [
                "CloudWatchSynthetics",
                "Duration",
                "CanaryName", aws_synthetics_canary.monitor.name,
                "StepName", m.name,
                { label = m.name }
              ]
            ]
          }
        }
      ],

      # ── Row 4: Alarm status widget ────────────────────────
      [
        {
          type   = "alarm"
          x      = 0
          y      = 5 + (ceil(length(var.monitors) / 3) * 5) + 7
          width  = 24
          height = 3
          properties = {
            title  = "Alarm Status"
            alarms = [
              for m in var.monitors :
              aws_cloudwatch_metric_alarm.endpoint_alarms[m.name].arn
            ]
          }
        }
      ]
    )
  })
}
