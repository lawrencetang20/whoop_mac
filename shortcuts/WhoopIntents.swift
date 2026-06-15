// WhoopIntents.swift
// Siri + Shortcuts support for the WHOOP macOS app via the App Intents framework.
//
// IMPORTANT: App Intents are part of the MAIN APP target (not a separate target).
// Add this file to the WHOOP app target ONLY. It reuses the snapshot model and the
// App Group reader already defined in `WhoopShared.swift` (`WhoopSnapshot`,
// `SnapshotStore`, `kAppGroupID`, `recoveryColor`) — do NOT redefine those here, or
// you'll get duplicate-symbol build errors. Make sure `WhoopShared.swift` is also a
// member of the app target (it already is, since it's shared with the widget).
//
// Reads the SAME `latest.json` the Python app mirrors into the App Group container
// `group.com.lawrencetang.whoop` (resolved via FileManager, never hardcoded).
//
// Requires: macOS 13+ (App Intents). Spoken `dialog` + AppShortcuts phrases work on
// macOS 13+; richer parameter UI requires 14+. Build with full Xcode.

import AppIntents
import Foundation

// MARK: - Recovery zone (spoken)

/// Human-readable recovery zone, mirroring the widget colors:
/// green >= 67, yellow 34-66, red < 34.
enum RecoveryZone: String {
    case green, yellow, red

    init(score: Int) {
        if score >= 67 { self = .green }
        else if score >= 34 { self = .yellow }
        else { self = .red }
    }

    /// Phrase that slots into "you're in the …".
    var spoken: String {
        switch self {
        case .green:  return "the green"
        case .yellow: return "the yellow"
        case .red:    return "the red"
        }
    }
}

// MARK: - Snapshot loading helper (intent-friendly)

/// Thin wrapper over the shared `SnapshotStore` that distinguishes "App Group not
/// configured" from "configured but no data yet", so intents can speak a helpful
/// sentence instead of failing silently.
enum IntentSnapshot {
    /// Loads the snapshot, or throws a spoken error when the container/file is missing.
    /// `SnapshotStore.load()` returns a placeholder on failure; here we want real data,
    /// so we read the file directly and surface the difference.
    static func load() throws -> WhoopSnapshot {
        guard let url = SnapshotStore.url else {
            throw IntentError.notConfigured
        }
        guard let data = try? Data(contentsOf: url) else {
            throw IntentError.noData
        }
        guard let snap = try? JSONDecoder().decode(WhoopSnapshot.self, from: data) else {
            throw IntentError.noData
        }
        return snap
    }
}

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case notConfigured
    case noData

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConfigured:
            return "WHOOP isn't set up yet. Open the WHOOP app to finish setup."
        case .noData:
            return "I don't have any WHOOP data yet. Open the app to sync first."
        }
    }
}

// MARK: - Recovery

struct GetRecoveryIntent: AppIntent {
    static var title: LocalizedStringResource = "Get WHOOP Recovery"
    static var description = IntentDescription(
        "Tells you your latest WHOOP recovery score and zone.",
        categoryName: "WHOOP"
    )
    // Show no app UI; this is a voice/Spotlight-first intent.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snap = try IntentSnapshot.load()
        guard let score = snap.recovery?.score else {
            return .result(dialog: "I don't have a recovery score for you yet.")
        }
        let zone = RecoveryZone(score: score)
        return .result(
            dialog: "Your recovery is \(score)%, you're in \(zone.spoken)."
        )
    }
}

// MARK: - Sleep

struct GetSleepIntent: AppIntent {
    static var title: LocalizedStringResource = "Get WHOOP Sleep"
    static var description = IntentDescription(
        "Tells you how long you slept and your sleep performance.",
        categoryName: "WHOOP"
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snap = try IntentSnapshot.load()
        let sleep = snap.sleep
        guard let hours = sleep?.hours else {
            return .result(dialog: "I don't have a sleep record for you yet.")
        }
        let duration = Self.spokenDuration(hours: hours)
        if let pct = sleep?.performance {
            return .result(
                dialog: "You slept \(duration), with \(pct)% sleep performance."
            )
        }
        return .result(dialog: "You slept \(duration).")
    }

    /// Turns 7.2 hours into a natural "7 hours and 12 minutes".
    static func spokenDuration(hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        let hPart = "\(h) hour\(h == 1 ? "" : "s")"
        if m == 0 { return hPart }
        let mPart = "\(m) minute\(m == 1 ? "" : "s")"
        return h == 0 ? mPart : "\(hPart) and \(mPart)"
    }
}

// MARK: - Strain

struct GetStrainIntent: AppIntent {
    static var title: LocalizedStringResource = "Get WHOOP Strain"
    static var description = IntentDescription(
        "Tells you your current WHOOP day strain.",
        categoryName: "WHOOP"
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snap = try IntentSnapshot.load()
        guard let value = snap.strain?.value else {
            return .result(dialog: "I don't have a strain value for you yet.")
        }
        // Strain is 0–21; speak it to one decimal, e.g. "12.3".
        let spoken = String(format: "%.1f", value)
        if let cals = snap.strain?.calories, cals > 0 {
            let kcal = Int(cals.rounded())
            return .result(
                dialog: "Your strain is \(spoken), and you've burned about \(kcal) calories."
            )
        }
        return .result(dialog: "Your strain is \(spoken).")
    }
}

// MARK: - App Shortcuts (Siri / Spotlight phrases)

/// Exposes the intents to Siri and Spotlight with natural phrases. The `\(.applicationName)`
/// token MUST appear in every phrase — Siri uses your app's name to disambiguate.
/// Keep this provider lightweight; it's evaluated at launch to register shortcuts.
struct WhoopShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetRecoveryIntent(),
            phrases: [
                "What's my \(.applicationName) recovery",
                "What's my recovery on \(.applicationName)",
                "Check my \(.applicationName) recovery",
                "How recovered am I on \(.applicationName)"
            ],
            shortTitle: "Recovery",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: GetSleepIntent(),
            phrases: [
                "What's my \(.applicationName) sleep",
                "How did I sleep on \(.applicationName)",
                "Check my \(.applicationName) sleep"
            ],
            shortTitle: "Sleep",
            systemImageName: "bed.double.fill"
        )
        AppShortcut(
            intent: GetStrainIntent(),
            phrases: [
                "What's my \(.applicationName) strain",
                "What's my strain on \(.applicationName)",
                "Check my \(.applicationName) strain"
            ],
            shortTitle: "Strain",
            systemImageName: "flame.fill"
        )
    }

    // Optional: a tint for the Shortcuts/Spotlight tile.
    static var shortcutTileColor: ShortcutTileColor = .red
}
