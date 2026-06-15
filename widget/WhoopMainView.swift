// WhoopMainView.swift  (host app target only)
// The native WHOOP app — a premium sidebar dashboard with Swift Charts, a recovery
// ring, insights, trend chips, and a recovery calendar, all reading the local API.

import SwiftUI
import Charts
import Combine
import AppKit

// MARK: - Palette

enum P {
    static let bg     = Color(red: 0.024, green: 0.024, blue: 0.031)
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
func trim1(_ v: Double?) -> String { guard let v else { return "--" }; return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
func grp(_ v: Double?) -> String { guard let v else { return "--" }; return Int(v).formatted(.number.grouping(.automatic)) }
func intStr(_ v: Int?, _ suffix: String = "") -> String { v == nil ? "--" : "\(v!)\(suffix)" }
func zoneName(_ s: Int) -> String { s >= 67 ? "High" : s >= 34 ? "Medium" : "Low" }

func relativeSync(_ iso: String?) -> String {
    guard let iso else { return "—" }
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = f.date(from: iso)
    if date == nil { f.formatOptions = [.withInternetDateTime]; date = f.date(from: iso) }
    guard let d = date else { return "—" }
    let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .abbreviated
    return rel.localizedString(for: d, relativeTo: Date())
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
    @State private var drift = false
    var body: some View {
        ZStack {
            P.bg
            blob(P.teal.opacity(0.16),   760, drift ? 300 : 340, drift ? -370 : -320, 40)
            blob(P.violet.opacity(0.14), 720, drift ? -370 : -320, drift ? -250 : -320, 40)
            blob(P.green.opacity(0.08),  720, drift ? 36 : -36,    drift ? 500 : 460, 50)
        }
        .ignoresSafeArea()
        // Slow, continuous drift so the backdrop feels alive (great on a demo screen).
        .onAppear { withAnimation(.easeInOut(duration: 17).repeatForever(autoreverses: true)) { drift = true } }
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
        CountingNumber(value: value == nil ? 0 : shown,
                       render: { value == nil ? render(nil) : render($0) })
            .onAppear { start() }
            .onChange(of: value) { _, _ in start() }
    }
    private func start() {
        guard let v = value else { return }
        shown = 0
        withAnimation(.easeOut(duration: 0.9)) { shown = v }
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

// MARK: - Calendar heatmap

struct CalendarHeatmap: View {
    let points: [RecoveryPoint]
    private struct Cell { let day: String?; let score: Int? }
    private let wdLabels = ["S", "M", "T", "W", "T", "F", "S"]
    private var columns: [[Cell]] {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = Locale(identifier: "en_US_POSIX")
        var map: [String: Int] = [:]; var dates: [Date] = []
        for p in points { if let dt = fmt.date(from: p.day) { dates.append(dt); if let s = p.recovery_score { map[p.day] = s } } }
        guard let first = dates.min(), let last = dates.max() else { return [] }
        let cal = Calendar(identifier: .gregorian)
        var cur = cal.date(byAdding: .day, value: -(cal.component(.weekday, from: first) - 1), to: first)!
        var cols: [[Cell]] = []; var col: [Cell] = []
        while cur <= last {
            let key = fmt.string(from: cur)
            col.append(Cell(day: cur >= first ? key : nil, score: map[key]))
            if col.count == 7 { cols.append(col); col = [] }
            cur = cal.date(byAdding: .day, value: 1, to: cur)!
        }
        if !col.isEmpty { while col.count < 7 { col.append(Cell(day: nil, score: nil)) }; cols.append(col) }
        return cols
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
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, col in
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

struct WhoopMainView: View {
    @StateObject private var data = WhoopData()
    @State private var section: AppSection = .overview
    @State private var days = 30

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { s in
                Label {
                    Text(s.rawValue).font(.system(size: 13.5, weight: section == s ? .semibold : .medium))
                } icon: {
                    Image(systemName: s.icon)
                        .foregroundStyle(section == s ? P.teal : Color.secondary)
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
                        Text("Synced \(relativeSync(st.last_sync))").font(.system(size: 11)).foregroundStyle(.tertiary)
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
                            switch section {
                            case .overview: OverviewSection(data: data)
                            case .recovery: RecoverySection(data: data)
                            case .sleep: SleepSection(data: data)
                            case .strain: StrainSection(data: data)
                            case .activities: ActivitiesSection(data: data)
                            }
                        }
                        .redacted(reason: (data.latest == nil && data.error == nil) ? .placeholder : [])
                        .shimmering(active: data.latest == nil && data.error == nil)
                        .id(section)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
                    }
                    .padding(28).frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.spring(response: 0.42, dampingFraction: 0.86), value: section)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .preferredColorScheme(.dark)
        .task { await data.load(days: days) }
        .onChange(of: days) { _, v in Task { await data.load(days: v) } }
        // Auto-refresh every 60s so the app stays current with the menu-bar app's syncs.
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if !data.loading { Task { await data.load(days: days) } }
        }
        // Deep links from the menu bar: whoop://recovery, whoop://sleep, … open the app here.
        .onOpenURL { url in
            if let s = AppSection(rawValue: (url.host ?? "").capitalized) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { section = s }
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(section.rawValue).font(.system(size: 30, weight: .bold))
            if data.loading { ProgressView().controlSize(.small).padding(.leading, 4) }
            Spacer()
            Picker("", selection: $days) {
                Text("7D").tag(7); Text("30D").tag(30); Text("90D").tag(90)
                Text("6M").tag(180); Text("1Y").tag(365); Text("All").tag(1825)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300).controlSize(.large)
            Button { Task { await data.load(days: days) } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered).controlSize(.large).help("Refresh")
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
    var body: some View {
        let rec = data.latest?.recovery
        let recP = data.latest?.recovery_prev
        let score = rec?.recovery_score
        let zone = recoveryColor(score)
        let name = (data.status?.profile?.first_name).flatMap { $0.isEmpty ? nil : ", \($0)" } ?? ""
        let delta: Double? = (score != nil && recP?.recovery_score != nil)
            ? Double(score! - recP!.recovery_score!) : nil
        HStack(alignment: .center, spacing: 30) {
            RecoveryRing(score: score, lineWidth: 16, valueFontSize: 54, showCaption: true, animate: true)
                .frame(width: 184, height: 184)
                .overlay { if let s = score, s >= 67 { GreenCelebration(color: zone).frame(width: 184, height: 184) } }
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
                Sparkline(values: data.recovery.suffix(30).compactMap { $0.recovery_score.map(Double.init) }, color: zone)
                    .frame(height: 38)
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
    private let cols = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    var body: some View {
        let slp = data.latest?.sleep, str = data.latest?.strain
        let slpP = data.latest?.sleep_prev, strP = data.latest?.strain_prev
        let sum = data.summary
        VStack(alignment: .leading, spacing: 18) {
            HeroCard(data: data)
            HStack(alignment: .top, spacing: 18) {
                Glass(accent: P.blue) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("SLEEP").font(.system(size: 11, weight: .heavy)).foregroundStyle(.secondary)
                            TrendChip(delta: deltaD(slp?.hours, slpP?.hours).map { $0 * 60 }, unit: "m") }
                        CountUp(value: slp?.hours, render: fmtHrs).font(.system(size: 33, weight: .bold))
                        kv("Performance", slp?.performance.map { "\(Int($0.rounded()))%" } ?? "--")
                        kv("Efficiency", slp?.efficiency.map { "\(Int($0.rounded()))%" } ?? "--")
                        kv("Sleep need", fmtHrs(slp?.need_hours))
                        Sparkline(values: data.sleep.suffix(30).compactMap { $0.hours }, color: P.blue)
                    }
                }
                Glass(accent: P.teal) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("DAY STRAIN").font(.system(size: 11, weight: .heavy)).foregroundStyle(.secondary)
                            TrendChip(delta: deltaD(str?.strain, strP?.strain), decimals: 1) }
                        CountUp(value: str?.strain, render: one).font(.system(size: 33, weight: .bold))
                        kv("Avg HR", intStr(str?.average_heart_rate, " bpm"))
                        kv("Max HR", intStr(str?.max_heart_rate, " bpm"))
                        kv("Calories", grp(str?.calories))
                        Sparkline(values: data.strain.suffix(30).compactMap { $0.strain }, color: P.teal)
                    }
                }
            }

            let ins = computeInsights(data)
            if !ins.isEmpty {
                Text("INSIGHTS").font(.system(size: 11, weight: .heavy)).foregroundStyle(.secondary)
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
            }

            if let s = sum {
                Text("AVERAGES").font(.system(size: 11, weight: .heavy)).foregroundStyle(.secondary)
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
            }
        }
    }
    func deltaII(_ a: Int?, _ b: Int?) -> Double? { (a == nil || b == nil) ? nil : Double(a! - b!) }
    func deltaD(_ a: Double?, _ b: Double?) -> Double? { (a == nil || b == nil) ? nil : a! - b! }
}

// MARK: - Recovery

struct RecoverySection: View {
    @ObservedObject var data: WhoopData
    @State private var sel: Date?
    var body: some View {
        VStack(spacing: 18) {
            Glass(title: "Recovery %", accent: P.green) {
                Chart {
                    ForEach(data.recovery) { p in
                        if let v = p.recovery_score {
                            AreaMark(x: .value("Day", parseDay(p.day)), y: .value("Recovery", v))
                                .foregroundStyle(.linearGradient(colors: [P.green.opacity(0.18), P.green.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Day", parseDay(p.day)), y: .value("Recovery", v))
                                .foregroundStyle(recoveryGradient).lineStyle(.init(lineWidth: 2.5)).interpolationMethod(.catmullRom)
                        }
                    }
                    if let sel, let p = nearestDay(data.recovery, \.day, to: sel), let v = p.recovery_score {
                        RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.18))
                        PointMark(x: .value("Day", parseDay(p.day)), y: .value("Recovery", v)).foregroundStyle(recoveryColor(v)).symbolSize(70)
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { chartTip(p.day, "\(v)%") }
                    }
                }
                .chartYScale(domain: 0...100).chartXSelection(value: $sel).timeAxis().frame(height: 230).drawIn()
            }
            HStack(spacing: 18) {
                Glass(title: "HRV (ms)", accent: P.teal) {
                    Chart {
                        ForEach(data.recovery) { p in
                            if let v = p.hrv_rmssd_milli {
                                AreaMark(x: .value("Day", parseDay(p.day)), y: .value("HRV", v))
                                    .foregroundStyle(.linearGradient(colors: [P.teal.opacity(0.3), P.teal.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                LineMark(x: .value("Day", parseDay(p.day)), y: .value("HRV", v)).foregroundStyle(P.teal).interpolationMethod(.catmullRom)
                            }
                        }
                        if let sel, let p = nearestDay(data.recovery, \.day, to: sel), let v = p.hrv_rmssd_milli {
                            RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.18))
                            PointMark(x: .value("Day", parseDay(p.day)), y: .value("HRV", v)).foregroundStyle(P.teal).symbolSize(70)
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { chartTip(p.day, "\(Int(v.rounded())) ms") }
                        }
                    }.chartXSelection(value: $sel).timeAxis().frame(height: 190)
                }
                Glass(title: "Resting HR (bpm)", accent: P.red) {
                    Chart {
                        ForEach(data.recovery) { p in
                            if let v = p.resting_heart_rate {
                                AreaMark(x: .value("Day", parseDay(p.day)), y: .value("RHR", v))
                                    .foregroundStyle(.linearGradient(colors: [P.red.opacity(0.28), P.red.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                LineMark(x: .value("Day", parseDay(p.day)), y: .value("RHR", v)).foregroundStyle(P.red).interpolationMethod(.catmullRom)
                            }
                        }
                        if let sel, let p = nearestDay(data.recovery, \.day, to: sel), let v = p.resting_heart_rate {
                            RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.18))
                            PointMark(x: .value("Day", parseDay(p.day)), y: .value("RHR", v)).foregroundStyle(P.red).symbolSize(70)
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { chartTip(p.day, "\(v) bpm") }
                        }
                    }.chartXSelection(value: $sel).timeAxis().frame(height: 190)
                }
            }
            Glass(title: "Recovery calendar", accent: P.green) {
                if data.recovery.isEmpty { Text("No data in range").foregroundStyle(.secondary) }
                else { CalendarHeatmap(points: data.recovery).frame(height: 112) }
            }
        }
    }
}

// MARK: - Sleep

struct SleepSection: View {
    @ObservedObject var data: WhoopData
    @State private var sel: Date?
    private let stageColors: [Color] = [P.violet, P.blue, Color(red: 0.58, green: 0.77, blue: 0.99), Color.white.opacity(0.28)]
    var body: some View {
        VStack(spacing: 18) {
            Glass(title: "Sleep stages (hours)", accent: P.blue) {
                Chart {
                    ForEach(data.sleep) { p in
                        bar(p, "Deep", p.deep_hours); bar(p, "REM", p.rem_hours)
                        bar(p, "Light", p.light_hours); bar(p, "Awake", p.awake_hours)
                    }
                    if let sel, let p = nearestDay(data.sleep, \.day, to: sel) {
                        RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                chartTip(p.day, fmtHrs((p.deep_hours ?? 0) + (p.rem_hours ?? 0) + (p.light_hours ?? 0) + (p.awake_hours ?? 0)))
                            }
                    }
                }
                .chartForegroundStyleScale(domain: ["Deep", "REM", "Light", "Awake"], range: stageColors)
                .chartXSelection(value: $sel).timeAxis().frame(height: 230).drawIn()
            }
            HStack(spacing: 18) {
                Glass(title: "Performance & efficiency (%)", accent: P.green) {
                    Chart {
                        ForEach(data.sleep) { p in
                            if let v = p.performance { LineMark(x: .value("Day", parseDay(p.day)), y: .value("V", v), series: .value("M", "Performance")).foregroundStyle(P.blue) }
                            if let v = p.efficiency { LineMark(x: .value("Day", parseDay(p.day)), y: .value("V", v), series: .value("M", "Efficiency")).foregroundStyle(P.green) }
                        }
                        if let sel, let p = nearestDay(data.sleep, \.day, to: sel) {
                            RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                    chartTip(p.day, "Perf \(p.performance.map { "\(Int($0.rounded()))%" } ?? "--") · Eff \(p.efficiency.map { "\(Int($0.rounded()))%" } ?? "--")")
                                }
                        }
                    }.chartYScale(domain: 0...100).chartForegroundStyleScale(domain: ["Performance", "Efficiency"], range: [P.blue, P.green])
                        .chartLegend(.visible).chartXSelection(value: $sel).timeAxis().frame(height: 190)
                }
                Glass(title: "Sleep need vs actual (h)", accent: P.violet) {
                    Chart {
                        ForEach(data.sleep) { p in
                            if let v = p.hours { BarMark(x: .value("Day", parseDay(p.day)), y: .value("Hours", v)).foregroundStyle(by: .value("Series", "Slept")).position(by: .value("Series", "Slept")) }
                            if let v = p.need_hours { BarMark(x: .value("Day", parseDay(p.day)), y: .value("Hours", v)).foregroundStyle(by: .value("Series", "Needed")).position(by: .value("Series", "Needed")) }
                        }
                        if let sel, let p = nearestDay(data.sleep, \.day, to: sel) {
                            RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                    chartTip(p.day, "Slept \(fmtHrs(p.hours)) · Need \(fmtHrs(p.need_hours))")
                                }
                        }
                    }
                    .chartForegroundStyleScale(domain: ["Slept", "Needed"], range: [P.blue, P.red.opacity(0.55)])
                    .chartLegend(.visible).chartXSelection(value: $sel).timeAxis().frame(height: 190)
                }
            }
            Glass(title: "Respiratory rate (rpm)", accent: P.violet) {
                Chart {
                    ForEach(data.sleep) { p in
                        if let v = p.respiratory_rate {
                            AreaMark(x: .value("Day", parseDay(p.day)), y: .value("RR", v))
                                .foregroundStyle(.linearGradient(colors: [P.violet.opacity(0.28), P.violet.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Day", parseDay(p.day)), y: .value("RR", v)).foregroundStyle(P.violet).interpolationMethod(.catmullRom)
                        }
                    }
                    if let sel, let p = nearestDay(data.sleep, \.day, to: sel), let v = p.respiratory_rate {
                        RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                        PointMark(x: .value("Day", parseDay(p.day)), y: .value("RR", v)).foregroundStyle(P.violet).symbolSize(70)
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { chartTip(p.day, String(format: "%.1f rpm", v)) }
                    }
                }.chartXSelection(value: $sel).timeAxis().frame(height: 170)
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
    @State private var sel: Date?
    var body: some View {
        VStack(spacing: 18) {
            Glass(title: "Day strain (0–21)", accent: P.teal) {
                Chart {
                    ForEach(data.strain) { p in
                        if let v = p.strain { BarMark(x: .value("Day", parseDay(p.day)), y: .value("Strain", v)).foregroundStyle(P.teal.gradient) }
                    }
                    if let sel, let p = nearestDay(data.strain, \.day, to: sel), let v = p.strain {
                        RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { chartTip(p.day, one(v)) }
                    }
                }.chartYScale(domain: 0...21).chartXSelection(value: $sel).timeAxis().frame(height: 230).drawIn()
            }
            Glass(title: "Calories burned", accent: P.orange) {
                Chart {
                    ForEach(data.strain) { p in
                        if let v = p.calories { BarMark(x: .value("Day", parseDay(p.day)), y: .value("Cal", v)).foregroundStyle(P.orange.gradient) }
                    }
                    if let sel, let p = nearestDay(data.strain, \.day, to: sel), let v = p.calories {
                        RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { chartTip(p.day, grp(v)) }
                    }
                }.chartXSelection(value: $sel).timeAxis().frame(height: 190)
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
                Glass(title: "Total strain by sport", accent: P.teal) {
                    Chart(data.sports) { s in
                        BarMark(x: .value("Strain", s.total_strain ?? 0), y: .value("Sport", s.sport_name.capitalized)).foregroundStyle(P.teal.gradient)
                    }.frame(height: max(140, CGFloat(data.sports.count) * 30))
                }
            }
            Glass(title: "Workouts", accent: P.violet) {
                if data.workouts.isEmpty { Text("No workouts in range").foregroundStyle(.secondary) }
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
                            HStack {
                                Text(w.day ?? "").frame(width: 96, alignment: .leading).foregroundStyle(.secondary)
                                Text("\(sportEmoji(w.sport_name)) \((w.sport_name ?? "—").capitalized)").frame(maxWidth: .infinity, alignment: .leading)
                                Text(one(w.strain)).frame(width: 54, alignment: .trailing).monospacedDigit()
                                Text(intStr(w.average_heart_rate)).frame(width: 46, alignment: .trailing).foregroundStyle(.secondary).monospacedDigit()
                                Text(intStr(w.max_heart_rate)).frame(width: 46, alignment: .trailing).foregroundStyle(.secondary).monospacedDigit()
                                Text(w.calories.map { "\(Int($0))" } ?? "—").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary).monospacedDigit()
                                Text(w.distance_meter.map { String(format: "%.2f km", $0 / 1000) } ?? "—").frame(width: 72, alignment: .trailing).foregroundStyle(.secondary).monospacedDigit()
                            }.font(.system(size: 12.5)).padding(.vertical, 7)
                            Divider().opacity(0.2)
                        }
                    }
                }
            }
        }
    }
}
