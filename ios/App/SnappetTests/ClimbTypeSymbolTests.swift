import XCTest
import UIKit
@testable import Snappet

/// Every climb type's SF Symbol must exist — a misspelt name renders nothing at all (the Library's blank "Boulder"
/// row, prompt 182) and nothing else fails.
final class ClimbTypeSymbolTests: XCTestCase {
    func testEveryClimbTypeSymbolResolves() {
        for type in ClimbType.allCases {
            XCTAssertNotNil(UIImage(systemName: type.symbol), "\(type) → \(type.symbol) is not an SF Symbol")
        }
    }

    func testEveryDisciplineSymbolResolves() {
        for d in WorkoutDiscipline.allCases {
            XCTAssertNotNil(UIImage(systemName: d.symbol), "\(d) → \(d.symbol) is not an SF Symbol")
        }
    }
}
