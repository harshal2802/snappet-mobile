import XCTest
import AVFoundation
@testable import Snappet

/// What the Studio golden-frame test classes share (prompt 304): where the golden images are,
/// whether this run records them, and the fixture videos, written once per test class.
class StudioFixtureTestCase: XCTestCase {

    /// `SnappetTests/GoldenFrames`, found from this file's own path.
    static let goldenDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("GoldenFrames", isDirectory: true)

    /// True while the marker file `GoldenFrames/.record` exists.
    static var isRecording: Bool {
        FileManager.default.fileExists(atPath: goldenDirectory.appendingPathComponent(".record").path)
    }

    /// What every golden test fails with while the marker is there.
    static let recordingMessage = "Golden images are being recorded in this run. Delete "
        + "SnappetTests/GoldenFrames/.record and run again."

    static func storedGolden(_ name: String) -> StudioGoldenImage? {
        guard let data = try? Data(contentsOf: goldenDirectory.appendingPathComponent(name)) else { return nil }
        return StudioGoldenRenderer.image(pngData: data)
    }

    /// The sources a class needs. Test classes run one after another, so one slot is enough.
    class var sources: [StudioGoldenSource] { StudioGoldenSource.golden }

    nonisolated(unsafe) private static var shared: StudioGoldenRenderer.Fixture?
    nonisolated(unsafe) private static var sharedError: String?

    override class func setUp() {
        super.setUp()
        shared = nil
        sharedError = nil
        do {
            shared = try StudioGoldenRenderer.makeFixture(sources, in: StudioGoldenRenderer.newFixtureDirectory())
        } catch {
            sharedError = error.localizedDescription
        }
    }

    override class func tearDown() {
        shared?.remove()
        shared = nil
        super.tearDown()
    }

    func fixture() throws -> StudioGoldenRenderer.Fixture {
        try XCTUnwrap(Self.shared, "the fixture videos were not written: \(Self.sharedError ?? "?")")
    }

    func scene(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> StudioGoldenScene {
        try XCTUnwrap(StudioGoldenScene.all.first { $0.id == id }, "no scene \(id)", file: file, line: line)
    }

    func golden(_ scene: StudioGoldenScene, frame: Int, file: StaticString = #filePath,
                line: UInt = #line) throws -> StudioGoldenImage {
        try XCTUnwrap(Self.storedGolden(scene.fileName(frame: frame)),
                      "no golden image \(scene.fileName(frame: frame))", file: file, line: line)
    }

    func attach(_ png: Data?, _ name: String) {
        guard let png else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name + ".png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func attach(_ image: StudioGoldenImage, _ name: String) {
        attach(StudioGoldenRenderer.pngData(image), name)
    }

    /// The simulator's tolerance for a path — what the golden tests use.
    func production(_ path: StudioSelfCheck.RenderPath) -> StudioGoldenTolerance {
        StudioSelfCheck.tolerance(for: path, on: .simulator)
    }
}
