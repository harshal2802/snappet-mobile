import XCTest
import SwiftData
@testable import Snappet

/// Applying and reversing the cleanup (wardrobe prompt 05). The plan is pure and tested
/// separately; this covers the part that writes to a real closet — and, more importantly, the
/// part that has to be able to take it all back.
@MainActor
final class WardrobeTidyStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    @discardableResult
    private func item(name: String, material: String = "") -> WardrobeItem {
        let i = WardrobeItem(name: name, category: .top, color: .blue, material: material)
        context.insert(i)
        return i
    }

    // MARK: apply

    func testApplyMovesBrandOutOfMaterialAndNormalizesIt() {
        let i = item(name: "Tee", material: "Uniqlo ")
        WardrobeTidyStore.apply(WardrobeTidyStore.plan(in: context).edits, in: context)

        XCTAssertEqual(i.brand, "Uniqlo", "the trailing space is gone")
        XCTAssertEqual(i.material, "", "the value moved rather than being copied")
    }

    func testApplyLiftsSizeOutOfTheName() {
        let i = item(name: "Black tank top size M")
        WardrobeTidyStore.apply(WardrobeTidyStore.plan(in: context).edits, in: context)

        XCTAssertEqual(i.sizeLabel, "M")
        XCTAssertEqual(i.name, "Black tank top")
    }

    /// The cleanup exists partly to populate the dropdowns — a tidy that leaves them empty has
    /// only done half the job.
    func testApplyFeedsTheBrandVocabulary() {
        item(name: "Tee", material: "Uniqlo ")
        item(name: "Legging", material: "Lululemon")
        WardrobeTidyStore.apply(WardrobeTidyStore.plan(in: context).edits, in: context)

        let brands = WardrobeVocabularyStore.choices(for: .brand, in: context).map(\.value)
        XCTAssertTrue(brands.contains("Uniqlo"))
        XCTAssertTrue(brands.contains("Lululemon"))
    }

    /// Apply teaches the dropdowns only from its OWN edits. The old loop re-remembered every
    /// item's brand/size on every run — untouched items must not be (re)counted by a tidy.
    func testApplyFeedsVocabularyOnlyFromItsOwnEdits() {
        let untouched = item(name: "Hoodie")
        untouched.brand = "Uniqlo"                      // already tidy — no edit targets it
        item(name: "Legging", material: "Lululemon ")   // the one real edit (material → brand)
        WardrobeTidyStore.apply(WardrobeTidyStore.plan(in: context).edits, in: context)

        let brands = WardrobeVocabularyStore.choices(for: .brand, in: context).map(\.value)
        XCTAssertTrue(brands.contains("Lululemon"), "the edit's new value is remembered")
        XCTAssertFalse(brands.contains("Uniqlo"),
                       "an untouched item's brand is not swept into the vocabulary by a tidy")
    }

    func testApplyIsRecordedAsOneBatch() {
        item(name: "Tee size S", material: "Uniqlo")
        let batch = WardrobeTidyStore.apply(WardrobeTidyStore.plan(in: context).edits, in: context)

        let edits = try! context.fetch(FetchDescriptor<WardrobeTidyEdit>())
        XCTAssertFalse(edits.isEmpty)
        XCTAssertTrue(edits.allSatisfy { $0.batchID == batch }, "one run is one batch")
        XCTAssertTrue(edits.allSatisfy { !$0.isUndone })
    }

    /// Nothing may change from merely *building* a plan.
    func testPlanningAloneChangesNothing() {
        let i = item(name: "Black tank top size M", material: "Uniqlo ")
        _ = WardrobeTidyStore.plan(in: context)

        XCTAssertEqual(i.material, "Uniqlo ")
        XCTAssertEqual(i.brand, "")
        XCTAssertEqual(i.name, "Black tank top size M")
        XCTAssertTrue(try! context.fetch(FetchDescriptor<WardrobeTidyEdit>()).isEmpty)
    }

    // MARK: undo — the reason the edit log exists

    func testUndoRestoresEveryOriginalValue() {
        let i = item(name: "Black tank top size M", material: "Uniqlo ")
        let batch = WardrobeTidyStore.apply(WardrobeTidyStore.plan(in: context).edits, in: context)

        WardrobeTidyStore.undo(batchID: batch, in: context)

        XCTAssertEqual(i.material, "Uniqlo ", "restored verbatim, whitespace and all")
        XCTAssertEqual(i.brand, "")
        XCTAssertEqual(i.sizeLabel, "")
        XCTAssertEqual(i.name, "Black tank top size M")
    }

    func testUndoMarksTheBatchRatherThanDeletingIt() {
        item(name: "Tee", material: "Uniqlo")
        let batch = WardrobeTidyStore.apply(WardrobeTidyStore.plan(in: context).edits, in: context)
        WardrobeTidyStore.undo(batchID: batch, in: context)

        let edits = try! context.fetch(FetchDescriptor<WardrobeTidyEdit>())
        XCTAssertFalse(edits.isEmpty, "history survives an undo")
        XCTAssertTrue(edits.allSatisfy(\.isUndone))
    }

    /// A second undo must be a no-op, not a re-application.
    func testUndoingTwiceIsHarmless() {
        let i = item(name: "Tee", material: "Uniqlo")
        let batch = WardrobeTidyStore.apply(WardrobeTidyStore.plan(in: context).edits, in: context)
        WardrobeTidyStore.undo(batchID: batch, in: context)
        WardrobeTidyStore.undo(batchID: batch, in: context)

        XCTAssertEqual(i.material, "Uniqlo")
        XCTAssertEqual(i.brand, "")
    }

    func testUndoableBatchReportsTheLatestRun() {
        item(name: "Tee", material: "Uniqlo")
        XCTAssertNil(WardrobeTidyStore.undoableBatch(in: context), "nothing applied yet")

        let batch = WardrobeTidyStore.apply(WardrobeTidyStore.plan(in: context).edits, in: context)
        let undoable = WardrobeTidyStore.undoableBatch(in: context)
        XCTAssertEqual(undoable?.id, batch)
        XCTAssertGreaterThan(undoable?.count ?? 0, 0)

        WardrobeTidyStore.undo(batchID: batch, in: context)
        XCTAssertNil(WardrobeTidyStore.undoableBatch(in: context), "an undone batch isn't offered")
    }

    // MARK: idempotence

    /// Re-running the cleanup after applying it must find nothing left to do.
    func testTidyingTwiceFindsNothingTheSecondTime() {
        item(name: "Black tank top size M", material: "Uniqlo")
        WardrobeTidyStore.apply(WardrobeTidyStore.plan(in: context).edits, in: context)

        let second = WardrobeTidyStore.plan(in: context)
        XCTAssertTrue(second.edits.isEmpty, "a tidied closet has nothing left to move")
    }
}
