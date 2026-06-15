"""Write a compact JSON snapshot of the latest stats.

Served to the native widget/app via GET /api/snapshot. Also written atomically to the
app's own data dir (temp file + os.replace) so a reader never sees a half-written file.

NOTE: we deliberately do NOT write into the widget's App Group container. This (non-member,
py2app/ad-hoc) process reaching into another app's container is what triggered the recurring
macOS "WHOOP would like to access data from other apps" prompt — and that grant can't persist
for a Python subprocess. Instead the widget fetches /api/snapshot from the local dashboard, so
the engine never touches the widget's container.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

from . import config, store


def build_snapshot() -> dict:
    latest = store.latest_stats()
    rec = latest.get("recovery") or {}
    slp = latest.get("sleep") or {}
    strn = latest.get("strain") or {}
    prof = latest.get("profile") or {}
    food = store.food_summary()  # today's intake/goal/net
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "last_sync": store.get_state("last_sync"),
        "name": (prof.get("first_name") or "").strip(),
        "recovery": {
            "score": rec.get("recovery_score"),
            "hrv_ms": _round(rec.get("hrv_rmssd_milli"), 1),
            "resting_hr": rec.get("resting_heart_rate"),
            "day": rec.get("day"),
        },
        "sleep": {
            "hours": slp.get("hours"),
            "performance": _round(slp.get("performance"), 0),
            "efficiency": _round(slp.get("efficiency"), 0),
            "day": slp.get("day"),
        },
        "strain": {
            "value": _round(strn.get("strain"), 1),
            "avg_hr": strn.get("average_heart_rate"),
            "calories": strn.get("calories"),
            "day": strn.get("day"),
        },
        "nutrition": {
            "calories": _round(food.get("calories"), 0),
            "protein_g": _round(food.get("protein_g"), 0),
            "carbs_g": _round(food.get("carbs_g"), 0),
            "fat_g": _round(food.get("fat_g"), 0),
            "burned": food.get("burned"),
            "net": _round(food.get("net"), 0),
            "goal": _round(food.get("goal"), 0),
            "remaining": _round(food.get("remaining"), 0),
            "day": food.get("day"),
        },
    }


def _round(v, ndigits):
    if v is None:
        return None
    return round(v, ndigits) if ndigits else round(v)


def _write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")  # the .app runs under an ASCII locale
    os.replace(tmp, path)


def write_snapshot() -> dict:
    """Write the snapshot to the app's own data dir only. The widget reads it over the
    API (/api/snapshot), not from a shared container, so the engine never touches the
    widget's App Group container (see the module docstring)."""
    snap = build_snapshot()
    _write_atomic(config.SNAPSHOT_PATH, json.dumps(snap, indent=2))
    return snap
