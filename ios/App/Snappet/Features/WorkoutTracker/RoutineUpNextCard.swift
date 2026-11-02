import SwiftUI

/// "Up next" on the Routines list (prompt 136, wireframe frame 5): the soonest planned routine with
/// Start / Skip, over this week's strip across every scheduled routine (✓ done · amber missed · planned).
/// Prompt 219: a calm accent card (was an orange gradient), sentence-case kicker.
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
                    .snappetLabel()
                    .accessibilityIdentifier("upNext.when")
                Text(routine.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                    .accessibilityIdentifier("upNext.name")
                Text("\(routine.exercises.count) block\(routine.exercises.count == 1 ? "" : "s") · \(routine.totalSets) set\(routine.totalSets == 1 ? "" : "s")")
                    .snappetDetail()
            } else {
                Text("This week").snappetLabel()
                Text("Nothing else planned").snappetTitle()
            }

            weekStrip

            if let upNext, let routine {
                HStack(spacing: 8) {
                    Button { start(routine) } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(SnappetWidePrimaryStyle())
                    .disabled(routine.exercises.isEmpty)
                    .accessibilityIdentifier("upNext.start")
                    if upNext.slotsOnDay > 1 {
                        Button { skipSlot(routine.id, upNext.slotKey) } label: {
                            Text("Skip this one").font(.system(size: 15, weight: .medium)).snappetPill(selected: false, large: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("upNext.skipSlot")
                    } else if upNext.isToday {
                        Button { skip(routine.id, upNext.day) } label: {
                            Text("Skip today").font(.system(size: 15, weight: .medium)).snappetPill(selected: false, large: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("upNext.skip")
                    }
                }
                .padding(.top, 4)
            }
        }
        .snappetPanel(glow: upNext != nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("upNext.card")
    }

    private func kicker(_ u: RoutineReminderPlanner.UpNext) -> String {
        let base = kickerBase(u)
        return u.slotsOnDay > 1 ? "\(base) · \(u.slot + 1) of \(u.slotsOnDay)" : base
    }

    private func kickerBase(_ u: RoutineReminderPlanner.UpNext) -> String {
        let time = u.start.formatted(date: .omitted, time: .shortened)
        if u.isToday { return "Up next · Today \(time)" }
        if calendar.isDateInTomorrow(u.start) { return "Up next · Tomorrow \(time)" }
        return "Up next · \(u.start.formatted(.dateTime.weekday(.wide))) \(time)"
    }

    private var weekStrip: some View {
        HStack(spacing: 4) {
            ForEach(week, id: \.day) { d in
                VStack(spacing: 3) {
                    Text(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: d.day.date(calendar: calendar)) - 1])
                        .font(.system(size: 10, weight: d.isToday ? .semibold : .regular))
                        .foregroundStyle(d.isToday ? SnappetColor.ink : SnappetColor.textTertiary)
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
        // Several sessions a day: "2/7"; otherwise the routine's initials ("SK") — the first word ("Sudarshan")
        // crowded the cell (user, on device, prompt 219). The full name is in the title + the VoiceOver label.
        let label = d.planned > 1 ? "\(d.done)/\(d.planned)" : d.names.first.map(Self.initials) ?? ""
        switch d.state {
        case .done:
            Group {
                if d.planned > 1 { Text(label).font(.system(size: 9, weight: .bold)) }
                else { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
            }
            .foregroundStyle(SnappetColor.onBrand)
            .frame(maxWidth: .infinity, minHeight: 24).background(SnappetColor.brand, in: shape)
        case .planned:
            Text(label).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
                .foregroundStyle(SnappetColor.brand)
                .frame(maxWidth: .infinity, minHeight: 24).overlay(shape.strokeBorder(SnappetColor.brand))
        case .missed:
            Text(label).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
                .foregroundStyle(.orange)   // missed = amber meaning colour (was coral, which is now the accent)
                .frame(maxWidth: .infinity, minHeight: 24).background(Color.orange.opacity(0.16), in: shape)
        case .skipped:
            Image(systemName: "arrow.uturn.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 24).background(SnappetColor.surfaceMuted, in: shape)
        case .none:
            SnappetColor.surfaceMuted.frame(maxWidth: .infinity, minHeight: 24).clipShape(shape)
        }
    }

    /// "Sudarshan Kriya" → "SK", "Push Day" → "PD", "Yoga" → "YO" — two letters that fit a narrow day cell.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 { return words.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased() }
        return String(words.first?.prefix(2) ?? "").uppercased()
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
