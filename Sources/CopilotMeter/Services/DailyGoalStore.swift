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
/// next time the goal is crossed the animation fires again. The
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
    /// celebration animation. Used to fire at most once per local day.
    @AppStorage("lastCelebratedDayKey") public var lastCelebratedDay: String = ""

    // MARK: - Transient UI state

    /// True while the emoji-frame fireworks burst is running in the
    /// menu bar (≈ 6 s after the goal is crossed). Drives `currentEmoji`.
    @Published public var animationActive: Bool = false

    /// Index into `Self.frames`. Re-rendered ~3×/s while
    /// `animationActive` is true.
    @Published public var animationFrame: Int = 0

    /// `true` whenever today's AI Credits ≥ `goalCredits` (and goal > 0).
    /// Used by the menu bar label + the popover panel to switch to
    /// the colored "goal hit" presentation. Survives across the day
    /// (not just during the 6-s burst) because the user wants the
    /// menu bar to *keep* saying "goal complete" until midnight.
    @Published public var achievedToday: Bool = false

    /// Cached "today" key used to detect midnight rollover so we can
    /// clear `lastCelebratedDay` *implicitly* (we don't need to — the
    /// dayKey comparison in evaluate() handles it — but we also use
    /// this to wipe `achievedToday` on rollover so the menu bar drops
    /// the colored state at the right moment if the user keeps the
    /// app open across midnight).
    @Published private(set) var cachedDayKey: String = ""

    // MARK: - Internals

    private var animationTimer: Timer?

    public init() {
        self.cachedDayKey = Self.todayKey()
    }

    deinit {
        animationTimer?.invalidate()
    }

    // MARK: - Animation frames

    /// Fireworks/celebration emoji cycle. All of these render in color
    /// in the menu bar (Unicode bitmap glyphs bypass the template
    /// rendering that monochrome SF Symbols are subject to).
    public static let frames = ["🎉", "✨", "🎆", "🎇", "🪅"]

    /// Emoji currently shown in the menu bar. While `animationActive`
    /// it cycles through `frames`; otherwise it settles to 🎉 so the
    /// colored "goal achieved" state stays visible until midnight.
    public var currentEmoji: String {
        guard animationActive else { return "🎉" }
        return Self.frames[animationFrame % Self.frames.count]
    }

    // MARK: - Public API

    /// Whether the user has set a non-zero target. Drives whether the
    /// "Daily goal" panel shows progress vs. an "edit to set a target"
    /// affordance.
    public var hasGoal: Bool { goalCredits > 0 }

    /// Called whenever the snapshot publishes a new today-credits value.
    /// - Updates `achievedToday`.
    /// - Fires the once-per-day fireworks burst on first crossing.
    /// - Clears stale celebration / achievement flags after midnight
    ///   so the menu bar drops the colored state at day rollover.
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
            startAnimation()
        }
    }

    /// Force-resets today's celebration flag so the next crossing
    /// fires the animation again. Exposed for debug / "test goal"
    /// affordance in the popover.
    public func resetCelebrationForToday() {
        lastCelebratedDay = ""
    }

    /// Forces the animation to play (used by the "Preview" button in
    /// the popover so the user can see what the celebration looks
    /// like without waiting to actually hit the goal).
    public func playAnimation() {
        startAnimation()
    }

    // MARK: - Animation

    private func startAnimation() {
        animationTimer?.invalidate()
        animationActive = true
        animationFrame = 0

        // 6 s total burst at ~3.3 frames/s ⇒ 20 ticks.
        var tick = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                tick += 1
                self.animationFrame = (self.animationFrame + 1) % Self.frames.count
                if tick >= 20 {
                    timer.invalidate()
                    self.animationTimer = nil
                    self.animationActive = false
                }
            }
        }
        // Ensure the timer keeps firing while menus are tracking.
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
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
