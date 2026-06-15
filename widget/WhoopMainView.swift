// WhoopMainView.swift  (host app target only)
// The native WHOOP app — a premium sidebar dashboard with Swift Charts, a recovery
// ring, insights, trend chips, and a recovery calendar, all reading the local API.

import SwiftUI
import Charts
import Combine

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
    case overview = "Overview", recovery = "Recovery", sleep = "Sleep", strain = "Strain", nutrition = "Nutrition", activities = "Activities"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .recovery: return "heart.fill"
        case .sleep: return "bed.double.fill"
        case .strain: return "bolt.fill"
        case .nutrition: return "fork.knife"
        case .activities: return "figure.run"
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
    var body: some View {
        ZStack {
            P.bg
            Circle().fill(RadialGradient(colors: [P.teal.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 420))
                .frame(width: 760, height: 760).blur(radius: 40).offset(x: 320, y: -340)
            Circle().fill(RadialGradient(colors: [P.violet.opacity(0.14), .clear], center: .center, startRadius: 0, endRadius: 420))
                .frame(width: 720, height: 720).blur(radius: 40).offset(x: -340, y: -300)
            Circle().fill(RadialGradient(colors: [P.green.opacity(0.08), .clear], center: .center, startRadius: 0, endRadius: 400))
                .frame(width: 720, height: 720).blur(radius: 50).offset(x: 0, y: 480)
        }.ignoresSafeArea()
    }
}

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
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 23, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(Color.white.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(P.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
                Label(s.rawValue, systemImage: s.icon).tag(s).font(.system(size: 14, weight: .semibold))
            }
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
                            case .nutrition: NutritionSection(data: data, days: days)
                            case .activities: ActivitiesSection(data: data)
                            }
                        }
                        .id(section)
                        .transition(.opacity)
                    }
                    .padding(28).frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.22), value: section)
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.rawValue).font(.system(size: 32, weight: .bold))
            if data.loading { ProgressView().controlSize(.small).padding(.leading, 8) }
            Spacer()
            Picker("", selection: $days) {
                Text("7D").tag(7); Text("30D").tag(30); Text("90D").tag(90)
                Text("6M").tag(180); Text("1Y").tag(365); Text("All").tag(1825)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 340)
            Button { Task { await data.load(days: days) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bordered)
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

struct OverviewSection: View {
    @ObservedObject var data: WhoopData
    private let cols = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    var body: some View {
        let rec = data.latest?.recovery, slp = data.latest?.sleep, str = data.latest?.strain
        let recP = data.latest?.recovery_prev, slpP = data.latest?.sleep_prev, strP = data.latest?.strain_prev
        let sum = data.summary
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                Glass(accent: recoveryColor(rec?.recovery_score)) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 18) {
                            RecoveryRing(score: rec?.recovery_score, lineWidth: 14, valueFontSize: 38).frame(width: 132, height: 132)
                            VStack(alignment: .leading, spacing: 9) {
                                HStack { Text("RECOVERY").font(.system(size: 11, weight: .heavy)).foregroundStyle(.secondary)
                                    TrendChip(delta: deltaII(rec?.recovery_score, recP?.recovery_score)) }
                                kv("HRV", rec?.hrv_rmssd_milli.map { "\(Int($0.rounded())) ms" } ?? "--")
                                kv("Resting HR", intStr(rec?.resting_heart_rate, " bpm"))
                                kv("Blood O₂", rec?.spo2_percentage.map { String(format: "%.1f%%", $0) } ?? "--")
                                kv("Skin temp", rec?.skin_temp_celsius.map { String(format: "%.1f°C", $0) } ?? "--")
                            }.frame(maxWidth: .infinity)
                        }
                        Sparkline(values: data.recovery.suffix(30).compactMap { $0.recovery_score.map(Double.init) }, color: P.green)
                    }
                }
                Glass(accent: P.blue) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("SLEEP").font(.system(size: 11, weight: .heavy)).foregroundStyle(.secondary)
                            TrendChip(delta: deltaD(slp?.hours, slpP?.hours).map { $0 * 60 }, unit: "m") }
                        Text(fmtHrs(slp?.hours)).font(.system(size: 33, weight: .bold)).monospacedDigit()
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
                        Text(one(str?.strain)).font(.system(size: 33, weight: .bold)).monospacedDigit()
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
                .chartYScale(domain: 0...100).chartXSelection(value: $sel).timeAxis().frame(height: 230)
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
                .chartXSelection(value: $sel).timeAxis().frame(height: 230)
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
                }.chartYScale(domain: 0...21).chartXSelection(value: $sel).timeAxis().frame(height: 230)
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

// MARK: - Nutrition

struct NutritionSection: View {
    @ObservedObject var data: WhoopData
    var days: Int
    @State private var sel: Date?
    private let cols = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    private func netStr(_ v: Double?) -> String {
        guard let v else { return "--" }
        let i = Int(v.rounded())
        return (i > 0 ? "+" : "") + i.formatted(.number.grouping(.automatic))
    }

    private func macro(_ label: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v == nil ? "--" : "\(Int(v!.rounded()))g")
                .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "fork.knife").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("No food logged yet").font(.system(size: 14, weight: .semibold))
            Text("Log a meal above and your energy balance shows up here.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).frame(height: 150)
    }

    var body: some View {
        let s = data.nutrition?.summary
        let hasData = data.energy.contains { $0.intake != nil } || (s?.calories != nil)
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: cols, spacing: 12) {
                StatTile(label: "Eaten today", value: grp(s?.calories))
                StatTile(label: "Burned today", value: grp(s?.burned))
                StatTile(label: "Net", value: netStr(s?.net))
                if let g = s?.goal, g > 0 {
                    StatTile(label: "Goal remaining", value: grp(s?.remaining))
                }
            }

            FoodLogCard(data: data, days: days)

            if let s, s.protein_g != nil || s.carbs_g != nil || s.fat_g != nil || (s.goal ?? 0) > 0 {
                Glass(accent: P.orange) {
                    HStack(spacing: 26) {
                        macro("Protein", s.protein_g)
                        macro("Carbs", s.carbs_g)
                        macro("Fat", s.fat_g)
                        Spacer()
                        if let g = s.goal, g > 0 {
                            Text("\(Int((((s.calories ?? 0) / g) * 100).rounded()))% of \(grp(g)) cal goal")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Glass(title: "Energy balance — eaten vs burned", accent: P.orange) {
                if hasData {
                    Chart {
                        ForEach(data.energy) { p in
                            if let i = p.intake {
                                BarMark(x: .value("Day", parseDay(p.day)), y: .value("Calories", i))
                                    .foregroundStyle(by: .value("Energy", "Eaten"))
                                    .position(by: .value("Energy", "Eaten"))
                            }
                            if let b = p.burned {
                                BarMark(x: .value("Day", parseDay(p.day)), y: .value("Calories", b))
                                    .foregroundStyle(by: .value("Energy", "Burned"))
                                    .position(by: .value("Energy", "Burned"))
                            }
                        }
                    }
                    .chartForegroundStyleScale(["Eaten": P.orange, "Burned": P.teal])
                    .timeAxis().frame(height: 220)
                } else { emptyHint }
            }

            Glass(title: "Calories eaten", accent: P.orange) {
                if hasData {
                    Chart {
                        ForEach(data.energy) { p in
                            if let i = p.intake {
                                BarMark(x: .value("Day", parseDay(p.day)), y: .value("Cal", i)).foregroundStyle(P.orange.gradient)
                            }
                        }
                        if let sel, let p = nearestDay(data.energy, \.day, to: sel), let i = p.intake {
                            RuleMark(x: .value("Day", parseDay(p.day))).foregroundStyle(.white.opacity(0.25))
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { chartTip(p.day, grp(i)) }
                        }
                    }
                    .chartXSelection(value: $sel).timeAxis().frame(height: 190)
                } else { emptyHint }
            }
        }
    }
}

// MARK: - Food logging

/// Log food right inside the app: plain-English lookup (when Nutritionix keys are set),
/// manual entry, and today's editable log. Mirrors the web dashboard's Nutrition tab.
struct FoodLogCard: View {
    @ObservedObject var data: WhoopData
    var days: Int

    @State private var query = ""
    @State private var preview: [FoodItem] = []
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var msg: String?
    @State private var msgErr = false
    // manual entry
    @State private var mName = ""
    @State private var mCal = ""
    @State private var mP = ""
    @State private var mC = ""
    @State private var mF = ""
    @State private var manualOpen = false

    private var nlConfigured: Bool { data.nutrition?.nutritionix == true }

    var body: some View {
        Glass(title: "Log food", accent: P.orange) {
            VStack(alignment: .leading, spacing: 12) {
                // 1) Plain-English lookup (needs Nutritionix keys)
                if nlConfigured {
                    HStack(spacing: 8) {
                        TextField("e.g. 2 eggs and a slice of toast", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await lookup() } }
                        Button { Task { await lookup() } } label: {
                            if busy { ProgressView().controlSize(.small) } else { Text("Look up") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                // 2) Parsed-item preview → pick what to add
                if !preview.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(preview) { it in
                            Button { toggle(it) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selected.contains(it.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(it.id) ? P.green : Color.secondary)
                                    Text(it.name).font(.system(size: 13, weight: .semibold))
                                    if let sv = it.serving, !sv.isEmpty {
                                        Text(sv).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(grp(it.calories)) cal").font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                        HStack {
                            Button("Add selected") { Task { await addSelected() } }
                                .buttonStyle(.borderedProminent).disabled(selected.isEmpty || busy)
                            Button("Clear") { preview = []; selected = [] }.buttonStyle(.bordered)
                        }
                    }
                }

                // 3) Manual entry (always available, even without keys)
                DisclosureGroup(isExpanded: $manualOpen) {
                    VStack(spacing: 8) {
                        TextField("Food name", text: $mName).textFieldStyle(.roundedBorder)
                        HStack(spacing: 8) {
                            numField("Calories", $mCal); numField("Protein g", $mP)
                            numField("Carbs g", $mC); numField("Fat g", $mF)
                        }
                        Button("Add") { Task { await addManual() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || mName.trimmingCharacters(in: .whitespaces).isEmpty || Double(mCal) == nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 6)
                } label: {
                    Text(nlConfigured ? "Add manually" : "Add food (manual)")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                }

                if !nlConfigured {
                    Text("Tip: add Nutritionix API keys to .env to log food in plain English.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let msg {
                    Text(msg).font(.system(size: 12, weight: .medium)).foregroundStyle(msgErr ? P.red : P.green)
                }

                // 4) Today's log (delete with the trash button)
                if let items = data.nutrition?.items, !items.isEmpty {
                    Divider().overlay(P.stroke)
                    ForEach(items) { it in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(it.name).font(.system(size: 13, weight: .semibold))
                                if let sv = it.serving, !sv.isEmpty {
                                    Text(sv).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(grp(it.calories)) cal").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                            Button { if let id = it.dbId { Task { await data.deleteFood(id, days: days) } } } label: {
                                Image(systemName: "trash").font(.system(size: 12))
                            }.buttonStyle(.borderless).foregroundStyle(P.red.opacity(0.85))
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private func numField(_ ph: String, _ b: Binding<String>) -> some View {
        TextField(ph, text: b).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
    }
    private func flash(_ m: String, err: Bool) { msg = m; msgErr = err }
    private func toggle(_ it: FoodItem) {
        if selected.contains(it.id) { selected.remove(it.id) } else { selected.insert(it.id) }
    }

    private func lookup() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        busy = true; msg = nil; defer { busy = false }
        do {
            let items = try await data.lookupFood(q)
            if items.isEmpty { flash("No foods recognized — try rephrasing, or add manually.", err: true) }
            else { preview = items; selected = Set(items.map(\.id)) }
        } catch { flash(error.localizedDescription, err: true) }
    }

    private func addSelected() async {
        let chosen = preview.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            try await data.addFood(chosen, days: days)
            preview = []; selected = []; query = ""
            flash("Added \(chosen.count) item\(chosen.count == 1 ? "" : "s").", err: false)
        } catch { flash(error.localizedDescription, err: true) }
    }

    private func addManual() async {
        let name = mName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let cal = Double(mCal) else { flash("Enter a name and calories.", err: true); return }
        let item = FoodItem(dbId: nil, name: name, serving: nil, calories: cal,
                            protein_g: Double(mP), carbs_g: Double(mC), fat_g: Double(mF), source: "manual")
        busy = true; defer { busy = false }
        do {
            try await data.addFood([item], days: days)
            mName = ""; mCal = ""; mP = ""; mC = ""; mF = ""
            flash("Added \(name).", err: false)
        } catch { flash(error.localizedDescription, err: true) }
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
