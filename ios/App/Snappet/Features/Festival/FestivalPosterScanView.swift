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
            .navigationTitle(isCreating ? "New lineup" : "Review lineup")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { installBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    /// A lineup built by hand (prompt 232) vs a poster's draft under review.
    private var isCreating: Bool { draft.source == .manual }

    // MARK: - Sections

    private var festivalSection: some View {
        Section {
            TextField("Festival name", text: $draft.name)
                .accessibilityIdentifier("festival.poster.name")
            TextField("Location", text: $draft.location)
            DatePicker("First day", selection: Self.dayBinding($draft.startDate),
                       displayedComponents: .date)
                .accessibilityIdentifier("festival.poster.startDate")
            DatePicker("Last day", selection: Self.dayBinding($draft.endDate),
                       displayedComponents: .date)
                .accessibilityIdentifier("festival.poster.endDate")
            Picker("Time zone", selection: $draft.utcOffsetSeconds) {
                ForEach(Self.offsetChoices(including: draft.utcOffsetSeconds), id: \.self) { offset in
                    Text(Self.offsetLabel(offset)).tag(offset)
                }
            }
            .accessibilityIdentifier("festival.poster.timeZone")
        } header: {
            Text("Festival")
        } footer: {
            if isCreating {
                Text("Set times are the festival's local time. Add days, stages and sets below — you can "
                     + "edit or delay anything later from Edit lineup.")
            } else if draft.source == .appleIntelligence {
                Label("Structured on this device by Apple Intelligence — please check it.",
                      systemImage: "sparkles")
            } else {
                Text("Read from your poster text — please check every set.")
            }
        }
    }

    private func daySection(_ day: Binding<FestivalDraft.DraftDay>) -> some View {
        Section {
            DatePicker("Day", selection: Self.dayBinding(day.date), displayedComponents: .date)
                .font(.subheadline.weight(.semibold))
            ForEach(day.stages) { $stage in
                stageRows($stage)
            }
            .onDelete { day.wrappedValue.stages.remove(atOffsets: $0) }
            Button {
                day.wrappedValue.stages.append(.init(name: "", sets: [.init(artist: "", start: "", end: "")]))
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
                        .keyboardType(.numbersAndPunctuation)
                    Text("–").foregroundStyle(.secondary)
                    TextField("HH:mm", text: $set.end)
                        .frame(width: 52).multilineTextAlignment(.trailing)
                        .font(.callout.monospaced())
                        .keyboardType(.numbersAndPunctuation)
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
                // The day after the last one (it used to repeat the last date — a duplicate day the
                // validator rejects), widening the festival's range to cover it.
                let date = draft.nextDayDate
                draft.days.append(.init(date: date, stages: [
                    .init(name: draft.days.last?.stages.first?.name ?? "Main Stage",
                          sets: [.init(artist: "", start: "", end: "")]),
                ]))
                if date > draft.endDate { draft.endDate = date }
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
        .buttonStyle(SnappetWidePrimaryStyle())
        .disabled(installer.isWorking)
        .padding()
        .background(.bar)
        .accessibilityIdentifier("festival.poster.install")
    }

    // MARK: - Date / time-zone helpers

    /// A `yyyy-MM-dd` string as a date-picker value (a blank or garbled string shows today; picking
    /// writes the string back). UTC on both sides, so the label date never shifts with the phone.
    static func dayBinding(_ text: Binding<String>) -> Binding<Date> {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return Binding(
            get: {
                let p = text.wrappedValue.split(separator: "-").compactMap { Int($0) }
                if p.count == 3, let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) {
                    return d
                }
                let today = Calendar.current.dateComponents([.year, .month, .day], from: .now)
                return cal.date(from: today) ?? .now
            },
            set: { date in
                let c = cal.dateComponents([.year, .month, .day], from: date)
                text.wrappedValue = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            })
    }

    /// UTC−12:00 … UTC+14:00 in 30-minute steps, plus the current value if it's an odd one (+05:45).
    static func offsetChoices(including current: Int) -> [Int] {
        var all = Array(stride(from: -12 * 3600, through: 14 * 3600, by: 1800))
        if !all.contains(current) { all.append(current); all.sort() }
        return all
    }

    static func offsetLabel(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "−" : "+"
        let a = abs(seconds)
        var label = String(format: "UTC%@%02d:%02d", sign, a / 3600, (a % 3600) / 60)
        if seconds == TimeZone.current.secondsFromGMT() { label += " (this phone)" }
        return label
    }

    // MARK: - Install (validate-before-install gate — reuses the shared installer)

    private func install() {
        let pack = draft.toPack()
        // The installer validates (FestivalPackValidator) before it writes; on failure it sets
        // phase == .failed(message) and installs nothing (the never-a-hallucination gate).
        if installer.install(pack: pack, sourceLabel: isCreating ? "Created by you" : "Poster scan",
                             into: context) != nil {
            onInstalled(pack)
            dismiss()
        }
    }
}
