import XCTest
@testable import Snappet

/// The overlay reference capture (prompt 304) runs and writes its files. Here, on the simulator,
/// that is all that can be checked: the reference itself has to be captured on a phone.
final class StudioOverlayReferenceCaptureTests: XCTestCase {

    func testCaptureWritesEveryFrameAndAManifest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-reference-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Something already there is cleared away first.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1]).write(to: directory.appendingPathComponent("stale.png"))

        let files = try await StudioGoldenRenderer.captureOverlayReference(
            into: directory, machine: .simulator, device: "unit test", capturedAt: "2026-11-25T00:00:00Z")

        XCTAssertEqual(files.map(\.lastPathComponent), StudioOverlayReference.fileNames)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set(StudioOverlayReference.fileNames), "exactly the capture's files")
        let manifest = try JSONDecoder().decode(StudioOverlayReference.Manifest.self,
                                                from: Data(contentsOf: try XCTUnwrap(files.last)))
        XCTAssertEqual(manifest.frames.map(\.file), Array(StudioOverlayReference.fileNames.dropLast()))
        XCTAssertEqual(manifest.machine, "simulator")
        XCTAssertEqual(manifest.device, "unit test")
        XCTAssertTrue(manifest.note.contains("NOT a reference"))
        for (entry, url) in zip(manifest.frames, files) {
            let image = try XCTUnwrap(StudioGoldenRenderer.image(pngData: Data(contentsOf: url)), entry.file)
            XCTAssertEqual(image.width, 540, entry.file)
            XCTAssertEqual(image.height, 960, entry.file)
            XCTAssertEqual(entry.width, 540)
            XCTAssertEqual(entry.height, 960)
        }

        // What the Core Animation tool drew here, for the record (printed, not asserted: it is
        // the simulator's behaviour, not ours). The plain white line of text is the only overlay
        // in frame 5 of the text scene; the same frame of the bare clip is the comparison.
        let fixtureDirectory = StudioGoldenRenderer.newFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let fixture = try StudioGoldenRenderer.makeFixture([.overlayBase], in: fixtureDirectory)
        var bare = StudioGoldenScene.passThrough(.overlayBase)
        bare.frames = [5]
        let without = try await StudioGoldenRenderer.frames(of: bare, fixture: fixture, path: .export)[0]
        let with = try XCTUnwrap(StudioGoldenRenderer.image(pngData: Data(contentsOf: files[0])))
        let result = StudioGoldenCompare.compare(actual: with, golden: without,
                                                 tolerance: StudioSelfCheck.tolerance(for: .export, on: .simulator))
        print("StudioOverlayReferenceCaptureTests: plain text over the clip, against the bare clip: \(result.summary)")
    }

    // MARK: The committed reference (prompt 307)

    /// `SnappetTests/GoldenFrames/OverlayReference`, found from this file's own path. The
    /// `GoldenFrames` folder is left out of the test bundle, so these are read from the repo.
    static let committedDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("GoldenFrames/OverlayReference", isDirectory: true)

    /// The committed reference is one whole phone capture: exactly the files a capture writes
    /// (and a README), a manifest from a device made by today's renderer, every frame a 540×960
    /// PNG named in the manifest.
    func testTheCommittedReferenceIsAWholePhoneCapture() throws {
        let present = Set(try FileManager.default.contentsOfDirectory(atPath: Self.committedDirectory.path))
        XCTAssertEqual(present.subtracting(["README.md"]), Set(StudioOverlayReference.fileNames))
        XCTAssertTrue(present.contains("README.md"), "the README says what the files are")

        let manifest = try JSONDecoder().decode(
            StudioOverlayReference.Manifest.self,
            from: Data(contentsOf: Self.committedDirectory.appendingPathComponent(StudioOverlayReference.manifestName)))
        XCTAssertEqual(manifest.machine, StudioSelfCheck.Machine.device.rawValue, "a simulator capture is not a reference")
        XCTAssertEqual(manifest.note, StudioOverlayReference.note(for: .device))
        XCTAssertEqual(manifest.renderer, StudioOverlayReference.renderer)
        XCTAssertEqual(manifest.frames.map(\.file), Array(StudioOverlayReference.fileNames.dropLast()))
        for entry in manifest.frames {
            let url = Self.committedDirectory.appendingPathComponent(entry.file)
            let image = try XCTUnwrap(StudioGoldenRenderer.image(pngData: Data(contentsOf: url)), entry.file)
            XCTAssertEqual(image.width, 540, entry.file)
            XCTAssertEqual(image.height, 960, entry.file)
            XCTAssertEqual(entry.width, 540, entry.file)
            XCTAssertEqual(entry.height, 960, entry.file)
        }
    }

    /// Every frame marked wrong is one the reference holds, and the README names it.
    func testKnownWrongFramesAreInTheReferenceAndNamedInTheReadme() throws {
        XCTAssertTrue(StudioOverlayReference.knownWrongFrames.isSubset(of: Set(StudioOverlayReference.fileNames)))
        let readme = try String(contentsOf: Self.committedDirectory.appendingPathComponent("README.md"), encoding: .utf8)
        for file in StudioOverlayReference.knownWrongFrames {
            XCTAssertTrue(readme.contains(file), "README.md should explain why \(file) is wrong")
        }
    }
}
