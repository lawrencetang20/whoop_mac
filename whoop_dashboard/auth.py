"""WHOOP OAuth 2.0 (Authorization Code flow) for a local desktop app.

Flow:
  1. Open the system browser to WHOOP's authorize URL.
  2. Run a one-shot localhost HTTP server to catch the ?code=... redirect.
  3. Exchange the code for access + refresh tokens; persist them.
  4. get_access_token() transparently refreshes when expired.

WHOOP rotates refresh tokens: every refresh returns a NEW refresh_token and
invalidates the old one, so we always persist whatever comes back.
"""

from __future__ import annotations

import http.server
import json
import os
import secrets
import threading
import time
import urllib.parse
import webbrowser
from typing import Optional

import httpx

from . import config

_refresh_lock = threading.Lock()

# Refresh this many seconds before the token actually expires, to avoid races.
_EXPIRY_SKEW = 90


class AuthError(RuntimeError):
    pass


# --- Token persistence -----------------------------------------------------

def _load_tokens() -> Optional[dict]:
    if not config.TOKEN_PATH.exists():
        return None
    try:
        return json.loads(config.TOKEN_PATH.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def _save_tokens(tok: dict) -> None:
    # Compute an absolute expiry from expires_in (read it; never hardcode 3600).
    if "expires_in" in tok:
        tok["expires_at"] = int(time.time()) + int(tok["expires_in"])
    data = json.dumps(tok, indent=2)
    # Create with 0600 from the start so the secret is never briefly world-readable.
    fd = os.open(config.TOKEN_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(data)
    try:
        os.chmod(config.TOKEN_PATH, 0o600)  # tighten if the file pre-existed with looser perms
    except OSError:
        pass


def is_authorized() -> bool:
    tok = _load_tokens()
    return bool(tok and tok.get("refresh_token"))


def logout() -> None:
    """Forget local tokens (does not revoke server-side; use revoke() for that)."""
    try:
        config.TOKEN_PATH.unlink()
    except FileNotFoundError:
        pass


# --- Authorization (interactive, run on a worker thread) -------------------

class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    server_version = "WhoopDashboard/0.1"
    result: dict = {}

    def do_GET(self):  # noqa: N802 (http.server API)
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        _CallbackHandler.result = {
            "code": params.get("code", [None])[0],
            "state": params.get("state", [None])[0],
            "error": params.get("error", [None])[0],
            "error_description": params.get("error_description", [None])[0],
        }
        ok = bool(_CallbackHandler.result["code"])
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        body = _RESULT_PAGE_OK if ok else _RESULT_PAGE_ERR
        self.wfile.write(body.encode("utf-8"))

    def log_message(self, *args):  # silence default stderr logging
        pass


def authorize(open_browser: bool = True, timeout: int = 300) -> dict:
    """Run the full interactive OAuth flow. Blocks until the user finishes in the
    browser (or `timeout` seconds elapse). Saves tokens and returns them.

    Raises AuthError on any failure. Intended to run on a background thread.
    """
    if not config.credentials_present():
        raise AuthError(
            "Missing WHOOP_CLIENT_ID / WHOOP_CLIENT_SECRET. Copy .env.example to .env "
            "and fill them in from your WHOOP developer app."
        )

    state = secrets.token_urlsafe(24)  # >= 8 chars as WHOOP requires
    auth_params = urllib.parse.urlencode({
        "response_type": "code",
        "client_id": config.CLIENT_ID,
        "redirect_uri": config.REDIRECT_URI,
        "scope": " ".join(config.SCOPES),
        "state": state,
    })
    auth_url = f"{config.AUTH_URL}?{auth_params}"

    _CallbackHandler.result = {}
    try:
        server = http.server.HTTPServer(("127.0.0.1", config.OAUTH_CALLBACK_PORT), _CallbackHandler)
    except OSError as e:
        raise AuthError(
            f"Could not bind localhost:{config.OAUTH_CALLBACK_PORT} for the OAuth redirect "
            f"({e}). Is another instance running, or is the port in use?"
        )
    server.timeout = timeout

    if open_browser:
        webbrowser.open(auth_url)
    else:
        print(f"Open this URL to authorize:\n{auth_url}")

    # Serve exactly one request (the redirect), then stop. handle_request honours
    # server.timeout and returns even if nothing arrives.
    server.handle_request()
    server.server_close()

    res = _CallbackHandler.result
    if not res:
        raise AuthError("Timed out waiting for the WHOOP authorization redirect.")
    if res.get("error"):
        raise AuthError(f"WHOOP denied authorization: {res['error']} — {res.get('error_description')}")
    if not res.get("code"):
        raise AuthError("No authorization code received from WHOOP.")
    if res.get("state") != state:
        raise AuthError("OAuth state mismatch — aborting (possible CSRF).")

    tok = _exchange_code(res["code"])
    _save_tokens(tok)
    return tok


def _exchange_code(code: str) -> dict:
    data = {
        "grant_type": "authorization_code",
        "code": code,
        "client_id": config.CLIENT_ID,
        "client_secret": config.CLIENT_SECRET,
        "redirect_uri": config.REDIRECT_URI,
    }
    resp = httpx.post(config.TOKEN_URL, data=data, timeout=30)
    if resp.status_code != 200:
        raise AuthError(f"Token exchange failed ({resp.status_code}): {resp.text[:300]}")
    return resp.json()


# --- Refresh + access-token access -----------------------------------------

def _refresh(tok: dict) -> dict:
    refresh_token = tok.get("refresh_token")
    if not refresh_token:
        raise AuthError("No refresh token stored — please reconnect WHOOP.")
    data = {
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": config.CLIENT_ID,
        "client_secret": config.CLIENT_SECRET,
        # Resend the full granted scope list (incl. offline). Sending only "offline"
        # would narrow the new access token and 401 every data call afterwards.
        "scope": " ".join(config.SCOPES),
    }
    resp = httpx.post(config.TOKEN_URL, data=data, timeout=30)
    if resp.status_code != 200:
        raise AuthError(
            f"Token refresh failed ({resp.status_code}): {resp.text[:300]}. "
            "You may need to reconnect WHOOP."
        )
    new = resp.json()
    # Rotation: keep the new refresh_token; fall back to the old only if absent.
    if not new.get("refresh_token"):
        new["refresh_token"] = refresh_token
    _save_tokens(new)
    return new


def get_access_token() -> str:
    """Return a currently-valid access token, refreshing if needed. Thread-safe."""
    tok = _load_tokens()
    if not tok:
        raise AuthError("Not connected to WHOOP. Run the connect flow first.")

    if int(time.time()) < tok.get("expires_at", 0) - _EXPIRY_SKEW:
        return tok["access_token"]

    # Expired (or near). Serialize refreshes so two threads don't both rotate.
    with _refresh_lock:
        tok = _load_tokens()  # re-read; another thread may have refreshed already
        if tok and int(time.time()) < tok.get("expires_at", 0) - _EXPIRY_SKEW:
            return tok["access_token"]
        tok = _refresh(tok)
        return tok["access_token"]


def refresh_now() -> str:
    """Force a token refresh regardless of expiry (used when the API returns 401)."""
    with _refresh_lock:
        tok = _load_tokens()
        if not tok:
            raise AuthError("Not connected to WHOOP.")
        tok = _refresh(tok)
        return tok["access_token"]


def revoke() -> None:
    """Revoke access server-side (DELETE /v2/user/access), then forget local tokens."""
    try:
        token = get_access_token()
        httpx.delete(
            f"{config.API_BASE}/user/access",
            headers={"Authorization": f"Bearer {token}"},
            timeout=30,
        )
    except Exception:
        pass
    logout()


_RESULT_PAGE_OK = """<!doctype html><html><head><meta charset="utf-8">
<title>WHOOP connected</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;background:#0b0b0c;color:#e7e7ea;
display:flex;height:100vh;align-items:center;justify-content:center;margin:0}
.card{text-align:center}.ok{color:#34d399;font-size:42px}</style></head>
<body><div class="card"><div class="ok">✓</div>
<h2>WHOOP connected</h2><p>You can close this tab and return to the app.</p></div></body></html>"""

_RESULT_PAGE_ERR = """<!doctype html><html><head><meta charset="utf-8">
<title>WHOOP authorization failed</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;background:#0b0b0c;color:#e7e7ea;
display:flex;height:100vh;align-items:center;justify-content:center;margin:0}
.card{text-align:center}.err{color:#f87171;font-size:42px}</style></head>
<body><div class="card"><div class="err">✕</div>
<h2>Authorization failed</h2><p>Return to the app and try connecting again.</p></div></body></html>"""
