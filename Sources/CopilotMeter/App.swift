import SwiftUI
import AppKit

@main
struct CopilotMeterApp: App {
    @StateObject private var refresher = UsageRefresher()
    @StateObject private var updates = UpdateChecker()
    @StateObject private var goalStore = DailyGoalStore()

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
            PopoverView(refresher: refresher, updates: updates, goal: goalStore)
        } label: {
            MenuBarLabel(refresher: refresher, updates: updates, goal: goalStore)
                .task {
                    refresher.startAutoRefresh(every: 60)
                    updates.start(initialDelay: 15)
                    PreviewWindowController.shared.attach(refresher: refresher, updates: updates, goal: goalStore)
                }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var refresher: UsageRefresher
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var goal: DailyGoalStore

    var body: some View {
        let today = refresher.snapshot.byWindow[.today] ?? .zero
        let chat = refresher.snapshot.blindChatByWindow[.today] ?? 0
        let totalCredits = today.aiCredits
        let totalUsd = today.aiCreditsUsd
        let totalRequests = Int(today.requests.rounded()) + chat
        let byRemote = refresher.snapshot.byWindowByRemote[.today] ?? [:]
        let localCredits = byRemote[nil]?.aiCredits ?? 0
        let remoteEntries: [(String, Double)] = byRemote
            .compactMap { (key, value) -> (String, Double)? in
                guard let name = key else { return nil }
                return value.aiCredits > 0 ? (name, value.aiCredits) : nil
            }
            .sorted { $0.1 > $1.1 }
        let breakdownText = remoteEntries.isEmpty ? nil : Self.breakdownString(
            localCredits: localCredits, remotes: remoteEntries
        )

        // Achievement state drives the menu-bar's emoji prefix +
        // colored gradient. The fireworks emoji sequence is purely a
        // visual flourish; the underlying number is unchanged.
        let achieved = goal.achievedToday
        let achievedStyle: AnyShapeStyle = achieved
            ? AnyShapeStyle(LinearGradient(
                colors: [.orange, .pink, .purple, .blue],
                startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(Color.primary)

        HStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if achieved {
                    Text(goal.currentEmoji)
                        .font(.system(size: 13))
                } else {
                    Image(systemName: totalCredits > 0 ? "chart.bar.fill" : "chart.bar")
                }
                if updates.hasUpdate {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -1)
                }
            }
            // Primary number is **AI Credits used today** — the same unit
            // GitHub uses on the side panel of the Copilot CLI since the
            // 2026-06-01 billing change. Breakdown chip (when there are
            // remotes) reuses the AIU split per host. When the daily
            // goal is met, the number flips to a colored gradient so
            // the menu bar visibly says "done for today".
            Text(totalCredits > 0 ? Formatters.compactCredits(totalCredits) : "—")
                .monospacedDigit()
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(achievedStyle)
            if achieved {
                Text("✓")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.green)
            } else if let breakdownText {
                Text(breakdownText)
                    .monospacedDigit()
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .help(tooltip(
            credits: totalCredits, usd: totalUsd, requests: totalRequests,
            localCredits: localCredits, remotes: remoteEntries
        ))
        // Drive goal evaluation off the published today-credits value.
        // The .onAppear fires once on the first body render so the app
        // picks up an already-met goal right after launch (in case the
        // goal had been met before the previous run quit).
        .onAppear { goal.evaluate(todayCredits: totalCredits) }
        .onChange(of: totalCredits) { newValue in
            goal.evaluate(todayCredits: newValue)
        }
    }

    /// Builds the compact "(L:12 host:30)" suffix shown after the credit total
    /// when remotes are configured. Each chip is an AI-Credit count rounded
    /// to the nearest unit. Up to 2 remote chips; any extra hosts collapse
    /// into a "+N" marker so the menu bar stays narrow.
    private static func breakdownString(localCredits: Double, remotes: [(String, Double)]) -> String {
        let visible = Array(remotes.prefix(2))
        let hidden = remotes.count - visible.count
        var parts: [String] = ["L:\(Formatters.compactCredits(localCredits))"]
        for (name, c) in visible {
            let short = name.count > 6 ? String(name.prefix(5)) + "…" : name
            parts.append("\(short):\(Formatters.compactCredits(c))")
        }
        if hidden > 0 {
            parts.append("+\(hidden)")
        }
        return "(" + parts.joined(separator: " ") + ")"
    }

    private func tooltip(credits: Double, usd: Double, requests: Int,
                         localCredits: Double, remotes: [(String, Double)]) -> String {
        var lines: [String] = [
            "Today: \(Formatters.compactCredits(credits)) AI Credits  ≈ \(Formatters.compactUSD(usd))",
            "\(requests) requests",
            "• Local: \(Formatters.compactCredits(localCredits))",
        ]
        for (name, c) in remotes {
            lines.append("• \(name): \(Formatters.compactCredits(c))")
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

    func attach(refresher: UsageRefresher, updates: UpdateChecker, goal: DailyGoalStore) {
        guard let window else { return }
        let hosting = NSHostingView(rootView: PopoverView(refresher: refresher, updates: updates, goal: goal))
        hosting.frame = NSRect(x: 0, y: 0, width: 540, height: 820)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 540, height: 820))
        window.makeKeyAndOrderFront(nil)
    }
}
