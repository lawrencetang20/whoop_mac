# Phase 2 — Native macOS WidgetKit widget

This builds a real macOS desktop / Notification Center widget that shows your latest
recovery, sleep, and strain. It reads the same `latest.json` snapshot the Python app
already produces — no second copy of your data, no network access from the widget.

```
Python app  ──writes──▶  ~/Library/Group Containers/<TEAMID>.group.com.lawrencetang.whoop/latest.json
                                                  │
                          WidgetKit widget  ──reads──┘   (refreshes ~every 30 min, no budget on macOS)
```

## Prerequisites

- **Full Xcode** (the App Store version, not just Command Line Tools). A WidgetKit
  extension can only be built/installed through an Xcode project.
- A free Apple ID is enough to sign for local use (Xcode → Settings → Accounts).

## Steps

### 1. Create the app + widget targets
1. Open Xcode → **File ▸ New ▸ Project ▸ macOS ▸ App**. Name it `WHOOP`,
   interface **SwiftUI**, language **Swift**. Note your **Team** and the auto-assigned
   **Bundle Identifier** (e.g. `com.lawrencetang.WHOOP`).
2. **File ▸ New ▸ Target ▸ Widget Extension**. Name it `WhoopWidget`. Uncheck
   "Include Configuration App Intent" (we use a static widget). Activate the scheme when prompted.

### 2. Add the source files
Delete the boilerplate `WhoopWidget.swift` Xcode generated, then add the files from this
folder:
- `WhoopShared.swift` → **check BOTH targets** (WHOOP app *and* WhoopWidget) in the file inspector.
- `WhoopWidget.swift` → WhoopWidget target only.
- `WhoopApp.swift` → WHOOP app target only (replace the generated `…App.swift`/`ContentView.swift`).

### 3. Enable the App Group on BOTH targets
For each target (WHOOP **and** WhoopWidget): select it → **Signing & Capabilities** →
**+ Capability ▸ App Groups** → add a group named exactly:

```
group.com.lawrencetang.whoop
```

This must match `kAppGroupID` in `WhoopShared.swift`. If you use a different id, change it
in all three places (both entitlements + the Swift constant).

> On macOS Sequoia (15+) the on-disk container is created with your **Team ID** prefix, e.g.
> `~/Library/Group Containers/AB12CD34EF.group.com.lawrencetang.whoop/`. The Swift code resolves
> this automatically via `FileManager.containerURL(...)`. You only need the real path for step 5.

### 4. Build & run once
Run the **WHOOP** app scheme once (⌘R). This creates the App Group container directory.
The app window will print the exact path it reads from (`Reads: …`). Copy that path.

### 5. Point the Python app at the container
So the Python sync writes the snapshot where the widget can read it, set the env var to the
**directory path from step 4** + `/latest.json`. For example, edit your `.env`:

```
WHOOP_GROUP_SNAPSHOT_PATH=/Users/lawrencetang/Library/Group Containers/AB12CD34EF.group.com.lawrencetang.whoop/latest.json
```

(Replace `AB12CD34EF` with your real Team ID prefix.) Then run a sync:

```
python -m whoop_dashboard snapshot   # or any sync; it now mirrors to the container
```

### 6. Add the widget
Right-click the desktop → **Edit Widgets** (or open Notification Center) → find **WHOOP** →
add the small or medium size. It should show your latest numbers. The containing app, while
open, watches the file and refreshes the widget instantly; when closed, the widget still
refreshes itself about every 30 minutes (macOS imposes no widget refresh budget).

## Files
| File | Target(s) | Purpose |
|------|-----------|---------|
| `WhoopShared.swift` | app + widget | Codable snapshot model + App Group reader + colors |
| `WhoopWidget.swift` | widget | TimelineProvider + small/medium widget views |
| `WhoopApp.swift` | app | Host app: holds entitlement, watches file, reloads widget |
| `WhoopApp.entitlements` | app | App Group entitlement (reference) |
| `WhoopWidget.entitlements` | widget | App Group entitlement (reference) |

The `.entitlements` files here are references — Xcode generates and manages its own when you
add the App Groups capability in step 3. Use these only to confirm the expected contents.
