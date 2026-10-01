import SwiftUI

/// "Up next" on the Routines list (prompt 136, wireframe frame 5): the soonest planned routine with
/// Start / Skip, over this week's strip across every scheduled routine (✓ done · coral missed · planned).
/// Only shown when something is scheduled, so an unscheduled list looks exactly as before.
struct RoutineUpNextCard: View {
    let upNext: RoutineReminderPlanner.UpNext?
    let week: [RoutineReminderPlanner.WeekDay]
    let routine: Routine?
    let start: (Routine) -> Void
    let skip: (UUID, DayKey) -> Void
    /// Skip one session on a day with several (prompt 144).
    var skipSlot: (UUID, SlotKey) -> Void = { _, _ in }

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let upNext, let routine {
                Text(kicker(upNext))
                    .font(.caption.weight(.heavy)).tracking(1)
                    .foregroundStyle(SnappetColor.workout)
                    .accessibilityIdentifier("upNext.when")
                Text(routine.name).font(.title3.weight(.bold))
                    .accessibilityIdentifier("upNext.name")
                Text("\(routine.exercises.count) blocks · \(routine.totalSets) sets")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("THIS WEEK").font(.caption.weight(.heavy)).tracking(1).foregroundStyle(SnappetColor.workout)
                Text("Nothing else planned").font(.headline)
            }

            weekStrip

            if let upNext, let routine {
                HStack(spacing: 10) {
                    Button { start(routine) } label: {
                        Label("Start", systemImage: "play.fill").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent).tint(SnappetColor.workout)
                    .disabled(routine.exercises.isEmpty)
                    .accessibilityIdentifier("upNext.start")
                    if upNext.slotsOnDay > 1 {
                        Button("Skip this one") { skipSlot(routine.id, upNext.slotKey) }
                            .buttonStyle(.bordered).tint(SnappetColor.workout)
                            .accessibilityIdentifier("upNext.skipSlot")
                    } else if upNext.isToday {
                        Button("Skip today") { skip(routine.id, upNext.day) }
                            .buttonStyle(.bordered).tint(SnappetColor.workout)
                            .accessibilityIdentifier("upNext.skip")
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [SnappetColor.workout.opacity(0.28), SnappetColor.workout.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(SnappetColor.workout.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("upNext.card")
    }

    private func kicker(_ u: RoutineReminderPlanner.UpNext) -> String {
        let base = kickerBase(u)
        return u.slotsOnDay > 1 ? "\(base) · \(u.slot + 1) OF \(u.slotsOnDay)" : base
    }

    private func kickerBase(_ u: RoutineReminderPlanner.UpNext) -> String {
        let time = u.start.formatted(date: .omitted, time: .shortened)
        if u.isToday { return "UP NEXT · TODAY \(time)" }
        if calendar.isDateInTomorrow(u.start) { return "UP NEXT · TOMORROW \(time)" }
        return "UP NEXT · \(u.start.formatted(.dateTime.weekday(.wide)).uppercased()) \(time)"
    }

    private var weekStrip: some View {
        HStack(spacing: 4) {
            ForEach(week, id: \.day) { d in
                VStack(spacing: 3) {
                    Text(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: d.day.date(calendar: calendar)) - 1])
                        .font(.caption2.weight(d.isToday ? .heavy : .regular))
                        .foregroundStyle(d.isToday ? .primary : .secondary)
                    cell(d)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(a11y(d))
            }
        }
    }

    @ViewBuilder private func cell(_ d: RoutineReminderPlanner.WeekDay) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        // Several sessions a day: "2/7"; otherwise the routine's first word.
        let label = d.planned > 1 ? "\(d.done)/\(d.planned)"
            : d.names.first.map { String($0.split(separator: " ").first ?? "") } ?? ""
        switch d.state {
        case .done:
            Group {
                if d.planned > 1 { Text(label).font(.system(size: 9, weight: .bold)) }
                else { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 24).background(SnappetColor.workout, in: shape)
        case .planned:
            Text(label).font(.system(size: 9, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(SnappetColor.workout)
                .frame(maxWidth: .infinity, minHeight: 24).background(SnappetColor.workout.opacity(0.25), in: shape)
        case .missed:
            Text(label).font(.system(size: 9, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(SnappetColor.brand)
                .frame(maxWidth: .infinity, minHeight: 24).background(SnappetColor.brand.opacity(0.18), in: shape)
        case .skipped:
            Image(systemName: "arrow.uturn.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 24).background(Color(.tertiarySystemFill), in: shape)
        case .none:
            Color(.tertiarySystemFill).frame(maxWidth: .infinity, minHeight: 24).clipShape(shape)
        }
    }

    private func a11y(_ d: RoutineReminderPlanner.WeekDay) -> String {
        let day = d.day.date(calendar: calendar).formatted(.dateTime.weekday(.wide))
        let names = d.names.joined(separator: ", ")
        switch d.state {
        case .done: return "\(day): done, \(names)"
        case .planned: return "\(day): planned, \(names)"
        case .missed: return "\(day): missed, \(names)"
        case .skipped: return "\(day): skipped"
        case .none: return "\(day): rest day"
        }
    }
}
