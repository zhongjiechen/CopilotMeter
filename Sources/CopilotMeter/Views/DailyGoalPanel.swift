import SwiftUI

/// Popover section that lets the user set a daily AI-Credits target
/// and watch progress toward it. When the goal is achieved, the panel
/// switches to a colored "Goal hit!" presentation with a short
/// SwiftUI confetti burst.
struct DailyGoalPanel: View {
    @ObservedObject var refresher: UsageRefresher
    @ObservedObject var goal: DailyGoalStore

    @State private var editing: Bool = false
    /// Local edit buffer so typing doesn't immediately re-evaluate the
    /// goal on every keystroke (which would spam the celebration
    /// trigger if the user types past the achievement threshold).
    @State private var draftCredits: String = ""

    private var todayCredits: Double {
        refresher.snapshot.byWindow[.today]?.aiCredits ?? 0
    }

    /// Progress from 0.0 to 1.0; clamped so the bar doesn't overflow
    /// once the goal is exceeded.
    private var progress: Double {
        guard goal.goalCredits > 0 else { return 0 }
        return min(1.0, todayCredits / goal.goalCredits)
    }

    private var percentText: String {
        guard goal.goalCredits > 0 else { return "—" }
        let p = Int((todayCredits / goal.goalCredits * 100).rounded())
        return "\(p)%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if editing || !goal.hasGoal {
                editor
            } else {
                progressView
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(goal.achievedToday
                      ? Color.green.opacity(0.12)
                      : Color.secondary.opacity(0.08))
        )
        .overlay(alignment: .topTrailing) {
            if goal.achievedToday {
                ConfettiBurst()
                    .allowsHitTesting(false)
                    .frame(width: 80, height: 50)
                    .padding(4)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: goal.achievedToday ? "checkmark.seal.fill" : "target")
                .foregroundStyle(goal.achievedToday ? AnyShapeStyle(celebrationGradient)
                                                    : AnyShapeStyle(Color.secondary))
            if goal.achievedToday {
                Text("Daily goal hit 🎉")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(celebrationGradient)
            } else {
                Text("Daily goal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Spacer()
            if goal.hasGoal && !editing {
                Button {
                    draftCredits = goal.goalCredits.trimmedString
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Edit daily AI-Credits target")
            }
        }
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(Formatters.compactCredits(todayCredits)) / \(Formatters.compactCredits(goal.goalCredits)) cr")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(goal.achievedToday ? AnyShapeStyle(celebrationGradient)
                                                        : AnyShapeStyle(Color.primary))
                Text("(\(percentText))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("≈ \(Formatters.compactUSD(goal.goalCredits * 0.01))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Goal in USD at the official $0.01 / credit rate.")
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(goal.achievedToday
                              ? AnyShapeStyle(celebrationGradient)
                              : AnyShapeStyle(Color.accentColor))
                        .frame(width: max(2, geo.size.width * progress))
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Editor

    private var editor: some View {
        HStack(spacing: 6) {
            TextField("e.g. 50", text: $draftCredits)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .help("Daily target in AI Credits. 1 credit = $0.01 USD.")
            Text("cr")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Save") {
                if let v = Double(draftCredits.trimmingCharacters(in: .whitespaces)), v >= 0 {
                    let old = goal.goalCredits
                    goal.goalCredits = v
                    if v != old {
                        // Allow a new celebration today if the user
                        // raised/lowered the goal mid-day. (Lowering
                        // below today's usage should still feel
                        // rewarding.)
                        goal.resetCelebrationForToday()
                    }
                    goal.evaluate(todayCredits: todayCredits)
                }
                editing = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            if goal.hasGoal {
                Button("Clear") {
                    goal.goalCredits = 0
                    goal.resetCelebrationForToday()
                    goal.evaluate(todayCredits: todayCredits)
                    editing = false
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if draftCredits.isEmpty {
                draftCredits = goal.hasGoal ? goal.goalCredits.trimmedString : ""
            }
        }
    }

    // MARK: - Style

    private var celebrationGradient: LinearGradient {
        LinearGradient(
            colors: [.orange, .pink, .purple, .blue],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Confetti burst

/// Tiny ornamental confetti effect rendered next to the "Goal hit" pill.
/// Twelve colored dots fly outward from the center over ~1.4 s, then
/// the view replays itself indefinitely (cheap; only runs while the
/// popover is open).
private struct ConfettiBurst: View {
    @State private var fired: Bool = false

    private let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]

    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                let angle = Double(i) * (2 * .pi / 14)
                let dist: CGFloat = fired ? 38 : 0
                Circle()
                    .fill(colors[i % colors.count])
                    .frame(width: 5, height: 5)
                    .offset(
                        x: cos(angle) * dist,
                        y: sin(angle) * dist
                    )
                    .opacity(fired ? 0 : 1)
                    .scaleEffect(fired ? 0.4 : 1.2)
            }
        }
        .onAppear { startBurst() }
    }

    private func startBurst() {
        // Loop the burst forever while the view is alive (popover open).
        // Each cycle: reset (instant) → animate outward (1.2 s) → pause.
        Task { @MainActor in
            while !Task.isCancelled {
                fired = false
                try? await Task.sleep(nanoseconds: 50_000_000)
                withAnimation(.easeOut(duration: 1.2)) {
                    fired = true
                }
                try? await Task.sleep(nanoseconds: 1_800_000_000)
            }
        }
    }
}

// MARK: - Double formatting helper

private extension Double {
    /// Pretty representation suitable for a TextField default. Drops the
    /// trailing ".0" for whole numbers so editing "50" stays "50".
    var trimmedString: String {
        if self == self.rounded() {
            return String(Int(self))
        }
        return String(format: "%g", self)
    }
}
