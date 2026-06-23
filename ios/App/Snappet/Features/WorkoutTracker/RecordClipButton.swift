import SwiftUI

/// The reusable **"Record a clip"** control for the timed-effort FOCUS covers (`TimedSetCover` and
/// `TimedAttemptCover`). A glass button that opens the in-app camera (`VideoRecorder`), saves the finished
/// recording into the user's Photos library (`MediaLibraryService.saveRecording`), and appends a
/// `RecordedClip` to `recordedClips` — which the host cover hands up to the session at commit, so the clip
/// attaches to the very set / attempt being logged. An in-place "N clips will attach" confirmation gives
/// the user certainty before they STOP & LOG.
///
/// Presenting the recorder over the (wall-clock-backed) cover keeps the effort timer running, so finishing
/// a recording drops the user **back on the same live set** — the whole point of the affordance.
///
/// **Device-only:** the Simulator has no camera (`VideoRecorder.isAvailable == false`), so the button is
/// always shown (the affordance stays reachable + testable) but a tap there surfaces a transient
/// "Camera isn't available" caption instead of presenting. The record → save → attach path can only be
/// exercised on hardware.
struct RecordClipButton: View {
    /// The clips recorded so far — owned by the host cover (a `@State`), so they survive this button's own
    /// appearance/disappearance and are read at commit time.
    @Binding var recordedClips: [RecordedClip]
    /// Surfaces the in-flight Photos-save to the host cover so it can hold STOP/commit until the clip has
    /// landed in `recordedClips`. The save is async (it needs the saved asset id back), so without this a
    /// record → immediate-STOP would read `recordedClips` *before* the append and silently drop the clip from
    /// the set being logged. Host-owned (a `@State`) and reset in a `defer` even on save failure (no deadlock).
    @Binding var savingClip: Bool
    /// a11y-id namespace + caption noun for the two covers: `("timedSet", "set")` / `("timedAttempt", "attempt")`.
    let idPrefix: String
    let attachNoun: String

    @State private var showingRecorder = false
    @State private var recordingStartedAt = Date()
    @State private var noticeText: String?

    /// Stateless Photos writer (same `Sendable` service the clip-delete path uses).
    private let mediaLibrary = MediaLibraryService()

    /// Explicit init so the memberwise initializer isn't lowered to `private` by the `private` stored
    /// members (the codebase pattern for views with `@State private var` — `TimedSetCover`, `SetMediaStrip`).
    init(recordedClips: Binding<[RecordedClip]>, savingClip: Binding<Bool>, idPrefix: String, attachNoun: String) {
        self._recordedClips = recordedClips
        self._savingClip = savingClip
        self.idPrefix = idPrefix
        self.attachNoun = attachNoun
    }

    var body: some View {
        VStack(spacing: 8) {
            if !recordedClips.isEmpty {
                Label("^[\(recordedClips.count) clip](inflect: true) will attach to this \(attachNoun)",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("\(idPrefix).clipCount")
            }
            if let noticeText {
                Text(noticeText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("\(idPrefix).recordNotice")
            }
            Button { present() } label: {
                Label(savingClip ? "Saving clip…" : "Record a clip",
                      systemImage: savingClip ? "arrow.down.circle" : "video.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(savingClip)
            .accessibilityIdentifier("\(idPrefix).record")
        }
        .fullScreenCover(isPresented: $showingRecorder) {
            VideoRecorder(onRecorded: { handleRecorded($0) },
                          onCancel: { showingRecorder = false })
                .ignoresSafeArea()
        }
    }

    /// Authorize then present the camera — or surface a notice when there's no camera (the Simulator) or
    /// access is declined, so the affordance never silently does nothing or crashes.
    ///
    /// Camera authorization MUST be granted before presenting: `UIImagePickerController` throws when its
    /// camera-only properties are configured on a camera the app isn't authorized for, and
    /// `VideoRecorder.isAvailable` (source availability) is `true` even while permission is `.notDetermined`.
    private func present() {
        noticeText = nil
        guard VideoRecorder.isAvailable else {
            noticeText = "Camera isn't available on this device."
            return
        }
        Task {
            guard await VideoRecorder.requestCaptureAccess() else {
                noticeText = "Allow camera access in Settings to record a clip."
                return
            }
            recordingStartedAt = Date()
            showingRecorder = true
        }
    }

    /// Save the finished recording to Photos (preserving it immediately) and queue it for attachment. A
    /// failed save (e.g. Photos add-only denied) leaves a recoverable notice rather than losing it silently.
    private func handleRecorded(_ url: URL) {
        showingRecorder = false
        let startedAt = recordingStartedAt
        savingClip = true
        Task {
            defer { savingClip = false }
            do {
                let clip = try await mediaLibrary.saveRecording(at: url, capturedAt: startedAt)
                recordedClips.append(clip)
                noticeText = nil
                Haptics.tap()
            } catch {
                noticeText = "Couldn't save the clip — allow Photos access in Settings to keep recordings."
            }
        }
    }
}
