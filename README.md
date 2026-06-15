# WHOOP Dashboard — a local Mac app for your WHOOP data

Read your own WHOOP data, store it **locally** on your Mac (SQLite), and see it as:

- a real **menu-bar app** (`/Applications/WHOOP.app`) — recovery always visible, with expandable,
  clickable **Recovery / Sleep / Strain / Activities** sub-sections that deep-link into the dashboard;
- a comprehensive **local dashboard** (opens in your browser) — a tabbed app with a recovery ring,
  full history, trends, a recovery calendar, sport breakdown, and stats;
- *(phase 2)* a **native desktop / Notification Center widget** — see [`widget/README.md`](widget/README.md).

Your data and tokens never leave your machine. The app talks only to WHOOP's official API.

---

## What you'll see

**Menu bar:** a recovery-zone heart + today's recovery %. The dropdown has expandable sub-sections —
**Recovery** (HRV, resting HR, blood oxygen, skin temp), **Sleep** (performance, efficiency, stages,
respiratory, sleep need), **Strain** (avg/max HR, calories), and **Activities** (that day's workouts).
Clicking any section opens the matching dashboard view.

**Dashboard** (tabbed):
- **Overview** — recovery ring, sleep, day strain, and averages over the selected range.
- **Recovery** — recovery %, HRV, resting HR trends, and a GitHub-style recovery calendar.
- **Sleep** — stages (deep/REM/light/awake), performance & efficiency, sleep need vs actual, respiratory rate.
- **Strain** — day strain and calories.
- **Nutrition** — log what you eat (calories + macros) and see **energy balance**: calories in vs WHOOP's calories out, with a daily net.
- **Activities** — per-sport breakdown, strain-by-sport, and the full workouts table.

Range selector covers **7 days → all time**.

---

## Setup (about 10 minutes, one time)

### Prerequisites
- An active **WHOOP membership** (any plan with the app).
- **Python 3.11+** (you have 3.13). macOS.

### Step 1 — Register a WHOOP developer app (gets you API access)
WHOOP requires a registered app to authorize access to your own data. It's free and quick.

1. Go to **https://developer-dashboard.whoop.com** and sign in with your WHOOP account.
2. Create a **Team** if prompted (any name).
3. Create a new **App** with:
   - **Name:** anything, e.g. `My Dashboard`.
   - **Redirect URI:** exactly
     ```
     http://localhost:8755/callback
     ```
   - **Scopes:** check `read:recovery`, `read:sleep`, `read:workout`, `read:cycles`,
     `read:profile`, `read:body_measurement`, and `offline`.
4. Save. Copy the **Client ID** and **Client Secret**.

> The redirect URI must match **character-for-character**. If you change the port, change it in
> both the dashboard and your `.env` (`WHOOP_REDIRECT_URI`).

### Step 2 — Install
```bash
cd ~/Desktop/whoop
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

cp .env.example .env
# open .env and paste your WHOOP_CLIENT_ID and WHOOP_CLIENT_SECRET
```

### Step 3 — Connect & pull your history
```bash
.venv/bin/python -m whoop_dashboard connect
```
This opens your browser to authorize WHOOP, then backfills your full history into a local
database. (Re-runs are safe — it only adds/updates.)

### Step 4 — Run it

```bash
.venv/bin/python run.py
```

- A **WHOOP** item appears in your menu bar showing today's recovery.
- Click a section (Recovery / Sleep / Strain / Activities) to open that dashboard view at
  **http://localhost:8756**, or **Open Full Dashboard**.
- It re-syncs automatically every 5 minutes, and on demand via **Sync now**.

Prefer just the web dashboard, no menu bar? `.venv/bin/python -m whoop_dashboard dashboard`.

### Step 5 — Make it a real Mac app (double-click to launch)

```bash
./scripts/make-app.sh        # builds /Applications/WHOOP.app
open /Applications/WHOOP.app  # or launch it from Spotlight / Launchpad
```

This creates a proper menu-bar app (no Dock icon) that runs from this project's virtualenv.
**Keep this project folder and its `.venv` in place** — the app points at them (it shows an
alert if they go missing).

To launch at login, **pick ONE** method (not both — they run the same app, and a second
copy just no-ops with a quiet notification):
- add **WHOOP.app** to System Settings → General → Login Items, **or**
- run `./scripts/install-login-item.sh` (a LaunchAgent that runs `run.py`).

### Optional — Start automatically at login
```bash
./scripts/install-login-item.sh        # registers a LaunchAgent that runs run.py at login
./scripts/install-login-item.sh remove # to undo
```

---

## Command reference
```
python run.py                          # launch menu bar + dashboard (main app)
python -m whoop_dashboard connect      # one-time: authorize + backfill full history
python -m whoop_dashboard sync         # incremental sync (recent window)
python -m whoop_dashboard backfill     # re-pull full history
python -m whoop_dashboard dashboard    # run only the web dashboard
python -m whoop_dashboard status       # counts + last sync (JSON)
python -m whoop_dashboard snapshot     # write the widget JSON snapshot
python -m whoop_dashboard build-food-db # download the offline common-foods DB (USDA, ~6 MB)
python -m whoop_dashboard logout       # forget local tokens
```

---

## Nutrition — track what you eat

The **Nutrition** tab (in the dashboard *and* the native app) adds *calories in* to complement
WHOOP's *calories out*, so you get a real energy-balance picture. Three ways to log:

- **Search the offline food database (no key needed)** — run `python -m whoop_dashboard build-food-db`
  once to download ~7,800 common foods from [USDA FoodData Central](https://fdc.nal.usda.gov/)
  (public domain, ~6 MB, stored locally). Then search *"chicken breast"*, pick it, set the grams,
  and calories + macros are computed for you. Fully offline.
- **Log in plain English (optional)** — with a free [Nutritionix](https://www.nutritionix.com/business/api)
  key in `.env` (`NUTRITIONIX_APP_ID`/`NUTRITIONIX_APP_KEY`), type *"2 eggs and a slice of toast"*
  and it parses the items for you.
- **Manual entry** — enter a name plus **any subset** of calories / protein / carbs / fat. Know
  only the protein? Log just that.
- **Energy balance** — a daily *eaten vs burned* chart with the net, plus an intake trend.
- **Menu bar** — today's intake, macros, and net (intake − WHOOP burn) appear under 🍽️ **Nutrition**.

Everything is local: your food log and the food database live in the same SQLite file
(`food_log` and `foods` tables) — nothing leaves your Mac.

## See it on your phone (Tailscale)

The dashboard is a normal web app, so your phone can use it — including logging food on the go.
[Tailscale](https://tailscale.com) is the clean way: a free private mesh VPN, so the phone
reaches your Mac from anywhere, encrypted, with **nothing exposed publicly**.

1. Install Tailscale on your **Mac** and **iPhone**, signed into the same account.
2. In `.env`, set `DASHBOARD_HOST=0.0.0.0`, then restart the app (`python run.py`).
3. Find your Mac's Tailscale address: `tailscale ip -4` (e.g. `100.101.102.103`).
4. On your phone (Tailscale on), open `http://100.101.102.103:8756` in Safari →
   **Share → Add to Home Screen** for an app-like icon.

On a private tailnet you can leave `DASHBOARD_TOKEN` empty. If instead you expose it over
shared Wi-Fi (`DASHBOARD_HOST=0.0.0.0` without Tailscale), set `DASHBOARD_TOKEN=some-secret`
and open the dashboard once as `http://<mac-ip>:8756/?token=some-secret` (a cookie remembers it)
so others on the network can't read your health data. Your Mac's own browser never needs the token.

---

## How it works

```
WHOOP API v2 ──OAuth──▶ auth.py ──tokens──▶ ~/Library/Application Support/WhoopDashboard/tokens.json
       │
   api.py (paginated, rate-limit aware)
       │
   sync.py ──▶ store.py (SQLite: cycles, recoveries, sleeps, workouts, profile)
                   │                    │
              dashboard.py (FastAPI)  snapshot.py ──▶ latest.json (for the native widget)
                   │                    │
              web/ (Chart.js)      menubar.py (rumps)
```

- **Code:** `whoop_dashboard/` (one module per concern; see comments in each file).
- **Your data:** `~/Library/Application Support/WhoopDashboard/whoop.sqlite3` — plain SQLite,
  query it yourself anytime. Tokens live beside it with `0600` permissions.
- **API contract:** WHOOP API **v2** (`https://api.prod.whoop.com/developer/v2`). The app handles
  rotating refresh tokens, `score_state` gating, pagination, and 429 backoff.

## Privacy
Everything runs locally. The only network calls are to `api.prod.whoop.com` (your data) and to a
CDN for the dashboard's charting library. Nothing is sent anywhere else.

## Troubleshooting
- **Browser didn't open / "redirect_uri mismatch":** the `WHOOP_REDIRECT_URI` in `.env` must exactly
  match what you registered (`http://localhost:8755/callback`).
- **"Not connected" after a while:** run `python -m whoop_dashboard connect` again. WHOOP rotates
  refresh tokens; if a refresh is ever missed the app reconnects from scratch.
- **No recovery for "today":** WHOOP only scores recovery after you wake and the sleep is processed —
  it can be blank early in the morning. `PENDING_SCORE` records appear once scored.
- **Menu bar item missing:** launch via `python run.py` from your normal login session (not over SSH).

## Tests
The nutrition feature has a test suite (stdlib `unittest` + FastAPI's in-process test
client — no extra dependencies, runs against a throwaway database, never touches your real
data):

```bash
.venv/bin/python -m unittest tests.test_nutrition
```

## Phase 2 — native widget
See [`widget/README.md`](widget/README.md). It needs full Xcode and reads the same `latest.json`.
