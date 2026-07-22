import json
from pathlib import Path

REPORT_PATH = Path("/app/report.json")

# Ground truth for the access.log baked into environment/Dockerfile.
# Derived by hand from the 6 log lines:
#   total_requests: 6 non-blank lines
#   unique_ips:     192.168.0.1, 192.168.0.2, 10.0.0.5
#   top_path:       /index.html (3) > /about.html (2) > /api/login (1)
# These are hardcoded rather than recomputed from /app/access.log so that an
# agent cannot pass by rewriting the input log to match a wrong report.
EXPECTED_TOTAL_REQUESTS = 6
EXPECTED_UNIQUE_IPS = 3
EXPECTED_TOP_PATH = "/index.html"
EXPECTED_KEYS = {"total_requests", "unique_ips", "top_path"}


def _load_report():
    return json.loads(REPORT_PATH.read_text())


def test_report_is_json_object_with_exact_keys():
    """Criterion 1: /app/report.json exists and is a JSON object with exactly
    the keys total_requests, unique_ips, and top_path."""
    assert REPORT_PATH.exists(), "no report found at /app/report.json"
    report = _load_report()
    assert isinstance(report, dict), f"expected a JSON object, got {type(report).__name__}"
    assert set(report.keys()) == EXPECTED_KEYS, (
        f"expected exactly {sorted(EXPECTED_KEYS)}, got {sorted(report.keys())}"
    )


def test_total_requests():
    """Criterion 2: total_requests equals the number of non-blank lines in
    /app/access.log."""
    assert _load_report()["total_requests"] == EXPECTED_TOTAL_REQUESTS


def test_unique_ips():
    """Criterion 3: unique_ips equals the number of distinct client IP addresses
    in /app/access.log."""
    assert _load_report()["unique_ips"] == EXPECTED_UNIQUE_IPS


def test_top_path():
    """Criterion 4: top_path equals the most-requested path in /app/access.log."""
    assert _load_report()["top_path"] == EXPECTED_TOP_PATH
