import SwiftUI

/// "Where are you now?" / "What's next?" (prompt 232) — the one picker for changing where you are:
/// after a set ends, from "End this set", from the live sheet's switch, and from the Festival home
/// card. Sets on now (starred first), running late (scheduled to have ended — the Halloween case),
/// up next, then the non-set choices: a break, walking to another stage, or heading home. Every
/// list is the pure `FestivalNight.whereOptions`; nothing is truncated.
struct FestivalWhereSheet: View {
    enum Choice {
        case set(FestivalSet)
        case stretch(FestivalNight.StretchKind)
        case endNight
    }

    let pack: FestivalPack
    let starred: Set<UUID>
    /// The set you're at (left out of the lists).
    let currentSetID: UUID?
    let title: String
    /// "BOYS NOIZE B2B SALOME ended at 01:30" — context under the title.
    let subtitle: String?
    /// The night is on (offers End the night) vs not started (choices start it).
    let nightOn: Bool
    let onPick: (Choice) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                list(now: timeline.date)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("festival.where.cancel")
                }
            }
        }
    }

    private func list(now: Date) -> some View {
        let options = FestivalNight.whereOptions(in: pack, starred: starred, excluding: currentSetID,
                                                 now: now)
        return List {
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(SnappetColor.textSecondary)
                    .listRowBackground(Color.clear)
            }
            if !options.onNow.isEmpty {
                Section("On now") {
                    ForEach(options.onNow) { set in
                        row(set, detail: range(set), note: nil)
                    }
                }
            }
            if !options.runningLate.isEmpty {
                Section {
                    ForEach(options.runningLate) { set in
                        row(set, detail: range(set) + " · scheduled to end "
                            + FestivalSchedule.timeLabel(set.end, offsetSeconds: pack.utcOffsetSeconds),
                            note: nil)
                    }
                } header: {
                    Text("Running late?")
                } footer: {
                    Text("Still playing past the lineup's time? Pick it — you can fix its time on the set's page.")
                }
            }
            if !options.upNext.isEmpty {
                Section("Up next") {
                    ForEach(options.upNext) { set in
                        row(set, detail: range(set), note: nil)
                    }
                }
            }
            Section("Not at a set") {
                choice(.rest, title: "Taking a break",
                       detail: "Heart rate keeps running · not counted as dancing")
                choice(.walking, title: "Walking to another stage",
                       detail: "Pick the set when you get there")
            }
            if nightOn {
                Section {
                    Button(role: .destructive) {
                        pick(.endNight)
                    } label: {
                        Text("End the night — heading home")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("festival.where.endNight")
                }
            }
        }
    }

    private func range(_ set: FestivalSet) -> String {
        "\(set.stage) · \(FestivalSchedule.timeLabel(set.start, offsetSeconds: pack.utcOffsetSeconds))"
            + "–\(FestivalSchedule.timeLabel(set.end, offsetSeconds: pack.utcOffsetSeconds))"
    }

    private func row(_ set: FestivalSet, detail: String, note: String?) -> some View {
        Button {
            pick(.set(set))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(set.artist).foregroundStyle(SnappetColor.ink)
                        if starred.contains(set.id) {
                            Image(systemName: "star.fill").font(.caption2)
                                .foregroundStyle(SnappetColor.brand)
                        }
                    }
                    Text(detail).font(.caption).foregroundStyle(SnappetColor.textSecondary)
                }
                Spacer()
                if let note {
                    Text(note).font(.caption2).foregroundStyle(SnappetColor.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("festival.where.set.\(set.artist)")
    }

    private func choice(_ kind: FestivalNight.StretchKind, title: String, detail: String) -> some View {
        Button {
            pick(.stretch(kind))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: kind.symbol)
                    .foregroundStyle(SnappetColor.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(SnappetColor.ink)
                    Text(detail).font(.caption).foregroundStyle(SnappetColor.textSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("festival.where.\(kind.rawValue)")
    }

    private func pick(_ choice: Choice) {
        onPick(choice)
        dismiss()
    }
}
