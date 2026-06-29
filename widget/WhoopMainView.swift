// WhoopMainView.swift  (host app target only)
// The native WHOOP app — a premium sidebar dashboard with Swift Charts, a recovery
// ring, insights, trend chips, and a recovery calendar, all reading the local API.

import SwiftUI
import Charts
import Combine
import AppKit

// MARK: - Palette

enum P {
    static let bg     = Color.whoopBG
    static let green  = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let teal   = Color(red: 0.18, green: 0.83, blue: 0.74)
    static let blue   = Color(red: 0.38, green: 0.65, blue: 0.98)
    static let violet = Color(red: 0.51, green: 0.55, blue: 0.97)
    static let red    = Color(red: 0.97, green: 0.44, blue: 0.44)
    static let orange = Color(red: 0.98, green: 0.57, blue: 0.24)
    static let yellow = Color(red: 0.98, green: 0.75, blue: 0.14)
    static let stroke = Color.white.opacity(0.07)
}

// Recovery line colored by zone via a vertical gradient mapped to the 0–100 y-scale
// (red < 34, yellow 34–66, green ≥ 67) — matches the ring + calendar zone language.
let recoveryGradient = LinearGradient(stops: [
    .init(color: P.red, location: 0.0), .init(color: P.red, location: 0.339),
    .init(color: P.yellow, location: 0.341), .init(color: P.yellow, location: 0.669),
    .init(color: P.green, location: 0.671), .init(color: P.green, location: 1.0),
], startPoint: .bottom, endPoint: .top)

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview", recovery = "Recovery", sleep = "Sleep", strain = "Strain", activities = "Activities"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .recovery: return "heart.fill"
        case .sleep: return "bed.double.fill"
        case .strain: return "bolt.fill"
        case .activities: return "figure.run"
        }
    }
    var accent: Color {
        switch self {
        case .overview: return P.teal
        case .recovery: return P.green
        case .sleep: return P.blue
        case .strain: return P.orange
        case .activities: return P.violet
        }
    }
}

// MARK: - Formatting

func fmtHrs(_ h: Double?) -> String {
    guard let h, h.isFinite, h >= 0 else { return "--" }
    let m = Int((h * 60).rounded()); return "\(m / 60)h \(String(format: "%02d", m % 60))m"
}
func one(_ v: Double?) -> String { v == nil ? "--" : String(format: "%.1f", v!) }
/// Trims a trailing ".0" for values the API already rounded (matches the web's raw render).
func trim1(_ v: Double?) -> String { guard let v, v.isFinite else { return "--" }; return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
func grp(_ v: Double?) -> String { guard let v, v.isFinite else { return "--" }; return Int(v).formatted(.number.grouping(.automatic)) }
func intStr(_ v: Int?, _ suffix: String = "") -> String { v == nil ? "--" : "\(v!)\(suffix)" }
// zoneName(_:) and parseISODate(_:) now live in WhoopShared.swift (shared with the widget).

func relativeSync(_ iso: String?) -> String { relativeSync(iso, now: Date()) }

/// Relative-time phrase against an explicit `now`, so a TimelineView can keep it ticking live
/// (and reflect a fresh last_sync immediately) instead of freezing the bucket it first rendered in.
func relativeSync(_ iso: String?, now: Date) -> String {
    guard let d = parseISODate(iso) else { return "—" }
    let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .abbreviated
    return rel.localizedString(for: d, relativeTo: now)
}

func sportEmoji(_ n: String?) -> String {
    let s = (n ?? "").lowercased()
    if s.contains("run") || s.contains("tread") { return "🏃" }
    if s.contains("weight") || s.contains("strength") || s.contains("functional") { return "🏋️" }
    if s.contains("cycl") || s.contains("bik") { return "🚴" }
    if s.contains("swim") { return "🏊" }
    if s.contains("walk") { return "🚶" }
    if s.contains("pickle") { return "🏓" }
    if s.contains("volley") { return "🏐" }
    if s.contains("yoga") || s.contains("pilates") { return "🧘" }
    if s.contains("basket") { return "🏀" }
    if s.contains("soccer") { return "⚽️" }
    return "💪"
}

// Clean, limited X-axis for time series (mirrors the web's maxTicksLimit: 8).
struct TimeAxisStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) {
                AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.system(size: 10))
            }
        }
    }
}
extension View { func timeAxis() -> some View { modifier(TimeAxisStyle()) } }

// Nearest data point to a hovered/selected date (for chart tooltips).
func nearestDay<T>(_ data: [T], _ dayOf: (T) -> String, to date: Date) -> T? {
    data.min(by: { abs(parseDay(dayOf($0)).timeIntervalSince(date)) < abs(parseDay(dayOf($1)).timeIntervalSince(date)) })
}

func chartTip(_ day: String, _ value: String) -> some View {
    VStack(spacing: 1) {
        Text(day).font(.system(size: 9)).foregroundStyle(.secondary)
        Text(value).font(.system(size: 12, weight: .bold))
    }
    .padding(.horizontal, 8).padding(.vertical, 5)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7).stroke(P.stroke))
}

// MARK: - Insights

struct Insight: Identifiable {
    let id = UUID()
    let icon: String, title: String, detail: String, tone: Color
}

@MainActor
func computeInsights(_ d: WhoopData) -> [Insight] {
    func mean(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
    var out: [Insight] = []

    let scores = d.recovery.compactMap { $0.recovery_score }
    if scores.count >= 8 {
        let last7 = Array(scores.suffix(7))
        let prev7 = Array(scores.dropLast(7).suffix(7))   // 7 days before the last 7 (matches web slice(-14,-7))
        if let a = mean(last7.map(Double.init)), let b = mean(prev7.map(Double.init)) {
            let delta = Int((a - b).rounded())
            out.append(Insight(
                icon: delta >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
                title: delta > 2 ? "Recovery trending up" : delta < -2 ? "Recovery dipping" : "Recovery holding steady",
                detail: "7-day average \(Int(a))% vs \(Int(b))% the week before.",
                tone: delta > 2 ? P.green : delta < -2 ? P.red : P.blue))
        }
    }
    let hrs = d.sleep.compactMap { $0.hours }, need = d.sleep.compactMap { $0.need_hours }
    if let g = mean(hrs), let n = mean(need) {
        let gap = n - g
        out.append(Insight(icon: "moon.stars.fill",
            title: gap > 0.5 ? "Carrying sleep debt" : "Meeting your sleep need",
            detail: gap > 0.5
                ? "Averaging \(fmtHrs(g)) vs \(fmtHrs(n)) needed — about \(Int((gap*60).rounded()))m short nightly."
                : "Averaging \(fmtHrs(g)) of \(fmtHrs(n)) needed.",
            tone: gap > 0.5 ? P.red : P.green))
    }
    if scores.count >= 7 {
        var byWd: [Int: [Double]] = [:]
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = Locale(identifier: "en_US_POSIX")
        for p in d.recovery {
            if let s = p.recovery_score, let dt = fmt.date(from: p.day) {
                byWd[Calendar.current.component(.weekday, from: dt), default: []].append(Double(s))
            }
        }
        let names = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        // Deterministic, ascending-weekday tie-break (matches the web's first-wins order).
        let means = byWd.mapValues { mean($0) ?? 0 }
        if let best = means.sorted(by: { $0.key < $1.key }).max(by: { $0.value < $1.value }) {
            out.append(Insight(icon: "checkmark.seal.fill",
                title: "Best recovery on \(names[best.key])s",
                detail: "You average \(Int(best.value.rounded()))% recovery on \(names[best.key])s.",
                tone: P.teal))
        }
    }
    if let s = d.sports.first {
        out.append(Insight(icon: "trophy.fill",
            title: "Go-to: \(s.sport_name.capitalized)",
            detail: "\(s.count) sessions logged · \(trim1(s.avg_strain)) avg strain.",
            tone: P.violet))
    }
    return Array(out.prefix(4))
}

// MARK: - Building blocks

struct AmbientBackground: View {
    @Environment(\.controlActiveState) private var controlActive
    @State private var drift = false
    var body: some View {
        let active = controlActive != .inactive
        ZStack {
            P.bg
            blob(P.teal.opacity(0.16),   760, drift ? 300 : 340, drift ? -370 : -320, 40)
            blob(P.violet.opacity(0.14), 720, drift ? -370 : -320, drift ? -250 : -320, 40)
            blob(P.green.opacity(0.08),  720, drift ? 36 : -36,    drift ? 500 : 460, 50)
        }
        .ignoresSafeArea()
        // Slow, continuous drift so the backdrop feels alive (great on a demo screen) — but
        // paused when the window isn't active so it doesn't burn cycles off-screen.
        .animation(active ? .easeInOut(duration: 17).repeatForever(autoreverses: true) : .easeOut(duration: 0.8), value: drift)
        .onAppear { drift = active }
        .onChange(of: active) { _, a in drift = a }
    }
    private func blob(_ c: Color, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat, _ blur: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [c, .clear], center: .center, startRadius: 0, endRadius: size * 0.55))
            .frame(width: size, height: size).blur(radius: blur).offset(x: x, y: y)
    }
}

// MARK: - Demo polish (count-up, chart draw-in, shimmer skeleton, celebration)

/// Animates from 0 → value on appear (and on change); shows "--" when nil. Apply .font(...).
struct CountUp: View {
    var value: Double?
    var render: (Double?) -> String
    @State private var shown: Double = 0
    var body: some View {
        CountingNumber(value: shown, render: { value == nil ? render(nil) : render($0) })
            // Entrance: count up from 0. On a later change (e.g. stepping days / a refresh):
            // interpolate from the CURRENT value to the new one — no flash back to 0 — and use the
            // same quick settle as the ring so digits and arc move together.
            .onAppear { shown = 0; if let v = value { withAnimation(Motion.settle) { shown = v } } }
            .onChange(of: value) { _, v in withAnimation(Motion.settleQuick) { shown = v ?? 0 } }
    }
}

/// Sweeps a chart in left-to-right on appear (re-fires when its section re-appears).
struct DrawInReveal: ViewModifier {
    @State private var reveal = false
    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                GeometryReader { geo in Rectangle().frame(width: reveal ? geo.size.width : 0) }
            }
            .onAppear { reveal = false; withAnimation(.easeInOut(duration: 0.85)) { reveal = true } }
    }
}
extension View { func drawIn() -> some View { modifier(DrawInReveal()) } }

/// A shimmering placeholder bar for loading/skeleton states.
struct Skeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    @State private var x: CGFloat = -1.2
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(0.06))
            .frame(width: width, height: height)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Color.white.opacity(0.16), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: x * geo.size.width)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onAppear { withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) { x = 1.6 } }
    }
}

/// A restrained "you're recovered" moment: two soft ripples expand once on appear, then a
/// whisper-quiet glow breathes around the ring. No confetti — just a premium beat.
struct GreenCelebration: View {
    let color: Color
    @State private var ripple = false
    @State private var pulse = false
    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle().stroke(color.opacity(0.45), lineWidth: 1.5)
                    .scaleEffect(ripple ? 1.55 : 0.96)
                    .opacity(ripple ? 0 : 0.5)
                    .animation(.easeOut(duration: 1.7).delay(Double(i) * 0.35), value: ripple)
            }
            Circle().stroke(color.opacity(0.35), lineWidth: 2).blur(radius: 3)
                .scaleEffect(pulse ? 1.06 : 0.99).opacity(pulse ? 0.15 : 0.5)
        }
        .allowsHitTesting(false)
        .onAppear {
            ripple = true
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// Sweeps a light gradient across content — pairs with `.redacted(.placeholder)` for a
/// shimmering skeleton while data loads.
struct Shimmer: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = -1.2
    func body(content: Content) -> some View {
        if active {
            content.overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width)
                        .blendMode(.plusLighter)
                }.allowsHitTesting(false)
            )
            .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.7 } }
        } else {
            content
        }
    }
}
extension View { func shimmering(active: Bool) -> some View { modifier(Shimmer(active: active)) } }

struct Glass<Content: View>: View {
    var title: String? = nil
    var accent: Color? = nil
    @ViewBuilder var content: Content
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(0.8).foregroundStyle(.secondary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color.white.opacity(hover ? 0.075 : 0.05), Color.white.opacity(0.015)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .leading) { if let accent { Rectangle().fill(accent).frame(width: 3).clipShape(Capsule()) } }
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(hover ? (accent ?? P.teal).opacity(0.4) : P.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: hover ? (accent ?? .black).opacity(0.28) : .black.opacity(0.35), radius: hover ? 24 : 18, y: 8)
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hover = h } }
    }
}

struct TrendChip: View {
    let delta: Double?
    var unit: String = ""
    var decimals: Int = 0
    var goodUp = true
    var body: some View {
        if let d = delta, d.isFinite {
            let flat = abs(d) < (decimals > 0 ? 0.05 : 0.5)
            let up = d >= 0
            let color = flat ? Color.secondary : (up == goodUp ? P.green : P.red)
            HStack(spacing: 3) {
                Image(systemName: flat ? "arrow.right" : (up ? "arrow.up" : "arrow.down")).font(.system(size: 9, weight: .bold))
                Text("\(up ? "+" : "")\(String(format: "%.\(decimals)f", d))\(unit)").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
        }
    }
}

struct StatTile: View {
    let label: String, value: String
    var accent: Color = P.teal
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 23, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(Color.white.opacity(hover ? 0.07 : 0.04))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(hover ? accent.opacity(0.45) : P.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .scaleEffect(hover ? 1.025 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }
}

func kv(_ k: String, _ v: String) -> some View {
    HStack { Text(k).font(.system(size: 12)).foregroundStyle(.secondary); Spacer()
        Text(v).font(.system(size: 13, weight: .semibold)).monospacedDigit() }
}

/// Canonical all-caps section eyebrow — same tracking as a Glass card title, so inline
/// labels (INSIGHTS / AVERAGES / SLEEP / DAY STRAIN) read identically to titled cards.
func sectionEyebrow(_ t: String) -> some View {
    Text(t.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(0.8).foregroundStyle(.secondary)
}

/// A designed empty state (icon + line, accent-tinted) for sparse ranges, instead of a bare
/// gray sentence dropped into a premium card.
func emptyState(_ icon: String, _ text: String, accent: Color) -> some View {
    VStack(spacing: 8) {
        Image(systemName: icon).font(.system(size: 22)).foregroundStyle(accent.opacity(0.6))
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity).padding(.vertical, 24)
}

/// "Thu, Jun 25" for a yyyy-MM-dd day string.
func napDate(_ day: String?) -> String {
    guard let day else { return "—" }
    let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; f.locale = .current
    return f.string(from: parseDay(day))
}
/// "6:07 PM" for an ISO timestamp, in local time.
func napClock(_ iso: String?) -> String? {
    guard let d = parseISODate(iso) else { return nil }
    let f = DateFormatter(); f.dateFormat = "h:mm a"; f.locale = .current
    return f.string(from: d)
}

// Tiny inline trend chart for the hero cards.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        if values.count >= 2 {
            Chart(Array(values.enumerated()), id: \.offset) { item in
                AreaMark(x: .value("i", item.offset), y: .value("v", item.element))
                    .foregroundStyle(.linearGradient(colors: [color.opacity(0.22), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("i", item.offset), y: .value("v", item.element))
                    .foregroundStyle(color).lineStyle(.init(lineWidth: 1.5)).interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden).frame(height: 30)
        }
    }
}

// MARK: - Tap-to-expand interactive charts (lightbox)

/// Payload for the currently expanded chart. The chart is a closure of (expanded, selection
/// binding) so the SAME bespoke `Chart {…}` body renders both inline and enlarged, and the
/// lightbox owns the scrubbing selection.
struct ExpandedChart: Identifiable {
    let id: String
    let title: String
    let accent: Color
    let chart: (_ expanded: Bool, _ sel: Binding<Date?>) -> AnyView
}

/// Wraps a chart in a Glass card that, on tap, pops it into a large interactive lightbox.
/// Inline it has no selection/scrub (so the tap is unambiguous); all interactivity lives in
/// the expanded view, where there's room for it.
struct ChartCard<Content: View>: View {
    let id: String
    let title: String
    let accent: Color
    var canExpand: Bool = true
    @ViewBuilder let content: (_ expanded: Bool, _ sel: Binding<Date?>) -> Content
    @EnvironmentObject private var appState: AppState
    @State private var hover = false

    var body: some View {
        Glass(title: title, accent: accent) {
            content(false, .constant(nil))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .opacity(hover && canExpand ? 0.9 : 0)
                        .help("Expand")
                }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard canExpand else { return }
            appState.expanded = ExpandedChart(id: id, title: title, accent: accent) { exp, sel in
                AnyView(content(exp, sel))
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
        .scaleEffect(hover ? 1.004 : 1)
    }
}

/// The full-window modal that presents an expanded chart: dim+blur backdrop, a Glass panel
/// that springs in, and Esc / X / click-outside to dismiss.
struct ChartLightbox: View {
    let item: ExpandedChart
    var onClose: () -> Void
    @State private var present = false
    @State private var sel: Date?
    @State private var closing = false
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { proxy in
            let w = min(proxy.size.width * 0.84, 980)
            let h = min(proxy.size.height * 0.82, 740)
            ZStack {
                // Backdrop — animate opacity only (never blur radius).
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color.black.opacity(0.38)
                }
                .opacity(present ? 1 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

                panel
                    .frame(width: w, height: h)
                    .scaleEffect(present ? 1 : 0.94)
                    .opacity(present ? 1 : 0)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .allowsHitTesting(!closing)   // stop the fading backdrop from eating clicks/Esc during exit
        .focusable()
        .focused($focused)
        .onExitCommand { close() }
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { present = true }
            focused = true
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(item.title.uppercased())
                    .font(.system(size: 12, weight: .heavy)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(P.stroke))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }
            item.chart(true, $sel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
        .background(LinearGradient(colors: [.white.opacity(0.06), .white.opacity(0.015)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .leading) { Rectangle().fill(item.accent).frame(width: 3).clipShape(Capsule()) }
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(item.accent.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
        .background(P.bg.clipShape(RoundedRectangle(cornerRadius: 20)))   // opaque base so the blurred dashboard doesn't bleed through
        .contentShape(Rectangle())
        .onTapGesture {}   // swallow taps so they don't reach the backdrop (scrub is a drag, unaffected)
    }

    private func close() {
        guard !closing else { return }
        closing = true
        sel = nil   // don't render a frozen crosshair through the dismiss animation
        withAnimation(.spring(response: 0.28, dampingFraction: 0.92)) { present = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { onClose() }
    }
}

// MARK: Chart helpers shared by inline + expanded rendering

extension View {
    // No-op now: the expanded charts are scrollable, and chartXSelection's click-drag would
    // fight the scroll gesture. Selection is driven entirely by the hover crosshair (cursorScrub).
    @ViewBuilder func chartXSelectionIf(_ on: Bool, value: Binding<Date?>) -> some View { self }
    @ViewBuilder func applyIf<T: View>(_ cond: Bool, _ transform: (Self) -> T) -> some View {
        if cond { transform(self) } else { self }
    }
}

/// Larger axes + faint y-gridlines when expanded; the compact `timeAxis()` inline.
struct ExpandableAxis: ViewModifier {
    let expanded: Bool
    func body(content: Content) -> some View {
        if expanded {
            content
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 8)) {
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.system(size: 11))
                    }
                }
                .chartYAxis {
                    AxisMarks {
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                        AxisValueLabel().font(.system(size: 11))
                    }
                }
        } else {
            content.timeAxis()
        }
    }
}

/// Cursor-tracking crosshair: hovering the expanded plot drives `sel` so the rule + tooltip
/// follow the pointer without a click. Line/area charts only.
struct CursorScrub: ViewModifier {
    @Binding var sel: Date?
    let active: Bool
    func body(content: Content) -> some View {
        // Built-in selection (click/drag to scrub) instead of a clear hover overlay — the overlay
        // captured the drag and blocked horizontal scrolling. chartXSelection is designed to
        // coexist with .chartScrollableAxes (two-finger scroll pans; click/drag scrubs).
        if active { content.chartXSelection(value: $sel) }
        else { content }
    }
}
extension View {
    func cursorScrub(_ sel: Binding<Date?>, active: Bool) -> some View { modifier(CursorScrub(sel: sel, active: active)) }
}

/// Makes an expanded chart horizontally scroll + zoom: two-finger scroll to pan, pinch or the
/// on-chart +/- controls to zoom, "fit" to show everything. Opens framed on the most recent
/// window (~30 days) so big ranges (90d / 6M / 1Y / All) are inspectable. Inactive inline.
struct ScrollZoom: ViewModifier {
    let active: Bool
    let firstDay: String?   // oldest day in the series
    let lastDay: String?    // most recent day, so we open showing the latest window
    @State private var visible: Double = 30
    @State private var started = false

    private let day: Double = 86_400
    private let pad: Double = 2 * 86_400   // trailing margin so the latest point isn't flush on the right edge

    private var firstDate: Date { parseDay(firstDay) }
    private var lastDate: Date { parseDay(lastDay) }
    /// The scrollable domain: all data, plus a couple days of breathing room on each end so a point
    /// at the very start/end is never clipped against the plot edge.
    private var domain: ClosedRange<Date> {
        firstDate.addingTimeInterval(-0.5 * day) ... lastDate.addingTimeInterval(pad)
    }
    private var spanDays: Double { max(lastDate.timeIntervalSince(firstDate) / day, 1) }
    private var maxVisible: Double { max(spanDays + 3, 14) }   // zoom-out can show the whole padded domain
    private func clamp(_ v: Double) -> Double { min(max(v, 7), maxVisible) }

    /// Anchor the window's TRAILING edge to the padded domain end, so "today" sits ~2 days inside
    /// the right edge instead of clamped flush against it.
    private var initialX: Date {
        domain.upperBound.addingTimeInterval(-visible * day)
    }

    func body(content: Content) -> some View {
        if active {
            content
                .chartXScale(domain: domain)
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visible * day)
                .chartScrollPosition(initialX: initialX)
                .overlay(alignment: .bottomTrailing) { controls }   // bottom corner — clear of the lightbox X button
                .onAppear {
                    guard !started else { return }
                    started = true
                    visible = min(spanDays + 2, 30)
                }
        } else {
            content
        }
    }

    private func zoom(_ factor: Double) {
        withAnimation(.easeOut(duration: 0.25)) { visible = clamp(visible * factor) }
    }

    private var controls: some View {
        HStack(spacing: 1) {
            ctl("minus", "Zoom out") { zoom(1.7) }
            ctl("plus", "Zoom in") { zoom(1 / 1.7) }
            ctl("arrow.left.and.right", "Fit all") { withAnimation(.easeOut(duration: 0.25)) { visible = maxVisible } }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(P.stroke))
        .padding(8)
    }

    private func ctl(_ icon: String, _ help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
extension View {
    func scrollZoom(active: Bool, firstDay: String?, lastDay: String?) -> some View {
        modifier(ScrollZoom(active: active, firstDay: firstDay, lastDay: lastDay))
    }
}

/// MIN / AVG / MAX / LATEST summary cells shown above an expanded chart.
@ViewBuilder
func chartStatStrip(_ values: [Double], _ fmt: @escaping (Double) -> String, accent: Color) -> some View {
    let xs = values.filter { $0.isFinite }
    let avg = xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    HStack(spacing: 10) {
        chartStatCell("MIN", xs.min(), fmt, accent)
        chartStatCell("AVG", avg, fmt, accent)
        chartStatCell("MAX", xs.max(), fmt, accent)
        chartStatCell("LATEST", xs.last, fmt, accent)
    }
}
private func chartStatCell(_ label: String, _ v: Double?, _ fmt: (Double) -> String, _ accent: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(v.map(fmt) ?? "--").font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(accent)
        Text(label).font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 9).padding(.horizontal, 12)
    .background(Color.white.opacity(0.04))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(P.stroke))
    .clipShape(RoundedRectangle(cornerRadius: 12))
}

// MARK: Reusable chart builders (shared by the sections AND the Overview expand cards)

@MainActor @ViewBuilder
func recoveryScoreChart(_ data: WhoopData, expanded: Bool, sel: Binding<Date?>) -> some View {
    VStack(spacing: 14) {
        if expanded { chartStatStrip(data.recovery.compactMap { $0.recovery_score.map(Double.init) }, { "\(Int($0))%" }, accent: P.green) }
        Chart {
            ForEach(data.recovery) { p in
                if let v = p.recovery_score {
                    AreaMark(x: .value("Day", parseDay(p.day)), y: .value("Recovery", v))
                        .foregroundStyle(.linearGradient(colors: [P.green.opacity(0.18), P.green.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", parseDay(p.day)), y: .value("Recovery", v))
                        .foregroundStyle(recoveryGradient).lineStyle(.init(lineWidth: 2.5)).interpolationMethod(.catmullRom)
                }
            }
            if expanded, let s = sel.wrappedValue, let p = nearestDay(data.recovery, \.day, to: s), let v = p.recovery_score {
                RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.18))
                PointMark(x: .value("Day", parseDay(p.day)), y: .value("Recovery", v)).foregroundStyle(recoveryColor(v)).symbolSize(70)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { chartTip(p.day, "\(v)%") }
            }
        }
        .chartYScale(domain: 0...100)
        .modifier(ExpandableAxis(expanded: expanded))
        .cursorScrub(sel, active: expanded)
        .scrollZoom(active: expanded, firstDay: data.recovery.first?.day, lastDay: data.recovery.last?.day)
        .frame(height: expanded ? nil : 230)
        .frame(maxHeight: expanded ? .infinity : nil)
        .applyIf(!expanded) { $0.drawIn() }
    }
}

@MainActor @ViewBuilder
func sleepHoursChart(_ data: WhoopData, expanded: Bool, sel: Binding<Date?>) -> some View {
    VStack(spacing: 14) {
        if expanded { chartStatStrip(data.sleep.compactMap { $0.hours }, { fmtHrs($0) }, accent: P.blue) }
        Chart {
            ForEach(data.sleep) { p in
                if let v = p.hours {
                    AreaMark(x: .value("Day", parseDay(p.day)), y: .value("Hours", v))
                        .foregroundStyle(.linearGradient(colors: [P.blue.opacity(0.25), P.blue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", parseDay(p.day)), y: .value("Hours", v)).foregroundStyle(P.blue).interpolationMethod(.catmullRom)
                }
            }
            if expanded, let s = sel.wrappedValue, let p = nearestDay(data.sleep, \.day, to: s), let v = p.hours {
                RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.18))
                PointMark(x: .value("Day", parseDay(p.day)), y: .value("Hours", v)).foregroundStyle(P.blue).symbolSize(70)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { chartTip(p.day, fmtHrs(v)) }
            }
        }
        .modifier(ExpandableAxis(expanded: expanded))
        .cursorScrub(sel, active: expanded)
        .scrollZoom(active: expanded, firstDay: data.sleep.first?.day, lastDay: data.sleep.last?.day)
        .frame(height: expanded ? nil : 230)
        .frame(maxHeight: expanded ? .infinity : nil)
        .applyIf(!expanded) { $0.drawIn() }
    }
}

@MainActor @ViewBuilder
func dayStrainChart(_ data: WhoopData, expanded: Bool, sel: Binding<Date?>) -> some View {
    VStack(spacing: 14) {
        if expanded { chartStatStrip(data.strain.compactMap { $0.strain }, { one($0) }, accent: P.teal) }
        Chart {
            ForEach(data.strain) { p in
                if let v = p.strain { BarMark(x: .value("Day", parseDay(p.day)), y: .value("Strain", v)).foregroundStyle(P.teal.gradient) }
            }
            if expanded, let s = sel.wrappedValue, let p = nearestDay(data.strain, \.day, to: s), let v = p.strain {
                RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { chartTip(p.day, one(v)) }
            }
        }
        .chartYScale(domain: 0...21)
        .modifier(ExpandableAxis(expanded: expanded))
        .cursorScrub(sel, active: expanded)
        .scrollZoom(active: expanded, firstDay: data.strain.first?.day, lastDay: data.strain.last?.day)
        .frame(height: expanded ? nil : 230)
        .frame(maxHeight: expanded ? .infinity : nil)
        .applyIf(!expanded) { $0.drawIn() }
    }
}

/// Wraps arbitrary inline card content (e.g. the Overview hero / sleep / strain cards) so that
/// tapping it pops a related full chart into the lightbox. Unlike ChartCard, the inline content
/// and the expanded chart are different views.
struct ExpandableCard<Inline: View>: View {
    let id: String
    let title: String
    let accent: Color
    var canExpand: Bool = true
    let makeChart: (_ expanded: Bool, _ sel: Binding<Date?>) -> AnyView
    @ViewBuilder let inline: () -> Inline
    @EnvironmentObject private var appState: AppState
    @State private var hover = false

    var body: some View {
        inline()
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .opacity(hover && canExpand ? 0.9 : 0)
                    .help("Expand")
                    .padding(6)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard canExpand else { return }
                appState.expanded = ExpandedChart(id: id, title: title, accent: accent, chart: makeChart)
            }
            .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }
}

// MARK: - Calendar heatmap

struct CalendarHeatmap: View {
    let points: [RecoveryPoint]
    private struct Cell { let day: String?; let score: Int? }
    private let wdLabels = ["S", "M", "T", "W", "T", "F", "S"]
    private let cols: [[Cell]]   // built once at init, not on every body render (matters on the "All" range)

    init(points: [RecoveryPoint]) {
        self.points = points
        self.cols = Self.buildColumns(points)
    }

    private static func buildColumns(_ points: [RecoveryPoint]) -> [[Cell]] {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = Locale(identifier: "en_US_POSIX")
        var map: [String: Int] = [:]; var dates: [Date] = []
        for p in points { if let dt = fmt.date(from: p.day) { dates.append(dt); if let s = p.recovery_score { map[p.day] = s } } }
        guard let first = dates.min(), let last = dates.max() else { return [] }
        let cal = Calendar(identifier: .gregorian)
        var cur = cal.date(byAdding: .day, value: -(cal.component(.weekday, from: first) - 1), to: first)!
        var out: [[Cell]] = []; var col: [Cell] = []
        while cur <= last {
            let key = fmt.string(from: cur)
            col.append(Cell(day: cur >= first ? key : nil, score: map[key]))
            if col.count == 7 { out.append(col); col = [] }
            cur = cal.date(byAdding: .day, value: 1, to: cur)!
        }
        if !col.isEmpty { while col.count < 7 { col.append(Cell(day: nil, score: nil)) }; out.append(col) }
        return out
    }
    private func color(_ s: Int?) -> Color { s == nil ? Color.white.opacity(0.05) : recoveryColor(s) }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { i in
                    Text(wdLabels[i]).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12, height: 12)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { r in
                                RoundedRectangle(cornerRadius: 2.5).fill(color(col[r].score)).frame(width: 12, height: 12)
                                    .help(col[r].day == nil ? "" : "\(col[r].day!): \(col[r].score.map { "\($0)%" } ?? "no data")")
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Root

/// The detail-header refresh button — styled like StatTile (white-opacity fill, P.stroke,
/// hover) instead of stock AppKit chrome, and the arrow spins exactly once per press.
struct RefreshButton: View {
    let action: () -> Void
    @State private var hover = false
    @State private var spins = 0
    var body: some View {
        Button { spins += 1; action() } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(hover ? 0.07 : 0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(hover ? P.teal.opacity(0.45) : P.stroke))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .rotationEffect(.degrees(Double(spins) * 360))
                .animation(.easeInOut(duration: 0.6), value: spins)
        }
        .buttonStyle(.plain)
        .help("Refresh")
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }
}

struct WhoopMainView: View {
    @ObservedObject var data: WhoopData
    @EnvironmentObject private var appState: AppState
    @State private var days = 30

    var body: some View {
        ZStack {
        NavigationSplitView {
            List(AppSection.allCases, selection: $appState.section) { s in
                Label {
                    Text(s.rawValue).font(.system(size: 13.5, weight: appState.section == s ? .semibold : .medium))
                } icon: {
                    Image(systemName: s.icon)
                        .foregroundStyle(appState.section == s ? P.teal : Color.secondary)
                }.tag(s)
            }
            .tint(P.teal)   // one accent for selection — restraint over a rainbow of colors
            .navigationSplitViewColumnWidth(min: 188, ideal: 200, max: 230)
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 9) {
                        Circle().fill(P.teal).frame(width: 9, height: 9).shadow(color: P.teal, radius: 5)
                        Text("WHOOP").font(.system(size: 16, weight: .heavy)).tracking(3)
                        Spacer()
                    }
                    if let name = data.status?.profile?.first_name, !name.isEmpty {
                        Text(name).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 18)
                    }
                }.padding(.horizontal, 18).padding(.top, 30).padding(.bottom, 4)
            }
            .safeAreaInset(edge: .bottom) {
                if let st = data.status {
                    VStack(alignment: .leading, spacing: 2) {
                        if let c = st.counts {
                            Text("\(c.days ?? 0) days · \(c.workouts ?? 0) workouts").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text("Synced \(relativeSync(st.last_sync))").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 18).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } detail: {
            ZStack {
                AmbientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if let e = data.error { banner(e) }
                        Group {
                            switch appState.section {
                            case .overview: OverviewSection(data: data)
                            case .recovery: RecoverySection(data: data)
                            case .sleep: SleepSection(data: data)
                            case .strain: StrainSection(data: data)
                            case .activities: ActivitiesSection(data: data)
                            }
                        }
                        .redacted(reason: (data.latest == nil && data.error == nil) ? .placeholder : [])
                        .shimmering(active: data.latest == nil && data.error == nil)
                        .id(appState.section)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
                    }
                    .padding(28).padding(.bottom, 44)   // breathing room so the last row scrolls fully into view
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.spring(response: 0.42, dampingFraction: 0.86), value: appState.section)
                }
                .scrollContentBackground(.hidden)
                .scrollDisabled(appState.expanded != nil)   // don't scroll the dashboard behind the lightbox
            }
        }
        .task { await data.load(days: days) }
        .onChange(of: days) { _, v in Task { await data.load(days: v) } }
        // Auto-refresh every 60s so the app stays current with the menu-bar app's syncs.
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if !data.loading { Task { await data.load(days: days) } }
        }
        // Deep links from the menu bar: whoop://recovery, whoop://sleep, … open the app here.
        .onOpenURL { url in
            if let s = AppSection(rawValue: (url.host ?? "").capitalized) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { appState.section = s }
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

            // Tap-to-expand chart lightbox — mounted at the root so it dims the whole window and
            // is never caught by the section's redaction/shimmer.
            if let item = appState.expanded {
                ChartLightbox(item: item) { appState.expanded = nil }
                    .zIndex(10)
            }
        }
        .frame(minWidth: 1000, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(appState.section.rawValue).font(.system(size: 30, weight: .bold))
            if data.loading { ProgressView().controlSize(.small).padding(.leading, 4) }
            Spacer()
            Picker("", selection: $days) {
                Text("7D").tag(7); Text("30D").tag(30); Text("90D").tag(90)
                Text("6M").tag(180); Text("1Y").tag(365); Text("All").tag(1825)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300).controlSize(.large)
            RefreshButton { Task { await data.load(days: days) } }
        }
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(P.yellow)
            Text(text).font(.callout)
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(P.yellow.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(P.yellow.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

// MARK: - Overview

func greeting() -> String {
    let h = Calendar.current.component(.hour, from: Date())
    return h < 5 ? "Still up" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
}

func recoveryStatus(_ score: Int?) -> String {
    guard let s = score else { return "Recovery is still being scored — check back once your sleep is processed." }
    if s >= 67 { return "You're in the green. Your body is primed — a great day to take on strain." }
    if s >= 34 { return "Moderately recovered. Train smart and keep an eye on your strain today." }
    return "Recovery is low. Prioritize rest, hydration, and easy movement today."
}

/// The Overview centerpiece: a big animated recovery ring + a personal greeting, a
/// zone-colored status line, the key recovery metrics, and a 30-day sparkline — all on a
/// glowing, recovery-zone-tinted panel.
struct HeroCard: View {
    @ObservedObject var data: WhoopData
    @Environment(\.controlActiveState) private var controlActive
    var body: some View {
        let rec = data.latest?.recovery
        let recP = data.latest?.recovery_prev
        let score = rec?.recovery_score
        let zone = recoveryColor(score)
        let onScreen = controlActive != .inactive   // pause the breathing pulse when the window isn't key
        let name = (data.status?.profile?.first_name).flatMap { $0.isEmpty ? nil : ", \($0)" } ?? ""
        let delta: Double? = (score != nil && recP?.recovery_score != nil)
            ? Double(score! - recP!.recovery_score!) : nil
        HStack(alignment: .center, spacing: 30) {
            RecoveryRing(score: score, lineWidth: 16, valueFontSize: 54, showCaption: true, animate: true)
                .frame(width: 184, height: 184)
                .overlay { if let s = score, s >= 67, onScreen { GreenCelebration(color: zone).frame(width: 184, height: 184) } }
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    Text("\(greeting())\(name)").font(.system(size: 21, weight: .bold))
                    TrendChip(delta: delta)
                    Spacer()
                }
                Text(recoveryStatus(score))
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(zone)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 28) {
                    heroStat("HRV", rec?.hrv_rmssd_milli.map { "\(Int($0.rounded()))" } ?? "--", "ms")
                    heroStat("Resting HR", intStr(rec?.resting_heart_rate), "bpm")
                    heroStat("Blood O₂", rec?.spo2_percentage.map { String(format: "%.0f", $0) } ?? "--", "%")
                    heroStat("Skin temp", rec?.skin_temp_celsius.map { String(format: "%.1f", $0) } ?? "--", "°C")
                }
                let spark = data.recovery.suffix(30).compactMap { $0.recovery_score.map(Double.init) }
                if spark.count >= 2 {
                    Sparkline(values: spark, color: zone).frame(height: 38)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(26)
        .background(
            ZStack {
                LinearGradient(colors: [zone.opacity(0.16), Color.white.opacity(0.02)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(zone.opacity(0.20)).frame(width: 320, height: 320)
                    .blur(radius: 100).offset(x: -70, y: -110)
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(zone.opacity(0.32), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: zone.opacity(0.22), radius: 32, y: 12)
    }
    private func heroStat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(label.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
        }
    }
}

struct OverviewSection: View {
    @ObservedObject var data: WhoopData
    @State private var appeared = false
    @State private var insShown = false   // INSIGHTS/AVERAGES often arrive a beat after the
    @State private var sumShown = false   // section appears — let them ride the cascade too
    private let cols = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    var body: some View {
        let slp = data.latest?.sleep, str = data.latest?.strain
        let slpP = data.latest?.sleep_prev, strP = data.latest?.strain_prev
        let sum = data.summary
        let ins = computeInsights(data)
        let napHrs = data.naps.filter { $0.day == data.latest?.day }.compactMap { $0.hours }.reduce(0, +)
        VStack(alignment: .leading, spacing: 18) {
            ExpandableCard(id: "ov.recovery", title: "Recovery %", accent: P.green, canExpand: data.latest != nil,
                           makeChart: { exp, sel in AnyView(recoveryScoreChart(data, expanded: exp, sel: sel)) }) {
                HeroCard(data: data)
            }
            .reveal(0, appeared)
            HStack(alignment: .top, spacing: 18) {
                ExpandableCard(id: "ov.sleep", title: "Sleep (hours)", accent: P.blue, canExpand: data.latest != nil,
                               makeChart: { exp, sel in AnyView(sleepHoursChart(data, expanded: exp, sel: sel)) }) {
                    Glass(accent: P.blue) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { sectionEyebrow("SLEEP")
                                TrendChip(delta: deltaD(slp?.hours, slpP?.hours).map { $0 * 60 }, unit: "m") }
                            CountUp(value: slp?.hours, render: fmtHrs).font(.system(size: 33, weight: .bold))
                            kv("Performance", slp?.performance.map { "\(Int($0.rounded()))%" } ?? "--")
                            kv("Efficiency", slp?.efficiency.map { "\(Int($0.rounded()))%" } ?? "--")
                            kv("Sleep need", fmtHrs(slp?.need_hours))
                            if napHrs > 0 {
                                HStack {
                                    Label("Nap", systemImage: "moon.zzz.fill").font(.system(size: 12)).foregroundStyle(P.blue)
                                    Spacer()
                                    Text(fmtHrs(napHrs)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                }
                            }
                            Sparkline(values: data.sleep.suffix(30).compactMap { $0.hours }, color: P.blue)
                        }
                    }
                }
                ExpandableCard(id: "ov.strain", title: "Day strain (0–21)", accent: P.teal, canExpand: data.latest != nil,
                               makeChart: { exp, sel in AnyView(dayStrainChart(data, expanded: exp, sel: sel)) }) {
                    Glass(accent: P.teal) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { sectionEyebrow("DAY STRAIN")
                                TrendChip(delta: deltaD(str?.strain, strP?.strain), decimals: 1) }
                            CountUp(value: str?.strain, render: one).font(.system(size: 33, weight: .bold))
                            kv("Avg HR", intStr(str?.average_heart_rate, " bpm"))
                            kv("Max HR", intStr(str?.max_heart_rate, " bpm"))
                            kv("Calories", grp(str?.calories))
                            Sparkline(values: data.strain.suffix(30).compactMap { $0.strain }, color: P.teal)
                        }
                    }
                }
            }
            .reveal(1, appeared)

            if !ins.isEmpty {
                sectionEyebrow("INSIGHTS").padding(.top, 2).reveal(2, appeared && insShown)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    ForEach(ins) { i in
                        Glass(accent: i.tone) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: i.icon).font(.system(size: 20)).foregroundStyle(i.tone)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(i.title).font(.system(size: 14, weight: .bold))
                                    Text(i.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .reveal(2, appeared && insShown)
            }

            if let s = sum {
                sectionEyebrow("AVERAGES").padding(.top, 2).reveal(3, appeared && sumShown)
                LazyVGrid(columns: cols, spacing: 12) {
                    StatTile(label: "Avg recovery", value: s.avg_recovery.map { "\(Int($0))%" } ?? "--")
                    StatTile(label: "Avg HRV", value: s.avg_hrv.map { "\(Int($0)) ms" } ?? "--")
                    StatTile(label: "Avg resting HR", value: s.avg_rhr.map { "\(Int($0)) bpm" } ?? "--")
                    StatTile(label: "Avg sleep", value: fmtHrs(s.avg_sleep_hours))
                    StatTile(label: "Avg sleep perf.", value: s.avg_sleep_performance.map { "\(Int($0))%" } ?? "--")
                    StatTile(label: "Avg day strain", value: trim1(s.avg_strain))
                    StatTile(label: "Best recovery", value: s.max_recovery.map { "\($0)%" } ?? "--")
                    StatTile(label: "Workouts", value: "\(s.workout_count ?? 0)")
                }
                .reveal(3, appeared && sumShown)
            }
        }
        // Assemble the four top-level rows on section-enter (re-fires only on appear, never on
        // the 60s auto-refresh). INSIGHTS/AVERAGES fade in when their data first lands so a cold
        // open cascades fully instead of snapping the bottom rows in. Same Reveal as the popover.
        .onAppear {
            appeared = false
            insShown = !ins.isEmpty
            sumShown = sum != nil
            withAnimation { appeared = true }
        }
        .onChange(of: ins.isEmpty) { _, empty in withAnimation { insShown = !empty } }
        .onChange(of: sum != nil) { _, has in withAnimation { sumShown = has } }
    }
    func deltaII(_ a: Int?, _ b: Int?) -> Double? { (a == nil || b == nil) ? nil : Double(a! - b!) }
    func deltaD(_ a: Double?, _ b: Double?) -> Double? { (a == nil || b == nil) ? nil : a! - b! }
}

// MARK: - Recovery

struct RecoverySection: View {
    @ObservedObject var data: WhoopData
    var body: some View {
        VStack(spacing: 18) {
            ChartCard(id: "rec.score", title: "Recovery %", accent: P.green, canExpand: data.latest != nil) { expanded, sel in
                recoveryScoreChart(data, expanded: expanded, sel: sel)
            }
            HStack(spacing: 18) {
                ChartCard(id: "rec.hrv", title: "HRV (ms)", accent: P.teal, canExpand: data.latest != nil) { expanded, sel in
                    VStack(spacing: 14) {
                        if expanded { chartStatStrip(data.recovery.compactMap { $0.hrv_rmssd_milli }, { "\(Int($0.rounded())) ms" }, accent: P.teal) }
                        Chart {
                            ForEach(data.recovery) { p in
                                if let v = p.hrv_rmssd_milli {
                                    AreaMark(x: .value("Day", parseDay(p.day)), y: .value("HRV", v))
                                        .foregroundStyle(.linearGradient(colors: [P.teal.opacity(0.3), P.teal.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                    LineMark(x: .value("Day", parseDay(p.day)), y: .value("HRV", v)).foregroundStyle(P.teal).interpolationMethod(.catmullRom)
                                }
                            }
                            if expanded, let s = sel.wrappedValue, let p = nearestDay(data.recovery, \.day, to: s), let v = p.hrv_rmssd_milli {
                                RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.18))
                                PointMark(x: .value("Day", parseDay(p.day)), y: .value("HRV", v)).foregroundStyle(P.teal).symbolSize(70)
                                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { chartTip(p.day, "\(Int(v.rounded())) ms") }
                            }
                        }
                        .modifier(ExpandableAxis(expanded: expanded))
                        .chartXSelectionIf(expanded, value: sel)
                        .cursorScrub(sel, active: expanded)
                        .scrollZoom(active: expanded, firstDay: data.recovery.first?.day, lastDay: data.recovery.last?.day)
                        .frame(height: expanded ? nil : 190)
                        .frame(maxHeight: expanded ? .infinity : nil)
                    }
                }
                ChartCard(id: "rec.rhr", title: "Resting HR (bpm)", accent: P.red, canExpand: data.latest != nil) { expanded, sel in
                    VStack(spacing: 14) {
                        if expanded { chartStatStrip(data.recovery.compactMap { $0.resting_heart_rate.map(Double.init) }, { "\(Int($0)) bpm" }, accent: P.red) }
                        Chart {
                            ForEach(data.recovery) { p in
                                if let v = p.resting_heart_rate {
                                    AreaMark(x: .value("Day", parseDay(p.day)), y: .value("RHR", v))
                                        .foregroundStyle(.linearGradient(colors: [P.red.opacity(0.28), P.red.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                    LineMark(x: .value("Day", parseDay(p.day)), y: .value("RHR", v)).foregroundStyle(P.red).interpolationMethod(.catmullRom)
                                }
                            }
                            if expanded, let s = sel.wrappedValue, let p = nearestDay(data.recovery, \.day, to: s), let v = p.resting_heart_rate {
                                RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.18))
                                PointMark(x: .value("Day", parseDay(p.day)), y: .value("RHR", v)).foregroundStyle(P.red).symbolSize(70)
                                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { chartTip(p.day, "\(v) bpm") }
                            }
                        }
                        .modifier(ExpandableAxis(expanded: expanded))
                        .chartXSelectionIf(expanded, value: sel)
                        .cursorScrub(sel, active: expanded)
                        .scrollZoom(active: expanded, firstDay: data.recovery.first?.day, lastDay: data.recovery.last?.day)
                        .frame(height: expanded ? nil : 190)
                        .frame(maxHeight: expanded ? .infinity : nil)
                    }
                }
            }
            Glass(title: "Recovery calendar", accent: P.green) {
                if data.recovery.isEmpty { emptyState("calendar", "No recovery data in this range", accent: P.green) }
                else { CalendarHeatmap(points: data.recovery).frame(height: 112) }
            }
        }
    }
}

// MARK: - Sleep

struct SleepSection: View {
    @ObservedObject var data: WhoopData
    private let stageColors: [Color] = [P.violet, P.blue, Color(red: 0.58, green: 0.77, blue: 0.99), Color.white.opacity(0.28)]
    var body: some View {
        VStack(spacing: 18) {
            ChartCard(id: "sleep.stages", title: "Sleep stages (hours)", accent: P.blue, canExpand: data.latest != nil) { expanded, sel in
                VStack(spacing: 14) {
                    if expanded { chartStatStrip(data.sleep.map { ($0.deep_hours ?? 0) + ($0.rem_hours ?? 0) + ($0.light_hours ?? 0) + ($0.awake_hours ?? 0) }.filter { $0 > 0 }, { fmtHrs($0) }, accent: P.blue) }
                    Chart {
                        ForEach(data.sleep) { p in
                            bar(p, "Deep", p.deep_hours); bar(p, "REM", p.rem_hours)
                            bar(p, "Light", p.light_hours); bar(p, "Awake", p.awake_hours)
                        }
                        if expanded, let s = sel.wrappedValue, let p = nearestDay(data.sleep, \.day, to: s) {
                            RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                    chartTip(p.day, fmtHrs((p.deep_hours ?? 0) + (p.rem_hours ?? 0) + (p.light_hours ?? 0) + (p.awake_hours ?? 0)))
                                }
                        }
                    }
                    .chartForegroundStyleScale(domain: ["Deep", "REM", "Light", "Awake"], range: stageColors)
                    .modifier(ExpandableAxis(expanded: expanded))
                    .cursorScrub(sel, active: expanded)
                    .scrollZoom(active: expanded, firstDay: data.sleep.first?.day, lastDay: data.sleep.last?.day)
                    .frame(height: expanded ? nil : 230)
                    .frame(maxHeight: expanded ? .infinity : nil)
                    .applyIf(!expanded) { $0.drawIn() }
                }
            }
            HStack(spacing: 18) {
                ChartCard(id: "sleep.perfeff", title: "Performance & efficiency (%)", accent: P.green, canExpand: data.latest != nil) { expanded, sel in
                    Chart {
                        ForEach(data.sleep) { p in
                            if let v = p.performance { LineMark(x: .value("Day", parseDay(p.day)), y: .value("V", v), series: .value("M", "Performance")).foregroundStyle(P.blue) }
                            if let v = p.efficiency { LineMark(x: .value("Day", parseDay(p.day)), y: .value("V", v), series: .value("M", "Efficiency")).foregroundStyle(P.green) }
                        }
                        if expanded, let s = sel.wrappedValue, let p = nearestDay(data.sleep, \.day, to: s) {
                            RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                    chartTip(p.day, "Perf \(p.performance.map { "\(Int($0.rounded()))%" } ?? "--") · Eff \(p.efficiency.map { "\(Int($0.rounded()))%" } ?? "--")")
                                }
                        }
                    }.chartYScale(domain: 0...100).chartForegroundStyleScale(domain: ["Performance", "Efficiency"], range: [P.blue, P.green])
                        .chartLegend(.visible)
                        .modifier(ExpandableAxis(expanded: expanded))
                        .cursorScrub(sel, active: expanded)
                        .scrollZoom(active: expanded, firstDay: data.sleep.first?.day, lastDay: data.sleep.last?.day)
                        .frame(height: expanded ? nil : 190)
                        .frame(maxHeight: expanded ? .infinity : nil)
                }
                ChartCard(id: "sleep.need", title: "Sleep need vs actual (h)", accent: P.violet, canExpand: data.latest != nil) { expanded, sel in
                    Chart {
                        ForEach(data.sleep) { p in
                            if let v = p.hours { BarMark(x: .value("Day", parseDay(p.day)), y: .value("Hours", v)).foregroundStyle(by: .value("Series", "Slept")).position(by: .value("Series", "Slept")) }
                            if let v = p.need_hours { BarMark(x: .value("Day", parseDay(p.day)), y: .value("Hours", v)).foregroundStyle(by: .value("Series", "Needed")).position(by: .value("Series", "Needed")) }
                        }
                        if expanded, let s = sel.wrappedValue, let p = nearestDay(data.sleep, \.day, to: s) {
                            RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                    chartTip(p.day, "Slept \(fmtHrs(p.hours)) · Need \(fmtHrs(p.need_hours))")
                                }
                        }
                    }
                    .chartForegroundStyleScale(domain: ["Slept", "Needed"], range: [P.blue, P.red.opacity(0.55)])
                    .chartLegend(.visible)
                    .modifier(ExpandableAxis(expanded: expanded))
                    .cursorScrub(sel, active: expanded)
                    .scrollZoom(active: expanded, firstDay: data.sleep.first?.day, lastDay: data.sleep.last?.day)
                    .frame(height: expanded ? nil : 190)
                    .frame(maxHeight: expanded ? .infinity : nil)
                }
            }
            ChartCard(id: "sleep.resp", title: "Respiratory rate (rpm)", accent: P.violet, canExpand: data.latest != nil) { expanded, sel in
                VStack(spacing: 14) {
                    if expanded { chartStatStrip(data.sleep.compactMap { $0.respiratory_rate }, { String(format: "%.1f", $0) }, accent: P.violet) }
                    Chart {
                        ForEach(data.sleep) { p in
                            if let v = p.respiratory_rate {
                                AreaMark(x: .value("Day", parseDay(p.day)), y: .value("RR", v))
                                    .foregroundStyle(.linearGradient(colors: [P.violet.opacity(0.28), P.violet.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                LineMark(x: .value("Day", parseDay(p.day)), y: .value("RR", v)).foregroundStyle(P.violet).interpolationMethod(.catmullRom)
                            }
                        }
                        if expanded, let s = sel.wrappedValue, let p = nearestDay(data.sleep, \.day, to: s), let v = p.respiratory_rate {
                            RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                            PointMark(x: .value("Day", parseDay(p.day)), y: .value("RR", v)).foregroundStyle(P.violet).symbolSize(70)
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { chartTip(p.day, String(format: "%.1f rpm", v)) }
                        }
                    }
                    .modifier(ExpandableAxis(expanded: expanded))
                    .cursorScrub(sel, active: expanded)
                    .scrollZoom(active: expanded, firstDay: data.sleep.first?.day, lastDay: data.sleep.last?.day)
                    .frame(height: expanded ? nil : 170)
                    .frame(maxHeight: expanded ? .infinity : nil)
                }
            }
            // Naps — WHOOP records these separately from the night's sleep.
            Glass(title: "Naps", accent: P.blue) {
                if data.naps.isEmpty {
                    emptyState("moon.zzz.fill", "No naps in this range", accent: P.blue)
                } else {
                    VStack(spacing: 10) {
                        ForEach(data.naps.reversed()) { nap in
                            HStack(spacing: 12) {
                                Image(systemName: "moon.zzz.fill").font(.system(size: 15)).foregroundStyle(P.blue)
                                    .frame(width: 32, height: 32).background(P.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(napDate(nap.day)).font(.system(size: 13.5, weight: .semibold))
                                    if let t = napClock(nap.start) {
                                        Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(fmtHrs(nap.hours)).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }
    @ChartContentBuilder func bar(_ p: SleepPoint, _ name: String, _ v: Double?) -> some ChartContent {
        if let v { BarMark(x: .value("Day", parseDay(p.day)), y: .value("Hours", v)).foregroundStyle(by: .value("Stage", name)) }
    }
}

// MARK: - Strain

struct StrainSection: View {
    @ObservedObject var data: WhoopData
    var body: some View {
        VStack(spacing: 18) {
            ChartCard(id: "strain.day", title: "Day strain (0–21)", accent: P.teal, canExpand: data.latest != nil) { expanded, sel in
                dayStrainChart(data, expanded: expanded, sel: sel)
            }
            ChartCard(id: "strain.cal", title: "Calories burned", accent: P.orange, canExpand: data.latest != nil) { expanded, sel in
                VStack(spacing: 14) {
                    if expanded { chartStatStrip(data.strain.compactMap { $0.calories }, { grp($0) }, accent: P.orange) }
                    Chart {
                        ForEach(data.strain) { p in
                            if let v = p.calories { BarMark(x: .value("Day", parseDay(p.day)), y: .value("Cal", v)).foregroundStyle(P.orange.gradient) }
                        }
                        if expanded, let s = sel.wrappedValue, let p = nearestDay(data.strain, \.day, to: s), let v = p.calories {
                            RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { chartTip(p.day, grp(v)) }
                        }
                    }
                    .modifier(ExpandableAxis(expanded: expanded))
                    .cursorScrub(sel, active: expanded)
                    .scrollZoom(active: expanded, firstDay: data.strain.first?.day, lastDay: data.strain.last?.day)
                    .frame(height: expanded ? nil : 190)
                    .frame(maxHeight: expanded ? .infinity : nil)
                }
            }
        }
    }
}

// MARK: - Activities

struct ActivitiesSection: View {
    @ObservedObject var data: WhoopData
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !data.sports.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 178), spacing: 14)], spacing: 14) {
                    ForEach(data.sports.prefix(8)) { s in
                        Glass(accent: P.teal) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(sportEmoji(s.sport_name)).font(.system(size: 26))
                                Text(s.sport_name.capitalized).font(.system(size: 15, weight: .bold))
                                kv("Sessions", "\(s.count)")
                                kv("Avg strain", trim1(s.avg_strain))
                                kv("Calories", grp(s.calories))
                            }
                        }
                    }
                }
                // Horizontal category bars (no Date axis) — expandable to taller bars, but no
                // date crosshair/stat-strip (those are meaningless here).
                ChartCard(id: "act.sport", title: "Total strain by sport", accent: P.teal, canExpand: !data.sports.isEmpty) { expanded, _ in
                    Chart(data.sports) { s in
                        BarMark(x: .value("Strain", s.total_strain ?? 0), y: .value("Sport", s.sport_name.capitalized))
                            .foregroundStyle(P.teal.gradient)
                            .annotation(position: .trailing, alignment: .leading) {
                                Text(trim1(s.total_strain)).font(.system(size: 10, weight: .bold)).monospacedDigit().foregroundStyle(.secondary)
                            }
                    }
                    .chartXScale(domain: 0...(max(data.sports.map { $0.total_strain ?? 0 }.max() ?? 1, 1) * 1.12))
                    .frame(height: expanded ? max(220, CGFloat(data.sports.count) * 52) : max(140, CGFloat(data.sports.count) * 30))
                    .frame(maxHeight: expanded ? .infinity : nil)
                    .applyIf(!expanded) { $0.drawIn() }
                }
            }
            Glass(title: "Workouts", accent: P.violet) {
                if data.workouts.isEmpty { emptyState("figure.run", "No workouts in this range", accent: P.violet) }
                else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Date").frame(width: 96, alignment: .leading)
                            Text("Sport").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Strain").frame(width: 54, alignment: .trailing)
                            Text("Avg").frame(width: 46, alignment: .trailing)
                            Text("Max").frame(width: 46, alignment: .trailing)
                            Text("Cal").frame(width: 60, alignment: .trailing)
                            Text("Dist").frame(width: 72, alignment: .trailing)
                        }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
                        ForEach(data.workouts.prefix(120)) { w in
                            WorkoutTableRow(w: w)
                            Divider().opacity(0.2)
                        }
                    }
                }
            }
        }
    }
}

/// One row of the Workouts table, extracted so it can highlight on hover like every Glass/StatTile.
/// Column widths are byte-identical to the header row so alignment is preserved.
private struct WorkoutTableRow: View {
    let w: WorkoutRow
    @State private var hover = false
    var body: some View {
        HStack {
            Text(w.day ?? "").frame(width: 96, alignment: .leading).foregroundStyle(.secondary)
            Text("\(sportEmoji(w.sport_name)) \((w.sport_name ?? "—").capitalized)").frame(maxWidth: .infinity, alignment: .leading)
            Text(one(w.strain)).frame(width: 54, alignment: .trailing).monospacedDigit()
            Text(intStr(w.average_heart_rate)).frame(width: 46, alignment: .trailing).foregroundStyle(.secondary).monospacedDigit()
            Text(intStr(w.max_heart_rate)).frame(width: 46, alignment: .trailing).foregroundStyle(.secondary).monospacedDigit()
            Text(w.calories.map { "\(Int($0))" } ?? "—").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary).monospacedDigit()
            Text(w.distance_meter.map { String(format: "%.2f km", $0 / 1000) } ?? "—").frame(width: 72, alignment: .trailing).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 12.5)).padding(.vertical, 7)
        .background(Color.white.opacity(hover ? 0.05 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}
