import SwiftUI
import UniformTypeIdentifiers

// MARK: - Round trip with another AI app: screens (prompt 247, issue #438 step 4)
//
// TtAISend → TtAIPrompt ("View and edit") → share sheet → TtAIImport ("Bring results back") → TtAICompare / the Analyzed
// player. Thin renderers over the pure `RacketAIRoundTrip.swift`; the clip goes out through `RacketVideoLibrary` +
// the system share sheet. Snappet makes no network call: the user picks the app, and brings its answer back by paste
// or a file. Pushed inside `RacketVideosCover`'s stack and saved through `RacketVideoStore`.

/// What AIPrompt needs to show the exact prompt that will be sent.
struct RacketAIPromptContext: Hashable, Sendable {
    var sport: RacketSport
    var clip: RacketAIClip
    var title: String
    var framesOnly: Bool
}

/// Saved per sport ("Edits are kept for next time") and the last app used.
enum RacketAIPrefs {
    static func customBody(_ sport: RacketSport) -> String? {
        UserDefaults.standard.string(forKey: RacketAIPrompt.storageKey(sport))
    }

    static func setCustomBody(_ body: String?, sport: RacketSport) {
        let t = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t, !t.isEmpty, t != RacketAIPrompt.defaultBody(sport) {
            UserDefaults.standard.set(t, forKey: RacketAIPrompt.storageKey(sport))
        } else {
            UserDefaults.standard.removeObject(forKey: RacketAIPrompt.storageKey(sport))
        }
    }

    static let lastAppKey = "racket.ai.lastApp"
    static var lastApp: RacketAIApp? {
        get { UserDefaults.standard.string(forKey: lastAppKey).flatMap(RacketAIApp.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: lastAppKey) }
    }
}

// MARK: - Shared pieces

private struct AIPanel<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pagerGlass(cornerRadius: 18)
    }
}

@MainActor private func aiNote(_ s: String) -> some View {
    Text(s).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
}

/// A choice row: title, detail, a check when picked.
private struct AIOptionRow: View {
    let title: String
    var detail: String? = nil
    let selected: Bool
    var enabled = true
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: { action(); Haptics.tap() }) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(enabled ? SnappetColor.ink : SnappetColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? SnappetColor.brand : SnappetColor.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? SnappetColor.brand : SnappetColor.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AIChip: View {
    let label: String
    var selected = false
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: { action(); Haptics.tap() }) {
            Text(label).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? Color.black : SnappetColor.brand)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(selected ? SnappetColor.brand : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(SnappetColor.hairline))
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor private func aiPrimary(_ label: String, id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
    Button(action: action) { Text(label).frame(maxWidth: .infinity, minHeight: 30).multilineTextAlignment(.center) }
        .buttonStyle(SnappetWidePrimaryStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier(id)
}

@MainActor private func aiSecondary(_ label: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
            .frame(maxWidth: .infinity, minHeight: 44).multilineTextAlignment(.center)
    }
    .buttonStyle(.plain)
    .pagerOutline()
    .accessibilityIdentifier(id)
}

extension RacketPartRef {
    /// "Game 1", "Whole recording", "Block 2".
    var shortTitle: String { title.replacingOccurrences(of: " video", with: "") }
}

// MARK: - TtAISend

struct RacketAISendScreen: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    let onPrompt: (RacketAIPromptContext) -> Void
    /// The share sheet finished: "Send, app replies" → AIImport.
    let onSent: () -> Void
    let onCancel: () -> Void

    @State private var kind: RacketAISendKind = .wholeSmaller
    @State private var app: RacketAIApp = .chatGPT
    @State private var permission = false
    @State private var working = false
    @State private var message: String?
    @State private var shareItems: ShareItems?
    @State private var configured = false

    private struct ShareItems: Identifiable { let id = UUID(); let items: [Any] }

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }
    private var sport: RacketSport { ex?.racketSport ?? .tableTennis }
    private var rallies: [RacketRally] {
        RacketRallyMarking.inRange(ex?.racketRecordingLog?.allRallies ?? [], ref.startSec, ref.endSec).filter(\.isRally)
    }
    private var unitWord: String {
        guard let ex else { return "game" }
        return ex.isRacketDrill ? "block" : ref.setIndex == nil ? "recording" : ex.racketFormat.sport.unit.noun
    }

    private var clip: RacketAIClip {
        kind == .ralliesOnly ? RacketAIClip.rallies(rallies, within: ref.startSec, ref.endSec) : .whole(ref.startSec, ref.endSec)
    }

    private var context: RacketAIPromptContext {
        RacketAIPromptContext(sport: sport, clip: clip, title: promptTitle, framesOnly: app.framesOnly)
    }

    private var promptTitle: String {
        guard let ex else { return ref.shortTitle }
        return ex.isRacketDrill ? "\(ref.shortTitle) of \(ex.displayName ?? "a drill")" : "\(ref.shortTitle) of match \(ex.racketMatchTitle)"
    }

    private var sendLabel: String { app == .other ? "Send" : "Send to \(app.name)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Analyze with another app").font(.system(size: 22, weight: .semibold))
                AIPanel {
                    Text("This leaves your phone").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SnappetColor.perfModerate)
                    aiNote("The video goes to the app you pick, under that app’s privacy terms. People in the video may be identifiable.")
                }
                .accessibilityIdentifier("racket.ai.send.privacy")
                Text("What to send").snappetLabel()
                ForEach(RacketAISendKind.allCases, id: \.self) { k in
                    let off = k == .ralliesOnly && rallies.isEmpty
                    AIOptionRow(title: k.title(unit: unitWord), detail: off ? "Mark rallies first" : k.detail,
                                selected: kind == k, enabled: !off, id: "racket.ai.send.kind.\(k.rawValue)") { kind = k }
                }
                AIPanel {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Prompt included").font(.system(size: 16, weight: .semibold))
                            aiNote("Written for \(sport.label.lowercased()), with the reply format Snappet reads.")
                        }
                        Spacer(minLength: 6)
                        AIChip(label: "View and edit", id: "racket.ai.send.prompt") { onPrompt(context) }
                    }
                }
                Text("Send to").snappetLabel()
                ForEach(RacketAIApp.allCases, id: \.self) { a in
                    AIOptionRow(title: a.rowLabel + (RacketAIPrefs.lastApp == a && a != .other ? " · last used" : ""),
                                selected: app == a, id: "racket.ai.send.app.\(a.rawValue)") {
                        app = a
                        permission = false
                    }
                }
                if app.framesOnly {
                    aiNote("Claude can’t take video, so Snappet sends still frames from \(kind == .ralliesOnly ? "each rally" : "the video"). Results will be rougher.")
                        .accessibilityIdentifier("racket.ai.send.framesNote")
                }
                if app == .other {
                    aiNote("The share sheet lists the apps on your phone that take video. Pick the one you want.")
                }
                Toggle(isOn: $permission) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("I have permission to share this video with \(app == .other ? "the app I pick" : app.name)")
                            .font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        aiNote("Required each time. Send stays off until this is on")
                    }
                }
                .accessibilityIdentifier("racket.ai.send.permission")
                if let message {
                    Text(message).font(SnappetType.detail).foregroundStyle(SnappetColor.perfModerate)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("racket.ai.send.message")
                }
                if working { ProgressView(app.framesOnly ? "Making the frames…" : "Making the video…") }
                aiPrimary(sendLabel, id: "racket.ai.send.go", enabled: permission && !working) { send() }
                aiNote("Snappet copies the prompt too, so you can paste it if the app doesn’t show it. Snappet doesn’t contact the app itself.")
            }
            .padding(20)
        }
        .navigationTitle("Send to another AI app")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onCancel() }.accessibilityIdentifier("racket.ai.send.cancel")
            }
        }
        .sheet(item: $shareItems) { s in
            ShareSheet(items: s.items) { completed, _ in
                cleanUp(s.items)
                if completed { onSent() }
            }
        }
        .onAppear {
            guard !configured else { return }
            configured = true
            kind = rallies.isEmpty ? .wholeSmaller : .ralliesOnly
            app = RacketAIPrefs.lastApp ?? .chatGPT
        }
    }

    private func cleanUp(_ items: [Any]) {
        for case let url as URL in items { try? FileManager.default.removeItem(at: url) }
    }

    private func send() {
        guard let log = ex?.racketRecordingLog else { return }
        let ctx = context
        let prompt = RacketAIPrompt.build(sport: ctx.sport, clip: ctx.clip, title: ctx.title, framesOnly: ctx.framesOnly,
                                          customBody: RacketAIPrefs.customBody(ctx.sport))
        UIPasteboard.general.string = prompt
        working = true
        message = nil
        let chosen = app
        let sentKind = kind
        Task {
            defer { working = false }
            do {
                var items: [Any] = [prompt]
                if chosen.framesOnly {
                    let shots = RacketAIFrames.times(ctx.clip).compactMap { f in
                        RacketVideoMap.segments(start: f.recSec, end: f.recSec + 0.5, log: log).first.map { (clipSec: f.clipSec, segment: $0) }
                    }
                    items += try await RacketVideoLibrary.shared.frames(shots)
                } else {
                    let pieces = ctx.clip.pieces.map {
                        (segments: RacketVideoMap.segments(start: $0.startSec, end: $0.endSec, log: log), start: $0.startSec, end: $0.endSec)
                    }
                    items.append(try await RacketVideoLibrary.shared.export(pieces, smaller: sentKind.smaller))
                }
                let request = RacketAIRequest(appRaw: chosen.rawValue, kindRaw: sentKind.rawValue, sentAt: .now,
                                              partStart: ref.startSec, partEnd: ref.endSec, clip: ctx.clip)
                store.updateLog(ref.exerciseID) { $0.aiRequests = ($0.aiRequests ?? []) + [request] }
                RacketAIPrefs.lastApp = chosen
                permission = false
                shareItems = ShareItems(items: items)
            } catch {
                message = "\(error.localizedDescription) The prompt is copied; you can share the video from Photos yourself, then bring the answer back here."
                Haptics.warning()
            }
        }
    }
}

// MARK: - TtAIPrompt

struct RacketAIPromptScreen: View {
    let context: RacketAIPromptContext

    @State private var body_ = ""
    @State private var editing = false
    @State private var copied = false
    @State private var configured = false

    private var tail: String {
        RacketAIPrompt.fixedTail(sport: context.sport, clip: context.clip, title: context.title, framesOnly: context.framesOnly)
    }
    private var full: String {
        RacketAIPrompt.build(sport: context.sport, clip: context.clip, title: context.title, framesOnly: context.framesOnly,
                             customBody: body_)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Written for \(context.sport.label.lowercased())").font(.system(size: 22, weight: .semibold))
                    .accessibilityIdentifier("racket.ai.prompt.title")
                aiNote("Built from this sport’s rules, endings and shots, so the reply matches what Snappet can read.")
                AIPanel {
                    if editing {
                        TextEditor(text: $body_)
                            .frame(minHeight: 150)
                            .scrollContentBackground(.hidden)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("racket.ai.prompt.editor")
                    } else {
                        Text(body_).font(SnappetType.body).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("racket.ai.prompt.body")
                    }
                }
                Text("Reply format, always included").snappetLabel()
                AIPanel {
                    Text(tail).font(.system(size: 13, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("racket.ai.prompt.tail")
                }
                HStack(spacing: 10) {
                    aiSecondary(editing ? "Done editing" : "Edit", id: "racket.ai.prompt.edit") {
                        if editing { RacketAIPrefs.setCustomBody(body_, sport: context.sport) }
                        editing.toggle()
                    }
                    aiSecondary("Reset to default", id: "racket.ai.prompt.reset") {
                        body_ = RacketAIPrompt.defaultBody(context.sport)
                        RacketAIPrefs.setCustomBody(nil, sport: context.sport)
                    }
                }
                aiNote("Edits are kept for next time. The reply format can’t be removed.")
                if copied {
                    Text("Copied").font(SnappetType.detail.weight(.semibold)).foregroundStyle(SnappetColor.brand)
                        .accessibilityIdentifier("racket.ai.prompt.copied")
                }
            }
            .padding(20)
        }
        .navigationTitle("Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Copy") {
                    UIPasteboard.general.string = full
                    copied = true
                    Haptics.success()
                }
                .accessibilityIdentifier("racket.ai.prompt.copy")
            }
        }
        .onAppear {
            guard !configured else { return }
            configured = true
            body_ = RacketAIPrefs.customBody(context.sport) ?? RacketAIPrompt.defaultBody(context.sport)
        }
        .onDisappear { if editing { RacketAIPrefs.setCustomBody(body_, sport: context.sport) } }
    }
}

// MARK: - TtAIImport

struct RacketAIImportScreen: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    let onCompare: (UUID) -> Void
    let onSuggestions: () -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var choices: [String: RacketAIImportBuilder.EndingChoice] = [:]
    @State private var side: RacketAISide = .near
    @State private var app: RacketAIApp = .chatGPT
    @State private var compareFirst = true
    @State private var importingFile = false
    @State private var fileError: String?
    @State private var configured = false

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }
    private var sport: RacketSport { ex?.racketSport ?? .tableTennis }
    private var request: RacketAIRequest? { ex?.racketRecordingLog?.lastAIRequest(partStart: ref.startSec, partEnd: ref.endSec) }
    private var clip: RacketAIClip { request?.clip ?? .whole(ref.startSec, ref.endSec) }
    /// Read once per change of the text (a reply can be long).
    @State private var result: Result<RacketAIParseReport, RacketAIParseError> = .failure(.empty)
    private var report: RacketAIParseReport? { if case .success(let r) = result { return r } else { return nil } }

    private var appName: String { RacketAISource.label(app: app, reported: report?.app) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Bring results back").font(.system(size: 22, weight: .semibold))
                aiNote("When the other app replies, copy its answer and paste it here, or save it as a file and choose it.")
                HStack(spacing: 10) {
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in load(strings.joined(separator: "\n")) }
                    }
                    .labelStyle(.titleAndIcon)
                    .tint(SnappetColor.brand)
                    .accessibilityIdentifier("racket.ai.import.paste")
                    AIChip(label: "Choose a file", id: "racket.ai.import.file") { importingFile = true }
                }
                Text("Or paste here").snappetLabel()
                TextEditor(text: $text)
                    .frame(minHeight: 110, maxHeight: 180)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SnappetColor.hairline))
                    .accessibilityIdentifier("racket.ai.import.text")
                if let fileError {
                    Text(fileError).font(SnappetType.detail).foregroundStyle(SnappetColor.perfModerate)
                }
                switch result {
                case .failure(let e):
                    if e != .empty {
                        Text(e.line).font(SnappetType.detail).foregroundStyle(SnappetColor.perfModerate)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("racket.ai.import.error")
                    }
                case .success(let r):
                    readPanel(r)
                    madeWith(r)
                    sidePicker
                    Text("How to bring them in").snappetLabel()
                    AIOptionRow(title: "Add as suggestions", detail: "Shown dashed and labelled \(appName)",
                                selected: !compareFirst, id: "racket.ai.import.suggest") { compareFirst = false }
                    AIOptionRow(title: "Compare with your tags first", detail: "See where they disagree",
                                selected: compareFirst, id: "racket.ai.import.compare") { compareFirst = true }
                    aiPrimary("Import", id: "racket.ai.import.go",
                              enabled: RacketAIImportBuilder.counts(r, choices: choices).read > 0) { importNow(r) }
                }
                aiNote("Never changes anything you’ve tagged yourself.")
            }
            .padding(20)
        }
        .navigationTitle("Import results")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onCancel() }.accessibilityIdentifier("racket.ai.import.cancel")
            }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json, .plainText, .commaSeparatedText, .text]) { res in
            switch res {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), data.count < 2_000_000,
                   let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                    fileError = nil
                    load(s)
                } else {
                    fileError = "Snappet couldn’t read that file. Choose a text or JSON file."
                }
            case .failure(let e):
                fileError = e.localizedDescription
            }
        }
        .onChange(of: text) { _, _ in resetChoices() }
        .onAppear {
            guard !configured else { return }
            configured = true
            app = request?.app ?? RacketAIPrefs.lastApp ?? .chatGPT
        }
    }

    private func load(_ s: String) {
        text = s
        resetChoices()
    }

    private func resetChoices() {
        result = RacketAIParser.parse(text, sport: sport, clipLengthSec: clip.lengthSec)
        choices = report.map(RacketAIImportBuilder.defaultChoices) ?? [:]
    }

    @ViewBuilder private func readPanel(_ r: RacketAIParseReport) -> some View {
        let counts = RacketAIImportBuilder.counts(r, choices: choices)
        AIPanel {
            HStack(alignment: .firstTextBaseline) {
                Text(counts.readLine).font(.system(size: 26, weight: .light))
                    .accessibilityIdentifier("racket.ai.import.read")
                Spacer()
                if let s = counts.skippedLine {
                    Text(s).font(SnappetType.detail.weight(.semibold)).foregroundStyle(SnappetColor.perfModerate)
                        .accessibilityIdentifier("racket.ai.import.skipped")
                }
            }
            ForEach(Array(r.skipped.prefix(5).enumerated()), id: \.offset) { k, s in
                aiNote(s.line).accessibilityIdentifier("racket.ai.import.skip.\(k)")
            }
            if r.skipped.count > 5 { aiNote("and \(r.skipped.count - 5) more") }
            ForEach(r.warnings, id: \.self) { w in aiNote(w) }
            ForEach(Array(r.unknownEndings.enumerated()), id: \.offset) { k, u in
                unknownRow(u, index: k)
            }
        }
    }

    @ViewBuilder private func unknownRow(_ u: RacketAIParseReport.Unknown, index k: Int) -> some View {
        let key = RacketAIWire.normalize(u.word)
        let current = choices[key] ?? .leaveOut
        VStack(alignment: .leading, spacing: 8) {
            Text(RacketAIImportBuilder.unknownLine(u)).font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("racket.ai.import.unknown.\(k)")
            FlowRow {
                if let s = u.suggestion {
                    AIChip(label: "Count it as \(s.label)", selected: current == .countAs(s), id: "racket.ai.import.countAs.\(k)") {
                        choices[key] = .countAs(s)
                    }
                }
                Menu {
                    ForEach(RacketRallyEnding.choices(for: sport), id: \.self) { e in
                        Button(e.label) { choices[key] = .countAs(e) }
                    }
                } label: {
                    let other: String = {
                        if case .countAs(let e) = current, e != u.suggestion { return "Counted as \(e.label)" }
                        return u.suggestion == nil ? "Count it as…" : "Something else…"
                    }()
                    Text(other).font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.brand)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .overlay(Capsule().strokeBorder(SnappetColor.hairline))
                }
                .accessibilityIdentifier("racket.ai.import.countOther.\(k)")
                AIChip(label: "Leave them out", selected: current == .leaveOut, id: "racket.ai.import.leaveOut.\(k)") {
                    choices[key] = .leaveOut
                }
            }
        }
    }

    @ViewBuilder private func madeWith(_ r: RacketAIParseReport) -> some View {
        AIPanel {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Made with").snappetLabel()
                    Text(request != nil && request?.app == app ? "\(appName), from your last send" : appName)
                        .font(SnappetType.body).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("racket.ai.import.app")
                }
                Spacer()
                Menu {
                    ForEach(RacketAIApp.allCases, id: \.self) { a in Button(a.name) { app = a } }
                } label: {
                    Text("Change app").font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.brand)
                }
                .accessibilityIdentifier("racket.ai.import.changeApp")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Model it reported").snappetLabel()
                Text(r.model ?? "Not given").font(SnappetType.body).accessibilityIdentifier("racket.ai.import.model")
            }
            if request == nil {
                aiNote("Not sent from Snappet, so times are read from the start of \(ref.shortTitle.lowercased()).")
            }
        }
    }

    private var sidePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which side were you on?").font(.system(size: 17, weight: .semibold))
            HStack(spacing: 10) {
                AIChip(label: "Near the camera", selected: side == .near, id: "racket.ai.import.side.near") { side = .near }
                AIChip(label: "Far side", selected: side == .far, id: "racket.ai.import.side.far") { side = .far }
            }
        }
    }

    private func importNow(_ r: RacketAIParseReport) {
        let name = appName
        let rallies = RacketAIImportBuilder.rallies(r, choices: choices, clip: clip, side: side, source: RacketAISource.raw(name))
        let imp = RacketAIImport(appRaw: app.rawValue, appName: name, model: r.model, importedAt: .now,
                                 partStart: ref.startSec, partEnd: ref.endSec, rallies: rallies)
        store.updateLog(ref.exerciseID) { $0.aiImports = ($0.aiImports ?? []) + [imp] }
        Haptics.success()
        if compareFirst { onCompare(imp.id) } else { onSuggestions() }
    }
}

// MARK: - TtAICompare

struct RacketAICompareScreen: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    let importID: UUID
    /// Done → the Analyzed player.
    let onDone: () -> Void

    @State private var picks: [String: RacketAICompare.Pick] = [:]
    @State private var configured = false

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }
    private var imp: RacketAIImport? { ex?.racketRecordingLog?.allAIImports.first { $0.id == importID } }
    private var yours: [RacketRally] {
        RacketRallyMarking.inRange(ex?.racketRecordingLog?.allRallies ?? [], ref.startSec, ref.endSec)
    }
    private var sides: (us: String, them: String) {
        RacketWatchCopy.sides(opponent: ex?.opponent, doubles: ex?.isDoubles ?? false)
    }
    private var result: RacketAICompareResult {
        RacketAICompare.build(ai: imp?.rallies ?? [], yours: yours, appName: imp?.appName ?? "Other app", sides: sides)
    }

    var body: some View {
        let r = result
        let name = imp?.appName ?? "Other app"
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Your tags vs \(name) · \((imp?.importedAt ?? .now).formatted(.dateTime.month(.abbreviated).day()))")
                    .snappetLabel()
                    .accessibilityIdentifier("racket.ai.compare.header")
                Text(r.disagreementLine).font(.system(size: 28, weight: .light))
                    .accessibilityIdentifier("racket.ai.compare.count")
                Text(r.matchLine).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("racket.ai.compare.match")
                if r.items.isEmpty {
                    aiNote("Nothing to decide: \(name) agrees with your tags.")
                }
                ForEach(Array(r.items.enumerated()), id: \.element.id) { k, item in
                    AIPanel {
                        Text(item.title).font(.system(size: 16, weight: .semibold))
                            .accessibilityIdentifier("racket.ai.compare.title.\(k)")
                        AIOptionRow(title: item.yours, selected: picks[item.id] != .theirs,
                                    id: "racket.ai.compare.yours.\(k)") { picks[item.id] = .yours }
                        AIOptionRow(title: item.theirs, selected: picks[item.id] == .theirs,
                                    id: "racket.ai.compare.theirs.\(k)") { picks[item.id] = .theirs }
                        if item.protected {
                            aiNote("You tagged this yourself. It changes only if you pick \(name) here.")
                        }
                    }
                }
                aiNote("Rallies you’ve tagged yourself keep your tags unless you pick the other app’s answer for that item.")
                aiPrimary("Keep my choices", id: "racket.ai.compare.keep") { apply() }
                if !r.items.isEmpty {
                    aiSecondary("Use \(name) for all", id: "racket.ai.compare.useAll") {
                        picks = RacketAICompare.useAppForAll(r, current: picks)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Compare results")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { apply() }.accessibilityIdentifier("racket.ai.compare.done")
            }
        }
        .onAppear {
            guard !configured else { return }
            configured = true
            picks = RacketAICompare.defaultPicks(r)
        }
    }

    private func apply() {
        guard let imp else { onDone(); return }
        let r = result
        let all = ex?.racketRecordingLog?.allRallies ?? []
        let outside = all.filter { !($0.startSec >= ref.startSec - 0.01 && $0.startSec < ref.endSec) }
        let out = RacketAIMerge.apply(r, picks: picks, yours: yours, ai: imp.rallies, source: imp.source)
        store.updateLog(ref.exerciseID) { l in
            l.rallies = (outside + out.rallies).sorted { $0.startSec < $1.startSec }
            l.aiImports = RacketAIMerge.review(l.aiImports ?? [], id: imp.id, accepted: out.accepted)
        }
        Haptics.success()
        onDone()
    }
}
