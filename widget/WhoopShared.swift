// WhoopShared.swift
// Add this file to BOTH targets: the WHOOP host app and the WhoopWidget extension.
//
// It decodes the latest.json snapshot that the Python app writes into the shared
// App Group container, and exposes a tiny model the widget renders, plus the
// WHOOP recovery-zone color helper.
//
// JSON schema written by whoop_dashboard/snapshot.py (fields may be null):
// {
//   "generated_at": "ISO8601", "last_sync": "ISO8601|null", "name": "string",
//   "recovery":  { "score": Int?, "hrv_ms": Double?, "resting_hr": Int?, "day": "YYYY-MM-DD?" },
//   "sleep":     { "hours": Double?, "performance": Int?, "efficiency": Int?, "day": "YYYY-MM-DD?" },
//   "strain":    { "value": Double?, "avg_hr": Int?, "calories": Double?, "day": "YYYY-MM-DD?" },
//   "nutrition": { "calories": Num?, "protein_g": Num?, "carbs_g": Num?, "fat_g": Num?,
//                  "burned": Num?, "net": Num?, "goal": Num?, "remaining": Num?, "day": "YYYY-MM-DD?" }
// }

import Foundation
import SwiftUI

// IMPORTANT: this must match the App Group id enabled on both targets.
// On macOS Sequoia (15+) the real container directory is prefixed with your Team ID,
// but you still pass the un-prefixed id here — FileManager resolves the real path.
// Never hardcode the Team-ID-prefixed path.
let kAppGroupID = "group.com.lawrencetang.whoop"
let kSnapshotFile = "latest.json"

// MARK: - Codable snapshot model (matches the JSON schema EXACTLY via CodingKeys)

struct WhoopSnapshot: Codable {
    var generatedAt: String?
    var lastSync: String?
    var name: String?
    var recovery: Recovery?
    var sleep: Sleep?
    var strain: Strain?
    var nutrition: Nutrition? = nil

    struct Recovery: Codable {
        var score: Int?
        var hrvMs: Double?
        var restingHr: Int?
        var day: String?
        enum CodingKeys: String, CodingKey {
            case score, day
            case hrvMs = "hrv_ms"
            case restingHr = "resting_hr"
        }
    }

    struct Sleep: Codable {
        var hours: Double?
        var performance: Int?
        var efficiency: Int?
        var day: String?
        // Field names already match (snake_case == camelCase here), but list them
        // explicitly so the model stays pinned to the schema.
        enum CodingKeys: String, CodingKey {
            case hours, performance, efficiency, day
        }
    }

    struct Strain: Codable {
        var value: Double?
        var avgHr: Int?
        var calories: Double?
        var day: String?
        enum CodingKeys: String, CodingKey {
            case value, calories, day
            case avgHr = "avg_hr"
        }
    }

    // Food you ate (calories IN) to pair with strain's calories OUT. Numeric fields are
    // Double? so they decode whether the JSON has 950 or 950.0 — never failing the whole
    // snapshot over an int-vs-float mismatch.
    struct Nutrition: Codable {
        var calories: Double?
        var proteinG: Double?
        var carbsG: Double?
        var fatG: Double?
        var burned: Double?
        var net: Double?
        var goal: Double?
        var remaining: Double?
        var day: String?
        enum CodingKeys: String, CodingKey {
            case calories, burned, net, goal, remaining, day
            case proteinG = "protein_g"
            case carbsG = "carbs_g"
            case fatG = "fat_g"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, recovery, sleep, strain, nutrition
        case generatedAt = "generated_at"
        case lastSync = "last_sync"
    }

    /// Sample data for the widget gallery / placeholder rendering.
    static let placeholder = WhoopSnapshot(
        generatedAt: nil,
        lastSync: nil,
        name: nil,
        recovery: .init(score: 78, hrvMs: 65, restingHr: 52, day: nil),
        sleep: .init(hours: 7.2, performance: 88, efficiency: 92, day: nil),
        strain: .init(value: 12.3, avgHr: 70, calories: 2100, day: nil),
        nutrition: .init(calories: 1850, proteinG: 120, carbsG: 180, fatG: 60,
                         burned: 2400, net: -550, goal: 2200, remaining: 350, day: nil)
    )
}

// MARK: - Snapshot loader (API fetch + own-container cache)
//
// The widget/app FETCH the snapshot from the local dashboard's /api/snapshot and cache
// it into THIS target's own App Group container. They never read a file the Python engine
// writes into our container — the engine doesn't touch our container at all. That removes
// the cross-app access that made macOS repeatedly prompt "WHOOP would like to access data
// from other apps" (a grant that can't persist for the engine's py2app Python process).

enum SnapshotStore {
    // Numeric loopback (not "localhost") so App Transport Security doesn't block the HTTP call.
    static let apiURL = URL(string: "http://127.0.0.1:8756/api/snapshot")!

    /// URL of the cache file inside our OWN App Group container (we are a group member, so
    /// reading/writing it is silent — no privacy prompt). Resolved via FileManager so the
    /// Team-ID-prefixed path on Sequoia is correct.
    static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: kAppGroupID)?
            .appendingPathComponent(kSnapshotFile)
    }

    /// Last cached snapshot from our own container, or the placeholder if missing/unreadable.
    static func load() -> WhoopSnapshot {
        guard let url = url,
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(WhoopSnapshot.self, from: data)
        else { return .placeholder }
        return snap
    }

    /// Fetch the latest snapshot from the local engine. On success, cache it into our own
    /// container and return it; on any failure, return the last cached value (or placeholder).
    static func fetch(completion: @escaping (WhoopSnapshot) -> Void) {
        var req = URLRequest(url: apiURL)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let snap = try? JSONDecoder().decode(WhoopSnapshot.self, from: data)
            else { completion(load()); return }
            if let url = url { try? data.write(to: url, options: .atomic) }  // own container → silent
            completion(snap)
        }.resume()
    }
}

// MARK: - WHOOP recovery zone color
//   green  >= 67  (0.20, 0.83, 0.60)
//   yellow 34–66  (0.98, 0.75, 0.14)
//   red    < 34   (0.97, 0.44, 0.44)

func recoveryColor(_ score: Int?) -> Color {
    guard let s = score else { return Color(red: 0.55, green: 0.57, blue: 0.62) } // neutral gray
    if s >= 67 { return Color(red: 0.20, green: 0.83, blue: 0.60) }
    if s >= 34 { return Color(red: 0.98, green: 0.75, blue: 0.14) }
    return Color(red: 0.97, green: 0.44, blue: 0.44)
}

// Accent tints used consistently across the widget and host app.
enum WhoopTint {
    static let sleep = Color(red: 0.45, green: 0.62, blue: 0.98)
    static let strain = Color(red: 0.30, green: 0.78, blue: 0.86)
    static let heart = Color(red: 0.97, green: 0.44, blue: 0.44)
    static let food = Color(red: 0.98, green: 0.57, blue: 0.24)
}

// MARK: - Shared design system (used by app, menu popover AND the widget extension)

/// The one near-black canvas all three surfaces sit on. Lives here (not in the app-only `P`)
/// so the widget extension matches exactly instead of drifting bluer/lighter.
extension Color {
    static let whoopBG = Color(red: 0.024, green: 0.024, blue: 0.031)
}

/// One easing/duration family so count-ups, the ring sweep and the center number all land
/// together as a single gesture across every surface.
enum Motion {
    static let settle = Animation.easeOut(duration: 0.9)
    static let settleQuick = Animation.easeOut(duration: 0.55)
}

/// Recovery zone in words (matches the menu pill + widget label).
func zoneName(_ s: Int) -> String { s >= 67 ? "High" : s >= 34 ? "Medium" : "Low" }

/// Parse WHOOP's ISO8601 timestamps (with or without fractional seconds).
func parseISODate(_ iso: String?) -> Date? {
    guard let iso else { return nil }
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)
}

/// "Updated 2h ago" for the widget's freshness line (nil when there's no valid timestamp).
func freshnessText(_ iso: String?, now: Date = Date()) -> String? {
    guard let d = parseISODate(iso) else { return nil }
    let r = RelativeDateTimeFormatter(); r.unitsStyle = .abbreviated
    return "Updated " + r.localizedString(for: d, relativeTo: now)
}

/// A staggered fade+rise that assembles a screen on appear; `index` sets the per-row delay.
/// Shared so the dashboard Overview and the menu popover use one identical entrance.
struct Reveal: ViewModifier {
    let index: Int
    let on: Bool
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 10)
            .animation(.spring(response: 0.45, dampingFraction: 0.85).delay(Double(index) * 0.055), value: on)
    }
}
extension View {
    func reveal(_ index: Int, _ on: Bool) -> some View { modifier(Reveal(index: index, on: on)) }
}

// MARK: - Formatting helpers (shared by both targets)

/// "7h 12m" from decimal hours, "--" when nil / invalid.
func hm(_ hours: Double?) -> String {
    guard let h = hours, h.isFinite, h >= 0 else { return "--" }
    let m = Int((h * 60).rounded())
    return "\(m / 60)h \(String(format: "%02d", m % 60))m"
}

/// One-decimal strain value, "--" when nil.
func strainText(_ strain: WhoopSnapshot.Strain?) -> String {
    guard let v = strain?.value else { return "--" }
    return String(format: "%.1f", v)
}

/// Optional Int with an optional suffix, "--" when nil.
func intText(_ value: Int?, suffix: String = "") -> String {
    guard let v = value else { return "--" }
    return "\(v)\(suffix)"
}

/// Rounded, grouped calorie integer ("1,850") from an optional Double, "--" when nil.
func kcal(_ v: Double?) -> String {
    guard let v = v, v.isFinite else { return "--" }
    return Int(v.rounded()).formatted(.number.grouping(.automatic))
}

/// The widget's one-line fuel value: "1,850 / 2,200" when a goal is set, else "1,850 cal".
func fuelText(_ n: WhoopSnapshot.Nutrition?) -> String {
    guard let cal = n?.calories else { return "--" }
    if let goal = n?.goal, goal > 0 { return "\(kcal(cal)) / \(kcal(goal))" }
    return "\(kcal(cal)) cal"
}

// MARK: - Recovery ring (shared by both targets)

/// A circular progress ring whose trim length and color reflect the recovery
/// score, with the percentage rendered in the center. Pure SwiftUI Circle trims.
struct RecoveryRing: View {
    let score: Int?
    var lineWidth: CGFloat = 12
    /// Font size for the big "%" number in the center.
    var valueFontSize: CGFloat = 30
    /// Show the small "RECOVERY" caption under the number.
    var showCaption: Bool = true
    /// Count the number up on appear (host app only; widgets render statically).
    var animate: Bool = false
    @State private var shown: Double = 0

    private var fraction: CGFloat {
        guard let s = score else { return 0 }
        return min(max(CGFloat(s) / 100, 0), 1)
    }

    /// When animating, the arc is driven by the same counting-up `shown` value as the center
    /// number, so the ring fills in lockstep with the digits instead of appearing pre-filled.
    private var arcFraction: CGFloat {
        let raw = (animate && score != nil) ? CGFloat(shown) / 100 : fraction
        return min(max(raw, 0), 1)
    }

    private var color: Color { recoveryColor(score) }

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(color.opacity(0.18), lineWidth: lineWidth)

            // Progress arc, starting at 12 o'clock and sweeping clockwise.
            Circle()
                .trim(from: 0, to: arcFraction)
                .stroke(
                    color.gradient,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.35), radius: 4)
                // No implicit .animation here: when animating, the arc rides the same
                // withAnimation transaction that drives `shown` (so it sweeps up once, in
                // sync with the number, instead of double-animating up-then-down). When not
                // animating, arcFraction == fraction and it renders statically (widgets).

            // Center label
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    if animate, let s = score {
                        CountingNumber(value: shown)
                            .font(.system(size: valueFontSize, weight: .bold, design: .rounded))
                            .foregroundStyle(color)
                            .onAppear { shown = 0; withAnimation(Motion.settle) { shown = Double(s) } }
                            .onChange(of: s) { _, n in withAnimation(Motion.settleQuick) { shown = Double(n) } }
                    } else {
                        Text(score.map(String.init) ?? "--")
                            .font(.system(size: valueFontSize, weight: .bold, design: .rounded))
                            .foregroundStyle(color)
                    }
                    if score != nil {
                        Text("%")
                            .font(.system(size: valueFontSize * 0.45, weight: .bold, design: .rounded))
                            .foregroundStyle(color.opacity(0.85))
                    }
                }
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                if showCaption {
                    Text("RECOVERY")
                        .font(.system(size: max(7, valueFontSize * 0.26), weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A Text whose value animates (counts up) when changed inside `withAnimation`. Conforms to
/// Animatable so SwiftUI interpolates frame-by-frame; `render` formats the current value.
struct CountingNumber: View, Animatable {
    var value: Double
    var render: (Double) -> String = { "\(Int($0.rounded()))" }
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(render(value)).monospacedDigit()
    }
}
