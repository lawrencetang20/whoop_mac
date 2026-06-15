"""Command-line entry point.

Usage:
  python -m whoop_dashboard            # launch the menu-bar app (default)
  python -m whoop_dashboard connect    # one-time: authorize WHOOP + backfill history
  python -m whoop_dashboard sync       # incremental sync (recent window)
  python -m whoop_dashboard backfill   # full history re-sync
  python -m whoop_dashboard dashboard  # run only the web dashboard (no menu bar)
  python -m whoop_dashboard serve      # headless engine: dashboard/API + auto-sync, no menu bar
  python -m whoop_dashboard status     # print counts + last sync
  python -m whoop_dashboard snapshot   # write the widget JSON snapshot and print it
  python -m whoop_dashboard logout     # forget local tokens
"""

from __future__ import annotations

import json
import sys

from . import auth, config, snapshot, store, sync


def _require_creds():
    if not config.credentials_present():
        print(
            "Missing WHOOP_CLIENT_ID / WHOOP_CLIENT_SECRET.\n"
            "Copy .env.example to .env and fill them in from https://developer-dashboard.whoop.com",
            file=sys.stderr,
        )
        sys.exit(1)


def cmd_connect():
    _require_creds()
    print("Opening your browser to authorize WHOOP…")
    auth.authorize()
    print("Authorized. Backfilling your full history (this can take a minute)…")
    result = sync.backfill(progress=lambda m: print(" ", m))
    print("Done:", json.dumps(result))


def cmd_sync():
    _require_creds()
    if not auth.is_authorized():
        print("Not connected. Run: python -m whoop_dashboard connect", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(sync.sync(progress=lambda m: print(" ", m)), indent=2))


def cmd_backfill():
    _require_creds()
    if not auth.is_authorized():
        print("Not connected. Run: python -m whoop_dashboard connect", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(sync.backfill(progress=lambda m: print(" ", m)), indent=2))


def cmd_dashboard():
    store.init_db()
    dashboard_thread = __import__("whoop_dashboard.dashboard", fromlist=["serve_in_thread"])
    dashboard_thread.serve_in_thread()
    print(f"Dashboard running at http://localhost:{config.DASHBOARD_PORT}  (Ctrl+C to stop)")
    try:
        import time
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


def cmd_serve():
    """Headless engine: serve the dashboard/API and auto-sync every 5 min, with no menu bar.
    Used when the native SwiftUI app owns the menu bar (MenuBarExtra popover)."""
    import time
    store.init_db()
    from . import dashboard
    dashboard.serve_in_thread(on_error=lambda m: print(m, file=sys.stderr))
    print(f"WHOOP engine serving http://localhost:{config.DASHBOARD_PORT} (headless)")

    def tick():
        if auth.is_authorized():
            try:
                sync.sync()
                snapshot.write_snapshot()
            except Exception as e:  # noqa: BLE001
                print(f"sync error: {e}", file=sys.stderr)

    tick()
    while True:
        time.sleep(300)
        tick()


def cmd_status():
    store.init_db()
    print(json.dumps({
        "authorized": auth.is_authorized(),
        "credentials_present": config.credentials_present(),
        "last_sync": store.get_state("last_sync"),
        "last_backfill": store.get_state("last_backfill"),
        "counts": store.counts(),
        "data_dir": str(config.DATA_DIR),
    }, indent=2))


def cmd_snapshot():
    store.init_db()
    print(json.dumps(snapshot.write_snapshot(), indent=2))


def cmd_logout():
    auth.logout()
    print("Local tokens removed.")


def cmd_menubar():
    from .menubar import main
    main()


def cmd_build_food_db():
    from . import fooddb
    store.init_db()
    n = fooddb.build(progress=lambda m: print(" ", m))
    print(f"Done — {n:,} common foods in the local database. Search works offline now.")


COMMANDS = {
    "connect": cmd_connect,
    "sync": cmd_sync,
    "backfill": cmd_backfill,
    "dashboard": cmd_dashboard,
    "serve": cmd_serve,
    "status": cmd_status,
    "snapshot": cmd_snapshot,
    "build-food-db": cmd_build_food_db,
    "logout": cmd_logout,
    "menubar": cmd_menubar,
    "run": cmd_menubar,
}


def main(argv=None):
    # Progress messages contain non-ASCII (…, —). Under a non-UTF-8 locale (LANG unset,
    # LC_ALL=C) stdout/stderr default to ASCII and print() would crash; force UTF-8.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    argv = argv if argv is not None else sys.argv[1:]
    cmd = argv[0] if argv else "menubar"
    fn = COMMANDS.get(cmd)
    if not fn:
        print(__doc__)
        sys.exit(2)
    fn()


if __name__ == "__main__":
    main()
