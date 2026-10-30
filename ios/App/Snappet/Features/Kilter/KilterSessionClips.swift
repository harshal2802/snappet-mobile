import SwiftUI
import SwiftData

/// "Videos from this session" on the climb page + the "Tag clips" sheet (prompt 214, mockup
/// `docs/ux-research/design-system/kilter-climb.html`). Same data and actions as the session page — clips are
/// `SessionMedia` of the live session, auto-tagged by time to the climb being worked; tagging here is the
/// session page's "Move to climb" (manual source); "Find new clips" is its Photos search.

// MARK: - Pure tagging logic

enum KilterClipTagging {
    enum Filter: String, CaseIterable, Identifiable {
        case untagged, all, thisClimb
        var id: String { rawValue }
        var label: String {
            switch self {
            case .untagged: return "Untagged"
            case .all: return "All"
            case .thisClimb: return "This climb"
            }
        }
    }

    /// The items a filter shows. `assigned` is an item's current climb (nil = untagged).
    static func visible<T>(_ items: [T], _ filter: Filter, climbUUID: String, assigned: (T) -> String?) -> [T] {
        switch filter {
        case .all: return items
        case .untagged: return items.filter { assigned($0) == nil }
        case .thisClimb: return items.filter { assigned($0) == climbUUID }
        }
    }

    /// The assignment changes "Done" applies: a selected item not yet on this climb moves to it; an item that
    /// was on this climb and is no longer selected becomes untagged. Everything else is left alone.
    static func changes(current: [UUID: String?], selected: Set<UUID>, climbUUID: String) -> [UUID: String?] {
        var out: [UUID: String?] = [:]
        for (id, assigned) in current {
            let isHere = assigned == climbUUID
            if selected.contains(id), !isHere { out[id] = .some(climbUUID) }
            if !selected.contains(id), isHere { out[id] = .some(nil) }
        }
        return out
    }
}

// MARK: - Studio project (shared with the session page)

enum KilterStudioProjects {
    /// Find or create the session's `StudioProject` (seeded from its video clips in capture order), reconciling
    /// videos discovered after it was created so every clip is editable. One project per session, shared by every
    /// scope (moved from `KilterSessionDetailView` so the climb page opens the same editor).
    @MainActor static func resolve(_ session: KilterSession, media: [SessionMedia], in context: ModelContext) -> StudioProject {
        let sid = session.id
        if let existing = try? context.fetch(
            FetchDescriptor<StudioProject>(predicate: #Predicate { $0.sessionID == sid })).first {
            let present = Set(existing.clips.compactMap(\.sessionMediaID))
            // Posted reels are OUTPUT, not footage (highlights P5) — never reconciled into the timeline.
            let missing = media.filter { $0.kind == .video && !$0.isReel && !present.contains($0.id) }
                .sorted { $0.offsetSec < $1.offsetSec }
            if !missing.isEmpty {
                var order = (existing.clips.map(\.order).max() ?? -1) + 1
                for m in missing {
                    existing.clips.append(TimelineClip(
                        sessionMediaID: m.id, localIdentifier: m.localIdentifier,
                        isPhoto: false, order: order, trimEnd: m.durationSec))
                    order += 1
                }
                try? context.save()
            }
            return existing
        }
        let clips = media.filter { $0.kind == .video && !$0.isReel }
            .sorted { $0.offsetSec < $1.offsetSec }
            .enumerated()
            .map { i, m in
                TimelineClip(sessionMediaID: m.id, localIdentifier: m.localIdentifier,
                             isPhoto: false, order: i, trimEnd: m.durationSec)
            }
        let project = StudioProject(sessionID: sid, title: "Kilter session", clips: clips)
        context.insert(project)
        try? context.save()
        return project
    }
}

// MARK: - Tag clips sheet

struct KilterTagClipsSheet: View {
    let climbUUID: String
    let climbName: String
    /// This session's clips (reels excluded), newest first.
    let media: [SessionMedia]
    /// Climb names for clips tagged elsewhere ("Pinch Me").
    let climbNames: [String: String]
    let onFindNew: () async -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var filter: KilterClipTagging.Filter = .untagged
    @State private var finding = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This session · \(media.count) clip\(media.count == 1 ? "" : "s") · tap to tag to \(climbName)")
                        .snappetDetail()
                    HStack(spacing: 6) {
                        ForEach(KilterClipTagging.Filter.allCases) { f in
                            Button { filter = f } label: {
                                Text("\(f.label) \(count(f))").font(.system(size: 13.5)).snappetPill(selected: filter == f)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("kilter.tagClips.filter.\(f.rawValue)")
                        }
                    }
                    let shown = KilterClipTagging.visible(media, filter, climbUUID: climbUUID) { $0.assignedClimbUUID }
                    if shown.isEmpty {
                        Text(media.isEmpty ? "No clips from this session yet. Film on your phone, then Find new clips."
                             : filter == .untagged ? "Every clip from this session is tagged." : "No clips here yet.")
                            .multilineTextAlignment(.center)
                            .snappetDetail().frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
                            ForEach(shown) { tile($0) }
                        }
                    }
                    Text("A clip already on another climb moves here when you tap it — the same as “Move to climb” on the session page.")
                        .font(SnappetType.label).foregroundStyle(SnappetColor.textTertiary)
                    Button {
                        Task { finding = true; await onFindNew(); finding = false }
                    } label: {
                        Label(finding ? "Searching…" : "Find new clips in Photos", systemImage: "magnifyingglass")
                            .font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity)
                            .snappetPill(selected: false, large: true)
                    }
                    .buttonStyle(.plain).disabled(finding)
                    .accessibilityIdentifier("kilter.tagClips.find")
                }
                .padding()
            }
            .background(SnappetColor.paper)
            .navigationTitle("Tag clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply(); dismiss() }.accessibilityIdentifier("kilter.tagClips.done")
                }
            }
        }
        .onAppear { selected = Set(media.filter { $0.assignedClimbUUID == climbUUID }.map(\.id)) }
    }

    private func count(_ f: KilterClipTagging.Filter) -> Int {
        KilterClipTagging.visible(media, f, climbUUID: climbUUID) { $0.assignedClimbUUID }.count
    }

    private func tile(_ m: SessionMedia) -> some View {
        let on = selected.contains(m.id)
        let elsewhere = m.assignedClimbUUID.flatMap { $0 == climbUUID ? nil : (climbNames[$0] ?? "Another climb") }
        return Button {
            if on { selected.remove(m.id) } else { selected.insert(m.id) }
            Haptics.tap()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                SessionMediaThumb(item: m, side: 104)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? SnappetColor.brand : .clear, lineWidth: 2))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18)).foregroundStyle(on ? SnappetColor.brand : .white.opacity(0.8))
                            .padding(5)
                    }
                    .opacity(elsewhere != nil && !on ? 0.55 : 1)
                Text(on ? "This climb" : (elsewhere ?? "Untagged"))
                    .font(.system(size: 10.5)).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(m.kind == .video ? "Video" : "Photo"), \(on ? "tagged to this climb" : (elsewhere ?? "untagged"))")
        .accessibilityIdentifier("kilter.tagClips.tile")
    }

    private func apply() {
        let current = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0.assignedClimbUUID) })
        let changes = KilterClipTagging.changes(current: current, selected: selected, climbUUID: climbUUID)
        guard !changes.isEmpty else { return }
        for m in media {
            guard let new = changes[m.id] else { continue }
            m.assignedClimbUUID = new
            m.assignmentSource = new == nil ? .general : .manual
        }
        try? modelContext.save()
    }
}
