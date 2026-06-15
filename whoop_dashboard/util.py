"""Small shared helpers: time parsing, local-day computation, duration formatting."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional


def parse_iso(ts: Optional[str]) -> Optional[datetime]:
    """Parse a WHOOP ISO-8601 timestamp (e.g. '2022-04-24T02:25:44.774Z') to an
    aware UTC datetime. Returns None for falsy input."""
    if not ts:
        return None
    # Python's fromisoformat accepts the trailing 'Z' only from 3.11+, but we
    # normalise it anyway for safety across versions.
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _offset_delta(tz_offset: Optional[str]) -> timedelta:
    """Convert a WHOOP timezone_offset string ('-05:00', '+01:30', 'Z') to a timedelta."""
    if not tz_offset or tz_offset == "Z":
        return timedelta(0)
    sign = -1 if tz_offset[0] == "-" else 1
    body = tz_offset.lstrip("+-")
    try:
        hh, mm = body.split(":")
    except ValueError:
        return timedelta(0)
    return sign * timedelta(hours=int(hh), minutes=int(mm))


def local_day(ts: Optional[str], tz_offset: Optional[str]) -> Optional[str]:
    """Return the local calendar date ('YYYY-MM-DD') for a UTC timestamp, shifted by
    the record's own timezone_offset. This makes 'per day' grouping match the day the
    user actually experienced rather than the UTC day."""
    dt = parse_iso(ts)
    if dt is None:
        return None
    local = dt.astimezone(timezone.utc).replace(tzinfo=None) + _offset_delta(tz_offset)
    return local.date().isoformat()


def ms_to_hours(ms: Optional[float]) -> Optional[float]:
    """Milliseconds -> hours (2 dp). None-safe."""
    if ms is None:
        return None
    return round(ms / 3_600_000.0, 2)


def ms_to_hm(ms: Optional[float]) -> str:
    """Milliseconds -> 'Hh Mm' human string. None-safe."""
    if not ms:
        return "--"
    total_min = int(ms // 60_000)
    return f"{total_min // 60}h {total_min % 60:02d}m"


def dig(obj: Optional[dict], *path, default=None):
    """Safely walk nested dicts: dig(record, 'score', 'stage_summary', 'x')."""
    cur = obj
    for key in path:
        if not isinstance(cur, dict):
            return default
        cur = cur.get(key)
    return cur if cur is not None else default
