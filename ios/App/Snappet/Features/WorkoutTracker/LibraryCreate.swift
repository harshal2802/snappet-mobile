import SwiftUI
import SwiftData

/// **＋ in the Library** (Library redesign L4a, prompt 186): create an activity before you've ever logged it — a climb
/// to project, a timed protocol, a run route, a dance / other activity. It's saved as a `LibraryEntry` template, shows
/// in Yours as "Not done yet", and its Activity page's Log it now starts from it. (A new lift is a custom exercise —
/// the existing `ExerciseEditorView`.)
enum LibraryCreate {

    /// The session entity a climb from the Add-a-climb sheet becomes — the same fields the live player stamps.
    static func climb(_ p: AddClimbParams) -> SessionExercise {
        var e = SessionExercise(exerciseId: "adhoc-\(SetKind.climbAttempt.rawValue)", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [], displayName: p.name.isEmpty ? nil : p.name,
                                kindRaw: SetKind.climbAttempt.rawValue)
        e.climbTypeRaw = p.type.rawValue
        e.climbGradeLabel = p.grade
        e.climbGradeScaleRaw = p.scale.rawValue
        e.gym = p.gym; e.wall = p.wall; e.climbColorRaw = p.color?.rawValue; e.setter = p.setter
        return e
    }

    static func timed(_ p: AddTimedParams) -> SessionExercise {
        var e = SessionExercise(exerciseId: "adhoc-\(SetKind.duration.rawValue)", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [], displayName: p.name, kindRaw: SetKind.duration.rawValue)
        e.timedSpec = p.spec
        e.timedCategory = p.category.rawValue
        return e
    }

    /// A run route, or a dance / other activity — a named `.duration` entity of that discipline.
    static func named(_ name: String, discipline: WorkoutDiscipline) -> SessionExercise {
        var e = SessionExercise(exerciseId: discipline == .run ? "adhoc-run" : "adhoc-\(discipline.rawValue)",
                                targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: [],
                                displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                kindRaw: SetKind.duration.rawValue)
        e.disciplineRaw = discipline.rawValue
        return e
    }

    /// Save a created activity; returns the route to its page, or `nil` when it has no identity (an unnamed climb
    /// with no gym / wall / colour).
    @MainActor
    static func save(_ exercise: SessionExercise, targetDistanceMeters: Double? = nil, history: [WorkoutSession],
                     in context: ModelContext, now: Date = .now) -> ActivityRoute? {
        guard let key = ActivityIdentity(sessions: history).key(for: exercise, loggedAt: now) else { return nil }
        let entry = LibraryEntry.entry(for: key, in: context, create: true)!
        entry.template = LibraryTemplate(exercise: exercise, targetDistanceMeters: targetDistanceMeters)
        entry.createdAt = now
        entry.updatedAt = now
        try? context.save()
        return ActivityRoute(key: key, title: LibraryCatalog.fallbackTitle(exercise))
    }
}

/// "New run route" — a name and (optionally) a distance.
struct NewRunRouteSheet: View {
    let unit: DistanceUnit
    let onSave: (_ name: String, _ meters: Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var distance = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Riverside 5k)", text: $name).accessibilityIdentifier("library.new.name")
                TextField("Distance (\(unit.display))", text: $distance).keyboardType(.decimalPad)
                    .accessibilityIdentifier("library.new.distance")
            }
            .navigationTitle("New run route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, SetMeasure.parseDistance(distance, unit: unit)); dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("library.new.save")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// "New activity" — a named dance or other activity.
struct NewNamedActivitySheet: View {
    let onSave: (_ name: String, _ discipline: WorkoutDiscipline) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var discipline: WorkoutDiscipline = .dance

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Salsa class)", text: $name).accessibilityIdentifier("library.new.name")
                Picker("Type", selection: $discipline) {
                    Text(WorkoutDiscipline.dance.label).tag(WorkoutDiscipline.dance)
                    Text(WorkoutDiscipline.other.label).tag(WorkoutDiscipline.other)
                }
                .pickerStyle(.segmented)
            }
            .navigationTitle("New activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(name, discipline); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("library.new.save")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
