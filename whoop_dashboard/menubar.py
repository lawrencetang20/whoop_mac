"""macOS menu-bar app (rumps) — interactive WHOOP panel.

The menu bar shows a recovery-zone heart + today's recovery %. The dropdown has
expandable, clickable sub-sections (Recovery / Sleep / Strain / Activities): each
shows its headline number, expands to the detail metrics, and deep-links into the
matching dashboard view (e.g. clicking inside Recovery opens localhost/#recovery).
Activities lists the workouts for the displayed day.

Threading: rumps Timer callbacks run on the MAIN thread (safe for UI). Network/IO
(OAuth, sync) runs on worker threads that only set self._latest / self._status; a
fast main-thread UI timer reflects those into the menu.
"""

from __future__ import annotations

import fcntl
import threading
import webbrowser
from datetime import datetime

import rumps

from . import auth, config, dashboard, store, sync


# --- formatting helpers ----------------------------------------------------

def _heart(score):
    if score is None:
        return "🤍"
    return "💚" if score >= 67 else "💛" if score >= 34 else "❤️"


def _trend(cur, prev):
    if cur is None or prev is None:
        return ""
    if cur > prev:
        return f"▲{cur - prev}"
    if cur < prev:
        return f"▼{prev - cur}"
    return "▬"


def _hm(hours):
    if hours is None:
        return "--"
    m = round(hours * 60)
    return f"{m // 60}h {m % 60:02d}m"


def _n(v, d=0):
    if v is None:
        return "--"
    return f"{v:.{d}f}" if d else f"{round(v)}"


def _cal(v):
    return f"{int(v):,}" if v is not None else "--"


_SPORT_ICONS = {
    "run": "🏃", "tread": "🏃", "walk": "🚶", "cycl": "🚴", "bik": "🚴",
    "weight": "🏋️", "strength": "🏋️", "functional": "🏋️", "swim": "🏊",
    "hik": "🥾", "yoga": "🧘", "pilates": "🧘", "basketball": "🏀",
    "soccer": "⚽", "tennis": "🎾", "golf": "⛳", "box": "🥊", "row": "🚣",
    "ellipt": "🔥", "ski": "⛷️", "skat": "⛸️", "climb": "🧗", "dance": "🕺",
}


def _sport_icon(name):
    if not name:
        return "💪"
    n = name.lower()
    for k, v in _SPORT_ICONS.items():
        if k in n:
            return v
    return "💪"


def _sport_name(name):
    return (name or "activity").replace("_", " ").title()


def _dur(minutes):
    if minutes is None:
        return "--"
    return f"{minutes // 60}h {minutes % 60:02d}m" if minutes >= 60 else f"{minutes}m"


def _time(iso):
    if not iso:
        return ""
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone().strftime("%-I:%M %p")
    except (ValueError, TypeError):
        return ""


class WhoopMenuBar(rumps.App):
    def __init__(self):
        super().__init__("WHOOP", title="WHOOP", quit_button=None)
        self._latest = None
        self._status = "Starting…"
        self._busy = False
        self._act_sig = object()  # forces first activities build
        self._last_ring = object()  # last recovery score rendered as the ring icon
        self._ring_ok = False
        self._notify_pending = None  # (title, subtitle, message) to post on the main thread

        self.mi_header = rumps.MenuItem("WHOOP", callback=self.on_overview)

        # Recovery sub-section (expandable; every row opens the recovery view).
        self.mi_rec = rumps.MenuItem("Recovery")
        self.mi_rec_hrv = rumps.MenuItem("HRV", callback=self.on_recovery)
        self.mi_rec_rhr = rumps.MenuItem("Resting heart rate", callback=self.on_recovery)
        self.mi_rec_spo2 = rumps.MenuItem("Blood oxygen", callback=self.on_recovery)
        self.mi_rec_temp = rumps.MenuItem("Skin temperature", callback=self.on_recovery)
        for it in (self.mi_rec_hrv, self.mi_rec_rhr, self.mi_rec_spo2, self.mi_rec_temp):
            self.mi_rec.add(it)
        self.mi_rec.add(rumps.MenuItem("Open Recovery view →", callback=self.on_recovery))

        # Sleep sub-section.
        self.mi_sleep = rumps.MenuItem("Sleep")
        self.mi_sleep_perf = rumps.MenuItem("Performance", callback=self.on_sleep)
        self.mi_sleep_eff = rumps.MenuItem("Efficiency", callback=self.on_sleep)
        self.mi_sleep_stages = rumps.MenuItem("Stages", callback=self.on_sleep)
        self.mi_sleep_resp = rumps.MenuItem("Respiratory rate", callback=self.on_sleep)
        self.mi_sleep_need = rumps.MenuItem("Sleep need", callback=self.on_sleep)
        for it in (self.mi_sleep_perf, self.mi_sleep_eff, self.mi_sleep_stages,
                   self.mi_sleep_resp, self.mi_sleep_need):
            self.mi_sleep.add(it)
        self.mi_sleep.add(rumps.MenuItem("Open Sleep view →", callback=self.on_sleep))

        # Strain sub-section.
        self.mi_strain = rumps.MenuItem("Strain")
        self.mi_strain_hr = rumps.MenuItem("Heart rate", callback=self.on_strain)
        self.mi_strain_cal = rumps.MenuItem("Calories", callback=self.on_strain)
        for it in (self.mi_strain_hr, self.mi_strain_cal):
            self.mi_strain.add(it)
        self.mi_strain.add(rumps.MenuItem("Open Strain view →", callback=self.on_strain))

        # Nutrition sub-section (calories you eat; pairs with Strain's calories out).
        self.mi_nutrition = rumps.MenuItem("Nutrition")
        self.mi_nutri_macros = rumps.MenuItem("Macros", callback=self.on_nutrition)
        self.mi_nutri_net = rumps.MenuItem("Net", callback=self.on_nutrition)
        for it in (self.mi_nutri_macros, self.mi_nutri_net):
            self.mi_nutrition.add(it)
        self.mi_nutrition.add(rumps.MenuItem("Log food / open Nutrition →", callback=self.on_nutrition))

        # Activities sub-section (submenu rebuilt when the day's workouts change).
        # Seed one child so the underlying NSMenu exists before the first clear().
        self.mi_activities = rumps.MenuItem("Activities")
        self.mi_activities.add(rumps.MenuItem("Loading…", callback=self._noop))

        self.mi_dashboard = rumps.MenuItem("Open Full Dashboard", callback=self.on_overview)
        self.mi_sync = rumps.MenuItem("Sync now", callback=self.on_sync)
        self.mi_notify = rumps.MenuItem("Daily notification", callback=self.on_toggle_notify)
        self.mi_status = rumps.MenuItem("Starting…", callback=self._noop)
        self.mi_connect = rumps.MenuItem("Connect WHOOP", callback=self.on_connect)
        self.mi_disconnect = rumps.MenuItem("Disconnect", callback=self.on_disconnect)

        self.menu = [
            self.mi_header,
            None,
            self.mi_rec, self.mi_sleep, self.mi_strain, self.mi_nutrition, self.mi_activities,
            None,
            self.mi_dashboard, self.mi_sync, self.mi_notify,
            None,
            self.mi_status, self.mi_connect, self.mi_disconnect,
            rumps.MenuItem("Quit", callback=rumps.quit_application),
        ]

        store.init_db()
        self._latest = store.latest_stats()
        self._status = ("Connecting to data…" if auth.is_authorized()
                        else "Not connected — click “Connect WHOOP”")
        dashboard.serve_in_thread(on_error=lambda m: setattr(self, "_status", m))
        self.refresh_ui()

        self._ui_timer = rumps.Timer(self.refresh_ui, 3)
        self._ui_timer.start()
        self._sync_timer = rumps.Timer(self.on_sync_timer, 300)  # pull from WHOOP every 5 min
        self._sync_timer.start()
        if auth.is_authorized():
            self._spawn(self._initial_sync)

    # --- worker helpers ----------------------------------------------------

    def _spawn(self, fn):
        if self._busy:
            return
        self._busy = True
        threading.Thread(target=self._wrap(fn), daemon=True).start()

    def _wrap(self, fn):
        def runner():
            try:
                fn()
            except Exception as e:
                self._status = f"Error: {e}"
            finally:
                self._busy = False
        return runner

    def _initial_sync(self):
        sync.sync(progress=lambda m: setattr(self, "_status", m))
        self._latest = store.latest_stats()
        self._maybe_notify()
        self._status = "Synced " + datetime.now().strftime("%-I:%M %p")

    def _do_sync(self):
        sync.sync_recent(progress=lambda m: setattr(self, "_status", m))
        self._latest = store.latest_stats()
        self._maybe_notify()
        self._status = "Synced " + datetime.now().strftime("%-I:%M %p")

    def _do_connect(self):
        self._status = "Opening browser to authorize…"
        auth.authorize()
        self._status = "Connected — backfilling history…"
        sync.backfill(progress=lambda m: setattr(self, "_status", m))
        self._latest = store.latest_stats()
        self._maybe_notify()
        self._status = "Synced " + datetime.now().strftime("%-I:%M %p")

    def _maybe_notify(self):
        """Queue a daily-recovery notification when a new recovery day appears
        (posted on the main thread by refresh_ui). No-op if disabled or unchanged."""
        if store.get_state("notifications_enabled", "1") != "1":
            return
        latest = self._latest or {}
        rec = latest.get("recovery") or {}
        day, score = rec.get("day"), rec.get("recovery_score")
        if not day or score is None or store.get_state("last_notified_day") == day:
            return
        store.set_state("last_notified_day", day)
        zone = ("You're recovered 🟢" if score >= 67
                else "Moderate 🟡" if score >= 34 else "Take it easy 🔴")
        hrv = rec.get("hrv_rmssd_milli")
        slp = latest.get("sleep") or {}
        self._notify_pending = (
            f"Recovery {score}%", zone,
            f"HRV {round(hrv) if hrv is not None else '--'} ms · slept {_hm(slp.get('hours'))}",
        )

    # --- main-thread UI ----------------------------------------------------

    def _render_menu_icon(self, score):
        """Render/refresh the recovery-ring menu-bar icon. Returns True if the ring
        icon is in use (so the title can stay minimal). Only re-renders on change."""
        if score == self._last_ring:
            return self._ring_ok
        self._last_ring = score
        if score is None:
            try:
                self.icon = None
            except Exception:
                pass
            self._ring_ok = False
            return False
        from . import ring as _ring
        path = config.DATA_DIR / "menubar_ring.png"
        ok = _ring.render_ring(score, path)
        try:
            self.template = False
            self.icon = str(path) if ok else None
        except Exception:
            ok = False
        self._ring_ok = ok
        return ok

    def refresh_ui(self, _timer=None):
        connected = auth.is_authorized()
        self.mi_connect.set_callback(None if connected else self.on_connect)
        self.mi_connect.title = "WHOOP connected ✓" if connected else "Connect WHOOP"
        self.mi_disconnect.set_callback(self.on_disconnect if connected else None)
        self.mi_sync.set_callback(None if self._busy else self.on_sync)

        latest = self._latest or {}
        rec = latest.get("recovery") or {}
        prev = latest.get("recovery_prev") or {}
        slp = latest.get("sleep") or {}
        strn = latest.get("strain") or {}
        prof = latest.get("profile") or {}
        day = latest.get("day") or ""

        score = rec.get("recovery_score")
        if self._render_menu_icon(score):
            # Native ring icon is showing — keep the text minimal next to it.
            self.title = f" {score}%" if score is not None else "WHOOP"
        else:
            self.title = f"{_heart(score)} {score}%" if score is not None else "WHOOP"

        name = (prof.get("first_name") or "").strip()
        self.mi_header.title = " · ".join(p for p in (name, day) if p) or "WHOOP"

        # Recovery
        self.mi_rec.title = (f"{_heart(score)} Recovery   {score}%   "
                             f"{_trend(score, prev.get('recovery_score'))}".rstrip()
                             if score is not None else "🤍 Recovery   --")
        self.mi_rec_hrv.title = f"HRV   {_n(rec.get('hrv_rmssd_milli'))} ms"
        self.mi_rec_rhr.title = f"Resting heart rate   {_n(rec.get('resting_heart_rate'))} bpm"
        self.mi_rec_spo2.title = f"Blood oxygen   {_n(rec.get('spo2_percentage'), 1)}%"
        self.mi_rec_temp.title = f"Skin temperature   {_n(rec.get('skin_temp_celsius'), 1)}°C"

        # Sleep
        if slp.get("hours") is not None:
            self.mi_sleep.title = f"😴 Sleep   {_hm(slp.get('hours'))}   ({_n(slp.get('performance'))}%)"
        else:
            self.mi_sleep.title = "😴 Sleep   --"
        self.mi_sleep_perf.title = f"Performance   {_n(slp.get('performance'))}%"
        self.mi_sleep_eff.title = f"Efficiency   {_n(slp.get('efficiency'))}%"
        self.mi_sleep_stages.title = (
            f"Deep {_hm(slp.get('deep_hours'))} · REM {_hm(slp.get('rem_hours'))} · "
            f"Light {_hm(slp.get('light_hours'))} · Awake {_hm(slp.get('awake_hours'))}"
        )
        self.mi_sleep_resp.title = f"Respiratory rate   {_n(slp.get('respiratory_rate'), 1)} rpm"
        self.mi_sleep_need.title = f"Sleep need   {_hm(slp.get('need_hours'))}  (got {_hm(slp.get('hours'))})"

        # Strain
        self.mi_strain.title = (f"⚡ Strain   {_n(strn.get('strain'), 1)}"
                                if strn.get("strain") is not None else "⚡ Strain   --")
        self.mi_strain_hr.title = (f"Heart rate   avg {_n(strn.get('average_heart_rate'))} · "
                                   f"max {_n(strn.get('max_heart_rate'))} bpm")
        self.mi_strain_cal.title = f"Calories   {_cal(strn.get('calories'))}"

        # Nutrition (today's intake — read directly; it's a fast local query).
        food = store.food_summary()
        intake = food.get("calories")
        goal, remaining = food.get("goal"), food.get("remaining")
        if goal is not None:
            self.mi_nutrition.title = f"🍽️ Nutrition   {_cal(intake or 0)} / {_cal(goal)} cal"
        elif intake is not None:
            self.mi_nutrition.title = f"🍽️ Nutrition   {_cal(intake)} cal"
        else:
            self.mi_nutrition.title = "🍽️ Nutrition   none yet"
        self.mi_nutri_macros.title = (f"Protein {_n(food.get('protein_g'))}g · "
                                      f"Carbs {_n(food.get('carbs_g'))}g · Fat {_n(food.get('fat_g'))}g")
        if remaining is not None:
            self.mi_nutri_net.title = (f"{int(remaining):,} cal left of {_cal(goal)} goal"
                                       if remaining >= 0 else f"{int(-remaining):,} cal over {_cal(goal)} goal")
        else:
            net = food.get("net")
            self.mi_nutri_net.title = (f"Net   {int(net):+,} cal  (burned {_cal(food.get('burned'))})"
                                       if net is not None else "Net   -- (no burn data yet)")

        # Activities (workouts on the displayed day) — rebuild submenu on change.
        acts = latest.get("day_workouts") or []
        self.mi_activities.title = (f"🏃 Activities   ({len(acts)})" if acts
                                    else "🏃 Activities   (none)")
        sig = tuple(a.get("start") for a in acts)
        if sig != self._act_sig:
            self._act_sig = sig
            self.mi_activities.clear()
            if acts:
                for i, a in enumerate(acts):
                    # Leading index keeps each row's title unique (rumps keys submenu
                    # children by title; identical titles would silently collapse).
                    title = (f"{i + 1}.  {_sport_icon(a.get('sport_name'))} {_sport_name(a.get('sport_name'))}"
                             f"   {_time(a.get('start'))}   ⚡{_n(a.get('strain'), 1)} · "
                             f"{_dur(a.get('minutes'))} · {_cal(a.get('calories'))} cal")
                    self.mi_activities.add(rumps.MenuItem(title, callback=self.on_activities))
            else:
                self.mi_activities.add(rumps.MenuItem("No activities this day", callback=self._noop))
            self.mi_activities.add(rumps.MenuItem("Open Activities view →", callback=self.on_activities))

        self.mi_status.title = self._status

        # Notification toggle state + post any queued notification (main thread).
        self.mi_notify.state = 1 if store.get_state("notifications_enabled", "1") == "1" else 0
        if self._notify_pending:
            title, subtitle, message = self._notify_pending
            self._notify_pending = None
            try:
                rumps.notification(title, subtitle, message)
            except Exception:
                pass

    # --- callbacks ---------------------------------------------------------

    def _noop(self, _=None):
        """Keeps info rows enabled (full contrast) rather than greyed out."""
        pass

    def _open(self, anchor=""):
        url = f"http://localhost:{config.DASHBOARD_PORT}/"
        if anchor:
            url += f"#{anchor}"
        webbrowser.open(url)

    def on_overview(self, _):
        self._open("")

    def on_recovery(self, _):
        self._open("recovery")

    def on_sleep(self, _):
        self._open("sleep")

    def on_strain(self, _):
        self._open("strain")

    def on_nutrition(self, _):
        self._open("nutrition")

    def on_activities(self, _):
        self._open("activities")

    def on_toggle_notify(self, sender):
        enabled = store.get_state("notifications_enabled", "1") == "1"
        store.set_state("notifications_enabled", "0" if enabled else "1")
        sender.state = 0 if enabled else 1

    def on_sync(self, _):
        if not auth.is_authorized():
            rumps.alert("Connect WHOOP first.")
            return
        self._spawn(self._do_sync)

    def on_sync_timer(self, _):
        if auth.is_authorized() and not self._busy:
            self._spawn(self._do_sync)

    def on_connect(self, _):
        if not config.credentials_present():
            rumps.alert(
                "Missing credentials",
                "Copy .env.example to .env and add your WHOOP Client ID and Secret "
                "from developer-dashboard.whoop.com, then restart the app.",
            )
            return
        self._spawn(self._do_connect)

    def on_disconnect(self, _):
        auth.logout()
        self._latest = None
        self._status = "Disconnected"


_lock_fp = None


def _ensure_single_instance() -> bool:
    """True if we acquired the single-instance lock; False if another copy holds it."""
    global _lock_fp
    _lock_fp = open(config.DATA_DIR / "app.lock", "w")
    try:
        fcntl.flock(_lock_fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def main():
    if not _ensure_single_instance():
        # Already running (e.g. configured to launch both at login and manually).
        # Use a quiet notification instead of a blocking modal that would pop every login.
        try:
            rumps.notification("WHOOP", "Already running",
                               "The WHOOP item is in your menu bar.")
        except Exception:
            pass
        print("WHOOP Dashboard is already running.")
        return
    WhoopMenuBar().run()


if __name__ == "__main__":
    main()
