import Foundation

/// A single observation of Copilot usage, normalized across all data sources.
public struct UsageRecord: Hashable, Codable, Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable {
        case copilotCLI      // Terminal CLI sessions
        case vscodeAgent     // VS Code Copilot agent / copilotcli mode (writes events.jsonl)
        case vscodeChat      // VS Code "Ask" chat mode (no token data, count-only)
        case codingAgent     // GitHub Copilot **Cloud Agent** — cloud-dispatched sessions
                             // fired off from PR `@copilot` mentions or VS Code's
                             // "Delegate to coding agent". The rawValue stays as
                             // "codingAgent" so existing cache.db rows still decode;
                             // the user-facing label is "Cloud Agent".
        case unknown

        public var displayName: String {
            switch self {
            case .copilotCLI: return "Copilot CLI"
            case .vscodeAgent: return "VS Code Agent"
            case .vscodeChat: return "VS Code Chat"
            case .codingAgent: return "Cloud Agent"
            case .unknown: return "Unknown"
            }
        }
    }

    public let timestamp: Date
    public let sessionId: String
    public let messageId: String?
    public let source: Source
    public let model: String
    public let outputTokens: Int
    public let inputTokens: Int       // 0 for per-message records; populated only from session.shutdown summaries
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    /// 1.0 for a single model API call; for session.shutdown summary rows this is the recorded `requests.count`
    public let requestCount: Double
    /// "Premium request cost" as recorded by Copilot, when available; nil for per-message records
    public let premiumCost: Double?
    /// **GitHub AI Credits**, in nano-AIU (1 AIU = 10^9 nano-AIU = $0.01 USD).
    /// Set when `session.shutdown.modelMetrics.<model>.totalNanoAiu` was present
    /// (newer Copilot CLI builds, post 2026-06-01 billing). For records where
    /// this is nil, callers should fall back to estimating from tokens via
    /// `PricingCatalog`.
    public let aiCreditsNano: Int64?
    /// Non-nil when this record was pulled from a remote host's
    /// ~/.copilot/session-state via SSH. The string is the user-chosen
    /// nickname from `remotes.json`.
    public let remoteName: String?

    public static func shutdownMessageId(lineOffset: Int64) -> String {
        "shutdown:\(lineOffset)"
    }

    public init(
        timestamp: Date,
        sessionId: String,
        messageId: String?,
        source: Source,
        model: String,
        outputTokens: Int,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        requestCount: Double,
        premiumCost: Double?,
        aiCreditsNano: Int64? = nil,
        remoteName: String? = nil
    ) {
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.messageId = messageId
        self.source = source
        self.model = model
        self.outputTokens = outputTokens
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.requestCount = requestCount
        self.premiumCost = premiumCost
        self.aiCreditsNano = aiCreditsNano
        self.remoteName = remoteName
    }
}
