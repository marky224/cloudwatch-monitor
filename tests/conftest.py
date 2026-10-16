"""
Shared fixtures for the status Lambda tests.

generate-status.py reads its environment and creates its boto3
clients at import time, so each test sets the environment first and
then loads a fresh copy of the module. botocore's Stubber answers
every AWS call; an unstubbed call raises, so nothing leaves the
machine.
"""

import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from botocore.stub import Stubber

SCRIPT = Path(__file__).resolve().parent.parent / "status-page" / "generate-status.py"

MONITORS = [
    {"name": "alpha", "url": "https://alpha.example.com", "type": "website"},
    {"name": "beta", "url": "https://beta.example.com/api", "type": "api"},
]

ALARM_NAMES = {
    "alpha": "test-monitor-alpha-failed",
    "beta": "test-monitor-beta-failed",
}

ENV = {
    "CANARY_NAME": "test-monitor",
    "MONITORS": json.dumps(MONITORS),
    "ALARM_NAMES": json.dumps(ALARM_NAMES),
    "BUCKET_NAME": "test-status-bucket",
    "AWS_DEFAULT_REGION": "us-east-1",
    "AWS_ACCESS_KEY_ID": "testing",
    "AWS_SECRET_ACCESS_KEY": "testing",
    "AWS_CONFIG_FILE": "/dev/null",
    "AWS_SHARED_CREDENTIALS_FILE": "/dev/null",
}


@pytest.fixture
def gs(monkeypatch):
    """A freshly loaded generate-status module with stubbed clients."""
    for key, value in ENV.items():
        monkeypatch.setenv(key, value)

    # The hyphen in the file name rules out a normal import.
    spec = importlib.util.spec_from_file_location("generate_status", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    with Stubber(module.cloudwatch) as cw, Stubber(module.s3) as s3:
        yield SimpleNamespace(module=module, cw=cw, s3=s3)
