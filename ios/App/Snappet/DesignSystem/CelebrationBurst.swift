import SwiftUI

/// A one-shot confetti burst for the suite's milestone moments (issue #80): habit-streak
/// milestones, first send of a grade, a reel landing. Rendered with `TimelineView` +
/// `Canvas` (no particle framework), runs ~1.5 s and removes itself.
///
/// **Reduce Motion**: the `.celebrates(on:)` modifier never shows the burst under Reduce
/// Motion — the success haptic still fires, so the moment is acknowledged without motion
/// (`SnappetMotion`'s contract).
struct CelebrationBurstView: View {
    /// Vary per firing so consecutive bursts don't repeat the exact same pattern.
    let seed: Int

    private static let duration: TimeInterval = 1.5
    private static let colors: [Color] = [
        SnappetColor.brand, SnappetColor.pomodoro, SnappetColor.habits, .orange, .yellow, .purple,
    ]

    private struct Particle {
        let angle: Double       // launch direction (radians, 0 = right, -π/2 = up)
        let speed: Double       // points / s
        let spin: Double        // radians / s
        let size: CGFloat
        let color: Color
        let isRect: Bool
    }

    private var particles: [Particle] {
        // A tiny deterministic LCG keyed on `seed` — repeatable per burst, varied across bursts.
        var state = UInt64(truncatingIfNeeded: seed &* 6_364_136_223_846_793_005 &+ 1)
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64.max >> 11)
        }
        return (0..<28).map { i in
            Particle(
                angle: -Double.pi / 2 + (next() - 0.5) * 1.9,   // a fan, mostly upward
                speed: 220 + next() * 260,
                spin: (next() - 0.5) * 12,
                size: 5 + next() * 5,
                color: Self.colors[i % Self.colors.count],
                isRect: next() > 0.4)
        }
    }

    var body: some View {
        let particles = self.particles
        TimelineView(.animation) { timeline in
            Canvas { context, canvasSize in
                // Progress anchored on the view's appearance — it exists only for one burst.
                guard let startDate else { return }
                let t = min(max(timeline.date.timeIntervalSince(startDate) / Self.duration, 0), 1)
                guard t < 1 else { return }
                let origin = CGPoint(x: canvasSize.width / 2, y: canvasSize.height * 0.45)
                let gravity = 520.0
                for particle in particles {
                    let time = t * Self.duration
                    let x = origin.x + CGFloat(cos(particle.angle) * particle.speed * time)
                    let y = origin.y + CGFloat(sin(particle.angle) * particle.speed * time
                                               + 0.5 * gravity * time * time)
                    let rotation = Angle(radians: particle.spin * time)
                    let opacity = 1 - (t * t)   // hold, then fade out
                    var piece = context
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: rotation)
                    piece.opacity = opacity
                    let rect = CGRect(x: -particle.size / 2, y: -particle.size / 2,
                                      width: particle.size,
                                      height: particle.isRect ? particle.size * 0.55 : particle.size)
                    if particle.isRect {
                        piece.fill(Path(rect), with: .color(particle.color))
                    } else {
                        piece.fill(Path(ellipseIn: rect), with: .color(particle.color))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { startDate = Date() }
    }

    @State private var startDate: Date?
}

private struct CelebrationModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fire by incrementing past 0; each new value plays one burst.
    let trigger: Int
    @State private var activeBurst = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if activeBurst > 0 {
                    CelebrationBurstView(seed: activeBurst)
                }
            }
            .onChange(of: trigger) { _, newValue in
                guard newValue > 0 else { return }
                Haptics.success()
                guard !reduceMotion else { return }   // acknowledged by haptic alone
                activeBurst = newValue
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    if activeBurst == newValue { activeBurst = 0 }
                }
            }
    }
}

extension View {
    /// Plays the suite's celebration burst (plus a success haptic) each time `trigger`
    /// increments past zero. Under Reduce Motion only the haptic fires.
    func celebrates(on trigger: Int) -> some View {
        modifier(CelebrationModifier(trigger: trigger))
    }
}
