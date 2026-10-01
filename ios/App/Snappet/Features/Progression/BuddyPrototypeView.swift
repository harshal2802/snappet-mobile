import SwiftUI

/// Workout → Settings → Labs → Training buddy (prototype, prompt 147). A playground to feel the 3D
/// buddy on a real phone before the progression system is designed around it: pick a style, scrub
/// stage and Form, toggle pause, tap to cheer. Nothing here is saved or tied to workouts yet.
struct BuddyPrototypeView: View {
    enum Style: String, CaseIterable, Identifiable {
        case creature = "Creature", companion = "Companion", athlete = "Athlete"
        var id: String { rawValue }
        var available: Bool { self == .creature }
        var icon: String {
            switch self {
            case .creature: "sparkles"
            case .companion: "pawprint.fill"
            case .athlete: "figure.strengthtraining.traditional"
            }
        }
    }

    @State private var style: Style = .creature
    @State private var stage: BuddyStage = .sprout
    @State private var form = 0.7
    @State private var paused = false
    @State private var cheer = 0
    @State private var preview: Progression.Moment?

    private var look: BuddyLook { BuddyLook(stage: stage, form: form, paused: paused) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                stagePanel
                stylePicker
                controls
                Text("Prototype — not tied to your workouts yet. Drag to turn your buddy, tap to make it cheer. Form changes its mood, never its size: a missed week makes it tired, not smaller.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(SnappetColor.paper.ignoresSafeArea())
        .fullScreenCover(item: $preview) { m in
            ProgressionMomentView(moment: m, form: form, sessions: 40, totalXP: 5_140) { preview = nil }
        }
        .navigationTitle("Training buddy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var stagePanel: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(hue: look.hue, saturation: 0.25, brightness: paused ? 0.35 : 0.3),
                                    Color(white: 0.08)],
                           startPoint: .top, endPoint: .bottom)
            Ellipse().fill(.black.opacity(0.35)).frame(width: 150, height: 22).blur(radius: 8).offset(y: -84)
            BuddyCreatureView(look: look, cheerTrigger: cheer)
                .padding(.bottom, 56)
            VStack(spacing: 2) {
                Text(stage.title).font(.title3.weight(.heavy)).foregroundStyle(.white)
                Text(look.mood).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                    .accessibilityIdentifier("buddy.mood")
            }
            .padding(.bottom, 14)
            .allowsHitTesting(false)
        }
        .frame(height: 380)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STYLE").font(.caption.weight(.heavy)).tracking(0.8).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(Style.allCases) { s in
                    Button {
                        if s.available { style = s }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: s.available ? s.icon : "lock.fill").font(.title2)
                            Text(s.rawValue).font(.caption.weight(.bold))
                            if !s.available { Text("Coming soon").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 78)
                        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(style == s ? SnappetColor.workout : .clear, lineWidth: 2))
                        .opacity(s.available ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("buddy.style.\(s.rawValue)")
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GROWTH STAGE").font(.caption.weight(.heavy)).tracking(0.8).foregroundStyle(.secondary)
            Picker("Stage", selection: $stage) {
                ForEach(BuddyStage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("buddy.stage")

            HStack {
                Text("Form").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int((form * 100).rounded()))%").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $form, in: 0...1)
                .tint(SnappetColor.workout)
                .disabled(paused)
                .accessibilityIdentifier("buddy.form")

            Toggle("Pause mode (rest week)", isOn: $paused)
                .accessibilityIdentifier("buddy.pause")

            Button {
                cheer += 1
            } label: {
                Label("Cheer (like after a PR)", systemImage: "party.popper.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.workout)
            .accessibilityIdentifier("buddy.cheer")

            // P3: see the full-screen moments without having to level up.
            HStack {
                Button("Preview level-up") { preview = .levelUp(level: 13) }
                    .accessibilityIdentifier("buddy.previewLevelUp")
                Spacer()
                Button("Preview growing up") { preview = .grewUp(from: .sprout, to: .adult, level: 10) }
                    .accessibilityIdentifier("buddy.previewGrewUp")
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }
}
