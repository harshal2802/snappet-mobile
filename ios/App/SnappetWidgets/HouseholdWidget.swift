import SwiftUI
import WidgetKit
import AppIntents

/// The household on the Home and Lock Screen (household prompt 04): the pet, the goal and your chores
/// today, ticked off right here (`ToggleChoreIntent`). Reads the App-Group snapshot the app publishes.
struct HouseholdWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: HouseholdWidgetStore.kind, provider: HouseholdProvider()) { entry in
            HouseholdWidgetView(entry: entry)
                .containerBackground(for: .widget) { BuddyWidgetView.ground }
        }
        .configurationDisplayName("Household chores")
        .description("Your chores today, the house goal and the house pet. Tick them off right here.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct HouseholdEntry: TimelineEntry {
    let date: Date
    let snapshot: HouseholdWidgetSnapshot
    /// No household yet (the app hasn't published one).
    let isEmpty: Bool
}

struct HouseholdProvider: TimelineProvider {
    func placeholder(in context: Context) -> HouseholdEntry {
        HouseholdEntry(date: .now, snapshot: .placeholder, isEmpty: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (HouseholdEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HouseholdEntry>) -> Void) {
        // The app reloads us on every change; refresh after midnight so "today" rolls over.
        let tomorrow = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400)).addingTimeInterval(60)
        completion(Timeline(entries: [entry()], policy: .after(tomorrow)))
    }

    private func entry() -> HouseholdEntry {
        if let s = HouseholdWidgetStore.read() { return HouseholdEntry(date: .now, snapshot: s, isEmpty: false) }
        return HouseholdEntry(date: .now, snapshot: .placeholder, isEmpty: true)
    }
}

struct HouseholdWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HouseholdEntry
    private var s: HouseholdWidgetSnapshot { entry.snapshot }
    private let sage = Color(red: 0.66, green: 0.78, blue: 0.31)

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemMedium: medium
        default: rectangular
        }
    }

    private var pet: some View {
        Image(s.imageName).resizable().scaledToFit()
            .accessibilityLabel("\(s.petName), house level \(s.level)")
    }

    private var goalLine: String {
        if let hour = s.powerHour, hour.end > entry.date { return "Power hour · \(hour.done) done" }
        return s.goalTarget > 0 ? "Goal \(s.goalDone)/\(s.goalTarget)" : "\(s.goalDone) done this week"
    }

    private func bar(_ height: CGFloat) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(sage).frame(width: g.size.width * min(1, Double(s.goalDone) / Double(max(1, s.goalTarget))))
            }
        }
        .frame(height: height)
    }

    private func row(_ chore: HouseholdWidgetSnapshot.Chore) -> some View {
        Button(intent: ToggleChoreIntent(choreID: chore.id.uuidString)) {
            HStack(spacing: 6) {
                Image(systemName: chore.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chore.done ? sage : .white.opacity(0.6))
                Text("\(chore.emoji) \(chore.name)")
                    .strikethrough(chore.done)
                    .foregroundStyle(chore.done ? .white.opacity(0.5) : chore.overdueDays > 0 ? .orange : .white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chore.done ? "\(chore.name), done. Tap to undo." : "Tick off \(chore.name)")
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                pet.frame(width: 44, height: 44)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(s.remaining)").font(.title2.weight(.heavy)).foregroundStyle(.white)
                    Text("to do").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            if entry.isEmpty {
                Text("Open Household to set up your chores").font(.caption).foregroundStyle(.white)
            } else {
                ForEach(s.chores.prefix(3)) { row($0) }
                Spacer(minLength: 0)
                bar(4)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var medium: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                pet.frame(width: 96, height: 96)
                Text("\(s.petName) · Lv \(s.level)").font(.caption2.weight(.heavy)).foregroundStyle(.white).lineLimit(1)
                Text(goalLine).font(.caption2).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                bar(4)
            }
            .frame(width: 110)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.isEmpty ? "HOUSEHOLD" : s.remaining == 0 ? "ALL DONE TODAY" : "YOURS TODAY · \(s.remaining)")
                    .font(.caption2.weight(.heavy)).foregroundStyle(.white.opacity(0.55))
                if entry.isEmpty {
                    Text("Open Household to set up your chores").font(.caption).foregroundStyle(.white)
                } else if s.chores.isEmpty {
                    Text("Nothing of yours today. Enjoy it.").font(.caption).foregroundStyle(.white.opacity(0.8))
                } else {
                    ForEach(s.chores.prefix(4)) { row($0) }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.remaining == 0 ? "Chores: all done" : "Chores: \(s.remaining) to do").font(.headline).widgetAccentable()
            Text(s.chores.first { !$0.done }.map { "\($0.emoji) \($0.name)" } ?? goalLine).font(.caption).lineLimit(1)
            Gauge(value: min(1, Double(s.goalDone) / Double(max(1, s.goalTarget)))) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
        }
    }
}
