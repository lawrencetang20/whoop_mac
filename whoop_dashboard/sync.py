"""Fetch WHOOP data into the local store.

Two modes:
- backfill():    pull the entire history (run once after connecting).
- sync_recent(): pull a recent window (run periodically / on demand). This also
                 re-fetches recent records so PENDING_SCORE rows become SCORED.

Records are upserted page-by-page as they stream in, so a mid-stream API failure
keeps everything fetched before it (idempotent ON CONFLICT upserts make this safe).
A backfill is only marked complete when all four data resources succeeded, so a
partial failure retries a full backfill next time instead of silently dropping to
the incremental window.

Volumes are small for a personal account (roughly one cycle/recovery/sleep per day),
so even a multi-year backfill is well under the 100/min, 10k/day limits.
"""

from __future__ import annotations

import threading
from datetime import datetime, timedelta, timezone
from typing import Callable, Optional

from . import snapshot, store
from .api import WhoopClient, WhoopAPIError

Progress = Optional[Callable[[str], None]]

# Single process-wide guard so the menu-bar timer and the dashboard "Sync now"
# button (different threads) can never run overlapping syncs against the API/DB.
_sync_lock = threading.Lock()

# (display name, API collection path, store upsert function)
_RESOURCES = (
    ("cycles", "/cycle", store.upsert_cycles),
    ("recoveries", "/recovery", store.upsert_recoveries),
    ("sleeps", "/activity/sleep", store.upsert_sleeps),
    ("workouts", "/activity/workout", store.upsert_workouts),
)
_BATCH = 200  # upsert in batches as pages arrive


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def _iso_days_ago(days: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days)).strftime(
        "%Y-%m-%dT%H:%M:%S.000Z"
    )


def _note(progress: Progress, msg: str) -> None:
    if progress:
        progress(msg)


def _sync(start: Optional[str], progress: Progress, polite_delay: float) -> dict:
    store.init_db()
    summary = {"cycles": 0, "recoveries": 0, "sleeps": 0, "workouts": 0,
               "errors": [], "failed": []}

    with WhoopClient(polite_delay=polite_delay) as client:
        # Profile + body are cheap single calls; failures here are non-fatal.
        try:
            _note(progress, "Syncing profile…")
            prof = client.profile()
            try:
                body = client.body_measurement()
            except WhoopAPIError:
                body = None
            store.upsert_profile(prof, body)
        except WhoopAPIError as e:
            summary["errors"].append(f"profile: {e}")

        for name, path, upsert in _RESOURCES:
            _note(progress, f"Syncing {name}…")
            batch: list = []
            count = 0
            try:
                for rec in client.paginate(path, start=start):
                    batch.append(rec)
                    if len(batch) >= _BATCH:
                        count += upsert(batch)
                        batch = []
                if batch:
                    count += upsert(batch)
                    batch = []
            except WhoopAPIError as e:
                # Persist whatever pages arrived before the failure, then record it.
                if batch:
                    try:
                        count += upsert(batch)
                    except Exception:
                        pass
                summary["errors"].append(f"{name}: {e}")
                summary["failed"].append(name)
            summary[name] = count

    store.set_state("last_sync", _now_iso())
    try:
        snapshot.write_snapshot()
    except Exception as e:  # snapshot must never break a sync
        summary["errors"].append(f"snapshot: {e}")
    return summary


def backfill(progress: Progress = None) -> dict:
    """Pull the full history (no start filter). Run once after connecting.
    Only marks the backfill complete if every data resource succeeded."""
    if not _sync_lock.acquire(blocking=False):
        _note(progress, "Already syncing…")
        return {"skipped": True, "reason": "already syncing"}
    try:
        summary = _sync(start=None, progress=progress, polite_delay=0.7)
        if not summary["failed"]:
            store.set_state("last_backfill", _now_iso())
            _note(progress, "Backfill complete.")
        else:
            _note(progress, f"Backfill incomplete — {', '.join(summary['failed'])} "
                            "failed; will retry next run.")
        return summary
    finally:
        _sync_lock.release()


def sync_recent(days: int = 14, progress: Progress = None) -> dict:
    """Pull the last `days` days. Cheap; safe to run on a timer."""
    if not _sync_lock.acquire(blocking=False):
        _note(progress, "Already syncing…")
        return {"skipped": True, "reason": "already syncing"}
    try:
        summary = _sync(start=_iso_days_ago(days), progress=progress, polite_delay=0.0)
        _note(progress, "Sync complete.")
        return summary
    finally:
        _sync_lock.release()


def sync(progress: Progress = None) -> dict:
    """Smart sync: full backfill until one fully succeeds, then incremental windows."""
    if store.get_state("last_backfill"):
        return sync_recent(progress=progress)
    return backfill(progress=progress)
