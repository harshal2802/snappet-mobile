import AuthenticationServices
import SwiftUI

// MARK: - "Find missing clips" (cloud-connect P1b, prompt 266)

/// The feed's one-row notice that some clips' footage is gone. Dismissing it remembers HOW MANY were
/// missing, so it stays quiet until more go missing (see `MissingClipsNotice`).
struct ClipsMissingCard: View {
    let count: Int
    let onReview: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 15))
                .foregroundStyle(SnappetColor.ink)
                .frame(width: 32, height: 32)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(MissingClipsNotice.title(count: count))
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(SnappetColor.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text("Session records are kept").snappetLabel().lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: onReview) {
                Text("Review").font(.system(size: 13, weight: .medium)).snappetPill(selected: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("clips.missing.review")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SnappetColor.textTertiary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("clips.missing.dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SnappetColor.hairline))
        .padding(.horizontal, SnappetSpacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clips.missing")
    }
}

/// The sheet: what is missing, and one way to bring it back — pick the footage from this iPhone's
/// library. Every pick is checked against the clip it would replace; the result says plainly how
/// many were attached and how many picks matched nothing.
struct MediaRelinkSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var working = false
    @State private var outcome: MissingClipsNotice.Outcome?

    private var groups: [MissingClipsNotice.Group] { MissingClipsNotice.groups(app.mediaLinks.missing) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("This footage was removed from this iPhone’s Photos. If you still have it somewhere — another app, a computer, a friend — save it back to Photos, then pick it here.")
                            .font(.subheadline).foregroundStyle(SnappetColor.textSecondary)
                        Button { showPicker = true } label: {
                            HStack {
                                Image(systemName: "photo.on.rectangle.angled")
                                Text("Pick from this iPhone").fontWeight(.medium)
                                Spacer()
                                if working { ProgressView() }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .foregroundStyle(SnappetColor.ink)
                            .background(SnappetColor.surfaceMuted,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(working)
                        .accessibilityIdentifier("clips.missing.pick")
                        Text("Snappet checks each pick against the clip’s capture time and length, so the wrong footage is never attached.")
                            .font(.footnote).foregroundStyle(SnappetColor.textTertiary)
                        if let outcome {
                            Label(outcome.message, systemImage: outcome.attached > 0 ? "checkmark.circle" : "info.circle")
                                .font(.subheadline.weight(.medium)).foregroundStyle(SnappetColor.ink)
                                .accessibilityIdentifier("clips.missing.outcome")
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Footage that lives in Google Photos, not on this iPhone (prompt 269).
                if app.google.isConfigured { GooglePhotosPickSection() }
                if groups.isEmpty {
                    Section {
                        Label("Every clip is on this phone", systemImage: "checkmark.circle")
                            .foregroundStyle(SnappetColor.textSecondary)
                            .accessibilityIdentifier("clips.missing.none")
                    }
                }
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.clips) { clip in
                            HStack(spacing: 10) {
                                Image(systemName: clip.isVideo ? "video" : "photo")
                                    .foregroundStyle(SnappetColor.textSecondary).frame(width: 24)
                                Text(MissingClipsNotice.line(for: clip)).foregroundStyle(SnappetColor.ink)
                                Spacer()
                                Text("Missing").font(.caption).foregroundStyle(SnappetColor.textTertiary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("clips.missing.row")
                        }
                    }
                }
            }
            .navigationTitle(MissingClipsNotice.sheetTitle(count: app.mediaLinks.missing.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("clips.missing.done")
                }
            }
            .sheet(isPresented: $showPicker) {
                MediaPicker { picked in
                    showPicker = false
                    guard !picked.isEmpty else { return }
                    working = true
                    Task {
                        let result = await app.relinkMissingClips(pickedIdentifiers: picked)
                        outcome = MissingClipsNotice.Outcome(result: result, picked: picked.count)
                        working = false
                    }
                }
                .ignoresSafeArea()
            }
        }
        .accessibilityIdentifier("clips.missing.sheet")
    }
}

// MARK: - Environment hook: a missing clip's placeholder offers "Find clip" where a host supports it

/// Whether the relink sheet is up. A reference (not a closure) in the environment, so handing it
/// down does not invalidate every clip surface on each feed update.
@MainActor
@Observable
final class MediaRelinkRequest {
    var isPresented = false
}

extension EnvironmentValues {
    /// Set by a screen that can present `MediaRelinkSheet` (the Clips feed). `nil` elsewhere, so the
    /// missing-clip placeholder shows no button it cannot honour.
    @Entry var mediaRelinkRequest: MediaRelinkRequest? = nil
}

/// "Pick from Google Photos" in Find missing clips (prompt 269). The person chooses items in
/// Google's own picker; Snappet checks each against the missing clips and copies the matches from
/// Google Photos into the "Snappet Clips" folder of their Google Drive, where they play from.
/// Nothing is saved to this iPhone's Photos, so it needs no free space here.
struct GooglePhotosPickSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL
    @State private var stage: Stage = .idle
    @State private var message: String?
    @State private var failure: String?
    @State private var work: Task<Void, Never>?

    private enum Stage: Equatable { case idle, signingIn, waiting, copying }
    private static let scopes = [GoogleScope.photosPicker, GoogleScope.driveFile]

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Button { start() } label: {
                    HStack {
                        Image(systemName: "cloud")
                        Text("Pick from Google Photos").fontWeight(.medium)
                        Spacer()
                        if stage != .idle { ProgressView() }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .foregroundStyle(SnappetColor.ink)
                    .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(stage != .idle)
                .accessibilityIdentifier("clips.missing.pickGoogle")
                switch stage {
                case .idle, .signingIn: EmptyView()
                case .waiting:
                    HStack {
                        Text("Choose your clips in Google Photos, then come back here.")
                            .font(.footnote).foregroundStyle(SnappetColor.textSecondary)
                        Spacer()
                        Button("Cancel") { work?.cancel() }.font(.footnote)
                    }
                case .copying:
                    Text(copyingText).font(.footnote).foregroundStyle(SnappetColor.textSecondary)
                }
                Text("Matching clips are copied from Google Photos to a “Snappet Clips” folder in your Google Drive and play from there. Nothing is saved to this iPhone, so it needs no free space.")
                    .font(.footnote).foregroundStyle(SnappetColor.textTertiary)
                if let message {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.medium)).foregroundStyle(SnappetColor.ink)
                        .accessibilityIdentifier("clips.missing.googleOutcome")
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("clips.missing.googleFailure")
                }
            }
            .padding(.vertical, 4)
        }
        .onDisappear { work?.cancel() }
    }

    private var copyingText: String {
        if case let .working(done, total) = app.mediaVault.phase { return "Copying \(done) of \(total) to Google Drive…" }
        return "Checking your picks…"
    }

    private func start() {
        message = nil
        failure = nil
        work = Task {
            defer { stage = .idle }
            do {
                if !(app.google.isSignedIn && Self.scopes.allSatisfy(app.google.grants)) {
                    stage = .signingIn
                    let pending = try app.google.beginSignIn(scopes: Self.scopes)
                    let callback = try await webAuthenticationSession.authenticate(
                        using: pending.url, callback: .customScheme(pending.callbackScheme), additionalHeaderFields: [:])
                    try await app.google.finishSignIn(pending, callback: callback)
                }
                stage = .waiting
                let session = try await app.mediaVault.beginGooglePick()
                openURL(session.pickerURL)
                let picks = try await app.mediaVault.waitForPicks(session)
                stage = .copying
                message = (await app.importGooglePicks(picks)).message
            } catch is CancellationError {
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            } catch GoogleAuthError.cancelled {
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
