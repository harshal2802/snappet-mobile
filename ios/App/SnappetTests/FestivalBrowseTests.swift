import XCTest
@testable import Snappet

/// The pure browse logic behind the hosted-catalog sheet (festival prompt 02, wireframe frame 3):
/// manifest decoding, row-state mapping, search/year filtering, and the meta-line formatting.
final class FestivalBrowseTests: XCTestCase {

    private func entry(id: String, name: String, location: String = "Somewhere",
                       start: String = "2026-06-24", end: String = "2026-06-28") -> FestivalLineupEntry {
        FestivalLineupEntry(id: id, name: name, location: location, startDate: start, endDate: end,
                            file: "\(id).fpack", url: nil, stages: 9, sets: 412,
                            sizeBytes: 38_000, updatedAt: "2026-06-22")
    }

    // MARK: - Manifest decode (the exact shape the web repo publishes)

    func testManifestDecodesTheHostedShape() throws {
        let json = """
        {
          "generatedAt": "2026-07-16",
          "festivals": [
            {
              "id": "glastonbury-2026",
              "name": "Glastonbury 2026",
              "location": "Worthy Farm, Pilton",
              "startDate": "2026-06-24",
              "endDate": "2026-06-28",
              "file": "glastonbury-2026.fpack",
              "stages": 9,
              "sets": 412,
              "sizeBytes": 38211,
              "updatedAt": "2026-06-22"
            }
          ]
        }
        """
        let manifest = try JSONDecoder().decode(FestivalLineupManifest.self,
                                                from: Data(json.utf8))
        XCTAssertEqual(manifest.festivals.count, 1)
        XCTAssertEqual(manifest.festivals[0].id, "glastonbury-2026")
        XCTAssertEqual(manifest.festivals[0].sets, 412)
        XCTAssertNil(manifest.festivals[0].url)
    }

    // MARK: - Row state

    func testRowStateMapsInstalledInstallingAndGet() {
        let glasto = entry(id: "glastonbury-2026", name: "Glastonbury 2026")
        XCTAssertEqual(FestivalBrowse.rowState(entry: glasto, installedPackIDs: [],
                                               installingPackID: nil, progress: 0), .get)
        XCTAssertEqual(FestivalBrowse.rowState(entry: glasto, installedPackIDs: ["glastonbury-2026"],
                                               installingPackID: nil, progress: 0), .installed)
        XCTAssertEqual(FestivalBrowse.rowState(entry: glasto, installedPackIDs: [],
                                               installingPackID: "glastonbury-2026", progress: 0.62),
                       .installing(0.62))
        // Another entry downloading doesn't light this row up.
        XCTAssertEqual(FestivalBrowse.rowState(entry: glasto, installedPackIDs: [],
                                               installingPackID: "sonar-2026", progress: 0.4), .get)
    }

    // MARK: - Filtering

    func testFilterMatchesNameAndLocationCaseInsensitively() {
        let entries = [
            entry(id: "glastonbury-2026", name: "Glastonbury 2026", location: "Worthy Farm, Pilton"),
            entry(id: "sonar-2026", name: "Sónar 2026", location: "Barcelona"),
        ]
        XCTAssertEqual(FestivalBrowse.filter(entries, query: "glasto", year: nil).map(\.id),
                       ["glastonbury-2026"])
        XCTAssertEqual(FestivalBrowse.filter(entries, query: "barcelona", year: nil).map(\.id),
                       ["sonar-2026"])
        XCTAssertEqual(FestivalBrowse.filter(entries, query: "  ", year: nil).count, 2,
                       "whitespace-only query is no filter")
        XCTAssertTrue(FestivalBrowse.filter(entries, query: "nope", year: nil).isEmpty)
    }

    func testFilterByYearChipAndYearsDerivation() {
        let entries = [
            entry(id: "a", name: "A", start: "2025-08-01", end: "2025-08-03"),
            entry(id: "b", name: "B", start: "2026-06-24", end: "2026-06-28"),
            entry(id: "c", name: "C", start: "2026-07-24", end: "2026-07-26"),
        ]
        XCTAssertEqual(FestivalBrowse.years(in: entries), ["2025", "2026"])
        XCTAssertEqual(FestivalBrowse.filter(entries, query: "", year: "2026").map(\.id), ["b", "c"])
        XCTAssertEqual(FestivalBrowse.filter(entries, query: "c", year: "2026").map(\.id), ["c"])
    }

    // MARK: - Meta line

    func testDateRangeFormats() {
        XCTAssertEqual(FestivalBrowse.dateRange(startDate: "2026-06-24", endDate: "2026-06-28"),
                       "Jun 24–28")
        XCTAssertEqual(FestivalBrowse.dateRange(startDate: "2026-08-30", endDate: "2026-09-01"),
                       "Aug 30 – Sep 1")
        XCTAssertEqual(FestivalBrowse.dateRange(startDate: "2026-06-24", endDate: "2026-06-24"),
                       "Jun 24")
        XCTAssertEqual(FestivalBrowse.dateRange(startDate: "garbage", endDate: "2026-06-28"),
                       "garbage – 2026-06-28", "unparseable dates degrade to the raw strings")
    }

    func testMetaLine() {
        XCTAssertEqual(FestivalBrowse.metaLine(startDate: "2026-06-24", endDate: "2026-06-28",
                                               stages: 9, sets: 412),
                       "Jun 24–28 · 9 stages · 412 sets")
    }
}
