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
        HStack(spacing: 3) {
            Image(systemName: total > 0 ? "chart.bar.fill" : "chart.bar")
            Text(total > 0 ? "\(total)" : "—")
                .monospacedDigit()
                .font(.system(size: 12, weight: .semibold))
        }
    }
}

/// Opens a regular NSWindow hosting the popover view for screenshot/debug.
@MainActor
final class PreviewWindowController {
    static let shared = PreviewWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 540, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "CopilotMeter — Preview"
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            // Keep preview window above other apps so it's easy to screenshot.
            w.level = .floating
            w.contentMinSize = NSSize(width: 540, height: 720)
            w.setContentSize(NSSize(width: 540, height: 820))
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
