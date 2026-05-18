import SwiftUI

extension UsageRecord.Source {
    var color: Color {
        switch self {
        case .copilotCLI: return .teal
        case .vscodeAgent: return .indigo
        case .vscodeChat: return .orange
        case .codingAgent: return .brown
        case .unknown: return .gray
        }
    }

    var shortLabel: String {
        switch self {
        case .copilotCLI: return "CLI"
        case .vscodeAgent: return "VS Code Agent"
        case .vscodeChat: return "VS Code Chat"
        case .codingAgent: return "Coding Agent"
        case .unknown: return "Unknown"
        }
    }
}

/// Always-visible legend explaining the three colored sources.
struct SourceLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach([UsageRecord.Source.copilotCLI, .vscodeAgent, .vscodeChat, .codingAgent], id: \.self) { src in
                HStack(spacing: 4) {
                    Circle().fill(src.color).frame(width: 8, height: 8)
                    Text(src.shortLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}
