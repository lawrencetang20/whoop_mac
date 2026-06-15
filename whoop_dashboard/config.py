"""Central configuration: endpoints, file paths, OAuth scopes, env loading.

All persistent local state (database, OAuth tokens, widget snapshot) lives under
~/Library/Application Support/WhoopDashboard/ so it survives app restarts and is
isolated from the source tree.
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

# Load .env from the project root (one directory up from this file).
PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env")

# --- WHOOP API v2 endpoints (v1 was retired in 2025) -----------------------
WHOOP_HOST = "https://api.prod.whoop.com"
AUTH_URL = f"{WHOOP_HOST}/oauth/oauth2/auth"
TOKEN_URL = f"{WHOOP_HOST}/oauth/oauth2/token"
API_BASE = f"{WHOOP_HOST}/developer/v2"

APP_NAME = "WhoopDashboard"
USER_AGENT = "WhoopDashboard/0.1 (local personal app)"

# OAuth scopes requested. "offline" is required to receive a refresh token so the
# app can keep syncing without you re-logging in.
SCOPES = [
    "read:recovery",
    "read:sleep",
    "read:workout",
    "read:cycles",
    "read:profile",
    "read:body_measurement",
    "offline",
]

# --- Credentials (from .env / environment) ---------------------------------
CLIENT_ID = os.getenv("WHOOP_CLIENT_ID", "")
CLIENT_SECRET = os.getenv("WHOOP_CLIENT_SECRET", "")
REDIRECT_URI = os.getenv("WHOOP_REDIRECT_URI", "http://localhost:8755/callback")
DASHBOARD_PORT = int(os.getenv("DASHBOARD_PORT", "8756"))

# Interface the dashboard binds to. Default 127.0.0.1 keeps it Mac-only. Set to
# 0.0.0.0 to also reach it from your phone over your Tailscale tailnet (or LAN).
DASHBOARD_HOST = os.getenv("DASHBOARD_HOST", "127.0.0.1")

# Optional shared secret required for NON-localhost requests (i.e. from your phone).
# Leave empty if you only reach the dashboard over a private Tailscale tailnet;
# set it if you bind to 0.0.0.0 on a shared Wi-Fi so others on the network can't read
# your health data. Localhost (your Mac's own browser + menu bar) never needs it.
DASHBOARD_TOKEN = os.getenv("DASHBOARD_TOKEN", "").strip()

# --- Nutritionix (food calorie/macro lookup) -------------------------------
# Free key from https://www.nutritionix.com/business/api — lets you log food in plain
# English ("2 eggs and toast") and have calories + macros filled in automatically.
# Optional: manual calorie entry works without it.
NUTRITIONIX_APP_ID = os.getenv("NUTRITIONIX_APP_ID", "").strip()
NUTRITIONIX_APP_KEY = os.getenv("NUTRITIONIX_APP_KEY", "").strip()

# Port the temporary local OAuth redirect-catcher listens on. Derived from the
# redirect URI so the two never drift apart.
def _redirect_port() -> int:
    try:
        return int(REDIRECT_URI.rsplit(":", 1)[1].split("/")[0])
    except (IndexError, ValueError):
        return 8755


OAUTH_CALLBACK_PORT = _redirect_port()

# --- Local state paths -----------------------------------------------------
DATA_DIR = Path(
    os.getenv(
        "WHOOP_DATA_DIR",
        Path.home() / "Library" / "Application Support" / "WhoopDashboard",
    )
)
DATA_DIR.mkdir(parents=True, exist_ok=True)
try:
    os.chmod(DATA_DIR, 0o700)  # this dir holds OAuth tokens + your health data
except OSError:
    pass

DB_PATH = DATA_DIR / "whoop.sqlite3"
TOKEN_PATH = DATA_DIR / "tokens.json"
# Small JSON snapshot of the latest stats, consumed by the native WidgetKit widget.
SNAPSHOT_PATH = DATA_DIR / "latest.json"

# Optional second snapshot location. For the phase-2 native widget, set this to the
# App Group container path (e.g. ~/Library/Group Containers/<TEAMID>.group.com.you.whoop/latest.json)
# so the widget can read it. Left unset until the widget is built.
_group_snap = os.getenv("WHOOP_GROUP_SNAPSHOT_PATH", "").strip()
GROUP_SNAPSHOT_PATH = Path(_group_snap) if _group_snap else None


def credentials_present() -> bool:
    """True once the user has filled in their WHOOP developer app credentials."""
    return bool(CLIENT_ID and CLIENT_SECRET)


def nutritionix_configured() -> bool:
    """True once Nutritionix API keys are present (enables natural-language food logging)."""
    return bool(NUTRITIONIX_APP_ID and NUTRITIONIX_APP_KEY)
