from datetime import datetime

from src.dates import parse_iso8601, to_display


def test_parses_date_and_time():
    assert parse_iso8601("2026-10-05T15:30:00") == datetime(2026, 10, 5, 15, 30, 0)


def test_display_format():
    assert to_display(datetime(2026, 10, 5, 15, 30)) == "2026-10-05 15:30"
