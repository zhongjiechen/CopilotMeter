import Foundation
import SwiftUI
import Combine

/// Tracks the user's daily AI-Credits target and the "celebration" state
/// shown in the menu bar / popover when today's usage crosses the target.
///
/// **Why AI Credits (not raw tokens)?** Since v0.1.16 AI Credits are the
/// primary metric in the menu bar — and the official 2026-06-01 GitHub
/// billing unit (1 credit = $0.01). Setting the goal in credits keeps it
/// trivially translatable to dollars and matches what the user sees.
///
/// Day-rollover behavior: the celebration fires **once per local
/// calendar day** the first time `todayCredits >= goalCredits`. After
/// midnight the cached `lastCelebratedDay` no longer matches, so the
/// next time the goal is crossed the celebration fires again. The
/// "achieved" colored state (no animation) is purely derived from the
/// current snapshot and rolls off on its own at midnight too (since
/// today's bucket resets to 0 in the aggregator).
@MainActor
public final class DailyGoalStore: ObservableObject {

    // MARK: - Persistent settings (NSUserDefaults via @AppStorage)

    /// Daily target, in AI Credits. 0 means "no goal set" → all goal
    /// affordances are hidden and the menu bar behaves normally.
    @AppStorage("dailyAiuGoalCredits") public var goalCredits: Double = 0

    /// ISO-day string ("2026-06-01") on which we last fired the
    /// celebration overlay. Used to fire at most once per local day.
    @AppStorage("lastCelebratedDayKey") public var lastCelebratedDay: String = ""

    // MARK: - Transient UI state

    /// `true` whenever today's AI Credits ≥ `goalCredits` (and goal > 0).
    /// Used by the menu bar label + the popover panel to switch to
    /// the colored "goal hit" presentation. Survives across the day
    /// (not just during the celebration burst) because the user wants
    /// the menu bar to *keep* saying "goal complete" until midnight.
    @Published public var achievedToday: Bool = false

    /// Cached "today" key used to detect midnight rollover so we can
    /// wipe `achievedToday` on rollover and let the menu bar drop the
    /// colored state at the right moment if the user keeps the app
    /// open across midnight.
    @Published private(set) var cachedDayKey: String = ""

    public init() {
        self.cachedDayKey = Self.todayKey()
    }

    // MARK: - Public API

    /// Whether the user has set a non-zero target. Drives whether the
    /// "Daily goal" panel shows progress vs. an "edit to set a target"
    /// affordance.
    public var hasGoal: Bool { goalCredits > 0 }

    /// Called whenever the snapshot publishes a new today-credits value.
    /// - Updates `achievedToday`.
    /// - Fires the once-per-day fullscreen celebration overlay on
    ///   first crossing.
    /// - Clears stale achievement flags after midnight so the menu
    ///   bar drops the colored state at day rollover.
    public func evaluate(todayCredits: Double) {
        let dayKey = Self.todayKey()
        if dayKey != cachedDayKey {
            cachedDayKey = dayKey
            achievedToday = false
        }

        let achieved = goalCredits > 0 && todayCredits >= goalCredits
        if achieved != achievedToday {
            achievedToday = achieved
        }

        guard achieved else { return }
        if lastCelebratedDay != dayKey {
            lastCelebratedDay = dayKey
            CelebrationOverlay.shared.play()
        }
    }

    /// Force-resets today's celebration flag so the next crossing
    /// fires the overlay again. Exposed for the popover's "play
    /// preview" affordance + the Save flow (so re-saving the goal
    /// re-arms the celebration).
    public func resetCelebrationForToday() {
        lastCelebratedDay = ""
    }

    /// Force-plays the celebration overlay (used by the "Preview"
    /// button in the popover so the user can see what the celebration
    /// looks like without waiting to actually hit the goal).
    public func playPreview() {
        CelebrationOverlay.shared.play()
    }

    // MARK: - Helpers

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = .current
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func todayKey() -> String {
        dayKeyFormatter.string(from: Date())
    }
}
