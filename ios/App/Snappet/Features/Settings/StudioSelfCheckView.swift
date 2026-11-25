#if DEBUG
import SwiftUI
import UIKit

/// Runs the Studio render check and holds what it found (prompt 304). Thin: the scenes come from
/// `StudioGoldenScene`, each one is rendered and compared by `StudioGoldenRenderer.check`, and
/// pass / fail, the summary and the report text are `StudioSelfCheck`'s.
@MainActor
@Observable
final class StudioSelfCheckModel {

    enum Phase: Equatable {
        case idle
        /// With what is being done now.
        case running(String)
        case finished
    }

    private(set) var phase: Phase = .idle
    private(set) var results: [StudioSelfCheck.SceneResult] = []
    private(set) var timing: StudioSelfCheck.Timing?
    private(set) var timingError: String?
    /// Set when the test videos could not be written; nothing was checked.
    private(set) var setupError: String?
    /// The 20 s export at 1080×1920. On by default; off skips it for a quick look at the frames.
    var includesTimedExport = true

    static var machine: StudioSelfCheck.Machine {
        #if targetEnvironment(simulator)
        return .simulator
        #else
        return .device
        #endif
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var summary: StudioSelfCheck.Summary { StudioSelfCheck.summary(results) }

    /// "Not run yet", what is running, or the verdict.
    var statusLine: String {
        switch phase {
        case .idle: return "Not run yet"
        case .running(let what): return "Running: \(what)"
        case .finished:
            if let setupError { return "FAIL — \(setupError)" }
            return (summary.allPassed ? "PASS" : "FAIL") + " — " + summary.line
        }
    }

    /// One word for the whole run, for VoiceOver and the UI test: idle, running, pass or fail.
    var verdict: String {
        switch phase {
        case .idle: return "idle"
        case .running: return "running"
        case .finished: return setupError == nil && summary.allPassed ? "pass" : "fail"
        }
    }

    /// Every scene with its result, `cut=pass;text=skipped;…`. The list below is built lazily,
    /// so this is the one place that names all of them at once.
    var sceneWords: String {
        results.map { "\($0.id)=\($0.status.word)" }.joined(separator: ";")
    }

    var report: String {
        var header = ["\(UIDevice.current.name) — \(Self.hardware), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"]
        let info = Bundle.main.infoDictionary
        header.append("Snappet \(info?["CFBundleShortVersionString"] as? String ?? "?") "
            + "(\(info?["CFBundleVersion"] as? String ?? "?")), \(Self.machine.label.lowercased())")
        if let setupError { header.append("The test videos could not be written: \(setupError)") }
        return StudioSelfCheck.report(header: header, machine: Self.machine, results: results,
                                      timing: timing, timingError: timingError)
    }

    /// The hardware model, e.g. `iPhone16,1`.
    private static var hardware: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private var task: Task<Void, Never>?

    func run() {
        guard !isRunning else { return }
        task = Task { await perform() }
    }

    func runAndWait() async {
        run()
        await task?.value
    }

    private func perform() async {
        results = []
        timing = nil
        timingError = nil
        setupError = nil
        phase = .running("writing the test videos")
        let directory = StudioGoldenRenderer.newFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture: StudioGoldenRenderer.Fixture
        do {
            fixture = try await Task.detached(priority: .userInitiated) {
                try StudioGoldenRenderer.makeFixture(StudioGoldenSource.golden, in: directory)
            }.value
        } catch {
            setupError = error.localizedDescription
            phase = .finished
            return
        }
        let machine = Self.machine
        for scene in StudioGoldenScene.all {
            phase = .running(scene.title)
            let result = await StudioGoldenRenderer.check(scene, fixture: fixture, machine: machine,
                                                          keepPassingImages: true) {
                StudioGoldenRenderer.bundledGolden($0)
            }
            results.append(result)
        }
        if includesTimedExport {
            phase = .running("the timed export")
            do {
                try await Task.detached(priority: .userInitiated) {
                    _ = try StudioGoldenRenderer.makeFixture([.large], in: directory)
                }.value
                timing = try await StudioGoldenRenderer.timedExport(fixture: fixture)
            } catch {
                timingError = error.localizedDescription
            }
        }
        phase = .finished
    }
}

/// **Studio render check** (prompt 304) — Settings → Developer, Debug builds only. Renders the
/// golden scenes on this device through the Studio's own export and preview, compares the frames
/// with the images the unit tests use, and times one longer export.
struct StudioSelfCheckView: View {
    @State private var model = StudioSelfCheckModel()
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Button {
                    copied = false
                    model.run()
                } label: {
                    Label(model.isRunning ? "Running…" : "Run the check", systemImage: "play.circle")
                }
                .disabled(model.isRunning)
                .accessibilityIdentifier("studioSelfCheck.run")

                Toggle("Include the 20 s export", isOn: $model.includesTimedExport)
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("studioSelfCheck.timedToggle")

                HStack(spacing: 10) {
                    if model.isRunning { ProgressView() }
                    Text(model.statusLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColour)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("studioSelfCheck.status")
                .accessibilityValue(model.verdict)

                // All the scenes' results in one element (the rows below exist only while on screen).
                Text(model.sceneWords.isEmpty ? "No results" : "\(model.results.count) scenes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("studioSelfCheck.results")
                    .accessibilityValue(model.sceneWords)
            } footer: {
                Text("Renders small test videos through the Studio's export and preview on this "
                     + "\(StudioSelfCheckModel.machine.label.lowercased()) and compares the frames with the "
                     + "images the unit tests use. Nothing is read from or saved to Photos.")
            }

            if !model.results.isEmpty {
                Section("Scenes") {
                    ForEach(model.results) { result in
                        sceneRow(result)
                    }
                }
            }

            Section("Timed export") {
                // One row, so the identifier names one element (on a Section it lands on every row).
                VStack(alignment: .leading, spacing: 4) {
                    if let timing = model.timing {
                        ForEach(timing.lines, id: \.self) { Text($0).font(.footnote) }
                    } else if let error = model.timingError {
                        Text("Failed: \(error)").font(.footnote).foregroundStyle(.red)
                    } else {
                        Text(model.includesTimedExport ? "Not run yet" : "Switched off")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("studioSelfCheck.timing")
            }

            Section {
                Button {
                    UIPasteboard.general.string = model.report
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(model.phase != .finished)
                .accessibilityIdentifier("studioSelfCheck.copy")
            }
        }
        .navigationTitle("Studio render check")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusColour: Color {
        switch model.verdict {
        case "pass": return .green
        case "fail": return .red
        default: return .primary
        }
    }

    @ViewBuilder
    private func sceneRow(_ result: StudioSelfCheck.SceneResult) -> some View {
        let label = HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                if case .skipped(let reason) = result.status {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else if case .failed(let reason) = result.status {
                    Text(reason).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
            Spacer()
            Text(result.status.word)
                .font(.caption.weight(.bold))
                .foregroundStyle(wordColour(result.status))
        }
        Group {
            if result.frames.isEmpty {
                label
            } else {
                NavigationLink { StudioSelfCheckSceneView(result: result) } label: { label }
            }
        }
        .accessibilityIdentifier("studioSelfCheck.scene.\(result.id)")
        .accessibilityValue(result.status.word)
    }

    private func wordColour(_ status: StudioSelfCheck.Status) -> Color {
        switch status {
        case .passed: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }
}

/// One scene's frames: the golden image, what this device rendered, and where they differ.
private struct StudioSelfCheckSceneView: View {
    let result: StudioSelfCheck.SceneResult

    var body: some View {
        List {
            ForEach(result.frames) { check in
                VStack(alignment: .leading, spacing: 8) {
                    Text(check.line)
                        .font(.caption)
                        .foregroundStyle(check.passed ? Color.primary : Color.red)
                    HStack(alignment: .top, spacing: 8) {
                        picture(StudioGoldenRenderer.bundledGoldenURL(check.goldenName).flatMap { try? Data(contentsOf: $0) },
                                "Golden")
                        picture(check.actualPNG, "Rendered")
                        picture(check.diffPNG, "Difference")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("studioSelfCheck.frame.\(check.id)")
                .accessibilityValue(check.passed ? "pass" : "fail")
            }
        }
        .navigationTitle(result.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func picture(_ png: Data?, _ caption: String) -> some View {
        VStack(spacing: 4) {
            if let png, let image = UIImage(data: png) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 190)
                    .border(Color.secondary.opacity(0.4))
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 190)
                    .overlay(Text("none").font(.caption2).foregroundStyle(.secondary))
            }
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
#endif
