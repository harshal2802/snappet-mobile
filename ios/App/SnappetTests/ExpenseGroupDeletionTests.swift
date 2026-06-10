import XCTest
import SwiftData
@testable import Snappet

/// Locks the #69 data-integrity guarantee: deleting an `ExpenseGroup` must sweep every
/// `ExpenseRecord` keyed to it (even splits, itemized receipts, and settlements all share
/// the one model) — the flat `groupID` reference means nothing cascades on its own.
/// Runs against an in-memory `ModelContainer`, no UI involved.
@MainActor
final class ExpenseGroupDeletionTests: XCTestCase {

    /// Kept as a property: a `ModelContext` does NOT retain its `ModelContainer`, so a
    /// helper returning only the context lets the container deallocate and every later
    /// SwiftData call traps (EXC_BREAKPOINT, no message). Hold the container for the
    /// test's lifetime and hand out its `mainContext`.
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func makeContext() -> ModelContext {
        container.mainContext
    }

    /// Two groups; the doomed one carries an even split, an itemized receipt, and a
    /// settlement. Deleting it must remove exactly its three records and the group, and
    /// leave the other group's record untouched.
    func testDeleteSweepsAllRecordTypesAndSparesOtherGroups() throws {
        let context = makeContext()
        let doomed = ExpenseGroup(name: "Trip", participants: ["A", "B"])
        let survivor = ExpenseGroup(name: "Roommates", participants: ["C", "D"])
        context.insert(doomed)
        context.insert(survivor)

        context.insert(ExpenseRecord(groupID: doomed.id, title: "Dinner", amount: 40,
                                     payer: "A", participants: ["A", "B"]))
        context.insert(ExpenseRecord(groupID: doomed.id, title: "Groceries", amount: 30,
                                     payer: "B", participants: ["A", "B"],
                                     items: [ReceiptItem(name: "Milk", price: 30, assignees: ["A"])]))
        context.insert(ExpenseRecord(groupID: doomed.id, title: "Settle", amount: 20,
                                     payer: "B", participants: ["A"], isSettlement: true))
        context.insert(ExpenseRecord(groupID: survivor.id, title: "Rent", amount: 800,
                                     payer: "C", participants: ["C", "D"]))
        try context.save()

        ExpenseGroupDeletion.delete(doomed, from: context)

        let remainingRecords = try context.fetch(FetchDescriptor<ExpenseRecord>())
        let remainingGroups = try context.fetch(FetchDescriptor<ExpenseGroup>())
        XCTAssertEqual(remainingRecords.map(\.title), ["Rent"], "only the other group's record survives")
        XCTAssertEqual(remainingGroups.map(\.name), ["Roommates"], "only the other group survives")
    }

    func testRecordCountCountsOnlyTheGroupsRecords() throws {
        let context = makeContext()
        let group = ExpenseGroup(name: "Trip", participants: ["A", "B"])
        let other = ExpenseGroup(name: "Other", participants: ["C"])
        context.insert(group)
        context.insert(other)
        context.insert(ExpenseRecord(groupID: group.id, title: "Dinner", amount: 40,
                                     payer: "A", participants: ["A", "B"]))
        context.insert(ExpenseRecord(groupID: group.id, title: "Settle", amount: 20,
                                     payer: "B", participants: ["A"], isSettlement: true))
        context.insert(ExpenseRecord(groupID: other.id, title: "Rent", amount: 800,
                                     payer: "C", participants: ["C"]))
        try context.save()

        XCTAssertEqual(ExpenseGroupDeletion.recordCount(for: group.id, in: context), 2)
        XCTAssertEqual(ExpenseGroupDeletion.recordCount(for: other.id, in: context), 1)
        XCTAssertEqual(ExpenseGroupDeletion.recordCount(for: UUID(), in: context), 0)
    }
}
