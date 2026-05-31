import SwiftUI

/// The Routines section: starter routines + the user's own, grouped. Tapping a routine pushes
/// its detail (where it can be started or edited); swipe to delete. Lives in the App Library's
/// NavigationStack.
struct RoutinesSectionView: View {
    let routines: [Routine]
    let resolver: ExerciseResolver
    let unit: WeightUnit
    let start: (Routine) -> Void
    let deleteRoutine: (Routine) -> Void
    let newRoutine: () -> Void

    private var mine: [Routine] { routines.filter { !$0.isStarter } }
    private var starters: [Routine] {
        routines.filter(\.isStarter).sorted { $0.name < $1.name }
    }

    var body: some View {
        Group {
            if routines.isEmpty {
                ContentUnavailableView {
                    Label("No routines", systemImage: "list.bullet.rectangle.portrait")
                } description: {
                    Text("Build a routine from the exercise catalog to start training.")
                } actions: {
                    Button("New Routine") { newRoutine() }.buttonStyle(.borderedProminent)
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if !mine.isEmpty {
                Section("My Routines") {
                    ForEach(mine) { routine in
                        NavigationLink(value: routine) { RoutineRow(routine: routine, resolver: resolver) }
                            .swipeActions { deleteButton(routine) }
                    }
                }
            }
            if !starters.isEmpty {
                Section("Starter Routines") {
                    ForEach(starters) { routine in
                        NavigationLink(value: routine) { RoutineRow(routine: routine, resolver: resolver) }
                            .swipeActions { deleteButton(routine) }
                    }
                }
            }
        }
    }

    private func deleteButton(_ routine: Routine) -> some View {
        Button(role: .destructive) { deleteRoutine(routine) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// One routine list row: name, sport/level chips, and an exercise-count summary.
struct RoutineRow: View {
    let routine: Routine
    let resolver: ExerciseResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let sport = routine.sport, sport != .general {
                    Image(systemName: sport.symbol).foregroundStyle(.orange)
                }
                Text(routine.name).font(.headline).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text("\(routine.exercises.count) exercises · \(routine.totalSets) sets")
                if let level = routine.level {
                    Text("·"); Text(level.display)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !routine.exercises.isEmpty {
                Text(routine.exercises.prefix(3)
                    .map { resolver.name(for: $0.exerciseId, override: $0.displayName) }
                    .joined(separator: ", ") + (routine.exercises.count > 3 ? "…" : ""))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
