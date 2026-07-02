import XCTest
@testable import Snappet

/// Pure `.spack` container tests (guide-photo pack). The fixture builder mirrors
/// `tools/workout/build_photo_pack.py` byte-for-byte, so these are effectively golden tests of
/// the cross-tool format: magic + 4B LE index length + index JSON + concatenated blobs.
final class ExercisePhotoPackTests: XCTestCase {

    /// Build pack bytes exactly like the python tool (sorted ids, start→end blob order).
    private func makePack(_ photos: [String: [Data]], magic: Data = ExercisePhotoPack.magic) -> Data {
        var index: [String: [[String: Int]]] = [:]
        var blob = Data()
        for id in photos.keys.sorted() {
            var entries: [[String: Int]] = []
            for photo in photos[id] ?? [] {
                entries.append(["offset": blob.count, "length": photo.count])
                blob.append(photo)
            }
            index[id] = entries
        }
        let json = try! JSONSerialization.data(withJSONObject: ["exercises": index])
        var pack = magic
        var length = UInt32(json.count).littleEndian
        pack.append(Data(bytes: &length, count: 4))
        pack.append(json)
        pack.append(blob)
        return pack
    }

    private func parse(_ pack: Data) throws -> ExercisePhotoPack.Index {
        let indexLength = try ExercisePhotoPack.indexLength(header: pack.prefix(12))
        let json = pack.subdata(in: 12..<(12 + indexLength))
        return try ExercisePhotoPack.parseIndex(json, packSize: Int64(pack.count))
    }

    func testRoundtripSlicesExactBlobs() throws {
        let bench = [Data("start-jpeg-bytes".utf8), Data("end-jpeg-bytes!!".utf8)]
        let squat = [Data("only-photo".utf8)]
        let pack = makePack(["Bench_Press": bench, "Squat": squat])

        let index = try parse(pack)
        XCTAssertEqual(index.exerciseCount, 2)
        XCTAssertEqual(index.photoCount, 3)

        let benchRanges = index.photoRanges(for: "Bench_Press")
        XCTAssertEqual(benchRanges.count, 2)
        for (range, expected) in zip(benchRanges, bench) {
            XCTAssertEqual(pack.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)), expected)
        }
        let squatRanges = index.photoRanges(for: "Squat")
        XCTAssertEqual(squatRanges.count, 1)
        XCTAssertEqual(pack.subdata(in: Int(squatRanges[0].lowerBound)..<Int(squatRanges[0].upperBound)),
                       squat[0])
    }

    func testUnknownExerciseHasNoRanges() throws {
        let pack = makePack(["Bench_Press": [Data("x".utf8)]])
        let index = try parse(pack)
        XCTAssertTrue(index.photoRanges(for: "Custom_123").isEmpty)
    }

    func testBadMagicThrows() {
        let pack = makePack(["Bench_Press": [Data("x".utf8)]], magic: Data("NOTAPACK".utf8))
        XCTAssertThrowsError(try parse(pack)) { error in
            XCTAssertEqual(error as? ExercisePhotoPack.PackError, .badMagic)
        }
    }

    func testTruncatedHeaderThrows() {
        XCTAssertThrowsError(try ExercisePhotoPack.indexLength(header: Data("SPHOT".utf8))) { error in
            XCTAssertEqual(error as? ExercisePhotoPack.PackError, .truncated)
        }
    }

    func testZeroIndexLengthThrows() {
        var pack = ExercisePhotoPack.magic
        pack.append(Data(count: 4))   // index length 0
        XCTAssertThrowsError(try ExercisePhotoPack.indexLength(header: pack)) { error in
            XCTAssertEqual(error as? ExercisePhotoPack.PackError, .badIndex)
        }
    }

    func testGarbageIndexJSONThrows() {
        XCTAssertThrowsError(try ExercisePhotoPack.parseIndex(Data("{nope".utf8), packSize: 100)) { error in
            XCTAssertEqual(error as? ExercisePhotoPack.PackError, .badIndex)
        }
    }

    func testTruncatedPackFailsBoundsCheck() throws {
        // A slice pointing past the end of the (cut-short) file must throw, not read garbage.
        let pack = makePack(["Bench_Press": [Data(repeating: 0xAB, count: 64)]])
        let indexLength = try ExercisePhotoPack.indexLength(header: pack.prefix(12))
        let json = pack.subdata(in: 12..<(12 + indexLength))
        XCTAssertThrowsError(try ExercisePhotoPack.parseIndex(json, packSize: Int64(pack.count - 10))) { error in
            XCTAssertEqual(error as? ExercisePhotoPack.PackError, .truncated)
        }
    }

    func testManifestDecodeAndSizeLabel() throws {
        let json = """
        {"version":1,"file":"photos-v1.spack","sizeBytes":39845888,
         "photoCount":1712,"exerciseCount":856,"generated":"2026-07-02T00:00:00+00:00"}
        """
        let manifest = try JSONDecoder().decode(PhotoPackManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.file, "photos-v1.spack")
        XCTAssertEqual(manifest.photoCount, 1712)
        XCTAssertFalse(manifest.sizeLabel.isEmpty)
    }
}
