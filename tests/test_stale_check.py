"""
Tests for the stale-data check in status-page/index.html.

The page's isStale() and its STALE_AFTER_MS threshold are pulled out
of the HTML and run under node with a fixed "now", so the check is
tested exactly as the browser runs it. formatAge(), which words the
banner's age, is pulled out and run the same way.
"""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

INDEX_HTML = Path(__file__).resolve().parent.parent / "status-page" / "index.html"

NOW = "2026-10-16T12:00:00Z"

CASES = [
    ("2026-10-16T11:45:01Z", False),  # 14 min 59 s old
    ("2026-10-16T11:45:00Z", False),  # exactly 15 min old
    ("2026-10-16T11:44:59Z", True),   # 15 min 1 s old
    ("2026-10-16T12:10:00Z", False),  # in the future (clock skew)
    (None, True),                     # missing
    ("", True),                       # empty
    ("not-a-date", True),             # unparseable
]

MINUTE_MS = 60 * 1000
HOUR_MS = 60 * MINUTE_MS
DAY_MS = 24 * HOUR_MS

AGE_CASES = [
    (MINUTE_MS, "1 minute"),
    (42 * MINUTE_MS, "42 minutes"),
    (59 * MINUTE_MS + 59 * 1000, "59 minutes"),
    (HOUR_MS, "1 hour"),
    (3 * HOUR_MS + 59 * MINUTE_MS, "3 hours"),
    (23 * HOUR_MS + 59 * MINUTE_MS, "23 hours"),
    (DAY_MS, "1 day"),
    (25 * HOUR_MS, "1 day"),
    (3 * DAY_MS, "3 days"),
]

pytestmark = pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")


def extract_function(html: str, name: str) -> str:
    """Return the source of the top-level function `name` in the page script."""
    func = re.search(rf"^( *)function {name}\(.*?^\1\}}", html, re.MULTILINE | re.DOTALL)
    if not func:
        pytest.fail(f"index.html has no {name}() function")
    return func.group(0)


def run_node(script: str):
    result = subprocess.run(
        ["node", "-e", script], capture_output=True, text=True, check=True
    )
    return json.loads(result.stdout)


def extract_stale_check() -> str:
    """Return the STALE_AFTER_MS constant and isStale() source from index.html."""
    html = INDEX_HTML.read_text()
    const = re.search(r"const STALE_AFTER_MS = [^;]+;", html)
    if not const:
        pytest.fail("index.html has no STALE_AFTER_MS constant")
    return const.group(0) + "\n" + extract_function(html, "isStale")


def test_stale_check():
    inputs = [ts for ts, _ in CASES]
    script = (
        extract_stale_check()
        + f"\nconst now = Date.parse({json.dumps(NOW)});"
        + f"\nconst inputs = {json.dumps(inputs)};"
        + "\nconsole.log(JSON.stringify(inputs.map((ts) => isStale(ts, now))));"
    )
    assert run_node(script) == [stale for _, stale in CASES]


def test_format_age():
    inputs = [age for age, _ in AGE_CASES]
    script = (
        extract_function(INDEX_HTML.read_text(), "formatAge")
        + f"\nconst inputs = {json.dumps(inputs)};"
        + "\nconsole.log(JSON.stringify(inputs.map(formatAge)));"
    )
    assert run_node(script) == [text for _, text in AGE_CASES]
