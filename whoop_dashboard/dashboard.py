"""Local dashboard: a FastAPI app serving one HTML page + JSON API routes.

The page (web/index.html) is static; all chart data is fetched from /api/* routes
that query the SQLite store. Runs on http://localhost:<DASHBOARD_PORT>.
"""

from __future__ import annotations

import hashlib
import hmac
import re
import threading
from datetime import date, timedelta

from fastapi import Body, FastAPI, Query, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from pathlib import Path

from . import auth, config, nutritionix, snapshot, store, sync

WEB_DIR = Path(__file__).resolve().parent / "web"

app = FastAPI(title="WHOOP Dashboard", docs_url=None, redoc_url=None)


def _asset_hash(name: str) -> str:
    """Short content hash of a web asset, used to cache-bust its URL. Recomputed
    per request (these files are tiny) so editing app.js/style.css instantly
    changes its ?v= and the browser fetches the new copy — never a stale cache."""
    try:
        return hashlib.sha256((WEB_DIR / name).read_bytes()).hexdigest()[:10]
    except OSError:
        return "0"


@app.middleware("http")
async def _gate(request: Request, call_next):
    """When DASHBOARD_TOKEN is set, require it for non-localhost (i.e. phone) requests.

    Your Mac's own browser and the menu bar hit 127.0.0.1 and are never challenged.
    A request from your phone must carry the token once (?token=…), after which a
    cookie keeps it authorized. Leave the token empty if you only reach the dashboard
    over a private Tailscale tailnet."""
    token = config.DASHBOARD_TOKEN
    host = request.client.host if request.client else ""
    if token and host not in ("127.0.0.1", "::1"):
        supplied = (request.query_params.get("token")
                    or request.headers.get("x-dashboard-token")
                    or request.cookies.get("wd_token"))
        if not supplied or not hmac.compare_digest(supplied, token):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        response = await call_next(request)
        if request.query_params.get("token") == token:
            response.set_cookie("wd_token", token, max_age=31_536_000,
                                httponly=True, samesite="lax")
        return response
    return await call_next(request)


@app.middleware("http")
async def _no_stale_assets(request: Request, call_next):
    """Make the browser revalidate static JS/CSS on every load (ETag → cheap 304s)
    so a changed asset is never served from a stale cache."""
    response = await call_next(request)
    if request.url.path.startswith("/static/"):
        response.headers["Cache-Control"] = "no-cache, must-revalidate"
    return response


def _range(days: int) -> tuple[str, str]:
    # Inclusive BETWEEN on both ends, so subtract days-1 to span exactly `days` days.
    end = date.today()
    start = end - timedelta(days=days - 1)
    return start.isoformat(), end.isoformat()


# --- request sanitizing (food entries come from a client form / JSON) -------
_DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _num(v, hi: float = 100_000.0):
    """Coerce a user-supplied value to a float in [0, hi], or None if absent/invalid.
    Rejects NaN/inf and negatives so bad input can't poison totals or charts."""
    if v is None or v == "":
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f != f or f in (float("inf"), float("-inf")):  # NaN / ±inf
        return None
    return max(0.0, min(hi, f))


def _clean_day(v):
    """Accept only a valid 'YYYY-MM-DD' string; anything else -> None (store uses today)."""
    if isinstance(v, str) and _DAY_RE.match(v):
        try:
            date.fromisoformat(v)
            return v
        except ValueError:
            return None
    return None


def _clean_text(v, limit: int):
    s = str(v).strip() if v is not None else ""
    return s[:limit] or None


def _touch_snapshot() -> None:
    """Rewrite latest.json so the native widget reflects food/goal changes without
    waiting for the next WHOOP sync. Best-effort — never fail the request over it."""
    try:
        snapshot.write_snapshot()
    except Exception:  # noqa: BLE001
        pass


@app.get("/")
def index():
    # Stamp the asset URLs with a content hash so the browser re-fetches app.js /
    # style.css whenever they change (otherwise it can run a stale cached copy).
    # The HTML itself is marked no-cache so a new build's hashes are always seen.
    # NB: read as UTF-8 explicitly — the .app bundle runs under an ASCII locale, so a
    # bare read_text() would UnicodeDecodeError on the page's “·/→” characters.
    html = (WEB_DIR / "index.html").read_text(encoding="utf-8")
    html = html.replace("/static/app.js", f"/static/app.js?v={_asset_hash('app.js')}")
    html = html.replace("/static/style.css", f"/static/style.css?v={_asset_hash('style.css')}")
    return HTMLResponse(html, headers={"Cache-Control": "no-cache, must-revalidate"})


@app.get("/api/status")
def status():
    return {
        "authorized": auth.is_authorized(),
        "credentials_present": config.credentials_present(),
        "last_sync": store.get_state("last_sync"),
        "last_backfill": store.get_state("last_backfill"),
        "counts": store.counts(),
        "profile": store.profile(),
        "nutritionix": config.nutritionix_configured(),
    }


@app.get("/api/latest")
def latest():
    return store.latest_stats()


@app.get("/api/snapshot")
def snapshot_json():
    """Compact widget snapshot (same JSON shape as latest.json). The native widget and
    app fetch THIS instead of reading a shared App Group file the engine writes into — so
    the engine never reaches into the widget's container (no macOS privacy prompt)."""
    return snapshot.build_snapshot()


@app.get("/api/summary")
def summary(days: int = Query(30, ge=1, le=3650)):
    start, end = _range(days)
    return store.summary_stats(start, end)


@app.get("/api/recovery")
def recovery(days: int = Query(90, ge=1, le=3650)):
    start, end = _range(days)
    return store.recovery_series(start, end)


@app.get("/api/sleep")
def sleep(days: int = Query(90, ge=1, le=3650)):
    start, end = _range(days)
    return store.sleep_series(start, end)


@app.get("/api/strain")
def strain(days: int = Query(90, ge=1, le=3650)):
    start, end = _range(days)
    return store.strain_series(start, end)


@app.get("/api/workouts")
def workouts(days: int = Query(90, ge=1, le=3650)):
    start, end = _range(days)
    return store.workouts_list(start, end)


@app.get("/api/sports")
def sports(days: int = Query(90, ge=1, le=3650)):
    start, end = _range(days)
    return store.sport_breakdown(start, end)


@app.post("/api/sync")
def trigger_sync():
    if not auth.is_authorized():
        return JSONResponse({"error": "not connected to WHOOP"}, status_code=409)
    result = sync.sync()  # sync.py serializes concurrent syncs internally
    if result.get("skipped"):
        return JSONResponse({"status": "already syncing"}, status_code=202)
    return {"status": "ok", "result": result}


# --- Nutrition (calories IN) -----------------------------------------------

@app.get("/api/nutrition")
def nutrition(days: int = Query(30, ge=1, le=3650), day: str | None = None):
    """Today's (or `day`'s) entries + summary, plus the daily-totals trend series."""
    start, end = _range(days)
    return {
        "summary": store.food_summary(day),
        "items": store.food_on_day(day),
        "series": store.nutrition_series(start, end),
        "nutritionix": config.nutritionix_configured(),
        "foods": store.food_db_count(),  # local common-foods DB size (0 = not built yet)
    }


@app.get("/api/food/search")
def food_search(q: str = "", limit: int = Query(20, ge=1, le=50)):
    """Search the local USDA common-foods DB (per-100 g macros). Works offline, no key —
    empty until built via `python -m whoop_dashboard build-food-db`."""
    return {"items": store.search_foods(q, limit), "count": store.food_db_count()}


@app.get("/api/energy")
def energy(days: int = Query(30, ge=1, le=3650)):
    """Per-day energy balance: calories IN (food) vs OUT (WHOOP) and the net."""
    start, end = _range(days)
    intake = {r["day"]: r["calories"] for r in store.nutrition_series(start, end)}
    burned = {r["day"]: r["calories"] for r in store.strain_series(start, end)}
    out = []
    for d in sorted(set(intake) | set(burned)):
        i, b = intake.get(d), burned.get(d)
        out.append({"day": d, "intake": i, "burned": b,
                    "net": (i - b) if (i is not None and b is not None) else None})
    return out


@app.post("/api/food/lookup")
def food_lookup(payload: dict = Body(...)):
    """Parse a plain-English phrase into food items (NOT saved yet) for confirmation."""
    query = _clean_text(payload.get("query"), 500) or ""
    try:
        items = nutritionix.lookup(query)
    except nutritionix.NutritionixError as e:
        return JSONResponse({"error": str(e)}, status_code=400)
    return {"items": items}


@app.post("/api/food")
def food_add(payload: dict = Body(...)):
    """Save one or more food entries. Accepts {items:[...]} or a single item dict.

    All numeric/text fields are sanitized here (this is user-supplied input) so a
    malformed value can't land in the database or skew the totals/charts."""
    day = _clean_day(payload.get("day"))
    raw_items = payload.get("items")
    items = raw_items if isinstance(raw_items, list) else [payload]
    saved = []
    for it in items:
        if not isinstance(it, dict):
            continue
        name = _clean_text(it.get("name"), 200)
        if not name:
            continue
        saved.append(store.add_food(
            name,
            calories=_num(it.get("calories")),
            protein_g=_num(it.get("protein_g"), hi=10_000),
            carbs_g=_num(it.get("carbs_g"), hi=10_000),
            fat_g=_num(it.get("fat_g"), hi=10_000),
            serving=_clean_text(it.get("serving"), 120),
            day=day or _clean_day(it.get("day")),
            source="nutritionix" if it.get("source") == "nutritionix" else "manual",
        ))
    if not saved:
        return JSONResponse({"error": "no valid food entries (name required)"}, status_code=400)
    _touch_snapshot()
    return {"saved": saved}


@app.delete("/api/food/{food_id}")
def food_delete(food_id: int):
    deleted = store.delete_food(food_id)
    if deleted:
        _touch_snapshot()
    return {"deleted": deleted}


@app.post("/api/goal")
def set_goal(payload: dict = Body(...)):
    """Set the daily calorie target. null / empty / zero / negative clears it."""
    cal = payload.get("calories")
    if cal in (None, ""):
        store.set_calorie_goal(None)
        _touch_snapshot()
        return {"summary": store.food_summary()}
    try:
        value = float(cal)
    except (TypeError, ValueError):
        return JSONResponse({"error": "calories must be a number"}, status_code=400)
    if value != value or value in (float("inf"), float("-inf")):
        return JSONResponse({"error": "calories must be a finite number"}, status_code=400)
    store.set_calorie_goal(value if value > 0 else None)
    _touch_snapshot()
    return {"summary": store.food_summary()}


# Static assets last so they don't shadow the API routes above.
app.mount("/static", StaticFiles(directory=WEB_DIR), name="static")


def serve_in_thread(port: int | None = None, on_error=None) -> threading.Thread | None:
    """Start uvicorn on a daemon thread so it coexists with the menu-bar run loop.

    If the port is already taken (e.g. a second instance), uvicorn would otherwise
    sys.exit() inside the daemon thread and die silently. We pre-check the port and
    also wrap server.run(), reporting any failure via on_error(message) so the caller
    can show it (rather than leaving the menu's dashboard links pointing at nothing).
    """
    import socket
    import uvicorn

    port = port or config.DASHBOARD_PORT

    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        already_listening = probe.connect_ex(("127.0.0.1", port)) == 0
    finally:
        probe.close()
    if already_listening:
        if on_error:
            on_error(f"Dashboard port {port} is already in use (another instance?)")
        return None

    server = uvicorn.Server(
        uvicorn.Config(app, host=config.DASHBOARD_HOST, port=port, log_level="warning")
    )

    def _run():
        try:
            server.run()
        except SystemExit:
            if on_error:
                on_error(f"Dashboard could not start on port {port}")
        except Exception as e:  # noqa: BLE001
            if on_error:
                on_error(f"Dashboard error: {e}")

    t = threading.Thread(target=_run, daemon=True, name="dashboard")
    t.start()
    return t
