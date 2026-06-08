import SwiftUI
import SwiftData
import Charts
import HighlightEngine

/// The rich post-session (or live) summary for a Kilter board session: duration, send/attempt
/// counts, hardest send, a grade pyramid, heart-rate stats + zones (when HR was captured), a
/// per-climb timeline (time-on-climb / attempts / rest), and the session's media with a
/// one-tap **highlight reel** (reusing the same `HighlightEngine` + `ReelExporter` as WorkoutTracker).
///
/// All statistics are computed by the pure `KilterSessionStats` / `WorkoutHRStats` helpers — this
/// view does no math.
struct KilterSessionDetailView: View {
    let sessionID: UUID
    let board: KilterBoardController
    let sessions: KilterSessionManager

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext

    @Query private var allSessions: [KilterSession]
    @Query private var allEntries: [KilterLogEntry]
    @Query private var allMedia: [SessionMedia]

    @State private var importing = false
    /// Multi-clip Studio project for this session — all clip editing (trim/speed/crop/text/HR overlay)
    /// happens here, with a full-screen preview; tapping a clip opens it scoped to that clip (with a
    /// Climb panel), a per-climb "Edit all" opens its clips together, and the bottom button opens the
    /// whole session.
    @State private var clipStudio: ClipStudioPresentation?
    /// Present the shared reel editor (preview / pin / remove / reorder / export).
    @State private var showingReel = false

    /// A scoped presentation of the session's shared Studio. `visibleClipMediaIDs` filters the studio
    /// to one clip (per-clip) or a climb's clips (per-climb); `nil` is the whole session. A non-nil
    /// `climbUUID` shows the floating Climb panel; `singleClip` enables "Move clip to another climb".
    private struct ClipStudioPresentation: Identifiable {
        let id = UUID()
        let project: StudioProject
        let visibleClipMediaIDs: Set<UUID>?
        let focusClipMediaID: UUID?
        let climbUUID: String?
        let singleClip: SessionMedia?
    }

    private var session: KilterSession? { allSessions.first { $0.id == sessionID } }
    private var entries: [KilterLogEntry] { allEntries.filter { $0.sessionId == sessionID } }
    private var media: [SessionMedia] { allMedia.filter { $0.sessionID == sessionID } }

    private var stats: KilterSessionStats? {
        guard let session else { return nil }
        return KilterSessionStats.make(from: entries.map(KilterClimbLog.from),
                                       start: session.startedAt, end: session.endedAt ?? .now,
                                       hrSeries: session.hrSeries.map { HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) },
                                       maxHR: session.maxHR, restHR: session.restHR)
    }

    private var hrStats: WorkoutHRStats? {
        guard let session, !session.hrSeries.isEmpty else { return nil }
        return WorkoutHRStats.make(from: session.hrSeries,
                                   maxHR: session.maxHR ?? HeartRateZone.defaultMaxHR)
    }

    var body: some View {
        Group {
            if let session, let stats {
                ScrollView {
                    VStack(spacing: 22) {
                        header(session)
                        summaryGrid(stats)
                        if let hrStats { hrSection(hrStats) }
                        if !stats.pyramid.isEmpty { pyramidSection(stats) }
                        if !stats.timeline.isEmpty { timelineSection(stats) }
                        mediaSection(session)
                    }
                    .padding(.vertical)
                }
            } else {
                ContentUnavailableView("Session unavailable", systemImage: "clock.badge.questionmark")
            }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        // Opening the summary of a live session flushes HR so far onto it, so the HR chart + any clip
        // opened from here show heart rate during the session (not only after it ends). No-op once ended.
        .task(id: sessionID) { sessions.syncLiveHR(in: modelContext) }
        // Reel: the shared auto-generate-then-edit flow (now full-length, uncapped).
        .sheet(isPresented: $showingReel) {
            if let session {
                NavigationStack { ReelView(source: .kilterSession(session, media: media)) }
            }
        }
        // All clip editing happens in the full-screen Studio (big preview + trim/speed/crop/text/HR
        // overlay + multi-clip timeline), scoped to the tapped clip / climb / whole session, with a
        // floating Climb panel for the per-clip & per-climb scopes.
        .fullScreenCover(item: $clipStudio) { p in
            KilterClipStudio(project: p.project, context: modelContext,
                             visibleClipMediaIDs: p.visibleClipMediaIDs,
                             focusClipMediaID: p.focusClipMediaID,
                             sessionId: sessionID, climbUUID: p.climbUUID,
                             singleClip: p.singleClip, climbTargets: climbReassignTargets)
        }
    }

    // MARK: - Header

    @ViewBuilder private func header(_ session: KilterSession) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: session.source == "ble" ? "antenna.radiowaves.left.and.right" : "hand.tap")
                Text(session.source == "ble" ? "Board session" : "Manual session")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(session.angle)°").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Text(session.startedAt, format: .dateTime.weekday().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if session.isActive {
                    Label { Text(session.startedAt, style: .timer).monospacedDigit() }
                        icon: { Image(systemName: "record.circle").foregroundStyle(.green) }
                        .font(.caption.weight(.medium))
                } else {
                    Text(durationString(session.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if session.isActive {
                // Close by id, not the in-memory `current`, so this works even for a session recovered
                // after navigation/relaunch (where `current` may be a different/!nil reference).
                Button(role: .destructive) { sessions.end(sessionID: sessionID, in: modelContext) } label: {
                    Label("End session", systemImage: "stop.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("kilter.summary.end")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    // MARK: - Summary grid

    private func summaryGrid(_ s: KilterSessionStats) -> some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 12) {
            metric("\(s.sends)", "Sends", "checkmark.seal.fill", .green)
            metric("\(s.totalClimbs)", "Climbs", "figure.climbing", .primary)
            metric(s.hardestSendGrade.map { kilterGrade($0) } ?? "—", "Hardest", "flame.fill", .orange)
            metric("\(s.projects)", "Projects", "target", .blue)
            // Total tries across all climbs (matches the per-climb "N attempts" in the timeline) —
            // clearer than "climbs left unsent", which read as 0 after a worked climb was finally sent.
            metric("\(s.totalAttempts)", "Tries", "arrow.uturn.up", .secondary)
            metric(String(format: "%.1f", s.sendsPerHour), "Sends/hr", "speedometer", .secondary)
        }
        .padding(.horizontal)
    }

    private func metric(_ value: String, _ label: String, _ icon: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Heart rate

    @ViewBuilder private func hrSection(_ hr: WorkoutHRStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Heart rate", systemImage: "heart.fill")
                if let kind = session?.metricsSourceRaw.flatMap(MetricsSourceKind.init(rawValue:)) {
                    Text("via \(kind.title)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                hrStat("\(Int(hr.avgBpm))", "Avg")
                Divider().frame(height: 28)
                hrStat("\(Int(hr.maxBpm))", "Max")
                Divider().frame(height: 28)
                hrStat("\(Int(hr.minBpm))", "Min")
                // HR-based calorie estimate (Keytel) for BLE sessions with a complete profile — fills
                // the band's energy = 0; hidden for watch sessions / incomplete profiles (Phase 2).
                if let kcal = session?.kcalEstimate {
                    Divider().frame(height: 28)
                    hrStat("\(Int(kcal.rounded()))", "kcal est.")
                }
            }
            if let session, session.hrSeries.count > 1 {
                Chart(session.hrSeries, id: \.t) { p in
                    LineMark(x: .value("t", p.t), y: .value("bpm", p.bpm))
                        .foregroundStyle(.pink)
                        .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .frame(height: 120)
            }
            zoneBar(hr)
            if hr.totalSeconds > 0 {
                HStack {
                    hrStat(Self.redlineMinutesLabel(hr.redlineSeconds), "Redline")
                    Divider().frame(height: 28)
                    hrStat("\(Int((hr.redlineFraction * 100).rounded()))%", "At Z4+")
                    Divider().frame(height: 28)
                    hrStat("\(Int(hr.edwardsTRIMP.rounded()))", "Strain")
                }
                .accessibilityIdentifier("kilter.hr.load")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    /// Compact minutes/seconds label for the redline tile (mirrors the WorkoutTracker ZoneBar).
    private static func redlineMinutesLabel(_ seconds: Double) -> String {
        let mins = seconds / 60
        return mins >= 1 ? "\(Int(mins.rounded()))m" : "\(Int(seconds.rounded()))s"
    }

    private func hrStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    /// A stacked time-in-zone bar (recovery → max), each segment proportional to dwell time.
    @ViewBuilder private func zoneBar(_ hr: WorkoutHRStats) -> some View {
        let total = max(hr.totalSeconds, 1)
        let segments = hr.orderedZoneSeconds.filter { $0.seconds > 0 }
        if !segments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(segments, id: \.zone) { seg in
                            seg.zone.color
                                .frame(width: max(2, geo.size.width * seg.seconds / total))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                HStack(spacing: 10) {
                    ForEach(segments, id: \.zone) { seg in
                        HStack(spacing: 3) {
                            Circle().fill(seg.zone.color).frame(width: 7, height: 7)
                            Text(seg.zone.label).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Grade pyramid

    private func pyramidSection(_ s: KilterSessionStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Grade pyramid", systemImage: "chart.bar.fill")
            Chart(s.pyramid) { g in
                BarMark(x: .value("Sends", g.sends), y: .value("Grade", kilterGrade(g.gradeLabel)))
                    .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                    .annotation(position: .trailing) {
                        Text("\(g.sends)").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(s.pyramid.count) * 30 + 20)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    // MARK: - Per-climb timeline

    private func timelineSection(_ s: KilterSessionStats) -> some View {
        // First timeline index per climb, so a climb that repeats shows its media strip once.
        let firstIndexForClimb = Dictionary(s.timeline.map { ($0.climbUUID, $0.index) },
                                            uniquingKeysWith: min)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Climbs", systemImage: "list.bullet")
                if let median = s.medianTimeOnClimb {
                    Text("median \(durationString(median))/climb")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(s.timeline) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: statusIcon(item.status))
                            .foregroundStyle(item.status.isSend ? .green : .orange)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.climbName).font(.subheadline).lineLimit(1)
                            Text(kilterGrade(item.gradeLabel)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            if let t = item.timeOnClimb {
                                Label(durationString(t), systemImage: "stopwatch")
                                    .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                            }
                            if item.attempts > 1 {
                                Text("\(item.attempts) attempts").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let rest = item.restBefore, rest > 30 {
                        Text("rested \(durationString(rest))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    effortRow(item)
                    // The photos/videos shot while working this climb (auto-tagged by time window).
                    if firstIndexForClimb[item.climbUUID] == item.index {
                        climbMediaStrip(climbUUID: item.climbUUID)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    /// Per-climb HR effort + recovery (shared `HREffortBadge`, identical to the WorkoutTracker per-set
    /// badge) plus the rest HRV before the climb (shared `HRVBadge`, Phase 3). Hidden entirely when the
    /// climb wasn't scored and no rest HRV exists (HR-less session / no recorded start / untrusted RR).
    @ViewBuilder private func effortRow(_ item: KilterSessionStats.TimelineItem) -> some View {
        if item.peakBpm != nil || item.restHRV.rmssd != nil {
            HStack(spacing: 10) {
                if item.peakBpm != nil {
                    HREffortBadge(
                        effort: ClimbEffort(peakBpm: item.peakBpm, peakHRR: item.peakHRR, hrRise: item.hrRise,
                                            timeToPeak: item.timeToPeak, hrRecovery60: item.hrRecovery60,
                                            hrRecovery30: item.hrRecovery30),
                        maxHR: session?.maxHR ?? HeartRateZone.defaultMaxHR)
                        .accessibilityIdentifier("kilter.climb.effort")
                }
                HRVBadge(hrv: item.restHRV)
            }
        }
    }

    /// A horizontal strip of the clips tagged to one climb. Tap a video to edit just that clip;
    /// long-press to move it to another climb or remove it. When the climb has ≥2 video clips, an
    /// "Edit all · N" button opens them together in one scoped studio.
    @ViewBuilder private func climbMediaStrip(climbUUID: String) -> some View {
        let clips = KilterMediaGrouping.clips(for: climbUUID, in: media,
                                              climbUUIDOf: { $0.assignedClimbUUID }, offsetOf: { $0.offsetSec })
        if !clips.isEmpty {
            let videoCount = clips.filter { $0.kind == .video }.count
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(clips) { mediaThumb($0) } }
                    }
                    .accessibilityIdentifier("kilter.climbMedia")
                    if videoCount >= 2 {
                        Button { editAllClips(forClimb: climbUUID) } label: {
                            Label("Edit all · \(videoCount)", systemImage: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .labelStyle(.titleOnly)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("kilter.climbMedia.editAll")
                    }
                }
            }
        }
    }

    private func mediaThumb(_ clip: SessionMedia) -> some View {
        SessionMediaThumb(item: clip, side: 64)
            .onTapGesture { editClip(clip) }
            .contextMenu { clipMenu(clip) }
    }

    @ViewBuilder private func clipMenu(_ clip: SessionMedia) -> some View {
        if clip.kind == .video {
            Button { editClip(clip) } label: { Label("Edit in studio", systemImage: "slider.horizontal.3") }
        }
        Menu {
            ForEach(climbTargets) { t in
                Button(t.name) { reassign(clip, to: t.uuid) }
            }
            Divider()
            Button("Unassigned") { reassign(clip, to: nil) }
        } label: { Label("Move to climb…", systemImage: "arrow.left.arrow.right") }
        Button(role: .destructive) { remove(clip) } label: { Label("Remove", systemImage: "trash") }
    }

    // MARK: - Media + highlight reel

    @ViewBuilder private func mediaSection(_ session: KilterSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Media & reel", systemImage: "film.stack")
            let videoCount = media.filter { $0.kind == .video }.count
            let photoCount = media.count - videoCount
            if media.isEmpty {
                Text("Photos and videos you film during the session show up here, tagged to the climb you were on.")
                    .font(.caption).foregroundStyle(.secondary)
                findClipsButton
            } else {
                Text("\(videoCount) video\(videoCount == 1 ? "" : "s")"
                     + (photoCount > 0 ? " · \(photoCount) photo\(photoCount == 1 ? "" : "s")" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                // Clips that fell outside every climb's window (the General bucket) — still editable.
                let unassigned = KilterMediaGrouping.unassigned(in: media,
                    climbUUIDOf: { $0.assignedClimbUUID }, offsetOf: { $0.offsetSec })
                if !unassigned.isEmpty {
                    Text("Unassigned").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(unassigned) { mediaThumb($0) } }
                    }
                }
                Button { showingReel = true } label: {
                    Label("Highlight reel", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(SnappetColor.moduleAccent("kilter"))
                .disabled(videoCount == 0)
                .accessibilityIdentifier("kilter.summary.generateReel")
                Button { presentStudio(session, visible: nil, focusing: nil, climbUUID: nil, single: nil) } label: {
                    Label("Open studio (multi-clip)", systemImage: "film.stack").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(videoCount == 0)
                .accessibilityIdentifier("kilter.summary.studio")
                findClipsButton
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    /// Re-run media discovery (after granting full Photos access, or to pick up clips filmed since).
    private var findClipsButton: some View {
        Button {
            Task {
                importing = true
                _ = await app.sessionMedia.requestAccess()
                sessions.importMedia(forSessionID: sessionID, in: modelContext)
                importing = false
            }
        } label: {
            Label(importing ? "Searching…" : "Find my clips", systemImage: "photo.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).disabled(importing)
    }

    // MARK: - Media mutations + studio

    private struct ClimbTarget: Identifiable { let uuid: String; let name: String; var id: String { uuid } }

    /// Unique climbs in this session, as reassignment targets ("Move to climb…").
    private var climbTargets: [ClimbTarget] {
        guard let stats else { return [] }
        var seen = Set<String>()
        return stats.timeline.compactMap { item in
            seen.insert(item.climbUUID).inserted ? ClimbTarget(uuid: item.climbUUID, name: item.climbName) : nil
        }
    }

    /// The same targets in the shape the Climb panel's "Move clip" menu expects.
    private var climbReassignTargets: [KilterClimbTarget] {
        climbTargets.map { KilterClimbTarget(uuid: $0.uuid, name: $0.name) }
    }

    private func reassign(_ clip: SessionMedia, to climbUUID: String?) {
        clip.assignedClimbUUID = climbUUID
        clip.assignmentSource = climbUUID == nil ? .general : .manual
        try? modelContext.save()
    }

    private func remove(_ clip: SessionMedia) {
        modelContext.delete(clip)
        try? modelContext.save()
    }

    /// Tap a clip → open the studio **scoped to just that clip** (big preview), with the Climb panel
    /// for the clip's climb. Videos only — photos aren't clip-editable.
    private func editClip(_ clip: SessionMedia) {
        guard clip.kind == .video, let session else { return }
        presentStudio(session, visible: [clip.id], focusing: clip.id,
                      climbUUID: clip.assignedClimbUUID, single: clip)
    }

    /// "Edit all · N" on a climb's strip → open the studio scoped to that climb's video clips together,
    /// with the Climb panel for the climb.
    private func editAllClips(forClimb climbUUID: String) {
        guard let session else { return }
        let ids = Set(climbVideoClips(climbUUID).map(\.id))
        presentStudio(session, visible: ids, focusing: nil, climbUUID: climbUUID, single: nil)
    }

    /// The video clips tagged to one climb, in capture order (the "Edit all" set / its count).
    private func climbVideoClips(_ climbUUID: String) -> [SessionMedia] {
        KilterMediaGrouping.clips(for: climbUUID, in: media,
                                  climbUUIDOf: { $0.assignedClimbUUID }, offsetOf: { $0.offsetSec })
            .filter { $0.kind == .video }
    }

    /// Build the scoped presentation over this session's shared `StudioProject`. `visible` filters the
    /// studio (nil = whole session); a non-nil `climbUUID` shows the Climb panel; `single` enables
    /// "Move clip to another climb".
    private func presentStudio(_ session: KilterSession, visible: Set<UUID>?, focusing: UUID?,
                               climbUUID: String?, single: SessionMedia?) {
        // Flush live HR onto the session before the clip editor reads it, so a clip opened DURING the
        // session shows heart rate (the editor loads the series once, on open). No-op once ended.
        sessions.syncLiveHR(in: modelContext)
        let project = resolveStudioProject(session)
        clipStudio = ClipStudioPresentation(project: project, visibleClipMediaIDs: visible,
                                            focusClipMediaID: focusing, climbUUID: climbUUID,
                                            singleClip: single)
    }

    /// Find or create this session's `StudioProject` (seeded from its video clips in capture order),
    /// reconciling any videos discovered after it was created so every clip is editable. Returns the
    /// one project all scopes share — the same one the workout side uses.
    private func resolveStudioProject(_ session: KilterSession) -> StudioProject {
        let sid = session.id
        if let existing = try? modelContext.fetch(
            FetchDescriptor<StudioProject>(predicate: #Predicate { $0.sessionID == sid })).first {
            let present = Set(existing.clips.compactMap(\.sessionMediaID))
            let missing = media.filter { $0.kind == .video && !present.contains($0.id) }
                .sorted { $0.offsetSec < $1.offsetSec }
            if !missing.isEmpty {
                var order = (existing.clips.map(\.order).max() ?? -1) + 1
                for m in missing {
                    existing.clips.append(TimelineClip(
                        sessionMediaID: m.id, localIdentifier: m.localIdentifier,
                        isPhoto: false, order: order, trimEnd: m.durationSec))
                    order += 1
                }
                try? modelContext.save()
            }
            return existing
        }
        let clips = media.filter { $0.kind == .video }
            .sorted { $0.offsetSec < $1.offsetSec }
            .enumerated()
            .map { i, m in
                TimelineClip(sessionMediaID: m.id, localIdentifier: m.localIdentifier,
                             isPhoto: false, order: i, trimEnd: m.durationSec)
            }
        let project = StudioProject(sessionID: sid, title: "Kilter session", clips: clips)
        modelContext.insert(project)
        try? modelContext.save()
        return project
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Re-render a stored combined grade label per the user's format preference.
    private func kilterGrade(_ label: String) -> String {
        let raw = UserDefaults.standard.string(forKey: "kilter.gradeFormat") ?? KilterGradeFormat.both.rawValue
        return kilterDisplayGrade(label, KilterGradeFormat(rawValue: raw) ?? .both)
    }

    private func statusIcon(_ status: KilterAscentStatus) -> String {
        switch status {
        case .flash: return "bolt.fill"
        case .sent: return "checkmark"
        case .project: return "target"
        case .attempt: return "arrow.uturn.up"
        }
    }

    /// Elapsed/duration as `H:MM:SS` (or `M:SS`) — reuses the app's single formatter so the climbing
    /// summary never drifts from the rest of the app.
    private func durationString(_ seconds: TimeInterval) -> String {
        WorkoutLiveSnapshot.elapsedString(seconds)
    }
}
