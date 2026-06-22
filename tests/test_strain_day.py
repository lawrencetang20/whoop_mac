"""Regression test for day-strain attribution.

WHOOP cycles run wake-to-wake, so the CURRENT (in-progress) cycle often starts late the
prior evening and therefore shares a `local_day` with the previous cycle. Day strain must be
attributed to the WAKE day (the cycle's recovery's sleep day) — exactly like recovery — so:
  * today's in-progress strain is never dropped because two cycles collide on one local_day, and
  * the strain series stays in step with the recovery series (no "recovery shows today but
    strain shows yesterday" mismatch).

This pins the behavior fixed in store.strain_series / _strain_for_cycle / latest_stats /
summary_stats. Run standalone:

    .venv/bin/python -m unittest tests.test_strain_day
"""

import os
import tempfile
import unittest
import warnings

warnings.simplefilter("ignore", ResourceWarning)
# Isolated throwaway DB so real WHOOP data is never touched (config reads this at import).
os.environ.setdefault("WHOOP_DATA_DIR", tempfile.mkdtemp(prefix="whoop-strain-test-"))

from whoop_dashboard import store  # noqa: E402

TZ = "-04:00"  # America/New_York-ish; 02:32Z lands at 22:32 the prior evening (local_day -1)


def _cycle(cid, start, strain, kj=9000.0):
    return {"id": cid, "user_id": 1, "start": start, "end": None, "timezone_offset": TZ,
            "score_state": "SCORED",
            "score": {"strain": strain, "kilojoule": kj,
                      "average_heart_rate": 60, "max_heart_rate": 160}}


def _sleep(sid, cid, end):
    # A sleep is attributed to the morning it ENDED (your wake day).
    return {"id": sid, "cycle_id": cid, "user_id": 1, "start": end, "end": end,
            "timezone_offset": TZ, "nap": False, "score_state": "SCORED",
            "score": {"stage_summary": {"total_light_sleep_time_milli": 1,
                                        "total_slow_wave_sleep_time_milli": 1,
                                        "total_rem_sleep_time_milli": 1},
                      "sleep_performance_percentage": 90}}


def _recovery(cid, sid, score):
    return {"cycle_id": cid, "sleep_id": sid, "user_id": 1,
            "created_at": "2026-06-22T11:00:00.000Z", "updated_at": "2026-06-22T11:00:00.000Z",
            "score_state": "SCORED",
            "score": {"recovery_score": score, "resting_heart_rate": 50, "hrv_rmssd_milli": 60}}


class StrainDayAttribution(unittest.TestCase):
    def setUp(self):
        store.init_db()
        with store._conn() as c:
            for t in ("cycles", "recoveries", "sleeps"):
                c.execute(f"DELETE FROM {t}")
        # Previous cycle: started early 06-21 -> local_day 06-21; woke 06-21.
        store.upsert_cycles([_cycle(2, "2026-06-21T05:19:22.000Z", 14.5)])
        store.upsert_sleeps([_sleep(20, 2, "2026-06-21T11:00:00.000Z")])
        store.upsert_recoveries([_recovery(2, 20, 73)])
        # CURRENT cycle: started 06-21 ~22:32 local -> local_day 06-21 (SAME as previous!),
        # but its recovery's sleep ended on 06-22 -> wake day 06-22. This is the collision.
        store.upsert_cycles([_cycle(1, "2026-06-22T02:32:55.000Z", 11.5)])
        store.upsert_sleeps([_sleep(10, 1, "2026-06-22T11:00:00.000Z")])
        store.upsert_recoveries([_recovery(1, 10, 65)])

    def tearDown(self):
        with store._conn() as c:
            for t in ("cycles", "recoveries", "sleeps"):
                c.execute(f"DELETE FROM {t}")

    def test_scenario_reproduces_the_collision(self):
        # Sanity: both cycles really do land on one local_day (the bug's precondition).
        with store._conn() as c:
            days = [r[0] for r in c.execute("SELECT local_day FROM cycles ORDER BY id")]
        self.assertEqual(days, ["2026-06-21", "2026-06-21"])

    def test_todays_strain_present_on_the_wake_day(self):
        s = {p["day"]: p["strain"] for p in store.strain_series("2026-06-19", "2026-06-22")}
        self.assertIn("2026-06-22", s, "today's in-progress cycle strain must surface on the wake day")
        self.assertAlmostEqual(s["2026-06-22"], 11.5, places=1)
        self.assertAlmostEqual(s["2026-06-21"], 14.5, places=1)

    def test_strain_days_align_with_recovery_days(self):
        sdays = {p["day"] for p in store.strain_series("2026-06-19", "2026-06-22")}
        rdays = {p["day"] for p in store.recovery_series("2026-06-19", "2026-06-22")}
        self.assertEqual(sdays, rdays, "strain and recovery must use the same (wake) days")

    def test_latest_pairs_strain_and_recovery_on_the_same_day(self):
        d = store.latest_stats()
        self.assertEqual(d["day"], "2026-06-22")
        self.assertEqual((d["strain"] or {}).get("day"), "2026-06-22")
        self.assertAlmostEqual((d["strain"] or {}).get("strain"), 11.5, places=1)
        self.assertEqual((d.get("strain_prev") or {}).get("day"), "2026-06-21")

    def test_summary_average_includes_both_cycles(self):
        # avg over the two days = (14.5 + 11.5) / 2; if a cycle were dropped it'd be just 14.5.
        sm = store.summary_stats("2026-06-19", "2026-06-22")
        self.assertAlmostEqual(sm["avg_strain"], 13.0, places=1)


if __name__ == "__main__":
    unittest.main()
