// WhoopApp.swift
// The containing macOS app target. A macOS widget must ship inside a host app —
// this app is intentionally minimal. Its jobs:
//   1. Carry the App Group entitlement so the shared container exists.
//   2. Watch latest.json and ask WidgetKit to reload when it changes (fast updates;
//      otherwise the widget refreshes on its own ~30 min timeline).
//   3. Offer a button to open the local dashboard.
// Add WhoopShared.swift to this target as well.

import SwiftUI
import WidgetKit

@main
struct WhoopApp: App {
    @StateObject private var watcher = SnapshotWatcher()

    var body: some Scene {
        WindowGroup {
            WhoopMainView()
                .onAppear { watcher.start() }   // keep mirroring data → reload widgets on change
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 1100, height: 740)
    }
}

struct ContentView: View {
    @EnvironmentObject var watcher: SnapshotWatcher
    var snap: WhoopSnapshot { watcher.snap }

    var body: some View {
        VStack(spacing: 20) {
            Text("WHOOP")
                .font(.title.bold())
                .tracking(6)
                .foregroundStyle(.secondary)

            HStack(spacing: 24) {
                // Mirror the widget's recovery ring for a consistent look.
                RecoveryRing(score: snap.recovery?.score,
                             lineWidth: 12, valueFontSize: 30)
                    .frame(width: 110, height: 110)

                VStack(alignment: .leading, spacing: 10) {
                    stat("HRV", snap.recovery?.hrvMs.map { "\(Int($0.rounded())) ms" } ?? "--")
                    stat("RHR", snap.recovery?.restingHr.map { "\($0) bpm" } ?? "--")
                    stat("Sleep", hm(snap.sleep?.hours))
                    stat("Strain", strainText(snap.strain))
                }
            }

            if let sync = snap.lastSync {
                Text("Last sync: \(sync)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Open Dashboard") {
                if let url = URL(string: "http://localhost:8756") {
                    NSWorkspace.shared.open(url)
                }
            }

            Text(SnapshotStore.url == nil
                 ? "⚠️ App Group not configured — see widget/README.md"
                 : "Reads: \(SnapshotStore.url!.path)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(28)
    }

    func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }
}

/// Polls the local engine's API for fresh data and reloads widget timelines on change,
/// so the widget updates quickly while the app is open. Fetching over the API (rather than
/// the engine writing into our container) is what keeps macOS from ever showing the
/// "access data from other apps" prompt.
final class SnapshotWatcher: ObservableObject {
    @Published var snap: WhoopSnapshot = SnapshotStore.load()
    private var poll: Timer?

    func start() {
        reload()
        // Poll the local API every 5 min (the widget also self-refreshes on its timeline).
        poll = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    func reload() {
        SnapshotStore.fetch { [weak self] snap in
            DispatchQueue.main.async {
                self?.snap = snap
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    deinit { poll?.invalidate() }
}
