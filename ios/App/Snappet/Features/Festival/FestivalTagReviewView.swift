import SwiftUI
import SwiftData

/// The tag-review sheet (wireframe frame 9): the day as a horizontal timeline — set blocks, clip
/// ticks — with the below-threshold clips floating to the top under "Needs you", the machine
/// reason rendered as each row's caption, Change › overrides, and one "keep all" for the auto
/// block. Review is NEVER homework: Later/Done both dismiss and every auto tag stands.
///
/// Carries its own `NavigationStack` (a sheet may, per the suite rule). All decisions come from
/// the pure `FestivalTagging` layer via `FestivalTagSync`; this view renders values and forwards
/// taps.
struct FestivalTagReviewView: View {
    let lineup: FestivalLineup
    let pack: FestivalPack
    /// Land on this poster day when it has clips (set detail passes its own day).
    var initialDay: String?
    /// The clips the user came from (Clips "Tag artist", prompt 172) — the one they were looking at first.
    /// Pinned in a highlighted "From Clips" card at the top, on their day, editable whatever their state
    /// (needs-you, auto-tagged, marked "Not from a set", or no set at that time).
    var focusMediaIDs: [UUID] = []

    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @Query private var tags: [FestivalClipTag]

    @State private var snapshot: FestivalTagSync.Snapshot?
    @State private var selectedDay: String?
    /// The row whose Change › dialog is up.
    @State private var changing: UUID?
    /// The clip whose "Pick another set…" list is up (prompt 172).
    @State private var pickingFor: UUID?

    init(lineup: FestivalLineup, pack: FestivalPack, initialDay: String? = nil, focusMediaIDs: [UUID] = []) {
        self.lineup = lineup
        self.pack = pack
        self.initialDay = initialDay
        self.focusMediaIDs = focusMediaIDs
        let packID = lineup.packID
        _tags = Query(filter: #Predicate<FestivalClipTag> { $0.packID == packID })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot, !snapshot.isEmpty {
                    content(snapshot)
                } else if snapshot != nil {
                    ContentUnavailableView {
                        Label("Nothing to tag yet", systemImage: "sparkles")
                    } description: {
                        Text("Film during a set — from the live sheet or straight from the Camera "
                             + "app — and your clips tag themselves to the artist.")
                    }
                } else {
                    ProgressView("Matching your clips…")
                }
            }
            .navigationTitle("Review tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                        .accessibilityIdentifier("festival.review.later")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("festival.review.done")
                }
            }
        }
        .task { await refresh(discover: true) }
        .sheet(item: Binding(get: { pickingFor.map(PickTarget.init) }, set: { pickingFor = $0?.id })) { t in
            setPicker(for: t.id)
        }
    }

    private struct PickTarget: Identifiable { let id: UUID }

    // MARK: - Content

    private func content(_ snap: FestivalTagSync.Snapshot) -> some View {
        let day = selectedDay ?? defaultDay(snap)
        let dayIDs = mediaIDs(on: day, snap)
        // Prompt 172: the clips the user came from are pinned up top, and not repeated in the lists below.
        let focus = focusMediaIDs.filter { snap.stamps[$0] != nil }
        let focusSet = Set(focus)
        let needs = snap.needsYou.filter { dayIDs.contains($0) && !focusSet.contains($0) }
        let autos = autoRows(on: dayIDs).filter { !focusSet.contains($0.mediaID) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !focus.isEmpty { focusCard(focus, snap: snap) }
                dayChips(snap)
                summary(day: day, clipCount: dayIDs.count, autoCount: autos.count,
                        needsYouCount: needs.count)
                timeline(day: day, snap: snap, needsYou: Set(needs))
                if !needs.isEmpty {
                    sectionHeader("Needs you")
                    ForEach(needs, id: \.self) { mediaID in
                        needsYouRow(mediaID, snap: snap)
                    }
                }
                if !autos.isEmpty {
                    sectionHeader("Auto-tagged") {
                        // Visible only while any row is still `auto` — keeping all makes them
                        // sticky `user` rows (they stay listed; the matcher just can't move them).
                        if autos.contains(where: { $0.source == .auto }) {
                            Button("Looks right · keep all") {
                                FestivalTagSync.keepAll(mediaIDs: autos.map(\.mediaID),
                                                        packID: lineup.packID, context: context)
                            }
                            .font(.caption.weight(.bold))
                            .tint(SnappetColor.festival)
                            .accessibilityIdentifier("festival.review.keepAll")
                        }
                    }
                    ForEach(autos, id: \.mediaID) { tag in
                        autoRow(tag, snap: snap)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
    }

    private func dayChips(_ snap: FestivalTagSync.Snapshot) -> some View {
        let days = daysWithClips(snap)
        return Group {
            if days.count > 1 {
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { date in
                        let on = date == (selectedDay ?? defaultDay(snap))
                        Button {
                            selectedDay = date
                        } label: {
                            Text(dayName(date))
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(on ? AnyShapeStyle(SnappetColor.festival)
                                               : AnyShapeStyle(SnappetColor.surfaceMuted),
                                            in: Capsule())
                                .foregroundStyle(on ? .white : SnappetColor.ink)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("festival.review.day.\(date)")
                    }
                }
            }
        }
    }

    private func summary(day: String?, clipCount: Int, autoCount: Int, needsYouCount: Int) -> some View {
        Text("\(day.map { dayName($0) + " · " } ?? "")"
             + FestivalTagging.summaryLine(clipCount: clipCount, autoCount: autoCount,
                                           needsYouCount: needsYouCount))
            .font(.caption.weight(.semibold))
            .foregroundStyle(SnappetColor.textSecondary)
            .accessibilityIdentifier("festival.review.summary")
    }

    /// The day-as-a-bar (frame 9): set blocks with clip ticks over them, needs-you ticks amber.
    @ViewBuilder
    private func timeline(day: String?, snap: FestivalTagSync.Snapshot, needsYou: Set<UUID>) -> some View {
        let sets = pack.days.first { $0.date == day }?.allSets ?? []
        let dayIDs = mediaIDs(on: day, snap)
        let layout = FestivalTagTimeline.layout(
            sets: sets,
            stamps: dayIDs.compactMap { snap.stamps[$0] },
            needsYou: needsYou)
        if !layout.blocks.isEmpty {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(layout.blocks) { block in
                        Text(block.artist)
                            .font(.system(size: 8, weight: .bold))
                            .lineLimit(1)
                            .foregroundStyle(SnappetColor.festival)
                            .padding(.horizontal, 3)
                            .frame(width: max(10, geo.size.width * block.width), height: 26,
                                   alignment: .leading)
                            .background(SnappetColor.festival.opacity(0.16),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .offset(x: geo.size.width * block.x, y: 10)
                    }
                    ForEach(layout.ticks) { tick in
                        Capsule()
                            .fill(tick.needsYou ? SnappetColor.perfModerate : SnappetColor.festival)
                            .frame(width: 3, height: 14)
                            .offset(x: geo.size.width * tick.x, y: 16)
                    }
                }
            }
            .frame(height: 46)
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
            .accessibilityIdentifier("festival.review.timeline")
        }
    }

    private func sectionHeader(_ title: String,
                               @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(SnappetColor.textSecondary)
                .kerning(1)
            Spacer()
            trailing()
        }
        .padding(.top, 2)
    }

    // MARK: Rows

    private func needsYouRow(_ mediaID: UUID, snap: FestivalTagSync.Snapshot) -> some View {
        let assignment = snap.assignments[mediaID]
        let stamp = snap.stamps[mediaID]
        return HStack(spacing: 10) {
            FestivalClipThumb(localIdentifier: snap.clipInfo[mediaID]?.localIdentifier,
                              isVideo: snap.clipInfo[mediaID]?.isVideo ?? true)
            VStack(alignment: .leading, spacing: 2) {
                if let stamp, let assignment {
                    Text("\(FestivalSchedule.timeLabel(stamp.captureDate, offsetSeconds: pack.utcOffsetSeconds))"
                         + " · \(FestivalTagging.caption(for: assignment.reason))")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(SnappetColor.textSecondary)
                }
                HStack(spacing: 6) {
                    Text(assignment?.set?.artist ?? "—")
                        .font(.subheadline.weight(.semibold))
                    if let assignment {
                        Text("\(FestivalTagging.percentLabel(assignment.confidence))"
                             + (FestivalTagging.alternativeLabel(for: assignment).map { " · \($0)" } ?? ""))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(SnappetColor.perfModerate)
                    }
                }
            }
            Spacer(minLength: 6)
            changeButton(mediaID, artist: assignment?.set?.artist)
        }
        .padding(10)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md)
            .strokeBorder(SnappetColor.perfModerate.opacity(0.5)))
    }

    private func autoRow(_ tag: FestivalClipTag, snap: FestivalTagSync.Snapshot) -> some View {
        HStack(spacing: 10) {
            FestivalClipThumb(localIdentifier: snap.clipInfo[tag.mediaID]?.localIdentifier,
                              isVideo: snap.clipInfo[tag.mediaID]?.isVideo ?? true)
            VStack(alignment: .leading, spacing: 2) {
                if let stamp = snap.stamps[tag.mediaID] {
                    Text("\(FestivalSchedule.timeLabel(stamp.captureDate, offsetSeconds: pack.utcOffsetSeconds))"
                         + " · \(tag.reason)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(SnappetColor.textSecondary)
                }
                HStack(spacing: 6) {
                    Text(tag.artist).font(.subheadline.weight(.semibold))
                    Text("✦ \(FestivalTagging.percentLabel(tag.confidence))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(SnappetColor.festival)
                }
            }
            Spacer(minLength: 6)
            changeButton(tag.mediaID, artist: tag.artist)
        }
        .padding(10)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md)
            .strokeBorder(SnappetColor.hairline))
    }

    /// Change › — a confirmationDialog (taps fire under XCUITest, the live-sheet precedent) over
    /// the assignment's own candidates, plus the "Not from a set" resolution.
    private func changeButton(_ mediaID: UUID, artist: String?) -> some View {
        Button("Change ›") { changing = mediaID }
            .font(.caption.weight(.bold))
            .tint(SnappetColor.festival)
            .accessibilityIdentifier("festival.review.change.\(artist ?? "clip")")
            .confirmationDialog("Which set is this clip from?",
                                isPresented: Binding(get: { changing == mediaID },
                                                     set: { if !$0 { changing = nil } }),
                                titleVisibility: .visible) {
                if let assignment = snapshot?.assignments[mediaID] {
                    ForEach(FestivalTagging.candidates(for: assignment)) { set in
                        Button("\(set.artist) · \(set.stage)") {
                            FestivalTagSync.resolve(mediaID: mediaID, to: set,
                                                    packID: lineup.packID, context: context)
                            Task { await refresh(discover: false) }
                        }
                    }
                }
                Button("Not from a set", role: .destructive) {
                    FestivalTagSync.resolveNotASet(mediaID: mediaID, packID: lineup.packID,
                                                   context: context)
                    Task { await refresh(discover: false) }
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    // MARK: - From Clips (prompt 172)

    /// The highlighted card for the clip(s) the user tapped "Tag artist" on.
    private func focusCard(_ ids: [UUID], snap: FestivalTagSync.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "play.square.stack").font(.caption2.weight(.bold))
                Text(ids.count == 1 ? "THE CLIP YOU TAPPED" : "FROM CLIPS · \(ids.count) CLIPS")
                    .font(.caption2.weight(.bold)).kerning(1)
            }
            .foregroundStyle(SnappetColor.festival)
            ForEach(ids, id: \.self) { focusRow($0, snap: snap) }
        }
        .padding(12)
        .background(SnappetColor.festival.opacity(0.08), in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md).strokeBorder(SnappetColor.festival, lineWidth: 2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("festival.review.focus")
    }

    private func focusRow(_ mediaID: UUID, snap: FestivalTagSync.Snapshot) -> some View {
        let tag = tags.first { $0.mediaID == mediaID }
        let assignment = snap.assignments[mediaID]
        let state: String = {
            if let tag, tag.isResolved { return "Tagged · \(tag.artist)" }
            if tag?.source == FestivalTagging.TagSource.none { return "Marked “Not from a set”" }
            if let a = assignment, let set = a.set {
                return "Best guess · \(set.artist) \(FestivalTagging.percentLabel(a.confidence))"
            }
            return "No set playing at this time"
        }()
        return HStack(spacing: 10) {
            FestivalClipThumb(localIdentifier: snap.clipInfo[mediaID]?.localIdentifier,
                              isVideo: snap.clipInfo[mediaID]?.isVideo ?? true)
            VStack(alignment: .leading, spacing: 2) {
                if let stamp = snap.stamps[mediaID] {
                    Text(FestivalSchedule.timeLabel(stamp.captureDate, offsetSeconds: pack.utcOffsetSeconds))
                        .font(.caption2.weight(.bold)).foregroundStyle(SnappetColor.textSecondary)
                }
                Text(state).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            Spacer(minLength: 6)
            Button("Change ›") { changing = mediaID }
                .font(.caption.weight(.bold))
                .tint(SnappetColor.festival)
                .accessibilityIdentifier("festival.review.focus.change")
                .confirmationDialog("Which set is this clip from?",
                                    isPresented: Binding(get: { changing == mediaID },
                                                         set: { if !$0 { changing = nil } }),
                                    titleVisibility: .visible) {
                    if let assignment {
                        ForEach(FestivalTagging.candidates(for: assignment)) { set in
                            Button("\(set.artist) · \(set.stage)") { resolve(mediaID, to: set) }
                        }
                    }
                    Button("Pick another set…") { pickingFor = mediaID }
                    Button("Not from a set", role: .destructive) {
                        FestivalTagSync.resolveNotASet(mediaID: mediaID, packID: lineup.packID, context: context)
                        Task { await refresh(discover: false) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
        }
        .padding(10)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private func resolve(_ mediaID: UUID, to set: FestivalSet) {
        FestivalTagSync.resolve(mediaID: mediaID, to: set, packID: lineup.packID, context: context)
        Task { await refresh(discover: false) }
    }

    /// Every set of the clip's day, nearest the moment it was filmed first (prompt 172).
    private func setPicker(for mediaID: UUID) -> some View {
        let capture = snapshot?.stamps[mediaID]?.captureDate ?? .now
        let day = pack.days.first { d in
            d.window(utcOffsetSeconds: pack.utcOffsetSeconds)?.contains(capture) == true
        }
        let sets = FestivalTagging.setsByProximity(day?.allSets ?? pack.allSets, to: capture)
        return NavigationStack {
            List(sets) { set in
                Button {
                    resolve(mediaID, to: set)
                    pickingFor = nil
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(set.artist).font(.subheadline.weight(.semibold)).foregroundStyle(SnappetColor.ink)
                            Text("\(set.stage) · \(FestivalSchedule.timeLabel(set.start, offsetSeconds: pack.utcOffsetSeconds))–"
                                 + FestivalSchedule.timeLabel(set.end, offsetSeconds: pack.utcOffsetSeconds))
                                .font(.caption).foregroundStyle(SnappetColor.textSecondary)
                        }
                        Spacer()
                        if set.start <= capture && capture <= set.end {
                            Text("PLAYING THEN").font(.caption2.weight(.bold)).foregroundStyle(SnappetColor.festival)
                        }
                    }
                }
                .accessibilityIdentifier("festival.review.pick.set")
            }
            .navigationTitle("Pick the set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pickingFor = nil } } }
        }
    }

    // MARK: - Derivation helpers (thin — the day math is the pack's)

    private func refresh(discover: Bool) async {
        snapshot = await FestivalTagSync.refresh(
            pack: pack, packID: lineup.packID, context: context,
            mediaService: discover ? app.sessionMedia : nil)
    }

    /// The day's RESOLVED tags (auto + kept/overridden), newest capture first — a kept tag stays
    /// listed rather than vanishing the moment "keep all" flips it sticky.
    private func autoRows(on dayIDs: Set<UUID>) -> [FestivalClipTag] {
        tags.filter { $0.isResolved && dayIDs.contains($0.mediaID) }
            .sorted {
                let a = snapshot?.stamps[$0.mediaID]?.captureDate ?? .distantPast
                let b = snapshot?.stamps[$1.mediaID]?.captureDate ?? .distantPast
                return a != b ? a > b : $0.mediaID.uuidString < $1.mediaID.uuidString
            }
    }

    private func daysWithClips(_ snap: FestivalTagSync.Snapshot) -> [String] {
        pack.days.map(\.date).filter { !mediaIDs(on: $0, snap).isEmpty }
    }

    private func defaultDay(_ snap: FestivalTagSync.Snapshot) -> String? {
        // From Clips (prompt 172): the day of the clip the user tapped.
        if let first = focusMediaIDs.first(where: { snap.stamps[$0] != nil }),
           let day = pack.days.map(\.date).first(where: { mediaIDs(on: $0, snap).contains(first) }) {
            return day
        }
        if let initialDay, !mediaIDs(on: initialDay, snap).isEmpty { return initialDay }
        let days = daysWithClips(snap)
        // The day that needs the user most, else the latest day with clips.
        return days.max { a, b in
            let an = snap.needsYou.filter { mediaIDs(on: a, snap).contains($0) }.count
            let bn = snap.needsYou.filter { mediaIDs(on: b, snap).contains($0) }.count
            return an != bn ? an < bn : a < b
        }
    }

    /// Media captured inside `day`'s rollover-to-rollover window.
    private func mediaIDs(on day: String?, _ snap: FestivalTagSync.Snapshot) -> Set<UUID> {
        guard let day,
              let window = pack.days.first(where: { $0.date == day })?
                  .window(utcOffsetSeconds: pack.utcOffsetSeconds) else { return [] }
        return Set(snap.stamps.filter { window.contains($0.value.captureDate) }.map(\.key))
    }

    private func dayName(_ date: String) -> String {
        guard let window = pack.days.first(where: { $0.date == date })?
            .window(utcOffsetSeconds: pack.utcOffsetSeconds) else { return date }
        return FestivalTagging.posterWeekday(
            for: window.start.addingTimeInterval(Double(FestivalDay.rolloverHour) * 3600),
            utcOffsetSeconds: pack.utcOffsetSeconds)
    }
}

/// A small poster thumb for review/set-detail rows: `AssetPosterLoader` when the asset resolves,
/// an honest placeholder otherwise (the simulator seed's sentinel identifiers land here).
struct FestivalClipThumb: View {
    let localIdentifier: String?
    var isVideo = true

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(SnappetColor.surfaceMuted)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 2)
            }
        }
        .frame(width: 46, height: 58)
        .task(id: localIdentifier) {
            guard let localIdentifier else { return }
            image = await AssetPosterLoader.poster(localIdentifier: localIdentifier,
                                                   pointSize: CGSize(width: 46, height: 58))
        }
    }
}
