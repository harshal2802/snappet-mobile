import SwiftUI
import SwiftData

/// What a picker needs to offer **Yours** (Library redesign L4b, prompt 187) — your activities as the Library's Yours
/// tab builds them, plus what turns a ticked row back into something to log or a routine block. Built once per
/// presentation (history doesn't change while a picker is open).
struct LibraryPickSource {
    var rows: [LibraryCatalog.Row] = []
    var hidden: Set<ActivityKey> = []
    private var history: [WorkoutSession] = []
    private var identity = ActivityIdentity(sessions: [])
    private var templates: [ActivityKey: LibraryTemplate] = [:]

    @MainActor
    static func build(history: [WorkoutSession], entries: [LibraryEntry], resolver: ExerciseResolver,
                      unit: WeightUnit) -> LibraryPickSource {
        var s = LibraryPickSource()
        s.history = history
        s.identity = ActivityIdentity(sessions: history)
        var created: [LibraryCatalog.CreatedInput] = []
        for e in entries {
            guard let key = e.key else { continue }
            if e.isHidden { s.hidden.insert(key) }
            if let t = e.template {
                s.templates[key] = t
                created.append(.init(key: key, template: t, createdAt: e.createdAt ?? e.updatedAt))
            }
        }
        s.rows = LibraryCatalog.yours(history: history, identity: s.identity, unit: unit, created: created) {
            WorkoutLibraryView.title($0, resolver: resolver)
        }
        return s
    }

    func row(_ key: ActivityKey) -> LibraryCatalog.Row? { rows.first { $0.key == key } }

    /// A fresh entity to log — set up the way you left it last time (or from what you created).
    func sessionExercise(_ key: ActivityKey) -> SessionExercise? {
        ActivityLauncher.sessionExercise(for: key, history: history, identity: identity, template: templates[key])
    }

    /// A routine block prescribing what you did last time.
    func routineBlock(_ key: ActivityKey, defaultUnit: WeightUnit) -> RoutineExercise? {
        ActivityLauncher.routineBlock(for: key, history: history, identity: identity, defaultUnit: defaultUnit,
                                      template: templates[key])
    }
}

/// Yours | Explore at the top of a picker.
struct LibraryPickModeBar: View {
    @Binding var yours: Bool

    var body: some View {
        Picker("Show", selection: $yours) {
            Text("Yours").tag(true)
            Text("Explore").tag(false)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("picker.mode")
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// One of your activities in a picker: grade badge or discipline glyph, title, "Last: …", and a tick.
struct LibraryPickRow: View {
    let row: LibraryCatalog.Row
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let c = row.climb {
                Text(c.grade ?? "–").font(.caption.weight(.heavy)).monospacedDigit()
                    .foregroundStyle(SnappetColor.kilter)
                    .frame(width: 36, height: 30)
                    .background(SnappetColor.kilter.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: row.discipline.symbol)
                    .font(.title3).foregroundStyle(row.discipline.accent)
                    .frame(width: 36, height: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.headline).lineLimit(1)
                Text(LibraryPick.subtitle(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? row.discipline.accent : Color.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
