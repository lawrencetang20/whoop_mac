"""Write a compact JSON snapshot of the latest stats.

This file is what the phase-2 native WidgetKit widget reads. It's written
atomically (temp file + os.replace) so a reader never sees a half-written file.
Set WHOOP_GROUP_SNAPSHOT_PATH to also mirror it into the widget's App Group container.
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


def _auto_group_paths() -> list:
    """Auto-detect the widget's App Group container(s), wherever the Team-ID prefix
    landed, so the native widget gets data with zero manual path configuration."""
    import glob
    base = Path.home() / "Library" / "Group Containers"
    return [Path(d) / "latest.json"
            for d in glob.glob(str(base / "*group.com.lawrencetang.whoop"))]


def write_snapshot() -> dict:
    snap = build_snapshot()
    text = json.dumps(snap, indent=2)
    _write_atomic(config.SNAPSHOT_PATH, text)
    targets = []
    if config.GROUP_SNAPSHOT_PATH is not None:
        targets.append(config.GROUP_SNAPSHOT_PATH)
    targets.extend(_auto_group_paths())  # App Group container, once the widget exists
    for path in targets:
        try:
            _write_atomic(path, text)
        except OSError:
            pass
    return snap
