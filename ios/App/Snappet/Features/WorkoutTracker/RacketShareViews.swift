import SwiftUI

// MARK: - Racket player, Share (prompt 254, issue #448 part 1 "Share")
//
// Boards ShareSheet and ShareExport: This rally / Rallies only / Whole game; Apply the look, Score and rally labels
// (drawn into the copy), Keep the speed; "12 rallies · 1:38 · about 96 MB"; Share makes a new copy (progress, Cancel;
// on failure nothing is lost: Try again or a smaller size), then the system share sheet. The plan is pure
// (`RacketSharePlan`); `RacketVideoLibrary.export` makes the copy. The original in Photos is never changed.

struct RacketShareSheet: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    let position: Double
    let rate: Float
    let look: RacketLook

    @Environment(\.dismiss) private var dismiss
    @State private var which: RacketShareWhich = .ralliesOnly
    @State private var applyLook = true
    @State private var labels = true
    @State private var keepSpeed = false
    @State private var fraction: Double?
    @State private var failure: String?
    @State private var work: Task<Void, Never>?
    @State private var shareURL: URL?
    @State private var configured = false
    /// UI tests only (`-uiTestShareName`): the last copy's size as any player shows it ("960×540"), shown when Share is
    /// opened again (the system share sheet covers this sheet, then closes it).
    @State private var madeSize: String?
    @MainActor static var lastMadeSize: String?

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }
    private var rallies: [RacketRally] {
        (ex?.racketRecordingLog?.rallies(ref.startSec, ref.endSec) ?? []).filter(\.isRally)
    }
    private var sides: (us: String, them: String) { RacketWatchCopy.sides(opponent: ex?.opponent, doubles: ex?.isDoubles ?? false) }
    private var quality: RacketRecordingQuality? { ex?.racketRecordingLog?.qualityRaw.flatMap(RacketRecordingQuality.init(rawValue:)) }

    private func plan(_ w: RacketShareWhich) -> RacketSharePlan? {
        RacketSharePlan.make(w, rallies: rallies, position: position, partStart: ref.startSec, partEnd: ref.endSec,
                             rate: rate, keepSpeed: keepSpeed, labels: labels, sides: sides, quality: quality,
                             skipping: ex?.racketRecordingLog?.timeouts(from: ref.startSec, to: ref.endSec) ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let fraction, let p = plan(which) {
                exporting(p, fraction)
            } else {
                form
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.07).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(SnappetColor.brand)
        .presentationDetents([.height(470)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(fraction != nil)
        // ShareSheet / ShareExport are portrait boards: upright however the phone is held.
        .portraitOnly()
        .sheet(item: Binding(get: { shareURL.map(URLBox.init) }, set: { shareURL = $0?.url })) { box in
            ShareSheet(items: [box.url]) { _, _ in dismiss() }
        }
        .onAppear {
            guard !configured else { return }
            configured = true
            #if DEBUG
            madeSize = Self.lastMadeSize
            #endif
            which = rallies.isEmpty ? .whole : .ralliesOnly
            applyLook = !look.isOriginal
        }
        .onDisappear { work?.cancel() }
    }

    private struct URLBox: Identifiable { let url: URL; var id: String { url.absoluteString } }

    // MARK: ShareSheet

    @ViewBuilder private var form: some View {
        HStack {
            Text("Share").font(.system(size: 17, weight: .semibold))
            Spacer()
            Button("Cancel") { dismiss() }.frame(minHeight: 44).accessibilityIdentifier("racket.share.cancel")
        }
        HStack(spacing: 8) {
            ForEach(RacketShareWhich.allCases, id: \.self) { w in
                RacketTagChip(label: w.label, selected: which == w, id: "racket.share.which.\(w.rawValue)", wide: true) { which = w }
                    .disabled(plan(w) == nil)
                    .opacity(plan(w) == nil ? 0.4 : 1)
            }
        }
        checkRow("Apply the look", detail: look.isOriginal ? "Original: nothing to apply" : look.label,
                 on: applyLook && !look.isOriginal, enabled: !look.isOriginal, id: "racket.share.look") { applyLook.toggle() }
        checkRow("Score and rally labels", detail: "Drawn into the shared copy", on: labels, enabled: !rallies.isEmpty,
                 id: "racket.share.labels") { labels.toggle() }
        checkRow("Keep the speed", detail: RacketSharePlan.speedLine(rate: rate, keep: keepSpeed), on: keepSpeed && rate != 1,
                 enabled: rate != 1, id: "racket.share.speed") { keepSpeed.toggle() }
        if let p = plan(which) {
            HStack {
                Text(p.summary(rallyNumber: RacketPlayerRallies(rallies).lastStarted(at: position).map { $0 + 1 }))
                    .font(.system(size: 15, weight: .semibold)).accessibilityIdentifier("racket.share.summary")
                Spacer()
                Text(p.sizeLine).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("racket.share.size")
            }
        }
        if let madeSize {
            Text(madeSize).font(.system(size: 11)).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.share.madeSize")
        }
        if let failure {
            Text(failure).font(SnappetType.detail).foregroundStyle(SnappetColor.perfModerate)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("racket.share.error")
        }
        Button { start(smaller: false) } label: {
            Text(failure == nil ? "Share" : "Try again").font(.system(size: 17, weight: .semibold)).foregroundStyle(SnappetColor.onBrand)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(SnappetColor.brand, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(plan(which) == nil)
        .accessibilityIdentifier(failure == nil ? "racket.share.go" : "racket.share.retry")
        if failure != nil {
            Button("Share at a smaller size") { start(smaller: true) }
                .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("racket.share.smaller")
        }
        Text("A new copy is made. The original is not changed.").font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
            .frame(maxWidth: .infinity)
    }

    private func checkRow(_ title: String, detail: String, on: Bool, enabled: Bool, id: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                    Text(detail).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                }
                Spacer()
                Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 24))
                    .foregroundStyle(on ? SnappetColor.brand : SnappetColor.textSecondary)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    // MARK: ShareExport

    @ViewBuilder private func exporting(_ p: RacketSharePlan, _ f: Double) -> some View {
        Text(p.progressLine(f)).font(.system(size: 17, weight: .semibold)).accessibilityIdentifier("racket.share.progress")
        ProgressView(value: f).tint(SnappetColor.brand)
        Text("Keep Snappet open. If it fails, nothing is lost: try again or share at a smaller size.")
            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        Button { work?.cancel(); work = nil; fraction = nil } label: {
            Text("Cancel").font(.system(size: 17, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                .frame(maxWidth: .infinity, minHeight: 50)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SnappetColor.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("racket.share.cancelExport")
    }

    /// UI tests only (`-uiTestShareName <tag>`): a name that says what the copy should be, so a device run can pull
    /// exactly the files it made ("uitest-share-<tag>-whole-warm-1.0x-labels.mp4") and nothing else.
    private func testFileName(_ p: RacketSharePlan, look: RacketLook) -> String? {
        #if DEBUG
        guard let tag = UserDefaults.standard.string(forKey: "uiTestShareName") else { return nil }
        return "uitest-share-\(tag)-\(p.which.rawValue)-\(look.rawValue)-\(p.speed)x-\(p.labels.isEmpty ? "nolabels" : "labels").mp4"
        #else
        return nil
        #endif
    }

    private func start(smaller: Bool) {
        guard let p = plan(which), let log = ex?.racketRecordingLog else { return }
        let pieces = p.ranges.map { (RacketVideoMap.segments(start: $0.lowerBound, end: $0.upperBound, log: log), $0.lowerBound, $0.upperBound) }
        failure = nil
        fraction = 0
        let chosenLook: RacketLook = applyLook ? look : .original
        work = Task {
            #if DEBUG
            // UI tests only (`-uiTestShareSlow`): hold ShareExport on screen; the simulator copies too fast to see it.
            if ProcessInfo.processInfo.arguments.contains("-uiTestShareSlow") {
                fraction = 0.64
                try? await Task.sleep(for: .seconds(3))
            }
            #endif
            do {
                let url = try await RacketVideoLibrary.shared.export(pieces, smaller: smaller, look: chosenLook, speed: p.speed,
                                                                     labels: p.labels, turns: log.copyTurns,
                                                                     progress: { f in fraction = f },
                                                                     fileName: testFileName(p, look: chosenLook))
                guard !Task.isCancelled else { return }
                #if DEBUG
                if testFileName(p, look: chosenLook) != nil, let s = await RacketVideoLibrary.displayedSize(of: url) {
                    Self.lastMadeSize = "\(Int(s.width.rounded()))×\(Int(s.height.rounded()))"
                }
                #endif
                fraction = nil
                shareURL = url
                Haptics.success()
            } catch is CancellationError {
                fraction = nil
            } catch {
                fraction = nil
                // One sentence (the export's own reason repeated "Couldn’t make…"); the reason goes to the debug log.
                failure = "Couldn’t make the copy. Nothing is lost: try again, or share at a smaller size."
                #if DEBUG
                print("RACKETSHARE \(error)")
                #endif
                Haptics.warning()
            }
        }
    }
}
