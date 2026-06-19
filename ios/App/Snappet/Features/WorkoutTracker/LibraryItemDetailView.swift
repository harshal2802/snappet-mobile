import SwiftUI

/// **Discipline-adaptive library item detail** (workout-redesign E3). Generalizes the old strength-only
/// `ExerciseDetailView`: a strength item still routes to the full `ExerciseDetailView` (metadata · muscle
/// map · progress · instructions · Edit/Delete for custom), but a climb / run / timed template renders its
/// own adaptive detail — a discipline header, a how-to/metadata block, and a discipline-adaptive **records**
/// header that reuses the `StatRibbon` shape. Muscles map is STRENGTH-ONLY (we do NOT fake anatomy for a
/// climb or a run, per the design direction). Records are best-effort from session blobs (the per-movement
/// history `@Model` is deferred, README §9).
struct LibraryItemDetailView: View {
    let item: LibraryItem
    let history: [WorkoutSession]
    let unit: WeightUnit

    var body: some View {
        switch item.source {
        case .strength(let ex):
            // The full, well-tested strength detail (Edit/Delete for custom lives here).
            ExerciseDetailView(exercise: ex, history: history, unit: unit)
        case .climb, .run, .timed:
            AdaptiveItemDetail(item: item, history: history, unit: unit)
        }
    }
}

/// The adaptive detail for a non-strength library item (climb / run / timed). One scaffold: a discipline
/// hero header → a metadata/how-to block → a records header. Renders on the host's stack (no nav stack).
private struct AdaptiveItemDetail: View {
    let item: LibraryItem
    let history: [WorkoutSession]
    let unit: WeightUnit

    private var accent: Color { item.discipline.accent }
    private var records: [LibraryRecords.Record] {
        LibraryRecords.records(for: item, history: history, unit: unit)
    }

    var body: some View {
        List {
            Section { header }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

            if !records.isEmpty {
                Section("Your records") {
                    StatRibbon(items: records.map {
                        StatRibbon.Item(text: "\($0.value) \($0.label.lowercased())",
                                        tint: accent, emphasized: true)
                    })
                    .accessibilityIdentifier("library.records")
                    Text("Best-effort from your logged sessions across this type.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            ForEach(Array(metadata.enumerated()), id: \.offset) { _, row in
                Section(row.title) {
                    ForEach(row.lines, id: \.self) { Text($0).font(.callout) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: item.symbol)
                .font(.largeTitle).foregroundStyle(accent)
                .frame(width: 52, height: 52)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: SnappetRadius.md))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.discipline.label.uppercased())
                    .font(.caption.weight(.bold)).tracking(0.6).foregroundStyle(accent)
                Text(item.title).font(.title3.weight(.semibold))
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Discipline-specific metadata / how-to sections.
    private var metadata: [(title: String, lines: [String])] {
        switch item.source {
        case .climb(let c):
            return [("About", ["\(c.climbType.label) climbing.",
                               "Typical grades: \(c.gradeBand).",
                               "Log a climb from a Quick Session to track sends and build a grade pyramid."])]
        case .run(let r):
            var about = ["\(r.terrain.display) run."]
            if let m = r.distanceMeters {
                let du: DistanceUnit = unit == .lb ? .mi : .km
                about.append("Suggested distance: \(SetMeasure.formatDistance(m, unit: du)).")
            }
            about.append("Distance is entered manually (no GPS route capture).")
            return [("About", about)]
        case .timed(let specData, let category, _):
            let spec = specData.flatMap { try? JSONDecoder().decode(TimedExerciseSpec.self, from: $0) }
                ?? TimedExerciseSpec(mode: .openCountUp)
            return [("Protocol", ["\(category.display) · \(spec.mode.label)", spec.summary])]
        case .strength:
            return []   // handled by ExerciseDetailView
        }
    }
}
