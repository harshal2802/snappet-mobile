import SwiftUI
import SwiftData

/// Route value for the **On the Board** timeline (Kilter Improvement P5).
struct KilterOnTheBoardRoute: Hashable {}

/// On the Board (wireframe `05_ontheboard`): a history of every climb the user **lit on the board** —
/// including the ones pulled up and worked but never logged as an ascent. A hero "N climbs worked" +
/// filter chips (status / angle / board), a timeline grouped by day/session with roll-ups, and a row per
/// deduped lit climb: a mini board thumbnail + name + grade/angle/time + a status chip (Lit / Attempt /
/// ✓ Sent, joined from the ascent log) + a one-tap **re-light** that re-sends the holds to the board.
///
/// All grouping / dedup / status-join is the pure `KilterOnTheBoard` helper; this view is a dumb renderer
/// over its result. The re-light leg is **device-pending** (a board must be connected to actually light).
struct KilterOnTheBoardView: View {
    let board: KilterBoardController
    /// The module's session manager — so a re-light records the climb into the CURRENT session (F3),
    /// not by mutating an arbitrary older row from a different session.
    let sessions: KilterSessionManager

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KilterLitEvent.litAt, order: .reverse) private var litEvents: [KilterLitEvent]
    @Query private var allEntries: [KilterLogEntry]

    private let catalog = KilterCatalog.shared
    /// The shared board-render cache (F5), so the timeline's per-row thumbnails resolve each
    /// `catalog.climb/holds/boardGeometry` from SQLite ONCE — keyed by `uuid|sizeId` — not on every
    /// re-render. The same type the gallery (P2) and the root recent rail use.
    @State private var thumbs = KilterThumbnailCache()
    @AppStorage("kilter.gradeFormat") private var gradeFormatRaw = KilterGradeFormat.both.rawValue
    private var gradeFormat: KilterGradeFormat { KilterGradeFormat(rawValue: gradeFormatRaw) ?? .both }

    /// Active filter selections (at most one value per facet).
    @State private var selections: [KilterOnTheBoard.Facet: String] = [:]
    /// A brief "re-lit" confirmation toast keyed by row id.
    @State private var relitRowID: String?

    private var logs: [KilterClimbLog] { allEntries.map(KilterClimbLog.from) }
    private var events: [KilterOnTheBoard.LitEvent] { litEvents.map(KilterOnTheBoard.LitEvent.from) }

    private func layoutName(_ id: Int) -> String? { catalog.layouts().first { $0.id == id }?.name }

    private var model: KilterOnTheBoard.DisplayModel {
        KilterOnTheBoard.build(events: events, logs: logs, selections: selections,
                               now: .now, layoutName: layoutName)
    }

    var body: some View {
        Group {
            if litEvents.isEmpty {
                ContentUnavailableView(
                    "Nothing lit yet", systemImage: "lightbulb",
                    description: Text("Light a climb on the board and it shows up here — even the ones you "
                                      + "work but never log."))
            } else {
                content(model)
            }
        }
        .navigationTitle("On the Board")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ model: KilterOnTheBoard.DisplayModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero(model)
                chipRail(model)
                ForEach(model.groups) { group in
                    groupSection(group)
                }
                if model.groups.isEmpty {
                    ContentUnavailableView(
                        "No matches", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("No lit climbs match the current filters."))
                        .padding(.top, 40)
                }
            }
            .padding(.vertical)
        }
    }

    /// The hero "N climbs worked".
    private func hero(_ model: KilterOnTheBoard.DisplayModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(model.climbsWorked)")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("CLIMBS WORKED")
                .font(.caption.weight(.bold)).tracking(0.5)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kilter.board.hero")
    }

    /// The filter chip rail (status / angle / board). A re-tap clears the selection.
    @ViewBuilder private func chipRail(_ model: KilterOnTheBoard.DisplayModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isOn: selections.isEmpty) { withAnimation(.snappy) { selections = [:] } }
                ForEach(KilterOnTheBoard.Facet.allCases, id: \.self) { facet in
                    ForEach(model.facetValues[facet] ?? [], id: \.self) { value in
                        chip(title: value, isOn: selections[facet] == value) {
                            withAnimation(.snappy) {
                                if selections[facet] == value { selections[facet] = nil }
                                else { selections[facet] = value }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .accessibilityIdentifier("kilter.board.chipRail")
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(isOn ? AnyShapeStyle(SnappetColor.moduleAccent("kilter"))
                                 : AnyShapeStyle(SnappetColor.surfaceMuted), in: Capsule())
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kilter.board.chip")
    }

    /// One day/session group: a headline + roll-up summary over its rows.
    private func groupSection(_ group: KilterOnTheBoard.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.headline)
                    .font(.headline)
                    .accessibilityIdentifier("kilter.board.groupHeader")
                Spacer()
                Text(group.summary)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            VStack(spacing: 0) {
                ForEach(group.rows) { row in
                    litRow(row)
                    if row.id != group.rows.last?.id { Divider().padding(.leading, 76) }
                }
            }
        }
    }

    /// A single lit-climb row: mini board thumbnail + name + grade/angle/time + status chip + re-light.
    private func litRow(_ row: KilterOnTheBoard.Row) -> some View {
        let e = row.event
        return HStack(spacing: 12) {
            thumbnail(for: e)
                .frame(width: 48, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.climbName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(metaLine(e)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            statusChip(row.status)
            relightButton(row)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kilter.board.row")
    }

    /// "V6 · 40° · 7:24 PM" — grade (per the user's format), angle, light time.
    private func metaLine(_ e: KilterOnTheBoard.LitEvent) -> String {
        let grade = e.gradeLabel.isEmpty ? "" : kilterDisplayGrade(e.gradeLabel, gradeFormat)
        let time = e.litAt.formatted(.dateTime.hour().minute())
        return [grade, "\(e.angle)°", time].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A mini board render of the climb's holds, resolved from the shared cache (F5) at the event's
    /// layout/size — keyed by `uuid|sizeId`, so a re-render or a repeated climb doesn't re-hit SQLite.
    @ViewBuilder private func thumbnail(for e: KilterOnTheBoard.LitEvent) -> some View {
        if let render = thumbs.render(forCatalogUUID: e.climbUUID, sizeId: e.sizeId, catalog: catalog) {
            KilterBoardView(geometry: render.geometry, holds: render.holds)
        } else {
            // A created climb (or a climb the local catalog lacks): a neutral placeholder tile.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SnappetColor.surfaceMuted)
                .overlay(Image(systemName: "square.grid.3x3")
                    .font(.caption).foregroundStyle(.secondary))
        }
    }

    private func statusChip(_ status: KilterOnTheBoard.Status) -> some View {
        let (tint, icon): (Color, String?) = {
            switch status {
            case .sent: return (.green, "checkmark")
            case .attempt: return (.orange, nil)
            case .lit: return (.secondary, nil)
            }
        }()
        return HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            Text(status.label)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tint.opacity(0.16), in: Capsule())
        .foregroundStyle(tint)
        .accessibilityIdentifier("kilter.board.statusChip")
    }

    /// One-tap re-light: re-resolve the climb's holds and send them to the board (and re-capture, bumping
    /// the lit event's `litAt`). A board must be connected to actually light; the row still records the
    /// re-light intent.
    private func relightButton(_ row: KilterOnTheBoard.Row) -> some View {
        Button {
            relight(row.event)
        } label: {
            Image(systemName: relitRowID == row.id ? "checkmark.circle.fill" : "arrow.clockwise.circle")
                .font(.title3)
                .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                .symbolEffect(.bounce, value: relitRowID == row.id)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kilter.board.relight")
        .accessibilityLabel("Re-light \(row.event.climbName)")
    }

    /// Re-light a previously-worked climb = "put this climb up again now": send its holds to the board AND
    /// upsert a lit-event for the CURRENT session via the shared capture path (F3). The old code bumped
    /// `litEvents.first(where: uuid match)` — the newest event across ALL sessions — which corrupted a
    /// DIFFERENT session's `litAt`. Recording into the current session (a fresh row when re-lit out of the
    /// originating session, the same row when re-lit within it) keeps every session's history intact.
    private func relight(_ e: KilterOnTheBoard.LitEvent) {
        if let climb = catalog.climb(e.climbUUID) {
            board.illuminate(catalog.holds(for: climb, sizeId: e.sizeId))
        }
        upsertLitEvent(climbUUID: e.climbUUID, climbName: e.climbName, layoutId: e.layoutId,
                       angle: e.angle, sizeId: e.sizeId, gradeLabel: e.gradeLabel,
                       sessionId: sessions.currentId, wasConnected: board.isConnected,
                       in: modelContext)
        Haptics.tap()
        withAnimation(.snappy) { relitRowID = e.id }
    }
}
