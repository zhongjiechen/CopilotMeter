import SwiftUI
import AppKit

/// Compact banner shown at the top of the popover when `UpdateChecker`
/// finds a newer GitHub release. Single button takes the user to the
/// release page in their browser.
struct UpdateBanner: View {
    let release: UpdateChecker.Release
    let currentVersion: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available: \(release.tagName)")
                    .font(.caption.weight(.semibold))
                Text("You're on v\(currentVersion). Tap to view the release notes & DMG.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(release.htmlURL)
            } label: {
                Text("Open")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.4), lineWidth: 0.5)
                )
        )
    }
}
