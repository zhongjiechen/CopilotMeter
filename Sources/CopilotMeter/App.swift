import SwiftUI
import AppKit

@main
struct CopilotMeterApp: App {
    @StateObject private var refresher = UsageRefresher()
    @StateObject private var updates = UpdateChecker()

    init() {
        // Open a regular window for screenshot / debug if --preview was passed.
        // We do this in the App init rather than via SceneBuilder because
        // conditional `Window` scenes confuse Swift's @SceneBuilder result type.
        if CommandLine.arguments.contains("--preview") ||
            ProcessInfo.processInfo.environment["COPILOTMETER_PREVIEW"] == "1" {
            PreviewWindowController.shared.show()
        }
        // Headless one-shot mode for diagnostics: runs a full refresh (local +
        // all enabled remotes), prints aggregate counts, and exits. Useful
        // when validating ingestion changes without dealing with the
        // menu-bar UI lifecycle.
        if CommandLine.arguments.contains("--once") {
            Self.runOnceAndExit()
        }
    }

    private static func runOnceAndExit() -> Never {
        let (cfg, _) = RemotesConfig.load()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionStateDir = home.appendingPathComponent(".copilot/session-state")
        let result = RefreshWorker.run(
            cachePath: CacheStore.defaultPath,
            sessionStateDir: sessionStateDir,
            remotes: cfg.remotes
        )
        let snap = result.snapshot
        print("== UsageRefresher one-shot result ==")
        if let err = result.errorMessage { print("error: \(err)") }
        for status in result.remoteStatuses {
            print("remote \(status.host): \(status.phase.rawValue)  err=\(status.lastError ?? "-")")
        }
        print("byWindowByRemote (today):")
        for (key, agg) in (snap.byWindowByRemote[.today] ?? [:]) {
            print("  \(key ?? "<local>"): requests=\(Int(agg.requests))")
        }
        print("byWindowByRemote (month):")
        for (key, agg) in (snap.byWindowByRemote[.month] ?? [:]) {
            print("  \(key ?? "<local>"): requests=\(Int(agg.requests))")
        }
        print("blindChatByWindow (month): \(snap.blindChatByWindow[.month] ?? 0)")
        exit(0)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(refresher: refresher, updates: updates)
        } label: {
            MenuBarLabel(refresher: refresher, updates: updates)
                .task {
                    refresher.startAutoRefresh(every: 60)
                    updates.start(initialDelay: 15)
                    PreviewWindowController.shared.attach(refresher: refresher, updates: updates)
                }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var refresher: UsageRefresher
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        let today = refresher.snapshot.byWindow[.today] ?? .zero
        let chat = refresher.snapshot.blindChatByWindow[.today] ?? 0
        let total = Int(today.requests.rounded()) + chat
        let byRemote = refresher.snapshot.byWindowByRemote[.today] ?? [:]
        let localCount = Int((byRemote[nil]?.requests ?? 0).rounded()) + chat
        let remoteEntries: [(String, Int)] = byRemote
            .compactMap { (key, value) -> (String, Int)? in
                guard let name = key else { return nil }
                let count = Int(value.requests.rounded())
                return count > 0 ? (name, count) : nil
            }
            .sorted { $0.1 > $1.1 }

        HStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: total > 0 ? "chart.bar.fill" : "chart.bar")
                if updates.hasUpdate {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -1)
                }
            }
            // If user has remotes enabled, show local + remote chips + total.
            // Otherwise just the total to keep the menu bar tidy.
            if remoteEntries.isEmpty {
                Text(total > 0 ? "\(total)" : "—")
                    .monospacedDigit()
                    .font(.system(size: 12, weight: .semibold))
            } else {
                let visible = Array(remoteEntries.prefix(2))
                let hiddenCount = remoteEntries.count - visible.count
                Text("L:\(localCount)")
                    .monospacedDigit()
                    .font(.system(size: 12, weight: .semibold))
                ForEach(visible, id: \.0) { (name, count) in
                    Text("·\(shortName(name)):\(count)")
                        .monospacedDigit()
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if hiddenCount > 0 {
                    Text("+\(hiddenCount)")
                        .monospacedDigit()
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Text("=\(total)")
                    .monospacedDigit()
                    .font(.system(size: 12, weight: .bold))
            }
        }
        .help(tooltip(localCount: localCount, remotes: remoteEntries, total: total))
    }

    /// Truncate long host names so the menu bar stays compact.
    private func shortName(_ name: String) -> String {
        name.count > 6 ? String(name.prefix(5)) + "…" : name
    }

    private func tooltip(localCount: Int, remotes: [(String, Int)], total: Int) -> String {
        var lines: [String] = ["Today: \(total) requests"]
        lines.append("• Local: \(localCount)")
        for (name, count) in remotes {
            lines.append("• \(name): \(count)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Opens a regular NSWindow hosting the popover view for screenshot/debug.
@MainActor
final class PreviewWindowController {
    static let shared = PreviewWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            // Position the preview window in the top-right of the main screen
            // so it stays out of the way of arbitrary other-app windows when
            // we screenshot it programmatically.
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let winSize = NSSize(width: 540, height: 820)
            let origin = NSPoint(
                x: screen.maxX - winSize.width - 40,
                y: screen.maxY - winSize.height - 40
            )
            let w = NSWindow(
                contentRect: NSRect(origin: origin, size: winSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "CopilotMeter — Preview"
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.level = .floating
            w.contentMinSize = NSSize(width: 540, height: 720)
            w.setContentSize(winSize)
            w.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            self.window = w
        }
    }

    func attach(refresher: UsageRefresher, updates: UpdateChecker) {
        guard let window else { return }
        let hosting = NSHostingView(rootView: PopoverView(refresher: refresher, updates: updates))
        hosting.frame = NSRect(x: 0, y: 0, width: 540, height: 820)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 540, height: 820))
        window.makeKeyAndOrderFront(nil)
    }
}
