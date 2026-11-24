import Foundation

/// Where a Photos video the Studio needs is right now (prompt 302). Reported per asset by the
/// device-only `StudioMediaAvailabilityService`; everything decided from it is pure and here.
enum StudioAssetStatus: Equatable, Sendable {
    /// On this phone: the composer can open it.
    case available
    /// Only in iCloud: it must be downloaded first.
    case inCloud
    /// Deleted from Photos, or Snappet is not allowed to see it. It cannot be downloaded.
    case missing
}

/// The pure availability plan for the Studio's media (prompt 302): which of the videos the
/// timeline needs are not on this phone, what the editor shows about it, and what is allowed
/// meanwhile. Foundation only; unit-tested in `StudioMediaPlanTests`.
///
/// It holds the inputs (`sources`, `statuses`) and the user's choices (`previewingWithout`, a
/// running `download`), and derives the rest, so it cannot disagree with itself.
struct StudioMediaPlan: Equatable {

    /// One video the render needs.
    struct Source: Equatable, Sendable {
        enum Role: Equatable, Sendable {
            /// A clip on the main track. `number` is its 1-based place among the visible clips.
            case clip(id: UUID, number: Int)
            /// The source of a picture-in-picture overlay.
            case pip(overlayID: UUID)
        }
        var role: Role
        var localIdentifier: String
    }

    /// A source that is not on this phone.
    struct Problem: Equatable, Sendable {
        var source: Source
        /// `.inCloud` or `.missing`, never `.available`.
        var status: StudioAssetStatus
    }

    /// A download in flight.
    struct Download: Equatable, Sendable {
        var localIdentifier: String
        /// 0…1, never moving back.
        var progress: Double
        /// Which request this is. Progress is reported through tasks that can arrive late, so a
        /// report carries its request's number and one from an earlier download is ignored
        /// (prompt 303).
        var request: Int = 0
    }

    /// Why the last download of one clip stopped. Tied to the clip, so the panel for another
    /// clip does not open already showing it (prompt 303).
    struct DownloadFailure: Equatable, Sendable {
        var localIdentifier: String
        var message: String
    }

    /// What the panel in the preview area shows for the first problem.
    struct Panel: Equatable, Sendable {
        var problem: Problem
        var title: String
        var message: String
        /// Offered for a clip in iCloud. A deleted clip has no download.
        var canDownload: Bool
        var canPreviewWithout: Bool
        var removeLabel: String
        /// The fraction done while this clip downloads, else `nil`.
        var downloadProgress: Double?
        /// Why the last download stopped, if it failed.
        var error: String?

        var downloadPercentLabel: String? {
            downloadProgress.map { "\(Int(($0 * 100).rounded(.down)))%" }
        }
    }

    private(set) var sources: [Source] = []
    private(set) var statuses: [String: StudioAssetStatus] = [:]
    /// The user chose "Preview without it": the editor is usable, the preview leaves the
    /// unavailable clips out, and export stays off.
    private(set) var previewingWithout = false
    private(set) var download: Download?
    private(set) var downloadFailure: DownloadFailure?
    /// The service has reported at least once. Until then nothing is known about where the
    /// videos are, and no preview is built: the composer would download an iCloud clip without a
    /// word (prompt 303).
    private(set) var isChecked = false

    /// The failed download's message, whichever clip it was for.
    var downloadError: String? { downloadFailure?.message }

    /// The videos the render needs, from the timeline: the video clips in timeline order
    /// (numbered as the picture-in-picture chooser numbers them), then the picture-in-picture
    /// sources. A picture-in-picture whose window starts at or after the end of the timeline is
    /// not drawn (`StudioGeometry.clampedWindow`), so it is not a source and cannot block the
    /// export (prompt 303). `total` of `nil` or `≤ 0` = length not known: every one counts.
    static func sources(clips: [TimelineClip], overlays: [OverlayItem], total: Double?) -> [Source] {
        var out: [Source] = clips.enumerated().compactMap { index, clip in
            clip.isPhoto ? nil : Source(role: .clip(id: clip.id, number: index + 1),
                                        localIdentifier: clip.localIdentifier)
        }
        out += overlays.filter { overlay in
            overlay.kind == .video && StudioGeometry.clampedWindow(
                start: overlay.startSec, end: overlay.endSec, total: total) != nil
        }.map { Source(role: .pip(overlayID: $0.id), localIdentifier: $0.content) }
        return out
    }

    // MARK: Derived

    /// An asset nobody has reported on is treated as available: the composer tries it, as it
    /// always did.
    func status(of localIdentifier: String) -> StudioAssetStatus {
        statuses[localIdentifier] ?? .available
    }

    /// The sources that are not on this phone, clips first (in timeline order), then PiP sources.
    var problems: [Problem] {
        sources.compactMap { source in
            let status = status(of: source.localIdentifier)
            return status == .available ? nil : Problem(source: source, status: status)
        }
    }

    /// The Photos identifiers the composer must not be handed.
    var unavailableIdentifiers: Set<String> { Set(problems.map(\.source.localIdentifier)) }

    var totalClips: Int {
        sources.filter { if case .clip = $0.role { return true } else { return false } }.count
    }
    var readyClips: Int {
        sources.filter {
            if case .clip = $0.role { return status(of: $0.localIdentifier) == .available }
            return false
        }.count
    }

    var allAvailable: Bool { problems.isEmpty }

    /// A preview can be made from what is here: at least one clip is on this phone.
    var canPreviewWithout: Bool { readyClips > 0 }

    /// Export and bake need every clip. The reason is shown next to the Export button.
    var exportBlockedReason: String? { allAvailable ? nil : "Export needs all clips" }

    /// The problem the panel is about: the first one, until the user chose to preview without it.
    var blocking: Problem? { previewingWithout ? nil : problems.first }

    /// The panel for the blocking problem, or `nil` when there is none.
    var panel: Panel? {
        guard let problem = blocking else { return nil }
        let downloading = download?.localIdentifier == problem.source.localIdentifier
        return Panel(problem: problem,
                     title: Self.title(for: problem, totalClips: totalClips),
                     message: Self.message(for: problem, ready: readyClips, total: totalClips),
                     canDownload: problem.status == .inCloud,
                     canPreviewWithout: canPreviewWithout,
                     removeLabel: Self.removeLabel(for: problem),
                     downloadProgress: downloading ? download?.progress : nil,
                     error: downloadFailure?.localIdentifier == problem.source.localIdentifier
                        ? downloadFailure?.message : nil)
    }

    /// The one line shown over the preview while it is made without some clips.
    var previewingWithoutNotice: String? {
        guard previewingWithout, let first = problems.first else { return nil }
        if problems.count > 1 { return "\(problems.count) clips are not in this preview" }
        switch first.source.role {
        case .clip(_, let number): return "Clip \(number) is not in this preview"
        case .pip: return "A picture-in-picture clip is not in this preview"
        }
    }

    // MARK: Transitions

    /// The timeline changed (an edit, undo, redo): the sources are read again. Statuses are kept
    /// by Photos identifier, so a clip that comes back with Undo is still known to be in iCloud.
    func settingSources(_ sources: [Source]) -> StudioMediaPlan {
        var p = self
        p.sources = sources
        return p.normalized()
    }

    /// The service reported on these assets.
    func checked(sources: [Source], statuses: [String: StudioAssetStatus]) -> StudioMediaPlan {
        var p = self
        p.sources = sources
        p.statuses.merge(statuses) { _, new in new }
        p.isChecked = true
        return p.normalized()
    }

    /// "Preview without it". Refused when nothing is here to preview.
    func previewingWithoutMissing() -> StudioMediaPlan {
        guard !problems.isEmpty, canPreviewWithout else { return self }
        var p = self
        p.previewingWithout = true
        return p
    }

    /// Back to the panel from "Preview without it".
    func showingOptions() -> StudioMediaPlan {
        var p = self
        p.previewingWithout = false
        return p
    }

    /// "Download clip". Only a clip in iCloud can be downloaded, and one at a time.
    /// `request` numbers this download; its progress reports carry the same number.
    func downloadBegan(_ localIdentifier: String, request: Int = 0) -> StudioMediaPlan {
        guard download == nil, status(of: localIdentifier) == .inCloud else { return self }
        var p = self
        p.download = Download(localIdentifier: localIdentifier, progress: 0, request: request)
        if p.downloadFailure?.localIdentifier == localIdentifier { p.downloadFailure = nil }
        return p
    }

    /// A progress report from download number `request`. One from another download is ignored.
    func downloadProgressed(_ fraction: Double, request: Int = 0) -> StudioMediaPlan {
        guard let current = download, current.request == request, fraction.isFinite else { return self }
        var p = self
        p.download = Download(localIdentifier: current.localIdentifier,
                              progress: max(current.progress, min(max(fraction, 0), 1)),
                              request: current.request)
        return p
    }

    /// The download ended and the clip is on this phone.
    func downloadFinished(_ localIdentifier: String) -> StudioMediaPlan {
        guard download?.localIdentifier == localIdentifier else { return self }
        var p = self
        p.download = nil
        if p.downloadFailure?.localIdentifier == localIdentifier { p.downloadFailure = nil }
        p.statuses[localIdentifier] = .available
        return p.normalized()
    }

    /// The download failed (no network, no space). The clip stays in iCloud and can be tried again.
    func downloadFailed(_ message: String) -> StudioMediaPlan {
        guard let current = download else { return self }
        var p = self
        p.download = nil
        p.downloadFailure = DownloadFailure(localIdentifier: current.localIdentifier, message: message)
        return p
    }

    /// The user cancelled: no message.
    func downloadCancelled() -> StudioMediaPlan {
        guard download != nil else { return self }
        var p = self
        p.download = nil
        return p
    }

    /// With no problem left there is nothing to preview "without". A download's error goes with
    /// its clip: once that clip is no longer a problem (downloaded, or removed from the video)
    /// there is nothing to show it on.
    private func normalized() -> StudioMediaPlan {
        var p = self
        let problems = p.problems
        if problems.isEmpty { p.previewingWithout = false }
        if let failed = p.downloadFailure?.localIdentifier,
           !problems.contains(where: { $0.source.localIdentifier == failed }) {
            p.downloadFailure = nil
        }
        return p
    }

    // MARK: Wording

    static let downloadFailedMessage = "The clip couldn't be downloaded. Check your connection and try again."

    static func title(for problem: Problem, totalClips: Int) -> String {
        let what: String
        switch problem.source.role {
        case .clip(_, let number): what = totalClips == 1 ? "This clip" : "Clip \(number)"
        case .pip: what = "A picture-in-picture clip"
        }
        return problem.status == .inCloud ? "\(what) is in iCloud" : "\(what) can't be found"
    }

    static func message(for problem: Problem, ready: Int, total: Int) -> String {
        let count = total > 1 ? "\(ready) of \(total) clips are ready. " : ""
        let name: String
        switch problem.source.role {
        case .clip(_, let number): name = total == 1 ? "it" : "clip \(number)"
        case .pip: name = "it"
        }
        switch problem.status {
        case .inCloud:
            return count + "Download \(name) to preview and export the whole video."
        case .missing, .available:
            return count + "It was deleted from Photos, or Snappet is not allowed to see it. "
                + "Remove \(name) to export the rest."
        }
    }

    static func removeLabel(for problem: Problem) -> String {
        switch problem.source.role {
        case .clip: return "Remove clip from video"
        case .pip: return "Remove picture-in-picture"
        }
    }

    /// The short mark on the clip's strip in the timeline.
    static func timelineLabel(for status: StudioAssetStatus) -> String? {
        switch status {
        case .available: return nil
        case .inCloud: return "iCloud"
        case .missing: return "Missing"
        }
    }

    /// What VoiceOver adds to the clip's label.
    static func accessibilityNote(for status: StudioAssetStatus) -> String? {
        switch status {
        case .available: return nil
        case .inCloud: return "in iCloud, not downloaded"
        case .missing: return "missing from Photos"
        }
    }
}

/// The parts of the timeline a "preview without it" leaves out, so the playhead can be mapped
/// between the timeline (which still shows every clip) and the shorter preview being played.
///
/// Transitions next to a left-out clip are not modelled: the preview is shorter by the clip's own
/// slot, and a cross-fade into it becomes a cut. The mapping is exact when no transition touches it.
struct StudioPreviewGaps: Equatable, Sendable {
    struct Gap: Equatable, Sendable {
        var start: Double
        var end: Double
        var length: Double { max(0, end - start) }
    }
    private(set) var gaps: [Gap] = []

    init() {}
    /// `slots` are the left-out clips' `[start, end)` on the timeline, in any order.
    init(slots: [(start: Double, end: Double)]) {
        gaps = slots.filter { $0.end > $0.start }
            .map { Gap(start: $0.start, end: $0.end) }
            .sorted { $0.start < $1.start }
    }

    var isEmpty: Bool { gaps.isEmpty }

    /// The length of what is played: the timeline without the gaps.
    func playableDuration(total: Double) -> Double {
        max(0, total - gaps.reduce(0) { $0 + $1.length })
    }

    /// The timeline position shown for a player position: every gap at or before it is skipped.
    func timelineTime(forPlayerTime playerTime: Double) -> Double {
        var t = max(0, playerTime)
        for gap in gaps where gap.start <= t { t += gap.length }
        return t
    }

    /// The player position for a timeline position. A position inside a gap maps to the cut where
    /// the gap was (the first frame after it).
    func playerTime(forTimelineTime timelineTime: Double) -> Double {
        var t = max(0, timelineTime)
        for gap in gaps.reversed() {
            if timelineTime >= gap.end { t -= gap.length } else if timelineTime > gap.start { t -= timelineTime - gap.start }
        }
        return max(0, t)
    }

    /// A window given in timeline time, in the player's time. `nil` when none of it is played
    /// (it lies inside a left-out clip).
    func playerWindow(start: Double, end: Double) -> (start: Double, end: Double)? {
        let s = playerTime(forTimelineTime: start), e = playerTime(forTimelineTime: end)
        return e > s ? (s, e) : nil
    }

    /// The project as the composer is handed it for a "preview without it" (prompt 303): the
    /// clips and picture-in-picture sources that are not on this phone are left out, and
    /// everything that carries a time on the timeline is moved to the shorter preview's time
    /// with the SAME mapping the playhead uses — overlay windows, picture-in-picture opacity
    /// keyframes, and where added music starts. Without this a picture-in-picture after the
    /// left-out clip showed late by that clip's length. A picture-in-picture that would only
    /// play inside a left-out clip is left out. Transitions are keyed by clip, not by time.
    /// Not exact: music that started before a left-out clip does not skip the same length.
    func playable(_ snapshot: StudioProjectSnapshot, unavailable: Set<String>) -> StudioProjectSnapshot {
        guard !unavailable.isEmpty || !isEmpty else { return snapshot }
        var s = snapshot
        s.clips.removeAll { !$0.isPhoto && unavailable.contains($0.localIdentifier) }
        s.overlays = snapshot.overlays.compactMap { overlay in
            if overlay.kind == .video, unavailable.contains(overlay.content) { return nil }
            guard !isEmpty else { return overlay }
            var ov = overlay
            if let window = playerWindow(start: overlay.startSec, end: overlay.endSec) {
                ov.startSec = window.start
                ov.endSec = window.end
            } else if overlay.kind == .video, overlay.endSec > overlay.startSec {
                return nil
            } else {
                ov.startSec = playerTime(forTimelineTime: overlay.startSec)
                ov.endSec = ov.startSec
            }
            ov.opacityKeyframes = overlay.opacityKeyframes.map { key in
                var key = key
                key.timeSec = playerTime(forTimelineTime: key.timeSec)
                return key
            }
            return ov
        }
        if !isEmpty {
            s.audioTracks = snapshot.audioTracks.map { track in
                var track = track
                track.startSec = playerTime(forTimelineTime: track.startSec)
                return track
            }
        }
        return s
    }
}

/// What the Studio says when the store could not be saved (prompt 302). Pure, so the wording and
/// the decision of what to show are tested.
enum StudioSaveFailure: Equatable, Sendable {
    /// An edit could not be saved. It is still in memory.
    case edit

    var message: String {
        switch self {
        case .edit:
            return "Your last change couldn't be saved. It is kept while the Studio is open, "
                + "and Snappet will try again with your next change."
        }
    }
}
