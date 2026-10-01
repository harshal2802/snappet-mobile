import SwiftUI
import RealityKit

/// The code-built 3D "creature" buddy (prototype, prompt 147): a soft glowing blob that grows by
/// stage and shows Form as mood. Drag to turn it, tap to make it cheer. Everything it draws comes
/// from the pure `BuddyLook`; this view only turns numbers into RealityKit entities.
struct BuddyCreatureView: View {
    let look: BuddyLook
    /// Bump to play the cheer (tap on the buddy does it too).
    var cheerTrigger: Int = 0
    /// Idle animation (bob, blink, sparks). Off for stills in scrolling lists — a cheer still plays.
    var animated: Bool = true
    /// Drag to turn. Off inside scroll views, where the drag belongs to scrolling.
    var interactive: Bool = true

    @State private var rig = BuddyRig()
    @State private var yaw: Float = 0
    @State private var dragStartYaw: Float = 0
    @State private var cheerStart: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: (reduceMotion || !animated) && cheerStart == nil)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let cheer = cheerStart.map { context.date.timeIntervalSince($0) }.flatMap { $0 < BuddyRig.cheerDuration ? $0 : nil }
            RealityView { content in
                content.camera = .virtual
                content.add(rig.scene)
            } update: { _ in
                rig.apply(look, time: reduceMotion || !animated ? 0.6 : t, cheer: cheer, yaw: yaw)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in yaw = dragStartYaw + Float(v.translation.width) * 0.012 }
                .onEnded { _ in dragStartYaw = yaw },
            isEnabled: interactive
        )
        .onTapGesture { cheer() }
        .onChange(of: cheerTrigger) { _, _ in cheer() }
        .accessibilityElement()
        .accessibilityLabel("Your training buddy, \(look.stage.title), \(look.mood)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Tap to cheer")
        .accessibilityIdentifier("buddy.creature")
    }

    private func cheer() {
        let start = Date.now
        cheerStart = start
        Haptics.tap()
        // Let a still buddy stop animating again once the cheer is over.
        Task {
            try? await Task.sleep(for: .seconds(BuddyRig.cheerDuration + 0.1))
            if cheerStart == start { cheerStart = nil }
        }
    }
}

/// Owns the entity graph so per-frame updates only move/recolour things; the stage-specific parts are
/// rebuilt only when the stage changes.
@MainActor
final class BuddyRig {
    static let cheerDuration: TimeInterval = 1.2

    let scene = Entity()
    private let turntable = Entity()
    private let pivot = Entity()
    private let body = ModelEntity(mesh: .generateSphere(radius: 0.25))
    private var parts = Entity()
    private var eyes: [Entity] = []
    private var arms: [Entity] = []
    private var tips: [ModelEntity] = []
    private var sparks: [ModelEntity] = []
    private var zzz: ModelEntity?
    private var builtStage: BuddyStage?
    private var builtPaused: Bool?

    init() {
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 38
        camera.look(at: [0, 0.06, 0], from: [0, 0.22, 1.7], relativeTo: nil)
        scene.addChild(camera)

        let key = DirectionalLight()
        key.light.intensity = 2600
        key.look(at: .zero, from: [0.6, 1.2, 1.0], relativeTo: nil)
        scene.addChild(key)
        let fill = PointLight()
        fill.light.intensity = 9000
        fill.light.attenuationRadius = 6
        fill.position = [-0.9, 0.2, 0.9]
        scene.addChild(fill)
        let rim = PointLight()
        rim.light.intensity = 7000
        rim.light.attenuationRadius = 6
        rim.position = [0.2, 0.6, -0.9]
        scene.addChild(rim)

        scene.addChild(turntable)
        turntable.addChild(pivot)
        pivot.addChild(body)
        pivot.addChild(parts)
    }

    // MARK: Per frame

    func apply(_ look: BuddyLook, time t: Double, cheer: Double?, yaw: Float) {
        if builtStage != look.stage || builtPaused != look.paused { rebuild(look) }

        let s = Float(look.bodyScale)
        let phase = 2 * Double.pi * look.bobHz * t
        var y = Float(sin(phase) * look.bobHeight)
        var spin: Float = 0
        var armLift: Float = 0
        var eyeOpen = Float(look.eyeOpen)

        if let c = cheer {
            let p = c / Self.cheerDuration
            y += Float(sin(Double.pi * p) * 0.09)
            spin = Float(2 * Double.pi * (p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2))
            armLift = Float(sin(Double.pi * p))
            eyeOpen = 0.35   // happy squint
        } else if !look.paused, t.truncatingRemainder(dividingBy: 3.7) < 0.12 {
            eyeOpen = 0.05   // blink
        }

        turntable.orientation = simd_quatf(angle: yaw + spin, axis: [0, 1, 0])
        turntable.scale = [s, s, s]
        pivot.position = [0, y - 0.03, 0]
        pivot.orientation = simd_quatf(angle: Float(look.droop), axis: [1, 0, 0])

        // Jelly squash with the bob — livelier at high Form.
        let squash: Float = 1 + Float(sin(phase) * 0.035 * (look.paused ? 0.4 : look.form))
        let girth: Float = 1 / squash.squareRoot()
        body.scale = look.stage == .egg ? SIMD3<Float>(0.95, 1.22, 0.95) : SIMD3<Float>(girth, squash, girth)

        let color = UIColor(hue: look.hue, saturation: look.saturation, brightness: look.brightness, alpha: 1)
        body.model?.materials = [Self.skin(color, glow: look.glow)]

        for eye in eyes { eye.scale = [1, max(0.05, eyeOpen), 1] }
        for (i, arm) in arms.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            arm.position = [side * 0.255, -0.05 + armLift * 0.17, 0.03]
            arm.orientation = simd_quatf(angle: side * (0.25 + armLift * 1.2), axis: [0, 0, 1])
        }
        let tipGlow = look.paused ? 0.05 : 0.4 + 0.6 * look.form * (0.75 + 0.25 * sin(t * 3))
        for tip in tips { tip.model?.materials = [Self.glowing(UIColor(hue: look.hue, saturation: 0.5, brightness: 1, alpha: 1), Float(tipGlow))] }

        for (k, spark) in sparks.enumerated() {
            let a = t * 1.4 + Double(k) * 2 * .pi / Double(max(1, sparks.count))
            spark.position = [Float(cos(a)) * 0.4, 0.12 + Float(sin(t * 2 + Double(k))) * 0.05, Float(sin(a)) * 0.4]
        }
        if let zzz {
            let f = t.truncatingRemainder(dividingBy: 3) / 3
            zzz.position = [0.17, 0.2 + Float(f) * 0.14, 0.2]
            zzz.scale = .init(repeating: Float(0.6 + f * 0.6))
        }
    }

    // MARK: Build (on stage / pause change)

    private func rebuild(_ look: BuddyLook) {
        parts.removeFromParent()
        parts = Entity()
        pivot.addChild(parts)
        eyes = []; arms = []; tips = []
        sparks.forEach { $0.removeFromParent() }
        sparks = []
        zzz?.removeFromParent(); zzz = nil

        let eyeY: Float = look.stage == .egg ? 0.0 : 0.05
        for side: Float in [-1, 1] {
            let eye = Entity()
            eye.position = [side * 0.085, eyeY, 0.212]
            let white = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [UnlitMaterial(color: .white)])
            let pupil = ModelEntity(mesh: .generateSphere(radius: 0.027), materials: [UnlitMaterial(color: UIColor(white: 0.08, alpha: 1))])
            pupil.position = [0, 0, 0.034]
            let shine = ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [UnlitMaterial(color: .white)])
            shine.position = [0.01, 0.012, 0.058]
            eye.addChild(white); eye.addChild(pupil); eye.addChild(shine)
            parts.addChild(eye)
            eyes.append(eye)
        }

        if look.stage == .egg {
            // Speckles on the shell.
            let dots: [SIMD3<Float>] = [[0.12, 0.17, 0.17], [-0.15, 0.12, 0.17], [0.19, -0.08, 0.14], [-0.1, -0.2, 0.15], [0.02, 0.27, 0.08]]
            for p in dots {
                let dot = ModelEntity(mesh: .generateSphere(radius: 0.018), materials: [Self.skin(UIColor(hue: 0.08, saturation: 0.35, brightness: 0.75, alpha: 1), glow: 0)])
                dot.position = p
                parts.addChild(dot)
            }
        } else {
            for side: Float in [-1, 1] {
                let foot = ModelEntity(mesh: .generateSphere(radius: 0.06), materials: [Self.skin(UIColor(white: 0.92, alpha: 1), glow: 0)])
                foot.position = [side * 0.1, -0.235, 0.05]
                foot.scale = [1.2, 0.55, 1.4]
                parts.addChild(foot)
            }
            // Blush.
            for side: Float in [-1, 1] {
                let blush = ModelEntity(mesh: .generateSphere(radius: 0.024), materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.55, blue: 0.6, alpha: 0.9))])
                blush.position = [side * 0.15, -0.02, 0.19]
                blush.scale = [1.3, 0.6, 0.4]
                parts.addChild(blush)
            }
        }

        if look.hasShellCup {
            let cup = ModelEntity(mesh: .generateCylinder(height: 0.11, radius: 0.235),
                                  materials: [Self.skin(UIColor(hue: 0.11, saturation: 0.2, brightness: 0.97, alpha: 1), glow: 0)])
            cup.position = [0, -0.2, 0]
            parts.addChild(cup)
        }

        if look.antennae > 0 {
            let xs: [Float] = look.antennae == 1 ? [0] : [-0.08, 0.08]
            for x in xs {
                let stalk = Entity()
                stalk.position = [x, 0.22, 0]
                stalk.orientation = simd_quatf(angle: -x * 3.5, axis: [0, 0, 1])
                let stem = ModelEntity(mesh: .generateCylinder(height: 0.14, radius: 0.009),
                                       materials: [Self.skin(UIColor(white: 0.25, alpha: 1), glow: 0)])
                stem.position = [0, 0.07, 0]
                let tip = ModelEntity(mesh: .generateSphere(radius: 0.028), materials: [Self.glowing(.white, 0.5)])
                tip.position = [0, 0.15, 0]
                stalk.addChild(stem); stalk.addChild(tip)
                parts.addChild(stalk)
                tips.append(tip)
            }
        }

        if look.hasArms {
            for _ in 0..<2 {
                let arm = ModelEntity(mesh: .generateSphere(radius: 0.055), materials: [Self.skin(UIColor(white: 0.95, alpha: 1), glow: 0)])
                arm.scale = [0.8, 1.5, 0.8]
                parts.addChild(arm)
                arms.append(arm)
            }
        }

        if look.hasCrown {
            // A floating halo of small gold beads above the head, tipped toward the viewer.
            let gold = Self.glowing(UIColor(red: 1, green: 0.82, blue: 0.35, alpha: 1), 0.8)
            let halo = Entity()
            halo.position = [0, 0.37, 0]
            halo.orientation = simd_quatf(angle: 0.35, axis: [1, 0, 0])
            for k in 0..<14 {
                let a = Float(k) / 14 * 2 * .pi
                let bead = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [gold])
                bead.position = [cos(a) * 0.1, 0, sin(a) * 0.1]
                halo.addChild(bead)
            }
            parts.addChild(halo)
        }

        for _ in 0..<look.sparks {
            let spark = ModelEntity(mesh: .generateSphere(radius: 0.018),
                                    materials: [Self.glowing(UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), 1)])
            turntable.addChild(spark)
            sparks.append(spark)
        }

        if look.paused {
            let z = ModelEntity(mesh: .generateText("Z z", extrusionDepth: 0.01, font: .systemFont(ofSize: 0.11, weight: .heavy)),
                                materials: [UnlitMaterial(color: UIColor(white: 0.92, alpha: 1))])
            pivot.addChild(z)
            zzz = z
        }

        builtStage = look.stage
        builtPaused = look.paused
    }

    // MARK: Materials

    private static func skin(_ color: UIColor, glow: Double) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: 0.38)
        m.metallic = .init(floatLiteral: 0)
        m.clearcoat = .init(floatLiteral: 0.6)
        m.clearcoatRoughness = .init(floatLiteral: 0.2)
        m.emissiveColor = .init(color: color)
        m.emissiveIntensity = Float(0.12 + glow * 1.6)
        return m
    }

    private static func glowing(_ color: UIColor, _ intensity: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.emissiveColor = .init(color: color)
        m.emissiveIntensity = 0.5 + intensity * 2.5
        return m
    }
}
