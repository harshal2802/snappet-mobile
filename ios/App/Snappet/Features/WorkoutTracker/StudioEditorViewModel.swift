import SwiftUI
import SwiftData
import AVFoundation

/// View model for the full-studio multi-clip editor (S1). Holds the `StudioProject` `@Model` and an
/// `UndoStack<StudioProjectSnapshot>`; every edit goes through the **pure** `StudioProjectEditor`
/// (so the logic is unit-tested) → commits to undo → writes the snapshot back to the `@Model` →
/// rebuilds the preview. The preview/export use the device-only `StudioComposer`; on the simulator
/// (no resolvable Photos assets) the player is nil and the view shows a device-only placeholder —
/// the timeline + all editing operations still work on the model.
@MainActor
@Observable
final class StudioEditorViewModel {
    let project: StudioProject
    private let context: ModelContext
    private let composer = StudioComposer()
    private var undo: UndoStack<StudioProjectSnapshot>

    var selectedClipID: UUID?
    private(set) var sourceDurations: [UUID: Double] = [:]
    var previewPlayer: AVPlayer?
    var isBuildingPreview = false
    var exportState: ExportShareState = .idle

    init(project: StudioProject, context: ModelContext) {
        self.project = project
        self.context = context
        undo = UndoStack(StudioProjectSnapshot(project))
    }

    // MARK: Derived

    var snapshot: StudioProjectSnapshot { undo.current }
    var clips: [TimelineClip] { StudioGeometry.ordered(snapshot.clips) }
    var canUndo: Bool { undo.canUndo }
    var canRedo: Bool { undo.canRedo }
    var selectedClip: TimelineClip? { clips.first { $0.id == selectedClipID } }
    var aspect: ClipEditGeometry.OutputAspect { snapshot.aspect }
    var totalDuration: Double {
        StudioGeometry.totalDuration(clips: snapshot.clips, sourceDurations: sourceDurations,
                                     transitions: snapshot.transitions)
    }
    func transitionKind(afterClipID: UUID) -> StudioTransitionKind {
        snapshot.transitions.first { $0.afterClipID == afterClipID }?.kind ?? .none
    }
    func outputDuration(of clip: TimelineClip) -> Double {
        StudioGeometry.clipOutputDuration(clip, sourceDuration: sourceDurations[clip.id])
    }

    // MARK: Lifecycle

    func onAppear() async {
        for clip in clips where !clip.isPhoto && sourceDurations[clip.id] == nil {
            if let d = await composer.sourceDuration(localIdentifier: clip.localIdentifier) {
                sourceDurations[clip.id] = d
            }
        }
        await rebuildPreview()
    }

    private func rebuildPreview() async {
        isBuildingPreview = true
        defer { isBuildingPreview = false }
        do {
            let (comp, vc) = try await composer.makeComposition(for: snapshot, sourceDurations: sourceDurations)
            let item = AVPlayerItem(asset: comp)
            item.videoComposition = vc
            previewPlayer = AVPlayer(playerItem: item)
        } catch {
            previewPlayer = nil   // device-only: no resolvable assets on the simulator
        }
    }

    // MARK: Edits (all via the pure StudioProjectEditor → undo → persist → rebuild)

    private func edit(_ transform: (StudioProjectSnapshot) -> StudioProjectSnapshot) {
        undo.commit(transform(undo.current))
        persist()
        Task { await rebuildPreview() }
    }
    func undoEdit() { undo.undo(); persist(); Task { await rebuildPreview() } }
    func redoEdit() { undo.redo(); persist(); Task { await rebuildPreview() } }
    private func persist() { undo.current.apply(to: project); try? context.save() }

    func select(_ id: UUID?) { selectedClipID = id }

    func deleteSelected() {
        guard let id = selectedClipID else { return }
        edit { StudioProjectEditor.removeClip($0, id: id) }
        selectedClipID = nil
    }
    func moveSelected(by delta: Int) {
        guard let id = selectedClipID, let idx = clips.firstIndex(where: { $0.id == id }) else { return }
        edit { StudioProjectEditor.moveClip($0, id: id, toIndex: idx + delta) }
    }
    /// Split the selected video clip at its midpoint (a playhead-driven split lands in S1's timeline polish).
    func splitSelected() {
        guard let clip = selectedClip, !clip.isPhoto else { return }
        let mid = outputDuration(of: clip) / 2
        edit { StudioProjectEditor.splitClip($0, id: clip.id, atOutputOffset: mid,
                                             sourceDuration: sourceDurations[clip.id]) }
    }
    func setSelectedSpeed(_ speed: Double) {
        guard let id = selectedClipID else { return }
        edit { StudioProjectEditor.setClipSpeed($0, id: id, speed: speed) }
    }
    func setSelectedFilter(_ filter: StudioFilter) {
        guard let id = selectedClipID else { return }
        edit { StudioProjectEditor.setClipFilter($0, id: id, filter: filter) }
    }
    func setTransitionAfterSelected(_ kind: StudioTransitionKind) {
        guard let id = selectedClipID else { return }
        edit { StudioProjectEditor.setTransition($0, afterClipID: id, kind: kind) }
    }
    func setAspect(_ aspect: ClipEditGeometry.OutputAspect) {
        edit { StudioProjectEditor.setAspect($0, aspect) }
    }
    func addText(_ string: String) {
        edit { StudioProjectEditor.addOverlay($0, OverlayItem(kind: .text, content: string)) }
    }

    // MARK: Export (device-only render)

    func export() async {
        exportState = .exporting
        do {
            let url = try await composer.export(snapshot, sourceDurations: sourceDurations)
            exportState = .exported(url)
        } catch {
            exportState = .failed((error as? LocalizedError)?.errorDescription ?? "Export failed.")
        }
    }
}
