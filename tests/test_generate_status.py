"""
Tests for status-page/generate-status.py.

Each test queues the AWS responses for one full Lambda run, calls
handler(), and checks the status.json it would upload. Stub order
per run: one DescribeAlarms, then five GetMetricData calls per
monitor (24h, 7d, 30d, 90d, daily history), then one PutObject.
"""

import json
from datetime import datetime, timedelta, timezone

import pytest
from botocore.stub import ANY

from conftest import ALARM_NAMES, MONITORS

FAKE_ACCOUNT = "123456789012"


class Capture:
    """Stubber parameter matcher that records the value it is compared with."""

    def __init__(self):
        self.value = None

    def __eq__(self, other):
        self.value = other
        return True

    def __ne__(self, other):
        self.value = other
        return False


def metric_result(values, query_id="success", timestamps=None):
    """A GetMetricData response; values are newest first."""
    if timestamps is None:
        now = datetime.now(timezone.utc)
        timestamps = [now - timedelta(minutes=30 * i) for i in range(len(values))]
    return {
        "MetricDataResults": [
            {
                "Id": query_id,
                "Label": "SuccessPercent",
                "Timestamps": timestamps,
                "Values": values,
                "StatusCode": "Complete",
            }
        ]
    }


def alarm(monitor, state):
    """A DescribeAlarms entry carrying the fields that must stay private."""
    name = ALARM_NAMES[monitor]
    topic = f"arn:aws:sns:us-east-1:{FAKE_ACCOUNT}:test-monitor-alarms"
    return {
        "AlarmName": name,
        "AlarmArn": f"arn:aws:cloudwatch:us-east-1:{FAKE_ACCOUNT}:alarm:{name}",
        "AlarmActions": [topic],
        "OKActions": [topic],
        "StateValue": state,
        "StateReason": "Threshold Crossed",
        "Namespace": "CloudWatchSynthetics",
        "MetricName": "SuccessPercent",
        "Dimensions": [
            {"Name": "CanaryName", "Value": "test-monitor"},
            {"Name": "StepName", "Value": monitor},
        ],
    }


def run_handler(gs, states, recent=None, windows=None, daily=None):
    """
    Queue one full run, call the handler, return the parsed status.json.
      states  — {monitor: StateValue}; a monitor left out has no alarm
      recent  — {monitor: 24h values, newest first}; default [100, 100]
      windows — {monitor: (7d, 30d, 90d)}; default 100 each
      daily   — {monitor: [(timestamp, value)]}; default no history
    """
    recent = recent or {}
    windows = windows or {}
    daily = daily or {}

    gs.cw.add_response(
        "describe_alarms",
        {"MetricAlarms": [alarm(m, s) for m, s in states.items()]},
        {
            "AlarmNames": list(ALARM_NAMES.values()),
            "AlarmTypes": ["MetricAlarm"],
            "MaxRecords": 100,
        },
    )
    for monitor in MONITORS:
        name = monitor["name"]
        # The 24h query must ask for newest first: its first value is
        # the latest run.
        gs.cw.add_response(
            "get_metric_data",
            metric_result(recent.get(name, [100.0, 100.0])),
            {
                "MetricDataQueries": ANY,
                "StartTime": ANY,
                "EndTime": ANY,
                "ScanBy": "TimestampDescending",
            },
        )
        for value in windows.get(name, (100.0, 100.0, 100.0)):
            gs.cw.add_response("get_metric_data", metric_result([value]))
        points = daily.get(name, [])
        gs.cw.add_response(
            "get_metric_data",
            metric_result([v for _, v in points], "daily", [t for t, _ in points]),
        )

    body = Capture()
    gs.s3.add_response(
        "put_object",
        {},
        {
            "Bucket": "test-status-bucket",
            "Key": "status.json",
            "Body": body,
            "ContentType": "application/json",
            "CacheControl": "max-age=60, s-maxage=60",
        },
    )

    gs.module.handler(None, None)

    gs.cw.assert_no_pending_responses()
    gs.s3.assert_no_pending_responses()
    return json.loads(body.value)


def row(status, name):
    return next(e for e in status["endpoints"] if e["name"] == name)


# ── Alarm state → row status ─────────────────────────────────

def test_alarm_ok_is_operational(gs):
    status = run_handler(gs, {"alpha": "OK", "beta": "OK"})
    assert row(status, "alpha")["status"] == "operational"


def test_alarm_alarm_is_outage(gs):
    status = run_handler(gs, {"alpha": "ALARM", "beta": "OK"})
    assert row(status, "alpha")["status"] == "outage"


def test_alarm_insufficient_data_is_unknown(gs):
    status = run_handler(gs, {"alpha": "INSUFFICIENT_DATA", "beta": "OK"})
    assert row(status, "alpha")["status"] == "unknown"


def test_missing_alarm_is_unknown(gs):
    status = run_handler(gs, {"alpha": "OK"})
    assert row(status, "alpha")["status"] == "operational"
    assert row(status, "beta")["status"] == "unknown"


def test_one_describe_alarms_call_with_all_names(gs):
    # run_handler queues exactly one DescribeAlarms with the full name
    # list; a second call or different parameters would raise.
    status = run_handler(gs, {"alpha": "OK", "beta": "ALARM"})
    assert [e["status"] for e in status["endpoints"]] == ["operational", "outage"]


# ── Current state vs. uptime history ─────────────────────────

@pytest.mark.parametrize(
    "state, recent, expected_status, expected_24h",
    [
        ("ALARM", [100.0, 100.0], "outage", 100.0),
        ("OK", [100.0, 0.0], "operational", 50.0),
    ],
)
def test_current_state_ignores_24h_average(gs, state, recent, expected_status, expected_24h):
    status = run_handler(gs, {"alpha": state, "beta": "OK"}, recent={"alpha": recent})
    alpha = row(status, "alpha")
    assert alpha["status"] == expected_status
    assert alpha["uptime_24h"] == expected_24h


def test_uptime_and_history_unchanged(gs):
    today = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    status = run_handler(
        gs,
        {"alpha": "OK", "beta": "OK"},
        windows={"alpha": (99.5, 98.0, 97.25)},
        daily={"alpha": [(today, 96.5)]},
    )
    alpha = row(status, "alpha")
    assert (alpha["uptime_7d"], alpha["uptime_30d"], alpha["uptime_90d"]) == (99.5, 98.0, 97.25)
    assert len(alpha["daily_history"]) == 90
    assert alpha["daily_history"][-1] == {"date": today.strftime("%Y-%m-%d"), "uptime": 96.5}
    assert alpha["display_name"] == "Alpha"
    assert (alpha["url"], alpha["type"]) == ("https://alpha.example.com", "website")


@pytest.mark.parametrize(
    "states, expected",
    [
        ({"alpha": "OK", "beta": "ALARM"}, "outage"),
        ({"alpha": "OK", "beta": "INSUFFICIENT_DATA"}, "unknown"),
        ({"alpha": "OK", "beta": "OK"}, "operational"),
    ],
)
def test_overall_is_worst_row(gs, states, expected):
    status = run_handler(gs, states)
    assert status["overall_status"] == expected


# ── Degraded: alarm OK, latest run failed ────────────────────

@pytest.mark.parametrize(
    "recent, expected",
    [
        ([0.0, 100.0, 100.0], "degraded"),     # latest run failed, alarm not fired yet
        ([100.0, 0.0, 0.0], "operational"),    # earlier failures, latest run passed
        ([], "operational"),                   # no recent data; the alarm says OK
    ],
)
def test_degraded_means_latest_run_failed(gs, recent, expected):
    status = run_handler(gs, {"alpha": "OK", "beta": "OK"}, recent={"alpha": recent})
    assert row(status, "alpha")["status"] == expected


def test_alarm_wins_over_latest_run(gs):
    status = run_handler(
        gs,
        {"alpha": "ALARM", "beta": "INSUFFICIENT_DATA"},
        recent={"alpha": [100.0], "beta": [0.0]},
    )
    assert row(status, "alpha")["status"] == "outage"
    assert row(status, "beta")["status"] == "unknown"


def test_degraded_row_sets_overall_degraded(gs):
    status = run_handler(gs, {"alpha": "OK", "beta": "OK"}, recent={"alpha": [0.0]})
    assert status["overall_status"] == "degraded"


# ── Public output ────────────────────────────────────────────

def test_status_json_has_no_arns_or_account_ids(gs):
    status = run_handler(gs, {"alpha": "ALARM", "beta": "OK"})
    body = json.dumps(status)
    assert "arn:" not in body
    assert FAKE_ACCOUNT not in body


def test_put_object_params(gs):
    # The PutObject stub only matches the expected Bucket, Key,
    # ContentType and CacheControl.
    status = run_handler(gs, {"alpha": "OK", "beta": "OK"})
    assert set(status) == {"last_updated", "overall_status", "canary_name", "endpoints"}
    assert status["canary_name"] == "test-monitor"
