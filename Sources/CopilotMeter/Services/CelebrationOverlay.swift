import AppKit
import QuartzCore
import SwiftUI

/// Full-screen, transparent, click-through overlay window that plays a
/// "daily goal complete" celebration. Three layers stacked:
///
/// 1. **Confetti rain** — `CAEmitterLayer` emitting along the top edge,
///    rectangular bits with rotation + gravity, ~3 s of birth then natural fade.
/// 2. **Three timed firework bursts** — radial `CAEmitterLayer`s with
///    additive render mode for the glow, at staggered screen positions
///    and times so it doesn't feel like a single event.
/// 3. **Center hero label** — large "🎉 Daily goal complete!" with the
///    same gradient as the popover, fades in / scales up / fades out.
///
/// The overlay sits at `.screenSaver` level so it floats above the
/// active app, `.ignoresMouseEvents = true` so clicks pass through to
/// whatever the user was doing, and `.canJoinAllSpaces` so it shows
/// regardless of which desktop Space is foreground. Auto-tears down
/// after `totalDuration` so we never leak a window.
///
/// Why CAEmitterLayer (and not SwiftUI Canvas)? CAEmitterLayer is the
/// system-level particle engine that ships with macOS — same one
/// AppKit / SceneKit hand off to. It's GPU-driven, runs fine even
/// when the foreground app is mid-render, and gives the unmistakable
/// "this is a Mac" look at zero implementation cost.
@MainActor
final class CelebrationOverlay {
    static let shared = CelebrationOverlay()

    private var window: NSWindow?

    /// Total wall-clock time the overlay is on screen before it
    /// dismisses itself. Tuned to feel celebratory but not intrusive.
    private let totalDuration: TimeInterval = 5.0

    private init() {}

    /// Spawn the celebration overlay on the screen that currently
    /// contains the mouse pointer (so a multi-display user sees it on
    /// the screen they're actively looking at). No-op if an overlay
    /// is already on screen.
    func play() {
        guard window == nil else { return }

        let screen = screenContainingMouse() ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.frame

        let w = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = false

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        installEffects(in: container, size: frame.size)

        w.contentView = container
        w.orderFrontRegardless()
        self.window = w

        // Soft, polite system chime. Doesn't fire in Do-Not-Disturb (we
        // route through NSSound which the user can mute globally).
        NSSound(named: NSSound.Name("Glass"))?.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration) { [weak self] in
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard let w = window else { return }
        // Tiny fade-out so it doesn't blink off.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                w.orderOut(nil)
                self?.window = nil
            }
        })
    }

    // MARK: - Effects

    private func installEffects(in container: NSView, size: CGSize) {
        guard let host = container.layer else { return }

        // 1) Confetti rain along the top edge — runs the whole duration
        //    minus the dismiss fade so it has time to fall off screen.
        let confetti = CAEmitterLayer()
        confetti.emitterPosition = CGPoint(x: size.width / 2, y: size.height)
        confetti.emitterShape = .line
        confetti.emitterSize = CGSize(width: size.width, height: 1)
        confetti.renderMode = .unordered
        confetti.emitterCells = makeConfettiCells()
        host.addSublayer(confetti)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            confetti.birthRate = 0
        }

        // 2) Three staggered firework bursts at varying X positions.
        let burstSpots: [(CGPoint, TimeInterval)] = [
            (CGPoint(x: size.width * 0.25, y: size.height * 0.55), 0.05),
            (CGPoint(x: size.width * 0.75, y: size.height * 0.45), 0.55),
            (CGPoint(x: size.width * 0.50, y: size.height * 0.65), 1.05),
        ]
        for (pos, delay) in burstSpots {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.firework(at: pos, in: host)
            }
        }

        // 3) Hero label — centered, big, gradient, with fade + scale.
        addHeroLabel(in: container, size: size)
    }

    private func firework(at position: CGPoint, in host: CALayer) {
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = position
        emitter.emitterShape = .point
        emitter.emitterSize = .zero
        emitter.renderMode = .additive
        emitter.beginTime = CACurrentMediaTime()
        emitter.emitterCells = makeFireworkCells()
        host.addSublayer(emitter)

        // One-shot: full birthRate for ~0.08 s, then cut to 0 so we get
        // a single explosion (not a continuous fountain).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            emitter.birthRate = 0
        }
        // Remove the layer once its particles have all expired (~ lifetime + buffer).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            emitter.removeFromSuperlayer()
        }
    }

    private func addHeroLabel(in container: NSView, size: CGSize) {
        // Use a SwiftUI hosting view so we get gradient text / SF Symbol
        // composition for free, but keep the overlay's WindowLevel /
        // ignoresMouseEvents from the NSWindow side.
        let hero = NSHostingView(rootView: CelebrationHeroLabel())
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.wantsLayer = true
        container.addSubview(hero)
        NSLayoutConstraint.activate([
            hero.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hero.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        // Start invisible, animate in, hold, animate out.
        hero.alphaValue = 0
        hero.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.6, y: 0.6))
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hero.animator().alphaValue = 1.0
            hero.layer?.setAffineTransform(.identity)
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration - 0.8) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.6
                hero.animator().alphaValue = 0
            })
        }
    }

    // MARK: - Particle cells

    private static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow,
        .systemGreen, .systemBlue, .systemPurple, .systemPink, .white,
    ]

    private func makeConfettiCells() -> [CAEmitterCell] {
        let rectImage = Self.confettiRectImage()
        return Self.palette.map { color in
            let cell = CAEmitterCell()
            cell.birthRate = 12
            cell.lifetime = 6.0
            cell.lifetimeRange = 1.5
            cell.velocity = 220
            cell.velocityRange = 80
            // Layers on macOS are non-flipped: +Y is up. To shoot DOWN
            // we want emissionLongitude = -π/2 (i.e. 3π/2). Without the
            // range it looks too uniform.
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 6
            cell.spin = 2.5
            cell.spinRange = 6
            cell.scale = 0.7
            cell.scaleRange = 0.3
            cell.alphaSpeed = -0.18
            cell.color = color.cgColor
            cell.contents = rectImage
            cell.yAcceleration = -120 // -Y = downward
            cell.xAcceleration = 5
            return cell
        }
    }

    private func makeFireworkCells() -> [CAEmitterCell] {
        let sparkImage = Self.sparkImage()
        return Self.palette.map { color in
            let cell = CAEmitterCell()
            cell.birthRate = 800
            cell.lifetime = 1.6
            cell.lifetimeRange = 0.4
            cell.velocity = 260
            cell.velocityRange = 110
            cell.emissionRange = 2 * .pi // radial, full circle
            cell.scale = 0.18
            cell.scaleRange = 0.06
            cell.scaleSpeed = -0.05
            cell.alphaSpeed = -0.6
            cell.color = color.cgColor
            cell.contents = sparkImage
            // Slight gravity so streaks droop downward like a real
            // firework instead of an infinite radial blast.
            cell.yAcceleration = -90
            return cell
        }
    }

    // MARK: - Particle images (drawn once, cached)

    private static let confettiRectImageRef: CGImage = {
        CelebrationOverlay.makeBitmap(size: CGSize(width: 14, height: 6)) { ctx, size in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }()
    private static func confettiRectImage() -> CGImage { confettiRectImageRef }

    private static let sparkImageRef: CGImage = {
        CelebrationOverlay.makeBitmap(size: CGSize(width: 16, height: 16)) { ctx, size in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }()
    private static func sparkImage() -> CGImage { sparkImageRef }

    private static func makeBitmap(size: CGSize, draw: (CGContext, CGSize) -> Void) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bits = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: bits
        ) else {
            // Fallback: return a 1x1 transparent image.
            let fb = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: bits)!
            return fb.makeImage()!
        }
        draw(ctx, size)
        return ctx.makeImage()!
    }

    // MARK: - Display routing

    /// Pick the screen currently under the mouse pointer so the
    /// celebration shows up where the user is looking. Falls back to
    /// the main screen if none matches (rare edge case during
    /// display config changes).
    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }
}

/// Big gradient hero label rendered centered in the overlay. Pulled out
/// as its own SwiftUI view so we get text+symbol+gradient composition
/// without writing CATextLayer plumbing.
private struct CelebrationHeroLabel: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(gradient)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            Text("Daily goal complete!")
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .foregroundStyle(gradient)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
            Text("🎉  Nice work — see you tomorrow.")
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.55), radius: 8, y: 4)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 10)
        )
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [.orange, .pink, .purple, .blue],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
