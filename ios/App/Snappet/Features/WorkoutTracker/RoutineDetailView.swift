import SwiftUI

/// A routine's detail (workout-redesign E4, Flow 5): its prescription as a **discipline-rhythm** of
/// type-tagged blocks — each block its `WorkoutDiscipline.accent`-tinted glyph + an adaptive prescription
/// line whose columns derive from the measure (strength `sets × reps`, timed `sets × hold`, climb
/// `type · grade · attempts`, run `distance`) — with a prominent Start button and an Edit action. A routine
/// that mixes a strength block + a timed circuit + a climb now reads as a colored modality rhythm, not a
/// flat reps×weight list. Pushed onto the App Library's stack.
struct RoutineDetailView: View {
    let routine: Routine
    let resolver: ExerciseResolver
    let unit: WeightUnit
    let start: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SuiteRouter.self) private var router
    @State private var editing = false
    @State private var sharing = false

    /// The disciplines present, in canonical order — drives the "mixed rhythm" summary chips.
    private var disciplines: [WorkoutDiscipline] {
        let present = Set(routine.exercises.map(\.discipline))
        return WorkoutDiscipline.allCases.filter { present.contains($0) }
    }

    var body: some View {
        List {
            if let detail = routine.detail, !detail.isEmpty {
                Section { Text(detail).font(.callout) }
            }

            Section {
                ForEach(routine.exercises) { re in
                    RoutineBlockRow(item: re, resolver: resolver, unit: unit)
                }
            } header: {
                HStack(spacing: 6) {
                    Text("\(routine.exercises.count) blocks · \(routine.totalSets) sets")
                    Spacer()
                    // The discipline rhythm: one accent dot per type the routine mixes (the Pulse Pro cue).
                    ForEach(disciplines) { d in
                        Image(systemName: d.symbol).font(.caption2).foregroundStyle(d.accent)
                    }
                }
            }

            if routine.sport != nil || routine.level != nil || !routine.tags.isEmpty || routine.sourceLabel != nil {
                Section("About") {
                    if let sport = routine.sport {
                        LabeledContent("Sport") {
                            Label(sport.display, systemImage: sport.symbol)
                        }
                    }
                    if let level = routine.level { LabeledContent("Level", value: level.display) }
                    if !routine.tags.isEmpty {
                        LabeledContent("Tags", value: routine.tags.joined(separator: ", "))
                    }
                    if let label = routine.sourceLabel {
                        if let urlString = routine.sourceURL, let url = URL(string: urlString) {
                            Link(destination: url) { LabeledContent("Source", value: label) }
                        } else {
                            LabeledContent("Source", value: label)
                        }
                    }
                }
            }
        }
        .navigationTitle(routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            Button { dismiss(); start() } label: {
                Label("Start Workout", systemImage: "play.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.workout)
            .padding()
            .background(.bar)
            .disabled(routine.exercises.isEmpty)
        }
        .toolbar {
            // Share-via-QR (workout-redesign E6) — mirrors KilterClimbDetailView's qrcode toolbar button.
            ToolbarItem(placement: .topBarTrailing) {
                Button { sharing = true } label: { Image(systemName: "qrcode") }
                    .accessibilityLabel("Share routine")
                    .accessibilityIdentifier("routine.share")
            }
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
        }
        .sheet(isPresented: $editing) {
            RoutineEditorView(routine: routine, resolver: resolver, defaultUnit: unit)
        }
        .sheet(isPresented: $sharing) {
            // Scanning a routine here routes it through the same router one-shot the snappet:// link path
            // uses, so WorkoutHomeView shows the one import-confirm preview (one import brain). Pop this
            // detail off first so the preview surfaces on the tracker root (where the import sheet lives).
            RoutineShareView(routine: routine, onScan: { scanned in
                router.popToRoot()
                router.pendingRoutineImport = scanned
            })
        }
    }
}

/// One **type-tagged block** row inside a routine detail / editor preview (workout-redesign E4). A leading
/// `WorkoutDiscipline.accent` edge-bar + glyph make the block's discipline legible at a glance; the
/// prescription line's columns derive from the measure. Replaces the strength-only `RoutineExerciseRow`.
struct RoutineBlockRow: View {
    let item: RoutineExercise
    let resolver: ExerciseResolver
    let unit: WeightUnit

    private var discipline: WorkoutDiscipline { item.discipline }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(discipline.accent).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: discipline.symbol).font(.caption).foregroundStyle(discipline.accent)
                    Text(resolver.name(for: item.exerciseId, override: item.displayName))
                        .font(.headline).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(prescription)
                    if item.restSeconds > 0 {
                        Label(restText(item.restSeconds), systemImage: "timer").labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes).font(.caption2).foregroundStyle(.tertiary).italic()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// The adaptive prescription string — the columns derive from the discipline's measure.
    private var prescription: String {
        switch discipline {
        case .strength:
            var s = "\(item.sets) × \(item.reps.isEmpty ? "—" : item.reps)"
            if let weight = item.weight {
                s += " · \(WorkoutMath.formatWeight(kg: WorkoutMath.toKg(weight, item.weightUnit), unit: unit)) \(unit.display)"
            }
            return s
        case .climb:
            var parts: [String] = [item.climbType.label]
            if let grade = item.climbGradeLabel, !grade.isEmpty { parts.append(grade) }
            parts.append("\(item.sets) attempt\(item.sets == 1 ? "" : "s")")
            return parts.joined(separator: " · ")
        case .timed:
            if let spec = item.timedSpec, spec.mode.isStructured { return spec.summary }
            if let hold = item.targetDurationSec, hold > 0 {
                return "\(item.sets) × \(Int(hold))s"
            }
            return "\(item.sets) × time"
        case .run:
            if let m = item.targetDistanceMeters, m > 0 {
                let du: DistanceUnit = unit == .lb ? .mi : .km
                return SetMeasure.formatDistance(m, unit: du)
            }
            return "Open run"
        case .dance, .other:
            return "\(item.sets) × time"
        }
    }
}

/// "90s" or "1m 30s" for a rest duration.
func restText(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let m = seconds / 60, s = seconds % 60
    return s == 0 ? "\(m)m" : "\(m)m \(s)s"
}
