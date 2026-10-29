import SwiftUI

/// The "Adjust" sheet for "Plan a session" (bug #4 — the plan was a fixed handout). Leads with
/// climber-language **selection strategies** that map under the hood to `KilterRecommender.Options`
/// + a grade offset (picking one seeds the fine-tune knobs), then exposes the three knobs directly.
/// Bindings write straight to `KilterPlanView`'s `@AppStorage`, so the preview regenerates live and
/// the choice persists. No raw tuning console — intent first.
struct KilterPlanConfigSheet: View {
    @Binding var strategyRaw: String
    @Binding var targetCount: Int
    @Binding var gradeOffset: Int
    @Binding var climbs: KilterPlanClimbs
    @Environment(\.dismiss) private var dismiss

    private var strategy: KilterRecommender.Strategy { .init(rawValue: strategyRaw) ?? .balanced }

    var body: some View {
        NavigationStack {
            List {
                Section("Strategy") {
                    ForEach(KilterRecommender.Strategy.allCases, id: \.self) { s in
                        Button { apply(s) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: s.systemImage)
                                    .frame(width: 26)
                                    .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.label).font(.subheadline.weight(.medium))
                                    Text(s.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if s == strategy {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kilter.plan.strategy.\(s.rawValue)")
                    }
                }

                Section("Fine-tune") {
                    Stepper("Session length: \(targetCount) climbs", value: $targetCount, in: 3...30)
                        .accessibilityIdentifier("kilter.plan.lengthStepper")
                    Stepper("Target grade: \(offsetLabel)", value: $gradeOffset, in: -3...3)
                }

                // Prompt 208: two plain switches — both off = only climbs you've never tried.
                Section {
                    Toggle("Include sent climbs", isOn: $climbs.includeSent)
                        .accessibilityIdentifier("kilter.plan.includeSent")
                    Toggle("Include projects", isOn: $climbs.includeProjects)
                        .accessibilityIdentifier("kilter.plan.includeProjects")
                } header: {
                    Text("Climbs to pick")
                } footer: {
                    Text(climbs.includeSent || climbs.includeProjects
                         ? "Included projects near your grade go into the project slots first."
                         : "Only climbs you’ve never tried.")
                }

                Section {
                    Label(rationale, systemImage: "wand.and.stars")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Adjust plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { apply(.balanced) }
                        .accessibilityIdentifier("kilter.plan.config.reset")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("kilter.plan.config.done")
                }
            }
        }
    }

    private var offsetLabel: String {
        gradeOffset == 0 ? "at grade" : (gradeOffset > 0 ? "+\(gradeOffset)" : "\(gradeOffset)")
    }

    private var rationale: String {
        let where_ = gradeOffset == 0 ? "around your working grade" : "at \(offsetLabel) your grade"
        let chase = switch (climbs.includeSent, climbs.includeProjects) {
        case (false, false): "all climbs you’ve never tried"
        case (true, false): "revisiting sent climbs too"
        case (false, true): "starting from your open projects"
        case (true, true): "sent climbs and projects welcome"
        }
        return "\(targetCount) climbs \(where_), \(chase)."
    }

    /// Selecting a strategy seeds the fine-tune knobs from its config (the climber can then tweak
    /// them; the strategy's goal *mix* stays tied to the selection).
    private func apply(_ s: KilterRecommender.Strategy) {
        let c = KilterRecommender.config(for: s)
        strategyRaw = s.rawValue
        targetCount = c.targetCount
        gradeOffset = c.gradeOffset
        climbs = c.climbs
    }
}
