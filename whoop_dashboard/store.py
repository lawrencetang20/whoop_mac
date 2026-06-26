"""Local SQLite store for WHOOP data.

Design notes:
- One row per durable record id (cycle id / recovery cycle_id / sleep uuid / workout uuid).
  Upserts are idempotent so re-syncing simply refreshes rows (e.g. when a record moves
  from PENDING_SCORE to SCORED).
- We keep both extracted columns (for fast querying/charts) AND the raw JSON blob (so we
  never lose a field the UI doesn't use yet).
- A `local_day` column (the user's local calendar date) is computed at ingest from each
  record's own timezone_offset, so per-day grouping matches lived days, not UTC.
- Every operation opens its own short-lived connection -> safe to call from the menu-bar
  thread, the sync worker thread, and the dashboard server thread concurrently. WAL mode
  lets readers and the writer coexist.
"""

from __future__ import annotations

import json
import re
import sqlite3
from contextlib import contextmanager
from datetime import date, datetime
from typing import Iterable, Optional

from . import config
from .util import dig, local_day, parse_iso

# kJ -> kcal
KJ_TO_KCAL = 0.239006


@contextmanager
def _conn():
    con = sqlite3.connect(config.DB_PATH, timeout=30)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL;")
    con.execute("PRAGMA foreign_keys=ON;")
    try:
        yield con
        con.commit()
    finally:
        con.close()


def init_db() -> None:
    """Create tables and indexes if they don't exist."""
    with _conn() as con:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS cycles (
                id                  INTEGER PRIMARY KEY,
                user_id             INTEGER,
                start               TEXT,
                "end"               TEXT,
                timezone_offset     TEXT,
                local_day           TEXT,
                score_state         TEXT,
                strain              REAL,
                kilojoule           REAL,
                average_heart_rate  INTEGER,
                max_heart_rate      INTEGER,
                updated_at          TEXT,
                raw                 TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_cycles_day ON cycles(local_day);

            CREATE TABLE IF NOT EXISTS recoveries (
                cycle_id            INTEGER PRIMARY KEY,
                sleep_id            TEXT,
                user_id             INTEGER,
                created_at          TEXT,
                updated_at          TEXT,
                score_state         TEXT,
                user_calibrating    INTEGER,
                recovery_score      INTEGER,
                resting_heart_rate  INTEGER,
                hrv_rmssd_milli     REAL,
                spo2_percentage     REAL,
                skin_temp_celsius   REAL,
                raw                 TEXT
            );

            CREATE TABLE IF NOT EXISTS sleeps (
                id                              TEXT PRIMARY KEY,
                cycle_id                        INTEGER,
                user_id                         INTEGER,
                start                           TEXT,
                "end"                           TEXT,
                timezone_offset                 TEXT,
                local_day                       TEXT,
                nap                             INTEGER,
                score_state                     TEXT,
                total_in_bed_time_milli         INTEGER,
                total_awake_time_milli          INTEGER,
                total_light_sleep_time_milli    INTEGER,
                total_slow_wave_sleep_time_milli INTEGER,
                total_rem_sleep_time_milli      INTEGER,
                total_sleep_time_milli          INTEGER,
                sleep_cycle_count               INTEGER,
                disturbance_count               INTEGER,
                respiratory_rate                REAL,
                sleep_performance_percentage    REAL,
                sleep_consistency_percentage    REAL,
                sleep_efficiency_percentage     REAL,
                sleep_needed_baseline_milli     INTEGER,
                sleep_needed_total_milli        INTEGER,
                raw                             TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_sleeps_day ON sleeps(local_day);

            CREATE TABLE IF NOT EXISTS workouts (
                id                  TEXT PRIMARY KEY,
                user_id             INTEGER,
                start               TEXT,
                "end"               TEXT,
                timezone_offset     TEXT,
                local_day           TEXT,
                sport_name          TEXT,
                score_state         TEXT,
                strain              REAL,
                average_heart_rate  INTEGER,
                max_heart_rate      INTEGER,
                kilojoule           REAL,
                percent_recorded    REAL,
                distance_meter      REAL,
                altitude_gain_meter REAL,
                raw                 TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_workouts_day ON workouts(local_day);

            CREATE TABLE IF NOT EXISTS profile (
                id               INTEGER PRIMARY KEY CHECK (id = 1),
                user_id          INTEGER,
                email            TEXT,
                first_name       TEXT,
                last_name        TEXT,
                height_meter     REAL,
                weight_kilogram  REAL,
                max_heart_rate   INTEGER
            );

            CREATE TABLE IF NOT EXISTS sync_state (
                key   TEXT PRIMARY KEY,
                value TEXT
            );

            -- Food you eat (calories IN), to pair with WHOOP's calories OUT. Unlike the
            -- WHOOP tables this is user-authored, so the id is a local autoincrement.
            CREATE TABLE IF NOT EXISTS food_log (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                local_day   TEXT NOT NULL,
                eaten_at    TEXT,
                name        TEXT NOT NULL,
                serving     TEXT,
                calories    REAL,
                protein_g   REAL,
                carbs_g     REAL,
                fat_g       REAL,
                source      TEXT,
                raw         TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_food_day ON food_log(local_day);
            """
        )
        # Lightweight migrations for columns added after the first release.
        sleep_cols = {r["name"] for r in con.execute("PRAGMA table_info(sleeps)")}
        if "sleep_needed_total_milli" not in sleep_cols:
            con.execute("ALTER TABLE sleeps ADD COLUMN sleep_needed_total_milli INTEGER")


# --- Upserts ---------------------------------------------------------------

def upsert_cycles(records: Iterable[dict]) -> int:
    rows = []
    for r in records:
        rows.append((
            r.get("id"),
            r.get("user_id"),
            r.get("start"),
            r.get("end"),
            r.get("timezone_offset"),
            local_day(r.get("start"), r.get("timezone_offset")),
            r.get("score_state"),
            dig(r, "score", "strain"),
            dig(r, "score", "kilojoule"),
            dig(r, "score", "average_heart_rate"),
            dig(r, "score", "max_heart_rate"),
            r.get("updated_at"),
            json.dumps(r),
        ))
    with _conn() as con:
        con.executemany(
            """INSERT INTO cycles
               (id,user_id,start,"end",timezone_offset,local_day,score_state,
                strain,kilojoule,average_heart_rate,max_heart_rate,updated_at,raw)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET
                 user_id=excluded.user_id, start=excluded.start, "end"=excluded."end",
                 timezone_offset=excluded.timezone_offset, local_day=excluded.local_day,
                 score_state=excluded.score_state, strain=excluded.strain,
                 kilojoule=excluded.kilojoule, average_heart_rate=excluded.average_heart_rate,
                 max_heart_rate=excluded.max_heart_rate, updated_at=excluded.updated_at,
                 raw=excluded.raw""",
            rows,
        )
    return len(rows)


def upsert_recoveries(records: Iterable[dict]) -> int:
    rows = []
    for r in records:
        rows.append((
            r.get("cycle_id"),
            r.get("sleep_id"),
            r.get("user_id"),
            r.get("created_at"),
            r.get("updated_at"),
            r.get("score_state"),
            1 if dig(r, "score", "user_calibrating") else 0,
            dig(r, "score", "recovery_score"),
            dig(r, "score", "resting_heart_rate"),
            dig(r, "score", "hrv_rmssd_milli"),
            dig(r, "score", "spo2_percentage"),
            dig(r, "score", "skin_temp_celsius"),
            json.dumps(r),
        ))
    with _conn() as con:
        con.executemany(
            """INSERT INTO recoveries
               (cycle_id,sleep_id,user_id,created_at,updated_at,score_state,
                user_calibrating,recovery_score,resting_heart_rate,hrv_rmssd_milli,
                spo2_percentage,skin_temp_celsius,raw)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(cycle_id) DO UPDATE SET
                 sleep_id=excluded.sleep_id, user_id=excluded.user_id,
                 created_at=excluded.created_at, updated_at=excluded.updated_at,
                 score_state=excluded.score_state, user_calibrating=excluded.user_calibrating,
                 recovery_score=excluded.recovery_score,
                 resting_heart_rate=excluded.resting_heart_rate,
                 hrv_rmssd_milli=excluded.hrv_rmssd_milli,
                 spo2_percentage=excluded.spo2_percentage,
                 skin_temp_celsius=excluded.skin_temp_celsius, raw=excluded.raw""",
            rows,
        )
    return len(rows)


def upsert_sleeps(records: Iterable[dict]) -> int:
    rows = []
    for r in records:
        light = dig(r, "score", "stage_summary", "total_light_sleep_time_milli", default=0)
        deep = dig(r, "score", "stage_summary", "total_slow_wave_sleep_time_milli", default=0)
        rem = dig(r, "score", "stage_summary", "total_rem_sleep_time_milli", default=0)
        total_sleep = (light or 0) + (deep or 0) + (rem or 0)
        # We attribute a sleep to the local day it ENDED on (the morning you woke up),
        # which is how WHOOP frames "last night's sleep" for today.
        day = local_day(r.get("end"), r.get("timezone_offset"))
        # WHOOP total sleep need = baseline + sleep-debt + recent-strain + recent-nap
        # (the nap term can be negative). We persist both baseline and the true total.
        base = dig(r, "score", "sleep_needed", "baseline_milli")
        total_need = None
        if base is not None:
            total_need = (
                base
                + (dig(r, "score", "sleep_needed", "need_from_sleep_debt_milli", default=0) or 0)
                + (dig(r, "score", "sleep_needed", "need_from_recent_strain_milli", default=0) or 0)
                + (dig(r, "score", "sleep_needed", "need_from_recent_nap_milli", default=0) or 0)
            )
        rows.append((
            r.get("id"),
            r.get("cycle_id"),
            r.get("user_id"),
            r.get("start"),
            r.get("end"),
            r.get("timezone_offset"),
            day,
            1 if r.get("nap") else 0,
            r.get("score_state"),
            dig(r, "score", "stage_summary", "total_in_bed_time_milli"),
            dig(r, "score", "stage_summary", "total_awake_time_milli"),
            light,
            deep,
            rem,
            total_sleep if r.get("score_state") == "SCORED" else None,
            dig(r, "score", "stage_summary", "sleep_cycle_count"),
            dig(r, "score", "stage_summary", "disturbance_count"),
            dig(r, "score", "respiratory_rate"),
            dig(r, "score", "sleep_performance_percentage"),
            dig(r, "score", "sleep_consistency_percentage"),
            dig(r, "score", "sleep_efficiency_percentage"),
            base,
            total_need,
            json.dumps(r),
        ))
    with _conn() as con:
        con.executemany(
            """INSERT INTO sleeps
               (id,cycle_id,user_id,start,"end",timezone_offset,local_day,nap,score_state,
                total_in_bed_time_milli,total_awake_time_milli,total_light_sleep_time_milli,
                total_slow_wave_sleep_time_milli,total_rem_sleep_time_milli,total_sleep_time_milli,
                sleep_cycle_count,disturbance_count,respiratory_rate,sleep_performance_percentage,
                sleep_consistency_percentage,sleep_efficiency_percentage,sleep_needed_baseline_milli,
                sleep_needed_total_milli,raw)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET
                 cycle_id=excluded.cycle_id, user_id=excluded.user_id, start=excluded.start,
                 "end"=excluded."end", timezone_offset=excluded.timezone_offset,
                 local_day=excluded.local_day, nap=excluded.nap, score_state=excluded.score_state,
                 total_in_bed_time_milli=excluded.total_in_bed_time_milli,
                 total_awake_time_milli=excluded.total_awake_time_milli,
                 total_light_sleep_time_milli=excluded.total_light_sleep_time_milli,
                 total_slow_wave_sleep_time_milli=excluded.total_slow_wave_sleep_time_milli,
                 total_rem_sleep_time_milli=excluded.total_rem_sleep_time_milli,
                 total_sleep_time_milli=excluded.total_sleep_time_milli,
                 sleep_cycle_count=excluded.sleep_cycle_count,
                 disturbance_count=excluded.disturbance_count,
                 respiratory_rate=excluded.respiratory_rate,
                 sleep_performance_percentage=excluded.sleep_performance_percentage,
                 sleep_consistency_percentage=excluded.sleep_consistency_percentage,
                 sleep_efficiency_percentage=excluded.sleep_efficiency_percentage,
                 sleep_needed_baseline_milli=excluded.sleep_needed_baseline_milli,
                 sleep_needed_total_milli=excluded.sleep_needed_total_milli, raw=excluded.raw""",
            rows,
        )
    return len(rows)


def upsert_workouts(records: Iterable[dict]) -> int:
    rows = []
    for r in records:
        rows.append((
            r.get("id"),
            r.get("user_id"),
            r.get("start"),
            r.get("end"),
            r.get("timezone_offset"),
            local_day(r.get("start"), r.get("timezone_offset")),
            r.get("sport_name"),
            r.get("score_state"),
            dig(r, "score", "strain"),
            dig(r, "score", "average_heart_rate"),
            dig(r, "score", "max_heart_rate"),
            dig(r, "score", "kilojoule"),
            dig(r, "score", "percent_recorded"),
            dig(r, "score", "distance_meter"),
            dig(r, "score", "altitude_gain_meter"),
            json.dumps(r),
        ))
    with _conn() as con:
        con.executemany(
            """INSERT INTO workouts
               (id,user_id,start,"end",timezone_offset,local_day,sport_name,score_state,
                strain,average_heart_rate,max_heart_rate,kilojoule,percent_recorded,
                distance_meter,altitude_gain_meter,raw)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET
                 user_id=excluded.user_id, start=excluded.start, "end"=excluded."end",
                 timezone_offset=excluded.timezone_offset, local_day=excluded.local_day,
                 sport_name=excluded.sport_name, score_state=excluded.score_state,
                 strain=excluded.strain, average_heart_rate=excluded.average_heart_rate,
                 max_heart_rate=excluded.max_heart_rate, kilojoule=excluded.kilojoule,
                 percent_recorded=excluded.percent_recorded, distance_meter=excluded.distance_meter,
                 altitude_gain_meter=excluded.altitude_gain_meter, raw=excluded.raw""",
            rows,
        )
    return len(rows)


def upsert_profile(profile: dict, body: Optional[dict]) -> None:
    body = body or {}
    with _conn() as con:
        con.execute(
            """INSERT INTO profile
               (id,user_id,email,first_name,last_name,height_meter,weight_kilogram,max_heart_rate)
               VALUES (1,?,?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET
                 user_id=excluded.user_id, email=excluded.email, first_name=excluded.first_name,
                 last_name=excluded.last_name, height_meter=excluded.height_meter,
                 weight_kilogram=excluded.weight_kilogram, max_heart_rate=excluded.max_heart_rate""",
            (
                profile.get("user_id"),
                profile.get("email"),
                profile.get("first_name"),
                profile.get("last_name"),
                body.get("height_meter"),
                body.get("weight_kilogram"),
                body.get("max_heart_rate"),
            ),
        )


# --- sync_state ------------------------------------------------------------

def get_state(key: str, default: Optional[str] = None) -> Optional[str]:
    with _conn() as con:
        row = con.execute("SELECT value FROM sync_state WHERE key=?", (key,)).fetchone()
    return row["value"] if row else default


def set_state(key: str, value: str) -> None:
    with _conn() as con:
        con.execute(
            "INSERT INTO sync_state(key,value) VALUES(?,?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )


def counts() -> dict:
    with _conn() as con:
        out = {}
        for t in ("cycles", "recoveries", "sleeps", "workouts"):
            out[t] = con.execute(f"SELECT COUNT(*) AS n FROM {t}").fetchone()["n"]
        # Distinct calendar days (cycles are wake-to-wake, not 1:1 with days).
        out["days"] = con.execute(
            "SELECT COUNT(DISTINCT local_day) AS n FROM cycles"
        ).fetchone()["n"]
        out["food"] = con.execute("SELECT COUNT(*) AS n FROM food_log").fetchone()["n"]
    return out


# --- Queries for the dashboard / menu bar ----------------------------------

def _rows(sql: str, params=()) -> list[dict]:
    with _conn() as con:
        return [dict(r) for r in con.execute(sql, params).fetchall()]


def recovery_series(start: str, end: str) -> list[dict]:
    """Recovery metrics per local day.

    A recovery is attributed to the day you WOKE UP (its sleep's local_day), falling
    back to the cycle day if the sleep is missing. This matches how you think about
    days and avoids gaps on days where no physiological cycle happened to start
    (WHOOP cycles are wake-to-wake and don't map 1:1 to calendar days). One row per
    day; if a day somehow has two recoveries, the one from the main (non-nap) sleep wins.
    """
    return _rows(
        """
        SELECT day, recovery_score, hrv_rmssd_milli, resting_heart_rate,
               spo2_percentage, skin_temp_celsius
        FROM (
            SELECT COALESCE(s.local_day, c.local_day) AS day,
                   r.recovery_score, r.hrv_rmssd_milli, r.resting_heart_rate,
                   r.spo2_percentage, r.skin_temp_celsius,
                   ROW_NUMBER() OVER (
                       PARTITION BY COALESCE(s.local_day, c.local_day)
                       ORDER BY (CASE WHEN s.nap = 0 THEN 0 ELSE 1 END), r.updated_at DESC
                   ) AS rn
            FROM recoveries r
            LEFT JOIN sleeps s ON s.id = r.sleep_id
            LEFT JOIN cycles c ON c.id = r.cycle_id
            WHERE r.score_state = 'SCORED'
        )
        WHERE rn = 1 AND day BETWEEN ? AND ?
        ORDER BY day
        """,
        (start, end),
    )


def strain_series(start: str, end: str) -> list[dict]:
    """Day strain / heart rate / calories per local day from cycles.

    A cycle's strain is attributed to the day you WOKE UP during it (its recovery's sleep
    local_day), matching recovery_series. The current wake-to-wake cycle often starts late
    the prior evening, so its own local_day trails the day you'd call "today" by one — using
    the wake day puts today's in-progress strain on today (and avoids two cycles colliding on
    one local_day, which previously hid it). Falls back to the cycle's own local_day when
    there's no recovery/sleep link. One representative (highest-strain) cycle per day.
    """
    return _rows(
        """
        SELECT day, strain, average_heart_rate, max_heart_rate, calories
        FROM (
            SELECT COALESCE(s.local_day, c.local_day) AS day,
                   c.strain, c.average_heart_rate, c.max_heart_rate,
                   ROUND(c.kilojoule * ?, 0) AS calories,
                   ROW_NUMBER() OVER (
                       PARTITION BY COALESCE(s.local_day, c.local_day) ORDER BY c.strain DESC
                   ) AS rn
            FROM cycles c
            LEFT JOIN recoveries r ON r.cycle_id = c.id
            LEFT JOIN sleeps s ON s.id = r.sleep_id
            WHERE c.score_state = 'SCORED'
        )
        WHERE rn = 1 AND day BETWEEN ? AND ?
        ORDER BY day
        """,
        (KJ_TO_KCAL, start, end),
    )


def sleep_series(start: str, end: str) -> list[dict]:
    """Main (non-nap) sleep per local day. Aggregated in case of multiple records."""
    return _rows(
        """
        SELECT local_day AS day,
               ROUND(SUM(total_sleep_time_milli) / 3600000.0, 2) AS hours,
               ROUND(AVG(sleep_needed_total_milli) / 3600000.0, 2) AS need_hours,
               ROUND(SUM(total_in_bed_time_milli) / 3600000.0, 2) AS in_bed_hours,
               ROUND(SUM(total_rem_sleep_time_milli) / 3600000.0, 2) AS rem_hours,
               ROUND(SUM(total_slow_wave_sleep_time_milli) / 3600000.0, 2) AS deep_hours,
               ROUND(SUM(total_light_sleep_time_milli) / 3600000.0, 2) AS light_hours,
               ROUND(SUM(total_awake_time_milli) / 3600000.0, 2) AS awake_hours,
               AVG(sleep_performance_percentage) AS performance,
               AVG(sleep_efficiency_percentage)  AS efficiency,
               AVG(sleep_consistency_percentage) AS consistency,
               AVG(respiratory_rate)             AS respiratory_rate,
               SUM(disturbance_count)            AS disturbances
        FROM sleeps
        WHERE nap = 0 AND score_state = 'SCORED' AND local_day BETWEEN ? AND ?
        GROUP BY local_day
        ORDER BY local_day
        """,
        (start, end),
    )


def naps_list(start: str, end: str) -> list[dict]:
    """Naps (nap = 1) per local day — kept separate from the main night sleep, which all the
    other sleep queries (nap = 0) intentionally exclude. A day can have more than one."""
    return _rows(
        """
        SELECT local_day AS day, start, "end" AS end,
               ROUND(total_sleep_time_milli / 3600000.0, 2) AS hours,
               sleep_performance_percentage AS performance
        FROM sleeps
        WHERE nap = 1 AND score_state = 'SCORED' AND local_day BETWEEN ? AND ?
        ORDER BY local_day, start
        """,
        (start, end),
    )


def workouts_list(start: str, end: str) -> list[dict]:
    return _rows(
        """
        SELECT id, local_day AS day, start, "end" AS end, sport_name, strain,
               average_heart_rate, max_heart_rate,
               ROUND(kilojoule * ?, 0) AS calories,
               ROUND(distance_meter, 0) AS distance_meter
        FROM workouts
        WHERE score_state = 'SCORED' AND local_day BETWEEN ? AND ?
        ORDER BY start DESC
        """,
        (KJ_TO_KCAL, start, end),
    )


def sport_breakdown(start: str, end: str) -> list[dict]:
    """Per-sport rollup over a date range (for the dashboard activities view)."""
    return _rows(
        """
        SELECT COALESCE(sport_name, 'unknown') AS sport_name,
               COUNT(*) AS count,
               ROUND(SUM(strain), 1) AS total_strain,
               ROUND(AVG(strain), 1) AS avg_strain,
               ROUND(AVG(average_heart_rate), 0) AS avg_hr,
               ROUND(SUM(kilojoule) * ?, 0) AS calories
        FROM workouts
        WHERE score_state = 'SCORED' AND local_day BETWEEN ? AND ?
        GROUP BY sport_name
        ORDER BY count DESC
        """,
        (KJ_TO_KCAL, start, end),
    )


def _with_minutes(rows: list[dict]) -> list[dict]:
    for r in rows:
        s, e = parse_iso(r["start"]), parse_iso(r["end"])
        r["minutes"] = round((e - s).total_seconds() / 60) if s and e else None
    return rows


_WORKOUT_COLS = """
    local_day AS day, start, "end" AS end, sport_name, strain,
    average_heart_rate, max_heart_rate,
    ROUND(kilojoule * ?, 0) AS calories,
    ROUND(distance_meter, 0) AS distance_meter
"""


def workouts_on_day(day: Optional[str]) -> list[dict]:
    """All workouts that occurred on a given local day (for the menu-bar list)."""
    if not day:
        return []
    return _with_minutes(_rows(
        f"SELECT {_WORKOUT_COLS} FROM workouts "
        "WHERE score_state = 'SCORED' AND local_day = ? ORDER BY start DESC",
        (KJ_TO_KCAL, day),
    ))


def recent_workouts(limit: int = 10) -> list[dict]:
    """The most recent N workouts (used by the dashboard)."""
    return _with_minutes(_rows(
        f"SELECT {_WORKOUT_COLS} FROM workouts "
        "WHERE score_state = 'SCORED' ORDER BY start DESC LIMIT ?",
        (KJ_TO_KCAL, limit),
    ))


def profile() -> Optional[dict]:
    rows = _rows("SELECT * FROM profile WHERE id = 1")
    return rows[0] if rows else None


def _strain_for_cycle(cycle_id) -> list:
    """Day-strain card for a specific cycle id — the one physiologically paired with a
    recovery. Used instead of a calendar-day match because the current wake-to-wake cycle
    often starts late the prior evening, so its local_day can trail the recovery's (sleep)
    day by one; matching by cycle keeps strain in step with the recovery/sleep shown and
    surfaces today's in-progress strain (including workouts)."""
    if cycle_id is None:
        return []
    return _rows(
        """
        SELECT COALESCE(s.local_day, c.local_day) AS day, c.strain,
               c.average_heart_rate, c.max_heart_rate, ROUND(c.kilojoule * ?, 0) AS calories
        FROM cycles c
        LEFT JOIN recoveries r ON r.cycle_id = c.id
        LEFT JOIN sleeps s ON s.id = r.sleep_id
        WHERE c.id = ? AND c.score_state = 'SCORED'
        """,
        (KJ_TO_KCAL, cycle_id),
    )


def latest_stats() -> dict:
    """Most recent values for the menu bar + widget snapshot. Fetches the two most
    recent recoveries so callers can show a day-over-day trend."""
    rec = _rows(
        """
        SELECT COALESCE(s.local_day, c.local_day) AS day, r.cycle_id AS cycle_id, r.recovery_score,
               r.hrv_rmssd_milli, r.resting_heart_rate, r.spo2_percentage, r.skin_temp_celsius
        FROM recoveries r
        LEFT JOIN sleeps s ON s.id = r.sleep_id
        LEFT JOIN cycles c ON c.id = r.cycle_id
        WHERE r.score_state = 'SCORED'
        ORDER BY COALESCE(s.local_day, c.local_day) DESC LIMIT 2
        """
    )
    # The "current day" is the most recent day that has a SCORED recovery; everything
    # shown (recovery, sleep, strain, activities) is scoped to this one day so the cards
    # never mix days. A bare cycle with no recovery yet won't pull the view forward.
    ref_day = rec[0]["day"] if rec else None
    if ref_day is None:
        fb = _rows(
            """
            SELECT day FROM (
                SELECT local_day AS day, "end" AS t FROM sleeps WHERE nap = 0 AND score_state = 'SCORED'
                UNION ALL
                SELECT local_day AS day, start AS t FROM cycles WHERE score_state = 'SCORED'
            ) ORDER BY t DESC LIMIT 1
            """
        )
        ref_day = fb[0]["day"] if fb else None

    sleep = _rows(
        """
        SELECT local_day AS day,
               ROUND(SUM(total_sleep_time_milli) / 3600000.0, 2) AS hours,
               ROUND(AVG(sleep_needed_total_milli) / 3600000.0, 2) AS need_hours,
               ROUND(SUM(total_rem_sleep_time_milli) / 3600000.0, 2) AS rem_hours,
               ROUND(SUM(total_slow_wave_sleep_time_milli) / 3600000.0, 2) AS deep_hours,
               ROUND(SUM(total_light_sleep_time_milli) / 3600000.0, 2) AS light_hours,
               ROUND(SUM(total_awake_time_milli) / 3600000.0, 2) AS awake_hours,
               AVG(sleep_performance_percentage) AS performance,
               AVG(sleep_efficiency_percentage) AS efficiency,
               AVG(respiratory_rate) AS respiratory_rate
        FROM sleeps
        WHERE nap = 0 AND score_state = 'SCORED' AND local_day = ?
        GROUP BY local_day
        """,
        (ref_day,),
    )
    # Pair Day Strain with the recovery's own cycle; fall back to a calendar-day match
    # only if that recovery has no cycle link (older data).
    strain = _strain_for_cycle(rec[0]["cycle_id"] if rec else None) or _rows(
        """
        SELECT local_day AS day, strain, average_heart_rate, max_heart_rate,
               ROUND(kilojoule * ?, 0) AS calories
        FROM cycles
        WHERE score_state = 'SCORED' AND local_day = ?
        ORDER BY strain DESC LIMIT 1
        """,
        (KJ_TO_KCAL, ref_day),
    )
    # Previous-day sleep/strain, so callers can show a day-over-day trend (vs. yesterday)
    # rather than vs. a range average. recovery_prev is the second row of `rec` above.
    sleep_prev = _rows(
        """
        SELECT local_day AS day,
               ROUND(SUM(total_sleep_time_milli) / 3600000.0, 2) AS hours,
               AVG(sleep_performance_percentage) AS performance
        FROM sleeps
        WHERE nap = 0 AND score_state = 'SCORED' AND local_day < ?
        GROUP BY local_day
        ORDER BY local_day DESC LIMIT 1
        """,
        (ref_day,),
    )
    # Previous day's strain = the cycle paired with the previous recovery (rec[1]); fall
    # back to the most recent cycle strictly before ref_day if that link is missing.
    strain_prev = _strain_for_cycle(rec[1]["cycle_id"] if len(rec) > 1 else None) or _rows(
        """
        SELECT local_day AS day, strain
        FROM cycles
        WHERE score_state = 'SCORED' AND local_day < ?
        ORDER BY local_day DESC, strain DESC LIMIT 1
        """,
        (ref_day,),
    )
    return {
        "day": ref_day,
        "recovery": rec[0] if rec else None,
        "recovery_prev": rec[1] if len(rec) > 1 else None,
        "sleep": sleep[0] if sleep else None,
        "sleep_prev": sleep_prev[0] if sleep_prev else None,
        "strain": strain[0] if strain else None,
        "strain_prev": strain_prev[0] if strain_prev else None,
        "day_workouts": workouts_on_day(ref_day),
        "profile": profile(),
    }


def summary_stats(start: str, end: str) -> dict:
    """Aggregate statistics over a date range for the 'Stats' view."""
    rec = _rows(
        """
        SELECT ROUND(AVG(recovery_score), 0) AS avg_recovery,
               MAX(recovery_score) AS max_recovery,
               MIN(recovery_score) AS min_recovery,
               ROUND(AVG(hrv_rmssd_milli), 1) AS avg_hrv,
               ROUND(AVG(resting_heart_rate), 0) AS avg_rhr,
               COUNT(*) AS days
        FROM (
            SELECT COALESCE(s.local_day, c.local_day) AS day, r.recovery_score,
                   r.hrv_rmssd_milli, r.resting_heart_rate,
                   ROW_NUMBER() OVER (
                       PARTITION BY COALESCE(s.local_day, c.local_day)
                       ORDER BY (CASE WHEN s.nap = 0 THEN 0 ELSE 1 END), r.updated_at DESC
                   ) AS rn
            FROM recoveries r
            LEFT JOIN sleeps s ON s.id = r.sleep_id
            LEFT JOIN cycles c ON c.id = r.cycle_id
            WHERE r.score_state = 'SCORED'
        )
        WHERE rn = 1 AND day BETWEEN ? AND ?
        """,
        (start, end),
    )
    slp = _rows(
        """
        SELECT ROUND(AVG(total_sleep_time_milli) / 3600000.0, 2) AS avg_sleep_hours,
               ROUND(AVG(sleep_performance_percentage), 0) AS avg_sleep_performance,
               ROUND(AVG(sleep_efficiency_percentage), 0) AS avg_sleep_efficiency
        FROM sleeps
        WHERE nap = 0 AND score_state = 'SCORED' AND local_day BETWEEN ? AND ?
        """,
        (start, end),
    )
    strn = _rows(
        """
        SELECT ROUND(AVG(strain), 1) AS avg_strain, MAX(strain) AS max_strain
        FROM (
            SELECT c.strain AS strain, COALESCE(s.local_day, c.local_day) AS day,
                   ROW_NUMBER() OVER (
                       PARTITION BY COALESCE(s.local_day, c.local_day) ORDER BY c.strain DESC
                   ) AS rn
            FROM cycles c
            LEFT JOIN recoveries r ON r.cycle_id = c.id
            LEFT JOIN sleeps s ON s.id = r.sleep_id
            WHERE c.score_state = 'SCORED'
        )
        WHERE rn = 1 AND day BETWEEN ? AND ?
        """,
        (start, end),
    )
    wko = _rows(
        """
        SELECT COUNT(*) AS workout_count,
               ROUND(SUM(strain), 1) AS total_workout_strain,
               ROUND(SUM(kilojoule) * ?, 0) AS total_calories
        FROM workouts
        WHERE score_state = 'SCORED' AND local_day BETWEEN ? AND ?
        """,
        (KJ_TO_KCAL, start, end),
    )
    return {
        **(rec[0] if rec else {}),
        **(slp[0] if slp else {}),
        **(strn[0] if strn else {}),
        **(wko[0] if wko else {}),
        "start": start,
        "end": end,
    }


# --- Food log (calories IN) ------------------------------------------------

def _today() -> str:
    return date.today().isoformat()


def add_food(
    name: str,
    *,
    calories: Optional[float] = None,
    protein_g: Optional[float] = None,
    carbs_g: Optional[float] = None,
    fat_g: Optional[float] = None,
    serving: Optional[str] = None,
    day: Optional[str] = None,
    source: str = "manual",
    raw: Optional[dict] = None,
) -> dict:
    """Insert one food entry and return the stored row (with its new id)."""
    day = day or _today()
    eaten_at = datetime.now().astimezone().isoformat(timespec="seconds")
    with _conn() as con:
        cur = con.execute(
            """INSERT INTO food_log
               (local_day,eaten_at,name,serving,calories,protein_g,carbs_g,fat_g,source,raw)
               VALUES (?,?,?,?,?,?,?,?,?,?)""",
            (day, eaten_at, name, serving, calories, protein_g, carbs_g, fat_g, source,
             json.dumps(raw) if raw is not None else None),
        )
        food_id = cur.lastrowid
    rows = _rows("SELECT * FROM food_log WHERE id = ?", (food_id,))
    return rows[0] if rows else {}


def delete_food(food_id: int) -> bool:
    with _conn() as con:
        cur = con.execute("DELETE FROM food_log WHERE id = ?", (food_id,))
        return cur.rowcount > 0


def _foods_conn():
    """Connection to the separate foods.sqlite3 reference DB (whole + branded foods)."""
    con = sqlite3.connect(config.FOODS_DB_PATH)
    con.row_factory = sqlite3.Row
    return con


def food_db_count() -> int:
    """Number of foods in the local reference DB (0 if it hasn't been built yet)."""
    try:
        with _foods_conn() as con:
            row = con.execute("SELECT COUNT(*) AS n FROM foods").fetchone()
            return row["n"] if row else 0
    except sqlite3.OperationalError:
        return 0


_FOOD_WORD = re.compile(r"[a-z0-9]+")


def _pretty(s):
    """Title-case names USDA stores in ALL CAPS (branded products, e.g. 'MISSION, CARB
    BALANCE'); leave already-mixed-case whole-food names ('Apples, raw') untouched."""
    if not s or any(c.islower() for c in s):
        return s
    return re.sub(r"[A-Za-z][A-Za-z']*", lambda m: m.group(0).capitalize(), s)


def search_foods(query: str, limit: int = 20) -> list[dict]:
    """Full-text search the local foods DB (whole + branded). Each query word becomes a
    prefix term, AND-combined — so 'mission carb tortilla' finds the Mission Carb Balance
    tortilla. Ranked by FTS5 bm25 (name weighted above brand). Returns per-100 g macros."""
    words = _FOOD_WORD.findall((query or "").lower())
    if not words:
        return []
    match = " ".join(w + "*" for w in words)
    limit = min(max(limit, 1), 50)
    try:
        with _foods_conn() as con:
            # Curated whole foods (USDA SR Legacy) rank first, so a generic query like
            # 'apple' returns "Apples, raw" rather than a branded applesauce; brand-specific
            # queries ('mission carb tortilla') have no whole-food match and surface branded.
            rows = con.execute(
                """
                SELECT f.fdc_id, f.name, f.brand, f.kcal_100g, f.protein_100g,
                       f.carb_100g, f.fat_100g, f.serving_g, f.serving_text, f.is_whole
                FROM foods_fts ft JOIN foods f ON f.fdc_id = ft.rowid
                WHERE foods_fts MATCH ?
                ORDER BY f.is_whole DESC, bm25(foods_fts, 5.0, 2.0), length(f.name)
                LIMIT ?
                """,
                (match, max(limit * 6, 200)),  # candidate pool floor so re-rank sees the best
            ).fetchall()
    except sqlite3.OperationalError:
        return []  # foods.sqlite3 not built yet

    # Float foods whose LEAD word EXACTLY matches a query word (or its plural) — so 'apple'
    # gives "Apples, raw" (lead 'apples'), not "Applebee's" or "Eggnog"; and 'oreo' gives the
    # branded OREO products (lead 'oreo') over an SR-Legacy "McFlurry with Oreo". Then prefer
    # curated whole foods, then shorter names. sorted() is stable, so SQL bm25 breaks ties.
    forms = set(words)
    for w in words:
        forms.add(w + "s")
        if w.endswith("s") and len(w) > 3:
            forms.add(w[:-1])

    def rank(r):
        toks = _FOOD_WORD.findall((r["name"] or "").lower())
        lead = 0 if (toks and toks[0] in forms) else 1
        return (lead, 0 if r["is_whole"] else 1, len(r["name"] or ""))

    out, seen = [], set()
    for r in sorted(rows, key=rank):
        key = ((r["name"] or "").lower(), (r["brand"] or "").lower())
        if key in seen:
            continue
        seen.add(key)
        d = dict(r); d.pop("is_whole", None)
        d["name"] = _pretty(d["name"])      # tidy ALL-CAPS branded names for display
        d["brand"] = _pretty(d["brand"])
        out.append(d)
        if len(out) >= limit:
            break
    return out


def food_on_day(day: Optional[str] = None) -> list[dict]:
    """Every food entry for a local day, newest first (for the log list)."""
    day = day or _today()
    return _rows(
        """SELECT id, local_day AS day, eaten_at, name, serving,
                  calories, protein_g, carbs_g, fat_g, source
           FROM food_log WHERE local_day = ? ORDER BY eaten_at DESC, id DESC""",
        (day,),
    )


def nutrition_series(start: str, end: str) -> list[dict]:
    """Per-day intake totals over a range (for trend charts + energy balance)."""
    return _rows(
        """SELECT local_day AS day,
                  ROUND(SUM(calories), 0)  AS calories,
                  ROUND(SUM(protein_g), 0) AS protein_g,
                  ROUND(SUM(carbs_g), 0)   AS carbs_g,
                  ROUND(SUM(fat_g), 0)     AS fat_g,
                  COUNT(*)                 AS items
           FROM food_log
           WHERE local_day BETWEEN ? AND ?
           GROUP BY local_day
           ORDER BY local_day""",
        (start, end),
    )


def burned_calories_for(day: Optional[str] = None) -> Optional[float]:
    """WHOOP calories burned for a local day (highest-energy cycle, any score state).

    Unlike the strain charts this does NOT require SCORED, so today's in-progress cycle
    still contributes a running estimate for the menu bar's net calculation."""
    day = day or _today()
    rows = _rows(
        """SELECT ROUND(MAX(kilojoule) * ?, 0) AS calories
           FROM cycles WHERE local_day = ? AND kilojoule IS NOT NULL""",
        (KJ_TO_KCAL, day),
    )
    return rows[0]["calories"] if rows and rows[0]["calories"] is not None else None


def get_calorie_goal() -> Optional[float]:
    """The user's daily calorie target, or None if unset."""
    v = get_state("calorie_goal")
    try:
        return float(v) if v not in (None, "") else None
    except (TypeError, ValueError):
        return None


def set_calorie_goal(calories: Optional[float]) -> None:
    """Set (or clear, with None) the daily calorie target."""
    set_state("calorie_goal", "" if calories is None else str(int(round(calories))))


def food_summary(day: Optional[str] = None) -> dict:
    """Intake totals + burned + net + goal/remaining for a day (menu bar, widget)."""
    day = day or _today()
    tot = _rows(
        """SELECT ROUND(SUM(calories), 0)  AS calories,
                  ROUND(SUM(protein_g), 0) AS protein_g,
                  ROUND(SUM(carbs_g), 0)   AS carbs_g,
                  ROUND(SUM(fat_g), 0)     AS fat_g,
                  COUNT(*)                 AS items
           FROM food_log WHERE local_day = ?""",
        (day,),
    )
    out = tot[0] if tot else {}
    burned = burned_calories_for(day)
    intake = out.get("calories")
    goal = get_calorie_goal()
    out["day"] = day
    out["burned"] = burned
    out["net"] = (intake - burned) if (intake is not None and burned is not None) else None
    out["goal"] = goal
    out["remaining"] = (goal - (intake or 0)) if goal is not None else None
    return out
