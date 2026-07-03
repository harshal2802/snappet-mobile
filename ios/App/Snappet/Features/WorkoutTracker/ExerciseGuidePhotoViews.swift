import SwiftUI

/// Shared render pieces for the downloaded exercise guide photos (`ExercisePhotoStore`):
/// the detail-view pager, the player's compact start/end strip, and the single async-decoded
/// photo they're built from. All of them render **nothing** when the pack isn't installed or
/// the exercise has no photos — the no-pack app is unchanged.

/// One guide photo, decoded off-main via the store's pack-slice read + NSCache.
/// Slot 0 = start position, slot 1 = end.
struct GuidePhotoView: View {
    let exerciseId: String
    let slot: Int
    var label: String?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .overlay(alignment: .topLeading) {
            if let label {
                Text(label)
                    .font(.caption2.weight(.bold)).tracking(0.5)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(SnappetColor.workout, in: Capsule())
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(8)
            }
        }
        .clipped()
        .task(id: "\(exerciseId)#\(slot)") {
            // Reset first: on identity reuse (e.g. the player advancing exercises) the old
            // exercise's photo must not linger while the new one decodes.
            image = nil
            let id = exerciseId, slot = slot
            image = await Task.detached(priority: .userInitiated) {
                ExercisePhotoStore.shared.photo(exerciseId: id, slot: slot)
            }.value
        }
    }

    /// One place owns the slot → badge mapping (pack convention: photos are start → end order).
    static func slotLabel(_ slot: Int, count: Int) -> String? {
        count >= 2 ? (slot == 0 ? "START" : "END") : nil
    }
}

/// The one rendering of the installer's in-flight download (shared by the exercise-detail CTA
/// and the Settings section, so progress presentation can't drift between them).
struct GuidePhotoInstallProgress: View {
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Downloading guide photos…").font(.callout)
            ProgressView(value: fraction)
        }
        .padding(.vertical, 2)
    }
}

/// The one rendering of a failed install/update (nothing when the phase isn't `.failed`).
struct GuidePhotoInstallError: View {
    let phase: ExercisePhotoInstaller.Phase

    var body: some View {
        if case .failed(let message) = phase {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}

/// The swipeable start→end pager at the top of the exercise detail.
struct GuidePhotoPager: View {
    let exerciseId: String
    let count: Int

    var body: some View {
        TabView {
            ForEach(0..<count, id: \.self) { slot in
                GuidePhotoView(exerciseId: exerciseId, slot: slot,
                               label: GuidePhotoView.slotLabel(slot, count: count))
            }
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .frame(height: 240)
        .accessibilityIdentifier("exercise.guidePhotos")
    }
}

/// The compact start/end thumbnail strip inside the player's "How to" card.
struct GuidePhotoStrip: View {
    let exerciseId: String

    private var count: Int {
        guard ExercisePhotoInstaller.shared.isInstalled else { return 0 }
        return ExercisePhotoStore.shared.photoCount(exerciseId: exerciseId)
    }

    var body: some View {
        let count = count
        if count > 0 {
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { slot in
                    GuidePhotoView(exerciseId: exerciseId, slot: slot,
                                   label: GuidePhotoView.slotLabel(slot, count: count))
                        .frame(width: 116, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: SnappetRadius.sm))
                }
            }
        }
    }
}
