import SwiftUI
import SwiftData
import Photos

/// Detail for a completed session: summary stats, every exercise with its sets, and the
/// **tagged-media gallery** (B1) — the photos/videos shot during this workout, auto-discovered
/// by capture-time window and/or added by hand.
struct SessionDetailView: View {
    let session: WorkoutSession
    let resolver: ExerciseResolver
    let unit: WeightUnit

    var body: some View {
        List {
            Section {
                LabeledContent("Date") {
                    Text(session.startedAt, format: .dateTime.weekday().month().day().hour().minute())
                }
                LabeledContent("Duration", value: "\(max(1, Int(session.duration / 60))) min")
                LabeledContent("Sets completed", value: "\(session.completedSetCount)")
                let vol = WorkoutMath.sessionVolumeKg(session)
                if vol > 0 {
                    LabeledContent("Total volume", value: WorkoutMath.formatVolume(kg: vol, unit: unit))
                }
            }

            SessionMediaSection(session: session)

            ForEach(session.exercises) { ex in
                Section {
                    if ex.skipped {
                        Text("Skipped").foregroundStyle(.secondary).italic()
                    } else {
                        ForEach(Array(ex.sets.enumerated()), id: \.offset) { idx, set in
                            SetLogRow(index: idx + 1, set: set, unit: unit)
                        }
                    }
                } header: {
                    Text(resolver.name(for: ex.exerciseId, override: ex.displayName))
                }
            }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Tagged-media gallery (B1)

/// The "Media from this workout" section: a thumbnail grid ordered by `offsetSec`, an
/// "Add photos/videos" PHPicker, a "Find media from this workout" auto-discovery action,
/// and swipe-to-remove. Photos access is requested value-first (on first appear / on tap),
/// reusing `SessionMediaService` (→ `PhotoLibraryService.requestAccess`).
///
/// `.limited` access can't be scanned by time window, so auto-discovery is hidden and only
/// the PHPicker is offered (the suite-wide limited-access fallback). The simulator has no
/// Photos, so this renders its empty / "add media" state there.
private struct SessionMediaSection: View {
    let session: WorkoutSession

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    // Per-session media, ordered by capture offset. `#Predicate` on the `sessionID` FK
    // (the suite's per-parent query convention).
    @Query private var media: [SessionMedia]

    @State private var showingPicker = false
    @State private var isDiscovering = false
    @State private var didAutoDiscover = false
    @State private var message: String?

    init(session: WorkoutSession) {
        self.session = session
        let sid = session.id
        _media = Query(filter: #Predicate<SessionMedia> { $0.sessionID == sid },
                       sort: \SessionMedia.offsetSec, order: .forward)
    }

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]

    var body: some View {
        Section {
            if media.isEmpty {
                ContentUnavailableView {
                    Label("No media yet", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Add photos and videos you took during this workout, or find them automatically.")
                }
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(media) { item in
                        SessionMediaThumb(item: item)
                            .contextMenu {
                                Button(role: .destructive) { remove(item) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.vertical, 4)
            }

            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }

            Button {
                Task { await autoDiscover(prompt: true) }
            } label: {
                if isDiscovering {
                    HStack { ProgressView(); Text("Finding media…") }
                } else {
                    Label("Find media from this workout", systemImage: "sparkle.magnifyingglass")
                }
            }
            .disabled(isDiscovering)

            Button {
                Task { await ensureAccessThenPick() }
            } label: {
                Label("Add photos/videos", systemImage: "plus")
            }
        } header: {
            Text("Media from this workout")
        }
        .sheet(isPresented: $showingPicker) {
            MediaPicker { ids in addManual(ids) }
        }
        .task {
            // Auto-discover once when the detail first appears, but only silently — never
            // prompt unless the user already granted full access (value-first).
            guard !didAutoDiscover else { return }
            didAutoDiscover = true
            if app.sessionMedia.canAutoDiscover { await autoDiscover(prompt: false) }
        }
    }

    private var existingIdentifiers: Set<String> { Set(media.map(\.localIdentifier)) }

    /// Run auto-discovery. `prompt` requests Photos access value-first (on the explicit
    /// "Find media" tap); the silent on-appear pass passes `prompt: false`.
    @MainActor
    private func autoDiscover(prompt: Bool) async {
        message = nil
        if prompt, !app.sessionMedia.canAutoDiscover {
            let status = await app.sessionMedia.requestAccess()
            app.photoAccess = status
            if status == .limited {
                // Limited access can't scan the library by time window — fall back to the picker.
                message = "Limited Photo access — pick the clips by hand."
                showingPicker = true
                return
            }
            guard status == .authorized else {
                message = "Photo access is needed to find media from this workout."
                return
            }
        }
        guard app.sessionMedia.canAutoDiscover else { return }

        isDiscovering = true
        defer { isDiscovering = false }
        do {
            let found = try await app.sessionMedia.discover(
                startedAt: session.startedAt, completedAt: session.completedAt,
                existingIdentifiers: existingIdentifiers)
            insert(found, addedManually: false)
            if prompt { message = found.isEmpty ? "No photos or videos found in this workout's time window." : nil }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "Couldn't search your library."
        }
    }

    @MainActor
    private func ensureAccessThenPick() async {
        if app.sessionMedia.currentStatus == .notDetermined {
            app.photoAccess = await app.sessionMedia.requestAccess()
        }
        showingPicker = true
    }

    private func addManual(_ ids: [String]) {
        let cands = app.sessionMedia.candidates(
            forIdentifiers: ids, startedAt: session.startedAt,
            existingIdentifiers: existingIdentifiers)
        insert(cands, addedManually: true)
    }

    private func insert(_ candidates: [SessionMediaService.Candidate], addedManually: Bool) {
        guard !candidates.isEmpty else { return }
        for c in candidates {
            context.insert(SessionMedia(
                sessionID: session.id, localIdentifier: c.localIdentifier,
                kind: c.kind, offsetSec: c.offsetSec, durationSec: c.durationSec,
                addedManually: addedManually))
        }
        try? context.save()
    }

    private func remove(_ item: SessionMedia) {
        context.delete(item)
        try? context.save()
    }
}

/// One thumbnail: loads a `PHImageManager` image for the asset, with an offset badge
/// ("+Ns") and a play glyph for videos. Renders a placeholder where the asset is missing
/// (e.g. on the simulator, which has no Photos library).
private struct SessionMediaThumb: View {
    let item: SessionMedia
    @State private var image: UIImage?

    private let side: CGFloat = 88

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: item.kind == .video ? "video" : "photo")
                            .foregroundStyle(.secondary))
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.title3).foregroundStyle(.white)
                    .shadow(radius: 2)
                    .frame(width: side, height: side, alignment: .center)
            }

            Text(offsetBadge)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(4)
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel("\(item.kind == .video ? "Video" : "Photo") at \(offsetBadge)")
        .task(id: item.localIdentifier) { await loadThumbnail() }
    }

    private var offsetBadge: String { "+\(Int(item.offsetSec.rounded()))s" }

    private func loadThumbnail() async {
        guard image == nil else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [item.localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return }
        let target = CGSize(width: side * 3, height: side * 3)
        let options = PHImageRequestOptions()
        // `.highQualityFormat` delivers a single (final) callback, so the continuation
        // resumes exactly once — no degraded-then-final double-resume to guard against.
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false   // on-device only
        let manager = PHImageManager.default()
        let loaded: UIImage? = await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFill, options: options) { img, _ in
                continuation.resume(returning: img)
            }
        }
        if let loaded { image = loaded }
    }
}

private struct SetLogRow: View {
    let index: Int
    let set: SetLog
    let unit: WeightUnit

    var body: some View {
        HStack {
            Text("Set \(index)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            if set.completedAt != nil {
                Text(detailText).font(.subheadline.monospacedDigit())
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    private var detailText: String {
        let reps = set.actualReps.map { "\($0) reps" } ?? "done"
        if let w = set.actualWeight, w > 0 {
            let kg = WorkoutMath.toKg(w, set.weightUnit)
            return "\(WorkoutMath.formatWeight(kg: kg, unit: unit)) \(unit.display) × \(set.actualReps ?? 0)"
        }
        return reps
    }
}
