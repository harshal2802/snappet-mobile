import Foundation
import HighlightEngine

/// The pure decision layer for the flagship reel flow's recovery + payoff surfaces (issue #72):
/// which copy and actions each dead-end shows (empty / Photos-denied / export-failed / Health
/// states), when a regenerate must be confirmed, where exported reels live on disk, and which old
/// renders to sweep. Foundation + engine only — no PhotoKit / HealthKit / UIKit — so every choice
/// here runs in `SnappetTests` with no simulator (the repo's "pure logic at a thin edge" rule).
enum ReelFlowPolicy {

    // MARK: - Inputs (platform-free mirrors, mapped at the view-model edge)

    /// Photo-library read access, collapsed from `PHAuthorizationStatus` by the caller.
    /// `.restricted` maps to `.denied` — the recovery (Settings) is the same surface.
    enum PhotoAccess: Equatable {
        case notDetermined, authorized, limited, denied
    }

    /// What a recovery surface can offer. Views map these to buttons; the policy decides which
    /// exist and in what order (first = primary).
    enum RecoveryAction: Hashable {
        /// Present the manual PHPicker (full-library browse). Only offered under `.authorized`:
        /// the picker itself presents without permission, but `media(forIdentifiers:)` resolves
        /// through `PHAsset.fetchAssets`, which returns nothing under full denial and only
        /// *granted* assets under `.limited` — picks outside a limited grant silently vanish, so
        /// limited surfaces offer `.extendLimitedSelection` instead (issue #72 verifier caveat +
        /// pre-merge review fix).
        case selectClips
        /// Present the system limited-library management sheet
        /// (`PHPhotoLibrary.presentLimitedLibraryPicker`) — the only surface that EXTENDS a
        /// `.limited` grant — then regenerate so the newly granted clips are auto-discovered by
        /// the session window. UIKit presentation stays in the view layer; the policy only
        /// decides *that* this is the limited remedy.
        case extendLimitedSelection
        /// Trigger the Photos authorization request (first ask, `.notDetermined`).
        case allowPhotoAccess
        /// Deep-link to the app's page in Settings. Photos toggles live there; Health read
        /// access does NOT (it's under Settings > Privacy & Security > Health > Snappet, or
        /// Health app > Profile > Apps) — Health surfaces keep this as a best-effort shortcut
        /// and their copy names the real path (pre-merge review fix).
        case openSettings
        /// Re-run the failed load / generate.
        case tryAgain
        /// Re-run the export — curation (pins / removals / order) is still in the view model.
        case retryExport
        /// Return to the editable `.ready` list without re-generating.
        case backToEdit
        /// Re-query HealthKit for workouts.
    }

    /// A fully-decided recovery surface: `ContentUnavailableView` copy + ordered actions.
    struct RecoverySpec: Equatable {
        let title: String
        let systemImage: String
        let message: String
        let actions: [RecoveryAction]
    }

    // MARK: - Reel screen: empty / failed states

    /// The reel's no-clips state, shaped by *why* there are no clips. Denial is the case the old
    /// screen got wrong twice: it surfaced as an action-less `.error`, and the natural remedy
    /// ("Select clips") cannot work without read access (see `RecoveryAction.selectClips`).
    static func emptyReelSpec(access: PhotoAccess) -> RecoverySpec {
        switch access {
        case .authorized:
            return RecoverySpec(
                title: "No clips for this workout",
                systemImage: "video.slash",
                message: "Snappet found no photos or videos shot during this session. You can pick clips yourself instead.",
                actions: [.selectClips])
        case .limited:
            // NOT `.selectClips`: PHPicker browses the full library but never widens the grant,
            // and `media(forIdentifiers:)` resolves only granted assets — picks outside the
            // selection would silently vanish and loop right back here. The limited-library
            // picker is the one surface that extends what Snappet can read.
            return RecoverySpec(
                title: "No clips for this workout",
                systemImage: "video.slash",
                message: "Snappet can only read the photos you’ve selected for it, and none were shot during this session. Select more clips for Snappet, or allow full access in Settings.",
                actions: [.extendLimitedSelection, .openSettings])
        case .denied:
            return RecoverySpec(
                title: "Photos access is off",
                systemImage: "photo.badge.exclamationmark",
                message: "Snappet can’t see the clips you shot because Photo access is denied. Allow access in Settings, then try again.",
                actions: [.openSettings, .tryAgain])
        case .notDetermined:
            return RecoverySpec(
                title: "Connect your Photos",
                systemImage: "photo.on.rectangle.angled",
                message: "Snappet needs Photo access to find the clips you shot during this session.",
                actions: [.allowPhotoAccess])
        }
    }

    // MARK: - Manual pick resolution (review fix — limited grants silently drop picks)

    /// What to do with a manual pick after identifier resolution. `PHAsset.fetchAssets` resolves
    /// only assets the app may read, so under a limited grant picks can vanish: silently building
    /// with fewer (or zero) clips looked like a no-op loop back to the same `.empty` screen.
    enum PickedMediaResolution: Equatable {
        /// Build with what resolved; `droppedCount > 0` ⇒ surface `pickedMediaShortfallNote`.
        case proceed(droppedCount: Int)
        /// Nothing resolved — show `pickedClipsUnavailableSpec()` instead of the generic empty.
        case allDropped
    }

    static func pickedMediaResolution(pickedCount: Int, resolvedCount: Int) -> PickedMediaResolution {
        if pickedCount > 0 && resolvedCount <= 0 { return .allDropped }
        return .proceed(droppedCount: max(0, pickedCount - resolvedCount))
    }

    /// The `.empty` surface when every picked clip failed to resolve: names the actual cause —
    /// the picks aren't in the Photos selection Snappet is allowed to read — instead of the
    /// generic no-clips copy, and routes to where it can be fixed.
    static func pickedClipsUnavailableSpec() -> RecoverySpec {
        RecoverySpec(
            title: "Snappet can’t read those clips",
            systemImage: "photo.badge.exclamationmark",
            message: "The clips you picked aren’t in the Photos selection Snappet is allowed to read, so none of them could be used. Allow more in Settings, then try again.",
            actions: [.openSettings, .tryAgain])
    }

    /// Footnote for a PARTIAL drop — the reel built, but not with everything the user picked.
    /// `nil` when nothing was dropped (the overwhelmingly common case stays clean).
    static func pickedMediaShortfallNote(droppedCount: Int) -> String? {
        guard droppedCount > 0 else { return nil }
        return droppedCount == 1
            ? "1 picked clip isn’t in the Photos selection Snappet can read, so the reel was built without it."
            : "\(droppedCount) picked clips aren’t in the Photos selection Snappet can read, so the reel was built without them."
    }

    /// A failed export is **recoverable**, not terminal: the curated edit is still in the view
    /// model, so the primary action retries with it intact and the secondary returns to the list.
    static func exportFailureSpec(message: String) -> RecoverySpec {
        RecoverySpec(
            title: "Export didn’t finish",
            systemImage: "exclamationmark.triangle",
            message: "\(message) Your pins, removals, and order are untouched.",
            actions: [.retryExport, .backToEdit])
    }

    /// Generate (load HR + media, run the engine) failed — offer to run it again.
    static func generateFailureSpec(message: String) -> RecoverySpec {
        RecoverySpec(
            title: "Couldn’t build the reel",
            systemImage: "exclamationmark.triangle",
            message: message,
            actions: [.tryAgain])
    }

    // MARK: - Regenerate confirmation

    /// Regenerating rebuilds from scratch — it wipes pins / removals / custom order and replaces
    /// the success screen. Returns the warning to confirm with, or `nil` when nothing of the
    /// user's would be lost (then regenerate runs directly, keeping the one-tap feel).
    /// `exportedUnsaved` = a rendered cut is on screen that hasn't been saved to Photos.
    static func regenerateConfirmation(pinnedCount: Int, removedCount: Int,
                                       hasCustomOrder: Bool, exportedUnsaved: Bool) -> String? {
        let hasCuration = pinnedCount > 0 || removedCount > 0 || hasCustomOrder
        switch (hasCuration, exportedUnsaved) {
        case (true, true):
            return "Regenerating rebuilds the reel from scratch — your pins, removals, and order are cleared, and this cut hasn’t been saved to Photos yet."
        case (true, false):
            return "Regenerating rebuilds the reel from scratch and clears your pins, removals, and custom order."
        case (false, true):
            return "This cut hasn’t been saved to Photos yet — making a new cut discards it. Save to Photos first to keep it."
        case (false, false):
            return nil
        }
    }

    // MARK: - Export destination (out of tmp, issue #72 §4)

    /// Finished reels land in `Application Support/Reels` — not `tmp`, which the system purges
    /// and which made backing out or "Make another cut" destroy the artifact.
    static let exportsDirectoryName = "Reels"

    /// How many previous renders survive a new export's sweep (the new file lands after the
    /// sweep, so up to `keepLatestExports + 1` files exist between exports). The kept files are
    /// an INTERNAL safety net only — nothing in the UI lists or reopens them — so user-facing
    /// copy must never imply a swept-but-kept export is retrievable; Save to Photos is the one
    /// durable home the copy promises (pre-merge review fix).
    static let keepLatestExports = 3

    static func exportsDirectory(under applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(exportsDirectoryName, isDirectory: true)
    }

    static func exportURL(in directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent("snappet-reel-\(id.uuidString).mp4")
    }

    /// Which existing renders to delete before a new export: everything beyond the newest
    /// `keepLatest`, ordered by modification date (path as a deterministic tie-break).
    static func sweepableExports(existing: [(url: URL, modifiedAt: Date)],
                                 keepLatest: Int = keepLatestExports) -> [URL] {
        guard existing.count > keepLatest else { return [] }
        let newestFirst = existing.sorted {
            $0.modifiedAt != $1.modifiedAt ? $0.modifiedAt > $1.modifiedAt : $0.url.path < $1.url.path
        }
        return newestFirst.dropFirst(keepLatest).map(\.url)
    }

}

extension ReelFlowPolicy.RecoveryAction {
    /// Button label — lives with the policy so the wording is test-asserted alongside the specs.
    var buttonTitle: String {
        switch self {
        case .selectClips: return "Select clips"
        case .extendLimitedSelection: return "Select more clips"
        case .allowPhotoAccess: return "Allow Photo access"
        case .openSettings: return "Open Settings"
        case .tryAgain: return "Try again"
        case .retryExport: return "Retry export"
        case .backToEdit: return "Back to my edit"
        }
    }

    /// accessibilityIdentifier suffix; each surface prefixes it ("reel" → "reelOpenSettings").
    var identifierSuffix: String {
        switch self {
        case .selectClips: return "SelectClips"
        case .extendLimitedSelection: return "ExtendSelection"
        case .allowPhotoAccess: return "AllowPhotoAccess"
        case .openSettings: return "OpenSettings"
        case .tryAgain: return "TryAgain"
        case .retryExport: return "RetryExport"
        case .backToEdit: return "BackToEdit"
        }
    }
}
