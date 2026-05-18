import SwiftUI
import AppKit

@main
struct CopilotMeterApp: App {
    @StateObject private var refresher = UsageRefresher()

    init() {
        // Open a regular window for screenshot / debug if --preview was passed.
        // We do this in the App init rather than via SceneBuilder because
        // conditional `Window` scenes confuse Swift's @SceneBuilder result type.
        if CommandLine.arguments.contains("--preview") ||
            ProcessInfo.processInfo.environment["COPILOTMETER_PREVIEW"] == "1" {
            PreviewWindowController.shared.show()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(refresher: refresher)
        } label: {
            MenuBarLabel(refresher: refresher)
                .task {
                    refresher.startAutoRefresh(every: 60)
                    PreviewWindowController.shared.attach(refresher: refresher)
                }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var refresher: UsageRefresher

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
            Image(systemName: total > 0 ? "chart.bar.fill" : "chart.bar")
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

    func attach(refresher: UsageRefresher) {
        guard let window else { return }
        let hosting = NSHostingView(rootView: PopoverView(refresher: refresher))
        hosting.frame = NSRect(x: 0, y: 0, width: 540, height: 820)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 540, height: 820))
        window.makeKeyAndOrderFront(nil)
    }
}
