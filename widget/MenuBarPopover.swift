// MenuBarPopover.swift  (host app target)
// The custom SwiftUI panel that drops from the menu-bar item — the recovery ring, three
// living "pillar" rows (recovery / sleep / strain) with day-over-day deltas, trends and
// progress, the latest workout, and quick actions, all styled like the app and choreographed
// to assemble on open. The Python engine runs headless; this app owns the menu bar.

import SwiftUI
import WidgetKit
import AppKit

/// Shared navigation state so the popover can deep-link the main window to a section.
@MainActor final class AppState: ObservableObject {
    @Published var section: AppSection = .overview
    @Published var expanded: ExpandedChart?   // the chart currently popped into the lightbox
}

// MARK: - Menu-bar label (the badge in the bar)

/// A compact recovery badge: a zone-colored ring + the score. Rendered to an NSImage so the
/// menu bar shows it in full color at the right size (SwiftUI labels can otherwise go template).
struct MenuBarLabel: View {
    @ObservedObject var data: WhoopData
    var body: some View {
        let score = data.latest?.recovery?.recovery_score
        if let img = MenuBarLabel.badge(score: score) {
            Image(nsImage: img)
        } else {
            Text("WHOOP")
        }
    }

    @MainActor static func badge(score: Int?) -> NSImage? {
        let renderer = ImageRenderer(content: MenuBarBadge(score: score))
        renderer.scale = 2
        let img = renderer.nsImage
        img?.isTemplate = false
        return img
    }
}

struct MenuBarBadge: View {
    var score: Int?
    var body: some View {
        let c = recoveryColor(score)
        let frac: CGFloat = score.map { min(max(CGFloat($0) / 100, 0), 1) } ?? 0
        HStack(spacing: 3) {
            ZStack {
                Circle().stroke(c.opacity(0.22), lineWidth: 2.4)
                Circle().trim(from: 0, to: frac)
                    .stroke(c, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            // The stroke is centered on the circle's path and overflows its frame by ~half the
            // line width; this inset keeps the full ring inside the rendered image so its edges
            // aren't clipped flat in the menu bar.
            .frame(width: 13, height: 13)
            .padding(2)
            Text(score.map(String.init) ?? "--")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(c)
        }
        .frame(height: 18)
    }
}

// MARK: - Press feedback (the staggered Reveal modifier now lives in WhoopShared.swift)

/// A shallow, non-bouncy press response shared by every clickable surface in the popover,
/// so a click feels physical instead of dead. Composes with each card's hover lift.
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - The popover panel

struct MenuBarPopover: View {
    @ObservedObject var data: WhoopData
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActive
    @State private var syncing = false
    @State private var syncError: String?
    @State private var appeared = false   // drives the entrance cascade (re-fires each open)
    @State private var visible = false    // gates repeatForever animations to on-screen only
    @State private var openHover = false  // hover state for the primary "Open WHOOP" pill

    /// True only while the popover is actually on-screen. `controlActiveState` flips to .inactive
    /// when AppKit orders the panel out — reliable even when .onDisappear doesn't fire in
    /// MenuBarExtra(.window) — so repeatForever animations never run off-screen between opens.
    private var active: Bool { visible && controlActive != .inactive }

    var body: some View {
        let rec = data.latest?.recovery
        let recP = data.latest?.recovery_prev
        let score = rec?.recovery_score
        let zone = recoveryColor(score)

        // Edge states: nothing loaded yet. Offline (engine unreachable) gets a calm card;
        // a genuine no-error cold load gets a redacted shimmer that resolves into real data.
        let offline = data.latest == nil && (data.error != nil || syncError != nil)
        let loadingCold = data.latest == nil && !offline

        VStack(alignment: .leading, spacing: 12) {
            header(score: score, zone: zone).reveal(0, appeared)

            if offline {
                coldStateCard().reveal(1, appeared)
            } else {
                Group {
                    hero(rec: rec, recP: recP, score: score, zone: zone).reveal(1, appeared)

                    VStack(spacing: 8) {
                        recoveryPillar(rec: rec, recP: recP, zone: zone).reveal(2, appeared)
                        sleepPillar().reveal(3, appeared)
                        strainPillar().reveal(4, appeared)
                    }
                }
                .redacted(reason: loadingCold ? .placeholder : [])
                .shimmering(active: loadingCold)
                .animation(.easeOut(duration: 0.3), value: loadingCold)

                if let w = data.workouts.first {
                    WorkoutStrip(workout: w) { open(.activities) }.reveal(5, appeared)
                }

                // Warm failure only (data present but the last sync failed) — a quiet inline note.
                if let err = syncError ?? data.error {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(P.yellow)
                        .lineLimit(2)
                        .reveal(6, appeared)
                }
            }

            footer().reveal(6, appeared)
        }
        .padding(15)
        .frame(width: 372)
        .background(P.bg)
        .environment(\.colorScheme, .dark)
        .task { await data.load(days: 30) }   // always refetch on open — never show a stale panel
        .onAppear { visible = true; appeared = false; withAnimation { appeared = true } }
        .onDisappear { visible = false; appeared = false }
    }

    // MARK: Header — live dot · WHOOP · zone pill · clock-driven synced time

    @ViewBuilder
    private func header(score: Int?, zone: Color) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let fresh = parseISODate(data.status?.last_sync).map { ctx.date.timeIntervalSince($0) < 900 } ?? false
            let dotColor = fresh ? P.teal : P.yellow
            HStack(spacing: 7) {
                Circle().fill(dotColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: dotColor, radius: 4)
                    .scaleEffect(active ? 1.25 : 1.0)
                    .opacity(active ? 0.6 : 1.0)
                    .animation(active ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true) : .default, value: active)
                Text("WHOOP").font(.system(size: 12, weight: .heavy)).tracking(3)
                if let s = score {
                    Text(zoneName(s).uppercased())
                        .font(.system(size: 9, weight: .heavy)).tracking(0.6)
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(zone.opacity(0.18), in: Capsule())
                        .foregroundStyle(zone)
                }
                Spacer(minLength: 4)
                if data.status?.last_sync != nil {
                    Text("Synced \(relativeSync(data.status?.last_sync, now: ctx.date))")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Cold / offline state — calm card instead of a wall of "--"

    @ViewBuilder
    private func coldStateCard() -> some View {
        VStack(spacing: 12) {
            RecoveryRing(score: nil, lineWidth: 8, valueFontSize: 26, showCaption: false, animate: false)
                .frame(width: 64, height: 64)
            VStack(spacing: 4) {
                Text(data.loading ? "Connecting…" : "WHOOP engine offline")
                    .font(.system(size: 13, weight: .bold))
                Text((syncError ?? data.error) ?? "Start the WHOOP engine to see your data.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22).padding(.horizontal, 14)
        .background(Color.white.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(P.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Hero — ring + greeting + day-over-day delta + status line

    @ViewBuilder
    private func hero(rec: LatestStats.Rec?, recP: LatestStats.Rec?, score: Int?, zone: Color) -> some View {
        let heroDelta = dII(score, recP?.recovery_score)
        HStack(spacing: 14) {
            // No "RECOVERY" caption here — at 78pt it crowds the ring; the header zone pill,
            // the status line, and the menu-bar badge already say this is recovery.
            RecoveryRing(score: score, lineWidth: 9, valueFontSize: 30, showCaption: false, animate: true)
                .frame(width: 78, height: 78)
                .overlay {
                    if let s = score, s >= 67, active { GreenCelebration(color: zone).frame(width: 78, height: 78) }
                }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("\(greeting())\(name)")
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    TrendChip(delta: heroDelta)
                }
                Text(recoveryStatus(score))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(zone)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(1)
            }
        }
    }

    // MARK: Pillars

    private func recoveryPillar(rec: LatestStats.Rec?, recP: LatestStats.Rec?, zone: Color) -> some View {
        let rhr = rec?.resting_heart_rate
        let rhrDelta = dII(rhr, recP?.resting_heart_rate)
        return PillarRow(
            icon: "heart.fill", label: "RECOVERY", accent: zone,
            value: rec?.hrv_rmssd_milli, render: { $0 == nil ? "--" : "\(Int($0!.rounded()))" }, unit: "ms",
            delta: dD(rec?.hrv_rmssd_milli, recP?.hrv_rmssd_milli), deltaDecimals: 0, deltaUnit: "",
            sparkValues: data.recovery.suffix(30).compactMap { $0.hrv_rmssd_milli },  // trend of the HRV headline
            onTap: { open(.recovery) }
        ) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(intStr(rhr)).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("bpm").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
                if rhrDelta != nil { miniDelta(rhrDelta, goodUp: false) }
                else { Text("RHR").font(.system(size: 8, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary) }
            }
        }
    }

    private func sleepPillar() -> some View {
        let slp = data.latest?.sleep
        let slpP = data.latest?.sleep_prev
        let frac = (slp?.hours).flatMap { h in (slp?.need_hours).map { n in n > 0 ? h / n : 0 } }
        return PillarRow(
            icon: "bed.double.fill", label: "SLEEP", accent: P.blue,
            value: slp?.hours, render: fmtHrs, unit: "",
            delta: dD(slp?.hours, slpP?.hours).map { $0 * 60 }, deltaDecimals: 0, deltaUnit: "m",
            sparkValues: data.sleep.suffix(30).compactMap { $0.hours },
            onTap: { open(.sleep) }
        ) {
            VStack(alignment: .trailing, spacing: 3) {
                ProgressBarMini(fraction: frac ?? 0, accent: P.blue)
                Text(slp?.performance.map { "\(Int($0.rounded()))% PERF" } ?? "vs need")
                    .font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    private func strainPillar() -> some View {
        let str = data.latest?.strain
        let strP = data.latest?.strain_prev
        return PillarRow(
            icon: "bolt.fill", label: "DAY STRAIN", accent: P.teal,   // teal matches the app's strain card/chart
            value: str?.strain, render: one, unit: "/21",
            delta: dD(str?.strain, strP?.strain), deltaDecimals: 1, deltaUnit: "",
            sparkValues: data.strain.suffix(30).compactMap { $0.strain },
            onTap: { open(.strain) }
        ) {
            VStack(alignment: .trailing, spacing: 3) {
                ProgressBarMini(fraction: (str?.strain).map { $0 / 21 } ?? 0, accent: P.teal)
                Text(str?.average_heart_rate.map { "AVG \($0)" } ?? "of 21")
                    .font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    // MARK: Footer — one condensed icon-led action row

    @ViewBuilder
    private func footer() -> some View {
        Divider().overlay(P.stroke)
        HStack(spacing: 8) {
            Button { open(.overview) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .semibold))
                    Text("Open WHOOP").font(.system(size: 12, weight: .semibold))
                }
                .padding(.vertical, 7).padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(P.teal.opacity(openHover ? 0.24 : 0.16))
                .overlay(Capsule().stroke(P.teal.opacity(openHover ? 0.6 : 0.4)))
                .clipShape(Capsule())
                .foregroundStyle(P.teal)
            }
            .buttonStyle(PressableButtonStyle())
            .onHover { h in withAnimation(.easeOut(duration: 0.18)) { openHover = h } }

            IconButton(icon: "arrow.clockwise", help: "Sync now", spinning: syncing) {
                Task { await syncNow() }
            }
            .disabled(syncing)

            IconButton(icon: "safari", help: "Open web dashboard") {
                NSWorkspace.shared.open(URL(string: "http://localhost:8756")!)
            }

            Spacer(minLength: 0)

            IconButton(icon: "power", help: "Quit", tint: .secondary) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: Helpers

    private var name: String {
        (data.status?.profile?.first_name).flatMap { $0.isEmpty ? nil : ", \($0)" } ?? ""
    }

    /// Compact inline delta (arrow + value) for secondary metrics. Inverted-polarity aware:
    /// e.g. a falling resting heart rate reads green via goodUp:false.
    @ViewBuilder
    private func miniDelta(_ d: Double?, goodUp: Bool, decimals: Int = 0) -> some View {
        if let d, d.isFinite {
            let flat = abs(d) < (decimals > 0 ? 0.05 : 0.5)
            let up = d >= 0
            let color: Color = flat ? .secondary : (up == goodUp ? P.green : P.red)
            HStack(spacing: 1) {
                Image(systemName: flat ? "arrow.right" : (up ? "arrow.up" : "arrow.down")).font(.system(size: 7, weight: .bold))
                Text("\(up ? "+" : "")\(String(format: "%.\(decimals)f", d))").font(.system(size: 9, weight: .bold)).monospacedDigit()
            }
            .foregroundStyle(color)
        }
    }

    private func dII(_ a: Int?, _ b: Int?) -> Double? { (a == nil || b == nil) ? nil : Double(a! - b!) }
    private func dD(_ a: Double?, _ b: Double?) -> Double? { (a == nil || b == nil) ? nil : a! - b! }

    private func open(_ section: AppSection) {
        appState.section = section
        NSApp.setActivationPolicy(.regular)   // promote to a full app (Dock icon) while open
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func syncNow() async {
        guard !syncing else { return }
        syncing = true; defer { syncing = false }
        syncError = nil
        var req = URLRequest(url: URL(string: "\(kAPIBase)/api/sync")!)
        req.httpMethod = "POST"; req.timeoutInterval = 60
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(code) {
                syncError = code == 409 ? "Not connected to WHOOP — open the app to reconnect." : "Sync unavailable (\(code))."
            }
        } catch {
            syncError = "Couldn't reach the WHOOP engine on localhost:8756."
        }
        await data.load(days: 30)
    }
}

// MARK: - Pillar row (recovery / sleep / strain) — reuses the app's card vocabulary

private struct PillarRow<Trailing: View>: View {
    let icon: String
    let label: String
    let accent: Color
    let value: Double?
    let render: (Double?) -> String
    let unit: String
    let delta: Double?
    var deltaDecimals: Int = 0
    var deltaUnit: String = ""
    let sparkValues: [Double]
    var onTap: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing
    @State private var hover = false

    var body: some View {
        Button { onTap?() } label: { card }
            .buttonStyle(PressableButtonStyle())
            .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }

    /// The 30-day trend line — collapsed entirely when there's too little history to plot, so a
    /// fresh/short-history account doesn't show an empty 44pt void on the row's right edge.
    @ViewBuilder private var trend: some View {
        if sparkValues.count >= 2 {
            Sparkline(values: sparkValues, color: accent)
                .frame(width: 44, height: 22)
                .drawIn()
        }
    }

    private var card: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    CountUp(value: value, render: render)
                        .font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                    if !unit.isEmpty {
                        Text(unit).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    TrendChip(delta: delta, unit: deltaUnit, decimals: deltaDecimals)
                }
                .lineLimit(1).minimumScaleFactor(0.8)   // safety net only — at 372pt nothing should scale
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            trailing
                .frame(width: 60, alignment: .trailing)  // room for "100% PERF" / "AVG 180" at full size
            trend
        }
        .padding(.vertical, 9).padding(.horizontal, 11)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(hover ? 0.07 : 0.04))
        .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 3).clipShape(Capsule()) }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(hover ? accent.opacity(0.45) : P.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .scaleEffect(hover ? 1.012 : 1)
    }
}

// MARK: - Latest workout strip (its own card so it has hover + press like the pillars)

private struct WorkoutStrip: View {
    let workout: WorkoutRow
    var onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(sportEmoji(workout.sport_name)).font(.system(size: 18))
                VStack(alignment: .leading, spacing: 1) {
                    Text("LAST WORKOUT").font(.system(size: 8, weight: .heavy)).tracking(0.6).foregroundStyle(.secondary)
                    Text((workout.sport_name ?? "Activity").capitalized).font(.system(size: 12, weight: .bold)).lineLimit(1)
                }
                Spacer(minLength: 6)
                miniStat("STRAIN", one(workout.strain))
                miniStat("HR", intStr(workout.average_heart_rate))
                if let d = workout.distance_meter, d > 0 { miniStat("KM", String(format: "%.2f", d / 1000)) }
                else { miniStat("CAL", grp(workout.calories)) }
            }
            .padding(.vertical, 8).padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .background(P.violet.opacity(hover ? 0.13 : 0.08))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(P.violet.opacity(hover ? 0.4 : 0.22)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(hover ? 1.012 : 1)
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Footer icon button (28pt circle with hover-lift + press + optional spin)

private struct IconButton: View {
    let icon: String
    let help: String
    var spinning: Bool = false
    var tint: Color = .primary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(hover ? 0.10 : 0.05), in: Circle())
                .overlay(Circle().stroke(hover ? tint.opacity(0.4) : P.stroke))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: spinning)
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }
}

// MARK: - Mini progress bar (fixed width avoids the GeometryReader first-pass 0-width flash)

private struct ProgressBarMini: View {
    let fraction: Double
    let accent: Color
    var width: CGFloat = 56
    @State private var filled = false

    var body: some View {
        let f = max(0, min(1, fraction.isFinite ? fraction : 0))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.10)).frame(width: width, height: 4)
            Capsule().fill(accent).frame(width: (filled ? f : 0) * width, height: 4)
        }
        .frame(width: width, alignment: .leading)
        .onAppear { filled = false; withAnimation(.easeOut(duration: 0.9).delay(0.2)) { filled = true } }
    }
}
