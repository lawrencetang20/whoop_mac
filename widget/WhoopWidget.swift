// WhoopWidget.swift
// The Widget Extension target's main source.
// Add WhoopShared.swift to this target too.
//
// Renders a premium WHOOP-style recovery ring (SwiftUI Circle trim, zone-colored,
// percentage in the center) plus sleep + strain. Supports .systemSmall and
// .systemMedium.

import WidgetKit
import SwiftUI

// MARK: - Timeline

struct WhoopEntry: TimelineEntry {
    let date: Date
    let snap: WhoopSnapshot
}

struct WhoopProvider: TimelineProvider {
    func placeholder(in context: Context) -> WhoopEntry {
        WhoopEntry(date: Date(), snap: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (WhoopEntry) -> Void) {
        if context.isPreview { completion(WhoopEntry(date: Date(), snap: .placeholder)); return }
        SnapshotStore.fetch { snap in completion(WhoopEntry(date: Date(), snap: snap)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WhoopEntry>) -> Void) {
        // Fetch from the local engine's API (not a shared file the engine writes), then
        // reload every ~15 min to match the menu-bar app's sync cadence.
        SnapshotStore.fetch { snap in
            let entry = WhoopEntry(date: Date(), snap: snap)
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// Note: formatting helpers (hm, strainText, intText), the RecoveryRing view,
// and the WhoopTint accents live in WhoopShared.swift so both targets share them.

// MARK: - Metric pill / row

/// Compact icon + value used along the bottom of the small widget.
struct MetricChip: View {
    let icon: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }
}

/// Labeled metric row used in the medium widget's right column.
struct MetricRow: View {
    let icon: String
    let label: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))   // fixed contrast on the near-black gradient
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Widget views

struct SmallWidgetView: View {
    let snap: WhoopSnapshot

    var body: some View {
        VStack(spacing: 0) {
            RecoveryRing(score: snap.recovery?.score, lineWidth: 11, valueFontSize: 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                MetricChip(icon: "bed.double.fill",
                           value: hm(snap.sleep?.hours),
                           tint: WhoopTint.sleep)
                Spacer()
                MetricChip(icon: "bolt.fill",
                           value: strainText(snap.strain),
                           tint: WhoopTint.strain)
            }
            .padding(.top, 4)
        }
        .padding(14)
    }
}

struct MediumWidgetView: View {
    let snap: WhoopSnapshot

    var body: some View {
        HStack(spacing: 18) {
            RecoveryRing(score: snap.recovery?.score, lineWidth: 13, valueFontSize: 34)
                .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((snap.name?.isEmpty == false ? snap.name! : "TODAY").uppercased())
                        .font(.system(size: 11, weight: .heavy)).tracking(1.5)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if let s = snap.recovery?.score {
                        Text("\(zoneName(s)) recovery".uppercased())
                            .font(.system(size: 11, weight: .heavy)).tracking(1.2)
                            .foregroundStyle(recoveryColor(s))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                // Freshness lives on the large widget (which has the room); medium stays compact.

                MetricRow(icon: "waveform.path.ecg", label: "HRV",
                          value: snap.recovery?.hrvMs.map { "\(Int($0.rounded())) ms" } ?? "--",
                          tint: recoveryColor(snap.recovery?.score))
                MetricRow(icon: "heart.fill", label: "RHR",
                          value: intText(snap.recovery?.restingHr, suffix: " bpm"),
                          tint: WhoopTint.heart)
                MetricRow(icon: "bed.double.fill", label: "Sleep",
                          value: hm(snap.sleep?.hours),
                          tint: WhoopTint.sleep)
                MetricRow(icon: "bolt.fill", label: "Strain",
                          value: strainText(snap.strain),
                          tint: WhoopTint.strain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }
}

struct LargeWidgetView: View {
    let snap: WhoopSnapshot

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((snap.name?.isEmpty == false ? snap.name! : "TODAY").uppercased())
                        .font(.system(size: 12, weight: .heavy)).tracking(1.5).foregroundStyle(.white.opacity(0.62))
                    if let s = snap.recovery?.score {
                        Text("\(zoneName(s)) recovery".uppercased())
                            .font(.system(size: 12, weight: .heavy)).tracking(1.2).foregroundStyle(recoveryColor(s))
                    }
                }
                Spacer()
                if let t = freshnessText(snap.lastSync) {
                    Text(t).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }

            RecoveryRing(score: snap.recovery?.score, lineWidth: 16, valueFontSize: 52, showCaption: true)
                .frame(width: 150, height: 150)
                .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                pillar("HRV", snap.recovery?.hrvMs.map { "\(Int($0.rounded()))" } ?? "--", "ms", recoveryColor(snap.recovery?.score))
                pillar("SLEEP", hm(snap.sleep?.hours), "", WhoopTint.sleep)
                pillar("STRAIN", strainText(snap.strain), "", WhoopTint.strain)
            }
        }
        .padding(18)
    }

    private func pillar(_ label: String, _ value: String, _ unit: String, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6)) }
            }
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(0.8).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct WhoopWidgetView: View {
    var entry: WhoopEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(snap: entry.snap)
        case .systemLarge:
            LargeWidgetView(snap: entry.snap)
        default:
            MediumWidgetView(snap: entry.snap)
        }
    }
}

// MARK: - Widget configuration

@main
struct WhoopWidget: Widget {
    let kind = "WhoopWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WhoopProvider()) { entry in
            if #available(macOS 14.0, *) {
                WhoopWidgetView(entry: entry)
                    .environment(\.colorScheme, .dark)   // background is always dark → force light text
                    .containerBackground(for: .widget) {
                        // Anchored to the shared near-black so all three surfaces match, with a
                        // faint diagonal sheen so it isn't dead flat.
                        LinearGradient(
                            colors: [Color(red: 0.06, green: 0.06, blue: 0.075), Color.whoopBG],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
            } else {
                WhoopWidgetView(entry: entry)
                    .environment(\.colorScheme, .dark)
            }
        }
        .configurationDisplayName("WHOOP")
        .description("Your latest recovery, sleep, and strain.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Previews

#if DEBUG
struct WhoopWidget_Previews: PreviewProvider {
    static let red = WhoopSnapshot(
        generatedAt: nil, lastSync: nil, name: "Lawrence",
        recovery: .init(score: 22, hrvMs: 31, restingHr: 63, day: nil),
        sleep: .init(hours: 4.1, performance: 52, efficiency: 70, day: nil),
        strain: .init(value: 18.2, avgHr: 95, calories: 3100, day: nil),
        nutrition: .init(calories: 2750, proteinG: 90, carbsG: 320, fatG: 95,
                         burned: 3100, net: -350, goal: 2400, remaining: -350, day: nil)
    )

    static var previews: some View {
        WhoopWidgetView(entry: WhoopEntry(date: .now, snap: .placeholder))
            .previewContext(WidgetPreviewContext(family: .systemSmall))
            .previewDisplayName("Small / Green")

        WhoopWidgetView(entry: WhoopEntry(date: .now, snap: red))
            .previewContext(WidgetPreviewContext(family: .systemMedium))
            .previewDisplayName("Medium / Red")
    }
}
#endif
