import Foundation
import Combine

/// Periodically polls the GitHub Releases API for a newer version of
/// CopilotMeter and, if one exists, exposes it on `@Published latestRelease`
/// so the popover can show an update banner.
///
/// **The one network call this app makes besides user-configured SSH remotes.**
///
/// Properties:
/// - Anonymous: unauthenticated GET to `api.github.com`, no User-Agent
///   beyond the system default URLSession identity, no query params, no body.
/// - Throttled: at most one call every `Self.minCheckInterval` (default 6h),
///   timestamp persisted in UserDefaults so reopening the menu bar doesn't
///   re-hit the API.
/// - Opt-out: set `defaults write com.copilotmeter.app disableUpdateChecks 1`
///   in Terminal to disable forever.
/// - Failure-silent: any network/parse error leaves `latestRelease` nil and
///   schedules a retry on the next interval.
@MainActor
public final class UpdateChecker: ObservableObject {

    public struct Release: Sendable, Equatable {
        public let tagName: String          // e.g. "v0.1.7"
        public let htmlURL: URL             // GitHub release page
        public let publishedAt: Date?
        public let body: String?
    }

    @Published public private(set) var latestRelease: Release?
    @Published public private(set) var lastCheckedAt: Date?
    @Published public private(set) var lastError: String?

    /// The currently running app's marketing version (CFBundleShortVersionString).
    public let currentVersion: String

    /// True iff `latestRelease.tagName` is strictly greater than the current
    /// version. Compares via simple dotted-integer semver (strips a leading
    /// `v`). Prerelease suffixes (e.g. "-beta.1") sort lower than a plain
    /// version — see `compareSemver`.
    public var hasUpdate: Bool {
        guard let r = latestRelease else { return false }
        return Self.compareSemver(r.tagName, currentVersion) == .orderedDescending
    }

    public static let minCheckInterval: TimeInterval = 7 * 24 * 3600  // 1 week
    public static let releasesURL = URL(
        string: "https://api.github.com/repos/zhongjiechen/CopilotMeter/releases/latest"
    )!

    private static let lastCheckedKey = "UpdateChecker.lastCheckedAt"
    private static let cachedTagKey = "UpdateChecker.cachedTag"
    private static let cachedURLKey = "UpdateChecker.cachedURL"
    private static let optOutKey = "disableUpdateChecks"

    private var timer: Timer?

    public init() {
        self.currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "0.0.0"

        // Hydrate from cache so the popover doesn't flash empty on launch.
        if let ts = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date {
            self.lastCheckedAt = ts
        }
        if let tag = UserDefaults.standard.string(forKey: Self.cachedTagKey),
           let urlStr = UserDefaults.standard.string(forKey: Self.cachedURLKey),
           let url = URL(string: urlStr) {
            self.latestRelease = Release(tagName: tag, htmlURL: url,
                                         publishedAt: nil, body: nil)
        }
    }

    /// Starts the periodic check. The first attempt fires after `initialDelay`
    /// seconds so we don't compete with the initial usage refresh for the
    /// first few moments after launch.
    public func start(initialDelay: TimeInterval = 15) {
        guard !isOptedOut() else { return }
        // First check (respects the throttle).
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
            await self?.checkIfDue()
        }
        // Periodic.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.minCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkIfDue() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Manual check (e.g. from a "Check now" button), bypasses the throttle.
    public func checkNow() async {
        await performCheck()
    }

    /// Respects the throttle: no-op if we checked within `minCheckInterval`.
    public func checkIfDue() async {
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < Self.minCheckInterval {
            return
        }
        await performCheck()
    }

    private func isOptedOut() -> Bool {
        UserDefaults.standard.bool(forKey: Self.optOutKey)
    }

    private func performCheck() async {
        guard !isOptedOut() else { return }
        do {
            let r = try await Self.fetchLatestRelease()
            self.latestRelease = r
            self.lastCheckedAt = Date()
            self.lastError = nil
            UserDefaults.standard.set(self.lastCheckedAt, forKey: Self.lastCheckedKey)
            UserDefaults.standard.set(r.tagName, forKey: Self.cachedTagKey)
            UserDefaults.standard.set(r.htmlURL.absoluteString, forKey: Self.cachedURLKey)
        } catch {
            // Failure is silent — UI just keeps showing the last cached value.
            self.lastError = "\(error.localizedDescription)"
        }
    }

    // MARK: - Network

    private static func fetchLatestRelease() async throws -> Release {
        var req = URLRequest(url: releasesURL)
        req.httpMethod = "GET"
        // Be explicit about the JSON API contract.
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        // Cache control: GitHub's CDN already caches this. URLSession's
        // default cache policy is fine; we throttle on our side too.
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "UpdateChecker", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad HTTP status"])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let urlStr = obj["html_url"] as? String,
              let url = URL(string: urlStr)
        else {
            throw NSError(domain: "UpdateChecker", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Parse error"])
        }
        let published = (obj["published_at"] as? String).flatMap(iso8601.date(from:))
        let body = obj["body"] as? String
        return Release(tagName: tag, htmlURL: url, publishedAt: published, body: body)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Semver

    enum SemverOrdering { case orderedAscending, orderedSame, orderedDescending }

    /// Compares two version strings ("v0.1.6", "0.1.7", "1.2.3-beta.1") by
    /// dotted-integer order. Components after the first non-numeric segment
    /// are compared lexicographically. A version with a prerelease suffix is
    /// less than the same version without one.
    static func compareSemver(_ lhs: String, _ rhs: String) -> SemverOrdering {
        func strip(_ s: String) -> (numbers: [Int], pre: String) {
            var s = s
            if s.hasPrefix("v") { s.removeFirst() }
            let dash = s.firstIndex(of: "-")
            let head = dash.map { String(s[..<$0]) } ?? s
            let pre = dash.map { String(s[s.index(after: $0)...]) } ?? ""
            let nums = head.split(separator: ".").map { Int($0) ?? 0 }
            return (nums, pre)
        }
        let (ln, lp) = strip(lhs)
        let (rn, rp) = strip(rhs)
        let len = max(ln.count, rn.count)
        for i in 0..<len {
            let a = i < ln.count ? ln[i] : 0
            let b = i < rn.count ? rn[i] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        // Same numeric core. A non-empty prerelease tag sorts BEFORE the
        // plain version, so "1.2.3-beta" < "1.2.3".
        switch (lp.isEmpty, rp.isEmpty) {
        case (true, true):  return .orderedSame
        case (false, true): return .orderedAscending
        case (true, false): return .orderedDescending
        case (false, false):
            if lp < rp { return .orderedAscending }
            if lp > rp { return .orderedDescending }
            return .orderedSame
        }
    }
}
