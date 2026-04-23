"""
generate-status.py — Lambda function for the public status page
─────────────────────────────────────────────────────────────────
Runs every 5 minutes via EventBridge. Queries CloudWatch for
per-endpoint SuccessPercent metrics, calculates uptime, and
writes status.json to the status page S3 bucket.

Environment variables (set by Terraform):
  CANARY_NAME  — name of the Synthetics canary
  MONITORS     — JSON list of monitored endpoints
  BUCKET_NAME  — S3 bucket for the status page
"""

import json
import os
from datetime import datetime, timedelta, timezone

import boto3

cloudwatch = boto3.client("cloudwatch")
s3 = boto3.client("s3")

CANARY_NAME = os.environ["CANARY_NAME"]
MONITORS = json.loads(os.environ["MONITORS"])
BUCKET_NAME = os.environ["BUCKET_NAME"]


def get_uptime(step_name: str, hours: int, period_seconds: int) -> float | None:
    """
    Query CloudWatch for the average SuccessPercent of a single
    canary step over the given time range.

    Returns a float 0–100, or None if no data exists yet.
    """
    now = datetime.now(timezone.utc)
    start = now - timedelta(hours=hours)

    result = cloudwatch.get_metric_data(
        MetricDataQueries=[
            {
                "Id": "success",
                "MetricStat": {
                    "Metric": {
                        "Namespace": "CloudWatchSynthetics",
                        "MetricName": "SuccessPercent",
                        "Dimensions": [
                            {"Name": "CanaryName", "Value": CANARY_NAME},
                            {"Name": "StepName", "Value": step_name},
                        ],
                    },
                    "Period": period_seconds,
                    "Stat": "Average",
                },
                "ReturnData": True,
            }
        ],
        StartTime=start,
        EndTime=now,
    )

    values = result["MetricDataResults"][0]["Values"]
    if not values:
        return None

    return round(sum(values) / len(values), 2)


def get_daily_history(step_name: str, days: int = 90) -> list[dict]:
    """
    Return per-day uptime percentages for the last N days.
    Each entry: {"date": "2026-04-22", "uptime": 100.0}
    Days with no data get uptime: null.
    """
    now = datetime.now(timezone.utc)
    start = now - timedelta(days=days)

    result = cloudwatch.get_metric_data(
        MetricDataQueries=[
            {
                "Id": "daily",
                "MetricStat": {
                    "Metric": {
                        "Namespace": "CloudWatchSynthetics",
                        "MetricName": "SuccessPercent",
                        "Dimensions": [
                            {"Name": "CanaryName", "Value": CANARY_NAME},
                            {"Name": "StepName", "Value": step_name},
                        ],
                    },
                    "Period": 86400,  # 1 day
                    "Stat": "Average",
                },
                "ReturnData": True,
            }
        ],
        StartTime=start,
        EndTime=now,
    )

    # Build a date → uptime lookup from the CloudWatch response.
    timestamps = result["MetricDataResults"][0]["Timestamps"]
    values = result["MetricDataResults"][0]["Values"]
    day_map = {}
    for ts, val in zip(timestamps, values):
        day_str = ts.strftime("%Y-%m-%d")
        day_map[day_str] = round(val, 2)

    # Fill in all days in the range, marking missing days as null.
    history = []
    for i in range(days):
        day = (start + timedelta(days=i + 1)).strftime("%Y-%m-%d")
        history.append({
            "date": day,
            "uptime": day_map.get(day),
        })

    return history


def get_current_status(uptime_24h: float | None) -> str:
    """
    Determine the current status label from the 24-hour uptime.
      100%     → operational
      90–99%   → degraded
      <90%     → outage
      no data  → unknown
    """
    if uptime_24h is None:
        return "unknown"
    if uptime_24h >= 100.0:
        return "operational"
    if uptime_24h >= 90.0:
        return "degraded"
    return "outage"


def display_name(name: str) -> str:
    """Convert 'portfolio-site' → 'Portfolio Site'."""
    return name.replace("-", " ").title()


def handler(event, context):
    """Lambda entry point — generate and upload status.json."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    endpoints = []
    for monitor in MONITORS:
        name = monitor["name"]

        # Query uptime for several windows.
        # Periods are chosen to keep data point counts reasonable.
        uptime_24h = get_uptime(name, hours=24, period_seconds=1800)
        uptime_7d = get_uptime(name, hours=168, period_seconds=3600)
        uptime_30d = get_uptime(name, hours=720, period_seconds=21600)
        uptime_90d = get_uptime(name, hours=2160, period_seconds=86400)

        # 90-day daily history for the uptime bar chart.
        daily_history = get_daily_history(name, days=90)

        status = get_current_status(uptime_24h)

        endpoints.append({
            "name": name,
            "display_name": display_name(name),
            "url": monitor["url"],
            "type": monitor["type"],
            "status": status,
            "uptime_24h": uptime_24h,
            "uptime_7d": uptime_7d,
            "uptime_30d": uptime_30d,
            "uptime_90d": uptime_90d,
            "daily_history": daily_history,
        })

    # Overall status: worst status across all endpoints.
    statuses = [e["status"] for e in endpoints]
    if "outage" in statuses:
        overall = "outage"
    elif "degraded" in statuses:
        overall = "degraded"
    elif "unknown" in statuses:
        overall = "unknown"
    else:
        overall = "operational"

    status_json = {
        "last_updated": now,
        "overall_status": overall,
        "canary_name": CANARY_NAME,
        "endpoints": endpoints,
    }

    # Write to S3 with a short cache TTL.
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key="status.json",
        Body=json.dumps(status_json, indent=2),
        ContentType="application/json",
        CacheControl="max-age=60, s-maxage=60",
    )

    print(f"Updated status.json: overall={overall}, endpoints={len(endpoints)}")
    return {"statusCode": 200, "body": f"Status updated: {overall}"}
