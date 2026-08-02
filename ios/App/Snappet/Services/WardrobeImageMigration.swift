import SwiftUI
import SwiftData
import UIKit

// One-time reclaim for closets captured before wardrobe prompt 03 (see that prompt for the
// measurement: 97 cut-outs averaging 10.4 MB, 1.01 GB for 100 garments, because capture stored
// the background-removed cut-out as a full-resolution lossless RGBA PNG).
//
// Two deliberate properties, both load-bearing:
//
// 1. **State is derived from the data, never from a flag.** An item needs work iff it has no
//    thumbnail or its master is over the policy cap. That makes the migration idempotent,
//    resumable after the app is killed mid-run, and self-healing after a backup restore (which
//    brings back masters but no thumbnails, by design).
// 2. **Strictly one item at a time, inside an `autoreleasepool`.** Each pass decodes a ~34 MB
//    bitmap; batching them is precisely how this would OOM on the device it is meant to fix.

/// Rewrites oversized closet photos in place and backfills missing thumbnails.
@MainActor
@Observable
final class WardrobeImageMigration {
    /// Where the run is up to — drives the progress banner on the Wardrobe home.
    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int)
        /// Finished this session, with the bytes reclaimed (0 when there was nothing to do).
        case finished(reclaimedBytes: Int)
    }

    private(set) var phase: Phase = .idle

    /// The in-flight run. Held here — as an UNSTRUCTURED task — rather than driven by a view's
    /// `.task` modifier, which SwiftUI cancels the moment that view disappears. Hanging the run
    /// off `WardrobeRootView.task` meant tapping "See all ›" into the closet (the single most
    /// likely next tap) cancelled the migration partway: measured on-device, it stopped at item
    /// 31 of 100 and left the other 69 rendering placeholder tiles. This object is `@State` on
    /// the root, which survives the push, so the work outlives the navigation.
    private var run: Task<Void, Never>?

    /// Does this item still need a pass? Also the migration's termination condition, so it must
    /// agree with what `prepare` actually produces — `WardrobeImagePolicyTests` pins that.
    nonisolated static func needsWork(_ item: WardrobeItem) -> Bool {
        guard let data = item.imageData else { return false }   // no photo, nothing to derive
        if item.thumbnailData == nil { return true }
        guard let size = WardrobeImageStore.pixelSize(of: data) else { return false }
        return WardrobeImagePolicy.needsDownscale(size, maxEdge: WardrobeImagePolicy.displayMaxEdge)
    }

    /// Kick off a run if one isn't already going. Fire-and-forget: safe to call on every
    /// appearance, and deliberately NOT awaited by the caller so no view lifecycle owns it.
    func start(in context: ModelContext) {
        guard run == nil else { return }
        run = Task { [weak self] in
            await self?.runIfNeeded(in: context)
            self?.run = nil
        }
    }

    /// Scan the closet and re-encode whatever is over the line. When there is nothing to do it
    /// costs one fetch and returns without touching `phase`.
    func runIfNeeded(in context: ModelContext) async {
        let pending: [WardrobeItem]
        do {
            pending = try context.fetch(FetchDescriptor<WardrobeItem>())
                .filter(Self.needsWork)
        } catch {
            return
        }
        guard !pending.isEmpty else { return }

        var reclaimed = 0
        phase = .running(done: 0, total: pending.count)

        for (index, item) in pending.enumerated() {
            if Task.isCancelled { break }
            reclaimed += await migrate(item)
            // Save per item, not per run: a kill mid-migration then keeps the work already done.
            try? context.save()
            phase = .running(done: index + 1, total: pending.count)
            // Yield so the closet stays scrollable while this grinds through a big closet.
            await Task.yield()
        }

        // The masters just changed underneath any cached decode.
        WardrobeImageCache.removeAll()
        phase = .finished(reclaimedBytes: reclaimed)
    }

    /// Re-encode one item. Returns the bytes reclaimed (never negative — if the "smaller" encode
    /// somehow came out bigger we keep the original master and only take the thumbnail).
    private func migrate(_ item: WardrobeItem) async -> Int {
        guard let original = item.imageData else { return 0 }
        let isCutout = WardrobeImageStore.hasAlpha(original)

        let prepared = await Task.detached(priority: .utility) {
            autoreleasepool {
                guard let image = UIImage(data: original) else { return nil as WardrobeImageStore.Prepared? }
                return WardrobeImageStore.prepare(image: image, isCutout: isCutout)
            }
        }.value

        guard let prepared else {
            // Undecodable blob: don't leave it as permanent pending work that re-runs forever.
            item.thumbnailData = Data()
            return 0
        }

        item.thumbnailData = prepared.thumbnail
        guard prepared.display.count < original.count else { return 0 }
        item.imageData = prepared.display
        return original.count - prepared.display.count
    }
}

/// The progress banner shown on the Wardrobe home while the reclaim runs, and the one-shot
/// "freed N MB" confirmation after. Silent when there was never any work to do.
struct WardrobeMigrationBanner: View {
    let phase: WardrobeImageMigration.Phase
    var onDismiss: () -> Void

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case let .running(done, total):
            banner {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Optimizing closet photos…")
                            .font(.caption.weight(.bold))
                        Text("\(done) of \(total)")
                            .font(.caption2)
                            .foregroundStyle(SnappetColor.textSecondary)
                    }
                    Spacer()
                }
            }
        case let .finished(reclaimed):
            if reclaimed > 0 {
                banner {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(SnappetColor.wardrobe)
                        Text("Freed \(reclaimed.formatted(.byteCount(style: .file))) of storage")
                            .font(.caption.weight(.bold))
                        Spacer()
                        Button("Done", action: onDismiss)
                            .font(.caption.weight(.bold))
                            .buttonStyle(.plain)
                            .foregroundStyle(SnappetColor.wardrobe)
                    }
                }
                .accessibilityIdentifier("wardrobe.migration.done")
            }
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(SnappetColor.hairline))
            .padding(.horizontal, 16)
            .accessibilityIdentifier("wardrobe.migration.banner")
    }
}
