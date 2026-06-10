import XCTest
@testable import Snappet

/// Pure logic behind the issue-#82 finance-UX pass: second-person balance/transfer
/// phrasing when the user has identified themselves, and cross-group participant-name
/// suggestions for a new group.
final class FinanceUXTests: XCTestCase {

    // MARK: - Second-person phrasing

    func testTransferReadsYouOweWhenUserIsDebtor() {
        XCTAssertEqual(SettleUp.transferLabel(debtor: "Alice", creditor: "Bob", me: "Alice"),
                       "You owe Bob")
    }

    func testTransferReadsOwesYouWhenUserIsCreditor() {
        XCTAssertEqual(SettleUp.transferLabel(debtor: "Alice", creditor: "Bob", me: "Bob"),
                       "Alice owes you")
    }

    func testTransferStaysThirdPersonForOthersOrUnknownMe() {
        XCTAssertEqual(SettleUp.transferLabel(debtor: "Alice", creditor: "Bob", me: "Cleo"),
                       "Alice owes Bob")
        XCTAssertEqual(SettleUp.transferLabel(debtor: "Alice", creditor: "Bob", me: nil),
                       "Alice owes Bob")
    }

    func testBalanceNameBecomesYou() {
        XCTAssertEqual(SettleUp.balanceName("Alice", me: "Alice"), "You")
        XCTAssertEqual(SettleUp.balanceName("Alice", me: "Bob"), "Alice")
        XCTAssertEqual(SettleUp.balanceName("Alice", me: nil), "Alice")
    }

    // MARK: - Participant suggestions

    func testSuggestionsCollectAcrossGroupsInFirstSeenOrder() {
        let names = SettleUp.participantSuggestions(
            existingGroups: [["Alice", "Bob"], ["Cleo", "Bob"]],
            alreadyChosen: [])
        XCTAssertEqual(names, ["Alice", "Bob", "Cleo"])
    }

    func testSuggestionsExcludeAlreadyChosenCaseInsensitively() {
        let names = SettleUp.participantSuggestions(
            existingGroups: [["Alice", "Bob"], ["Cleo"]],
            alreadyChosen: ["alice ", ""])
        XCTAssertEqual(names, ["Bob", "Cleo"])
    }

    func testSuggestionsDropEmptiesAndDuplicates() {
        let names = SettleUp.participantSuggestions(
            existingGroups: [["", "Alice", "ALICE", " "], ["Alice"]],
            alreadyChosen: [])
        XCTAssertEqual(names, ["Alice"])
    }
}
