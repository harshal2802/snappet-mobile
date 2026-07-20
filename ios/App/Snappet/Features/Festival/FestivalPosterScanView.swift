import SwiftUI
import SwiftData

/// A short, canned lineup-poster string — shown behind "Use a sample" so a first-time user sees the
/// format the parser expects (and the sim UI test drives the flow with no camera). Real users paste
/// their own festival's schedule text or scan the poster.
enum FestivalPosterSample {
    static let text = """
    Sunset Sounds 2026
    Riverside Park
    2026-08-15

    MAIN STAGE
    18:00 Opening Act
    19:30 The Midnights
    21:00 - 22:30 Neon Parade

    RIVER STAGE
    20:00 DJ Marlow
    22:00 Aurora Skies
    """
}

/// **Poster-scan capture** (festival prompt 06, wireframe frame 2's "Scan a lineup poster"): the
/// ingestion entry for a user with no hosted `.fpack`. Two ways in — photograph the printed poster
/// (Apple Vision OCR via the shared `ReceiptDocumentScanner`, a real-device edge) or paste the lineup
/// text — both land on the SAME pure path: `FestivalPosterIntelligence.draft(fromOCR:)` structures the
/// text (on-device Foundation Models when available, else the heuristic floor) into an editable
/// `FestivalDraft` the host then presents for review. Nothing installs from here — the user always
/// reviews and edits first.
struct FestivalPosterScanView: View {
    /// Hand the built draft back to the host, which presents the review editor.
    let onDraft: (FestivalDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pastedText = ""
    @State private var showingCamera = false
    @State private var building = false

    private var offsetSeconds: Int { TimeZone.current.secondsFromGMT() }
    private var canBuild: Bool {
        !building && !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Point your camera at the printed schedule, or paste the lineup text. Snappet "
                         + "reads it on this device and drops you into a draft you review before it's added.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if ReceiptDocumentScanner.isSupported {
                    Section {
                        Button { showingCamera = true } label: {
                            Label("Scan a poster with the camera", systemImage: "camera.viewfinder")
                        }
                        .disabled(building)
                        .accessibilityIdentifier("festival.poster.camera")
                    }
                }

                Section {
                    TextEditor(text: $pastedText)
                        .frame(minHeight: 160)
                        .font(.callout.monospaced())
                        .accessibilityIdentifier("festival.poster.paste")
                    Button("Use a sample lineup") { pastedText = FestivalPosterSample.text }
                        .font(.footnote)
                        .disabled(building)
                        .accessibilityIdentifier("festival.poster.sample")
                } header: {
                    Text("Paste lineup text")
                } footer: {
                    Text("One line per set — a time (HH:MM) and the artist. Stage names on their own "
                         + "line group the sets beneath them; a yyyy-MM-dd line starts a day.")
                }

                Section {
                    Button {
                        build(from: pastedText)
                    } label: {
                        HStack {
                            if building { ProgressView().padding(.trailing, 4) }
                            Text(building ? "Reading…" : "Build a draft")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SnappetColor.festival)
                    .disabled(!canBuild)
                    .accessibilityIdentifier("festival.poster.build")
                } footer: {
                    privacyNote
                }
            }
            .navigationTitle("Scan a lineup poster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(building)
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                ReceiptDocumentScanner { text in
                    showingCamera = false
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        build(from: text)
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    private var privacyNote: some View {
        Label {
            Text("**On-device only.** " + (FestivalPosterIntelligence.isIntelligenceAvailable
                 ? "Apple Intelligence structures the text on this iPhone — nothing about the poster leaves it."
                 : "The lineup is parsed on this iPhone — nothing about the poster leaves it."))
        } icon: {
            Image(systemName: "lock.fill").foregroundStyle(SnappetColor.festival)
        }
        .font(.footnote)
    }

    /// Structure the OCR/pasted text into a draft (FM when available, else the floor) and hand it up.
    private func build(from text: String) {
        building = true
        Task {
            let draft = await FestivalPosterIntelligence.draft(fromOCR: text,
                                                               defaultOffsetSeconds: offsetSeconds)
            building = false
            onDraft(draft)
        }
    }
}

/// **The draft-review editor** (festival prompt 06): the editable form pre-filled from the poster.
/// NEVER installs a hallucination — the user confirms/edits every field, then "Add to my festivals"
/// builds a `FestivalPack` and runs it through `FestivalPackValidator` (via the shared installer's
/// `install(pack:)`). A draft that doesn't validate surfaces the validator's EXACT message inline and
/// installs nothing; a clean one installs as a local `poster-…` lineup, offline forever after.
struct FestivalPosterDraftView: View {
    let installer: FestivalLineupInstaller
    /// Called after a successful install so the host can dismiss + log.
    let onInstalled: (FestivalPack) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var draft: FestivalDraft

    init(draft: FestivalDraft, installer: FestivalLineupInstaller,
         onInstalled: @escaping (FestivalPack) -> Void) {
        self.installer = installer
        self.onInstalled = onInstalled
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                festivalSection
                ForEach($draft.days) { $day in
                    daySection($day)
                }
                addDaySection
                if case .failed(let message) = installer.phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("festival.poster.error")
                    } footer: {
                        Text("Fix the highlighted problem above, then try again — nothing is installed "
                             + "until the whole lineup checks out.")
                    }
                }
            }
            .accessibilityIdentifier("festival.poster.draft")
            .navigationTitle("Review lineup")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { installBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    // MARK: - Sections

    private var festivalSection: some View {
        Section {
            TextField("Festival name", text: $draft.name)
                .accessibilityIdentifier("festival.poster.name")
            TextField("Location", text: $draft.location)
            TextField("First day (yyyy-MM-dd)", text: $draft.startDate)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Last day (yyyy-MM-dd)", text: $draft.endDate)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: {
            Text("Festival")
        } footer: {
            if draft.source == .appleIntelligence {
                Label("Structured on this device by Apple Intelligence — please check it.",
                      systemImage: "sparkles")
            } else {
                Text("Read from your poster text — please check every set.")
            }
        }
    }

    private func daySection(_ day: Binding<FestivalDraft.DraftDay>) -> some View {
        Section {
            TextField("Day (yyyy-MM-dd)", text: day.date)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.subheadline.weight(.semibold))
            ForEach(day.stages) { $stage in
                stageRows($stage)
            }
            .onDelete { day.wrappedValue.stages.remove(atOffsets: $0) }
            Button {
                day.wrappedValue.stages.append(.init(name: "Stage", sets: []))
            } label: {
                Label("Add a stage", systemImage: "plus.circle")
            }
            .font(.footnote)
        } header: {
            Text(day.date.wrappedValue.isEmpty ? "Day" : day.date.wrappedValue)
        }
    }

    private func stageRows(_ stage: Binding<FestivalDraft.DraftStage>) -> some View {
        Group {
            TextField("Stage name", text: stage.name)
                .font(.subheadline.weight(.medium))
            ForEach(stage.sets) { $set in
                HStack(spacing: 8) {
                    TextField("Artist", text: $set.artist)
                    Spacer(minLength: 4)
                    TextField("HH:mm", text: $set.start)
                        .frame(width: 52).multilineTextAlignment(.trailing)
                        .font(.callout.monospaced())
                    Text("–").foregroundStyle(.secondary)
                    TextField("HH:mm", text: $set.end)
                        .frame(width: 52).multilineTextAlignment(.trailing)
                        .font(.callout.monospaced())
                }
            }
            .onDelete { stage.wrappedValue.sets.remove(atOffsets: $0) }
            Button {
                stage.wrappedValue.sets.append(.init(artist: "", start: "", end: ""))
            } label: {
                Label("Add a set", systemImage: "plus.circle")
            }
            .font(.caption)
        }
    }

    private var addDaySection: some View {
        Section {
            Button {
                draft.days.append(.init(date: draft.endDate, stages: [.init(name: "Stage", sets: [])]))
            } label: {
                Label("Add a day", systemImage: "plus.circle")
            }
            .font(.footnote)
        }
    }

    private var installBar: some View {
        Button {
            install()
        } label: {
            Label("Add to my festivals", systemImage: "plus.circle.fill")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(SnappetColor.festival)
        .disabled(installer.isWorking)
        .padding()
        .background(.bar)
        .accessibilityIdentifier("festival.poster.install")
    }

    // MARK: - Install (validate-before-install gate — reuses the shared installer)

    private func install() {
        let pack = draft.toPack()
        // The installer validates (FestivalPackValidator) before it writes; on failure it sets
        // phase == .failed(message) and installs nothing (the never-a-hallucination gate).
        if installer.install(pack: pack, sourceLabel: "Poster scan", into: context) != nil {
            onInstalled(pack)
            dismiss()
        }
    }
}
