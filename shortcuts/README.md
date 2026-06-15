# Phase 3 — Siri & Shortcuts via App Intents

This adds voice + Shortcuts support to the WHOOP macOS app. Ask Siri "What's my WHOOP
recovery" (or run it from Shortcuts / Spotlight) and it speaks a natural sentence like
**"Your recovery is 72%, you're in the green."**

It reads the **same** `latest.json` snapshot the Python app already mirrors into the App
Group container — no second copy of your data, no network access. The intents reuse the
`WhoopSnapshot` model, `SnapshotStore` reader, and `recoveryColor` from
`widget/WhoopShared.swift`.

```
Python app ──writes──▶ ~/Library/Group Containers/<TEAMID>.group.com.lawrencetang.whoop/latest.json
                                              │
                       App Intents (Siri) ──reads──┘   (on demand, when you ask)
```

## Key fact: App Intents live in the MAIN APP target

Unlike the WidgetKit widget (a separate extension), App Intents and the
`AppShortcutsProvider` belong to the **WHOOP app target itself**. There is **no** new
target to create. You only add one source file to the existing app target.

## Prerequisites

- **Full Xcode** (App Store version, not just Command Line Tools). App Intents must be
  compiled and the app installed via an Xcode project; they can't be built standalone.
- You've already completed `widget/README.md` (app target exists, App Group enabled, the
  Python sync mirrors `latest.json` into the container). The intents depend on that exact
  setup.
- macOS 13 Ventura or later on the machine that runs the app.

## Steps

### 1. Add the source file to the app target
In Xcode, drag **`shortcuts/WhoopIntents.swift`** into the project navigator. In the dialog:
- Check **"Copy items if needed"** (or reference in place — your choice).
- Under **Add to targets**, check **WHOOP (the app)** only. **Do NOT** add it to the
  WhoopWidget extension.

> `WhoopIntents.swift` reuses `WhoopSnapshot`, `SnapshotStore`, `kAppGroupID`, and
> `recoveryColor` from `WhoopShared.swift`. Confirm `WhoopShared.swift` is a member of the
> app target (it already is, since it's shared with the widget). Do **not** add a second
> copy of those symbols — that causes duplicate-symbol errors.

### 2. App Group must match the widget
The intents resolve the container via
`FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.lawrencetang.whoop")`.
That id is `kAppGroupID` in `WhoopShared.swift` and **must equal** the App Group you enabled
on the app + widget targets (see `widget/README.md` step 3):

```
group.com.lawrencetang.whoop
```

On macOS Sequoia (15+) the real on-disk directory is Team-ID-prefixed
(`<TEAMID>.group.com.lawrencetang.whoop`). The code never hardcodes that — `FileManager`
resolves the real path. If you ever change the group id, change it in **all** places: both
`.entitlements` files, the App Groups capability on both targets, and `kAppGroupID`.

### 3. Enable Siri
1. Select the **WHOOP** app target → **Signing & Capabilities** → **+ Capability ▸ Siri**.
   (This adds the `com.apple.developer.siri` entitlement so Siri can invoke your intents.)
2. Build & run the app once (⌘R). At launch, the `WhoopShortcuts` provider registers the
   phrases with the system. The app must be **launched at least once** for Siri/Spotlight to
   learn the shortcuts.
3. Grant Siri permission if macOS prompts. You can verify registration in
   **System Settings ▸ (Apple Intelligence &) Siri** and in the **Shortcuts** app under the
   WHOOP app.

### 4. Try it
- **Siri:** "Hey Siri, what's my WHOOP recovery?" → spoken: *"Your recovery is 72%, you're
  in the green."* Also try "what's my WHOOP sleep" and "what's my WHOOP strain".
- **Spotlight:** ⌘-Space, type "WHOOP recovery", press return.
- **Shortcuts app:** the three actions (Get WHOOP Recovery / Sleep / Strain) appear under
  the WHOOP app and can be dropped into any shortcut.

If you haven't synced yet, the intents speak a helpful fallback instead of failing:
*"I don't have any WHOOP data yet. Open the app to sync first."* — and if the App Group
isn't configured: *"WHOOP isn't set up yet. Open the WHOOP app to finish setup."*

## The intents

| Intent | Sample phrase | Spoken result |
|--------|---------------|---------------|
| `GetRecoveryIntent` | "What's my WHOOP recovery" | "Your recovery is 72%, you're in the green." |
| `GetSleepIntent` | "How did I sleep on WHOOP" | "You slept 7 hours and 12 minutes, with 88% sleep performance." |
| `GetStrainIntent` | "What's my WHOOP strain" | "Your strain is 12.3, and you've burned about 2100 calories." |

Recovery zone wording mirrors the widget colors: **green ≥ 67, yellow 34–66, red < 34**.

## Example Shortcuts automations

Because the actions return their values to Shortcuts, you can build automations:

- **Rest reminder** — *"If recovery < 40, remind me to rest."*
  1. New Shortcut → **Get WHOOP Recovery**.
  2. Add an **If** → the recovery number **is less than** `40`.
  3. Inside the If → **Show Notification** "Recovery is low — take it easy today." (or
     **Add Reminder**).
  4. (Optional) In the **Automation** tab, run this daily at, say, 7:00 AM.

- **Morning briefing** — chain **Get WHOOP Recovery**, **Get WHOOP Sleep**, **Get WHOOP
  Strain** and **Speak Text** for a spoken summary when you unlock your Mac.

- **High-strain wind-down** — *"If strain > 15 after 8 PM, suggest a recovery routine."*

## Files

| File | Target | Purpose |
|------|--------|---------|
| `WhoopIntents.swift` | app | `GetRecovery/Sleep/StrainIntent` + `WhoopShortcuts` provider + snapshot helper |
| `WhoopShared.swift` (in `widget/`) | app + widget | Reused: `WhoopSnapshot`, `SnapshotStore`, `kAppGroupID`, `recoveryColor` |

> Reminder: full Xcode is required to build and install. App Intents cannot be compiled
> with Command Line Tools alone.
