"""Date helpers for the example app."""

from datetime import datetime


def parse_iso8601(value: str) -> datetime:
    """Parse an ISO-8601 timestamp such as "2026-10-05T15:30:00+02:00"."""
    return datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")


def to_display(value: datetime) -> str:
    """Format a datetime the way the app shows it to users."""
    return value.strftime("%Y-%m-%d %H:%M")
