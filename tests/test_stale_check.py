"""
Tests for the stale-data check in status-page/index.html.

The page's isStale() and its STALE_AFTER_MS threshold are pulled out
of the HTML and run under node with a fixed "now", so the check is
tested exactly as the browser runs it.
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

pytestmark = pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")


def extract_stale_check() -> str:
    """Return the STALE_AFTER_MS constant and isStale() source from index.html."""
    html = INDEX_HTML.read_text()
    const = re.search(r"const STALE_AFTER_MS = [^;]+;", html)
    func = re.search(r"^( *)function isStale\(.*?^\1\}", html, re.MULTILINE | re.DOTALL)
    if not const or not func:
        pytest.fail("index.html has no STALE_AFTER_MS constant or isStale() function")
    return const.group(0) + "\n" + func.group(0)


def test_stale_check():
    inputs = [ts for ts, _ in CASES]
    script = (
        extract_stale_check()
        + f"\nconst now = Date.parse({json.dumps(NOW)});"
        + f"\nconst inputs = {json.dumps(inputs)};"
        + "\nconsole.log(JSON.stringify(inputs.map((ts) => isStale(ts, now))));"
    )
    result = subprocess.run(
        ["node", "-e", script], capture_output=True, text=True, check=True
    )
    assert json.loads(result.stdout) == [stale for _, stale in CASES]
