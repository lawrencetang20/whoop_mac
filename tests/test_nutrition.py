"""Tests for the nutrition / calorie-tracking feature.

Run from the project root with no extra dependencies:

    .venv/bin/python -m unittest tests.test_nutrition

Uses an isolated throwaway database (WHOOP_DATA_DIR) so your real WHOOP data and
tokens are never touched, and FastAPI's in-process TestClient (no server/port needed).
"""

import datetime
import os
import sqlite3
import tempfile
import unittest
import warnings

# Harness-only GC noise: the app closes every connection deterministically via the
# store._conn() context manager, but TestClient's thread-pool can GC short-lived
# connections after the request returns. Not an app leak.
warnings.simplefilter("ignore", ResourceWarning)

# Configure an isolated DB + a dashboard token BEFORE importing the app, because
# whoop_dashboard.config reads these at import time.
os.environ["WHOOP_DATA_DIR"] = tempfile.mkdtemp(prefix="whoop-test-")
os.environ["DASHBOARD_TOKEN"] = "testtoken"
os.environ.pop("NUTRITIONIX_APP_ID", None)
os.environ.pop("NUTRITIONIX_APP_KEY", None)

from fastapi.testclient import TestClient  # noqa: E402
from whoop_dashboard import config, dashboard, snapshot, store  # noqa: E402

# Mutating routes refresh the widget snapshot, which normally also mirrors into the
# real App Group container globbed from $HOME. Neutralize that mirror so tests can
# never overwrite the actual widget's latest.json (they still write the temp copy).
snapshot._auto_group_paths = lambda: []

TODAY = datetime.date.today().isoformat()


def local_client() -> TestClient:
    """A client whose peer address is 127.0.0.1, so it bypasses the token gate
    exactly like the Mac's own browser does. base_url uses an allowed host so the
    TrustedHost (DNS-rebinding) middleware doesn't reject it."""
    return TestClient(dashboard.app, base_url="http://127.0.0.1", client=("127.0.0.1", 5000))


class NutritionTests(unittest.TestCase):
    def setUp(self):
        store.init_db()
        with sqlite3.connect(config.DB_PATH) as con:  # clean slate per test
            con.execute("DELETE FROM food_log")
            con.execute("DELETE FROM cycles")
            con.execute("DELETE FROM sync_state")
            con.commit()
        self.c = local_client()

    def _seed_cycle(self, kilojoule=11000):
        with sqlite3.connect(config.DB_PATH) as con:
            con.execute(
                "INSERT INTO cycles (id,user_id,local_day,score_state,strain,kilojoule) "
                "VALUES (1,1,?,'SCORED',12.0,?)", (TODAY, kilojoule))
            con.commit()

    def test_add_and_summary(self):
        r = self.c.post("/api/food", json={"name": "Banana", "calories": 105, "protein_g": 1.3})
        self.assertEqual(r.status_code, 200)
        n = self.c.get("/api/nutrition").json()
        self.assertEqual(n["summary"]["calories"], 105)
        self.assertEqual(len(n["items"]), 1)

    def test_bulk_add(self):
        r = self.c.post("/api/food", json={"items": [
            {"name": "Eggs", "calories": 140}, {"name": "Toast", "calories": 80}]})
        self.assertEqual(len(r.json()["saved"]), 2)
        self.assertEqual(self.c.get("/api/nutrition").json()["summary"]["calories"], 220)

    def test_rejects_empty_name(self):
        self.assertEqual(self.c.post("/api/food", json={"name": "  ", "calories": 100}).status_code, 400)

    def test_sanitizes_bad_input(self):
        # Non-numeric calories -> None; negative macro -> clamped to 0; long name -> capped.
        r = self.c.post("/api/food", json={"name": "X" * 500, "calories": "abc", "protein_g": -5})
        self.assertEqual(r.status_code, 200)
        item = self.c.get("/api/nutrition").json()["items"][0]
        self.assertIsNone(item["calories"])
        self.assertEqual(item["protein_g"], 0)
        self.assertLessEqual(len(item["name"]), 200)

    def test_delete(self):
        self.c.post("/api/food", json={"name": "Snack", "calories": 200})
        fid = self.c.get("/api/nutrition").json()["items"][0]["id"]
        self.assertTrue(self.c.delete(f"/api/food/{fid}").json()["deleted"])
        self.assertEqual(self.c.get("/api/nutrition").json()["summary"]["items"], 0)

    def test_energy_balance(self):
        self._seed_cycle(11000)
        self.c.post("/api/food", json={"name": "Day total", "calories": 2000})
        today = next(x for x in self.c.get("/api/energy").json() if x["day"] == TODAY)
        self.assertEqual(today["intake"], 2000)
        self.assertEqual(today["burned"], round(11000 * store.KJ_TO_KCAL))
        self.assertEqual(today["net"], today["intake"] - today["burned"])

    def test_goal_set_clear_invalid(self):
        self.assertEqual(self.c.post("/api/goal", json={"calories": 2200}).json()["summary"]["goal"], 2200)
        self.c.post("/api/food", json={"name": "Lunch", "calories": 700})
        self.assertEqual(self.c.get("/api/nutrition").json()["summary"]["remaining"], 1500)
        self.assertIsNone(self.c.post("/api/goal", json={"calories": None}).json()["summary"]["goal"])
        self.assertIsNone(self.c.post("/api/goal", json={"calories": 0}).json()["summary"]["goal"])
        self.assertEqual(self.c.post("/api/goal", json={"calories": "abc"}).status_code, 400)

    def test_snapshot_includes_nutrition(self):
        self._seed_cycle()
        self.c.post("/api/food", json={"name": "Meal", "calories": 600})
        self.c.post("/api/goal", json={"calories": 2200})
        snap = snapshot.build_snapshot()
        self.assertEqual(snap["nutrition"]["calories"], 600)
        self.assertEqual(snap["nutrition"]["goal"], 2200)

    def test_lookup_without_keys_is_graceful(self):
        r = self.c.post("/api/food/lookup", json={"query": "2 eggs"})
        self.assertEqual(r.status_code, 400)
        self.assertIn("Nutritionix", r.json()["error"])

    def test_index_renders_and_is_utf8(self):
        # The page has non-ASCII (em-dashes/arrows), so index() must decode UTF-8 —
        # under the .app's ASCII locale a bare read_text() would 500 the dashboard.
        raw = (dashboard.WEB_DIR / "index.html").read_bytes()
        self.assertRaises(UnicodeDecodeError, raw.decode, "ascii")  # genuinely has non-ASCII
        raw.decode("utf-8")  # ...and is valid UTF-8
        r = self.c.get("/")
        self.assertEqual(r.status_code, 200)
        self.assertIn('data-tab="strain"', r.text)  # the dashboard renders its tab nav
        self.assertIn("app.js?v=", r.text)  # cache-busting applied

    def test_token_gate(self):
        # Non-localhost peer (default client host) but an allowed Host header, so it reaches the
        # token gate instead of being rejected by TrustedHost — must present the token.
        remote = TestClient(dashboard.app, base_url="http://127.0.0.1")
        self.assertEqual(remote.get("/api/status").status_code, 401)
        self.assertEqual(remote.get("/api/status?token=wrong").status_code, 401)
        self.assertEqual(remote.get("/api/status?token=testtoken").status_code, 200)
        self.assertEqual(local_client().get("/api/status").status_code, 200)  # localhost never gated


if __name__ == "__main__":
    unittest.main()
