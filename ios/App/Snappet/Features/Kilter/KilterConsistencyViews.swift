import SwiftUI

/// The two reusable **consistency surfaces** for the redesigned Kilter history (Kilter Improvement P4),
/// both driven by the pure `KilterConsistency` day buckets so they hold no math:
///   • `KilterHeatmapView` — a GitHub-style activity grid (cell fill scales with the day's sends; the
///     current day gets an accent ring); tapping a populated cell navigates to that day's session.
///   • `KilterMonthCalendarView` — a tappable month calendar with a send-dot on active days; tapping a
///     day with a session opens it.
/// Each surface DOUBLES AS NAVIGATION: `onSelectDay` receives the tapped `KilterConsistency.Day` (it
/// carries `sessionIDs`), and the host pushes the first session's `KilterSessionRoute`.

/// GitHub-style consistency heatmap: weeks as columns, weekdays as rows, fill intensity = sends that day.
struct KilterHeatmapView: View {
    let days: [KilterConsistency.Day]
    var calendar: Calendar = .current
    /// Tapped a populated day (≥1 session) → the host navigates to its session(s).
    var onSelectDay: (KilterConsistency.Day) -> Void = { _ in }

    private let cell: CGFloat = 13
    private let spacing: CGFloat = 3

    /// Columns of (up to) 7 days each — weeks, oldest→newest. The first column is padded at the top so
    /// each row is a fixed weekday (the canonical GitHub alignment).
    private var weeks: [[KilterConsistency.Day?]] {
        guard let first = days.first else { return [] }
        let lead = (calendar.component(.weekday, from: first.date) - calendar.firstWeekday + 7) % 7
        var padded: [KilterConsistency.Day?] = Array(repeating: nil, count: lead)
        padded.append(contentsOf: days.map { Optional($0) })
        return stride(from: 0, to: padded.count, by: 7).map { Array(padded[$0..<min($0 + 7, padded.count)]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Consistency", systemImage: "square.grid.3x3.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(activeDays) active day\(activeDays == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: spacing) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                cellView(day)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding()
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .padding(.horizontal)
        .accessibilityIdentifier("kilter.history.heatmap")
    }

    private var activeDays: Int { days.filter { !$0.isEmpty }.count }

    @ViewBuilder private func cellView(_ day: KilterConsistency.Day?) -> some View {
        if let day {
            let isToday = calendar.isDateInToday(day.date)
            RoundedRectangle(cornerRadius: 3)
                .fill(fill(day))
                .frame(width: cell, height: cell)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(isToday ? SnappetColor.moduleAccent("kilter") : .clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
                .onTapGesture { if !day.isEmpty { onSelectDay(day) } }
                .accessibilityIdentifier(day.isEmpty ? "kilter.heatmap.cell.empty" : "kilter.heatmap.cell")
        } else {
            Color.clear.frame(width: cell, height: cell)
        }
    }

    private func fill(_ day: KilterConsistency.Day) -> Color {
        guard !day.isEmpty else { return Color(.tertiarySystemFill) }
        // Floor the opacity so even a one-send day reads, then scale to the busiest day.
        return SnappetColor.moduleAccent("kilter").opacity(0.30 + 0.70 * day.intensity)
    }
}

/// A tappable month calendar: a 7-column weekday grid with a send-dot on days that had a session.
/// Tapping a populated day opens its session.
struct KilterMonthCalendarView: View {
    /// The days of the month to render (from `KilterConsistency.monthDays`).
    let days: [KilterConsistency.Day]
    /// Any date inside the month being shown (for the header + leading-blank alignment).
    let month: Date
    var calendar: Calendar = .current
    var onSelectDay: (KilterConsistency.Day) -> Void = { _ in }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 4), count: 7) }

    /// Leading empty cells so day 1 lands under its real weekday column.
    private var leadingBlanks: Int {
        guard let first = days.first else { return 0 }
        return (calendar.component(.weekday, from: first.date) - calendar.firstWeekday + 7) % 7
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(start + $0) % 7] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(month.formatted(.dateTime.month(.wide).year()), systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(weekdaySymbols, id: \.self) { s in
                    Text(s).font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(0..<leadingBlanks, id: \.self) { _ in Color.clear.frame(height: 30) }
                ForEach(days) { day in dayCell(day) }
            }
        }
        .padding()
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .padding(.horizontal)
        .accessibilityIdentifier("kilter.history.calendar")
    }

    @ViewBuilder private func dayCell(_ day: KilterConsistency.Day) -> some View {
        let isToday = calendar.isDateInToday(day.date)
        VStack(spacing: 2) {
            Text("\(calendar.component(.day, from: day.date))")
                .font(.caption.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? SnappetColor.moduleAccent("kilter") : .primary)
            if !day.isEmpty {
                Circle()
                    .fill(SnappetColor.moduleAccent("kilter").opacity(0.4 + 0.6 * day.intensity))
                    .frame(width: 6, height: 6)
            } else {
                Circle().fill(.clear).frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(isToday ? SnappetColor.moduleAccent("kilter").opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { if !day.isEmpty { onSelectDay(day) } }
        .accessibilityIdentifier(day.isEmpty ? "kilter.calendar.day.empty" : "kilter.calendar.day")
    }
}
