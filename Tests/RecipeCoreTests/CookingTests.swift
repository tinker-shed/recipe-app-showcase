import XCTest
@testable import RecipeCore
final class CookingTests: XCTestCase {
  func testCookingProgressAndWakeLifecycle() {
    var session = CookingSession()
    XCTAssertTrue(session.shouldPreventSleep)
    session.toggleIngredient(12); session.highlight(18)
    session.foreground = false
    XCTAssertFalse(session.shouldPreventSleep)
    session.foreground = true
    XCTAssertEqual(session.checked, [12]); XCTAssertEqual(session.currentBlock, 18)
    session.toggleIngredient(12); XCTAssertTrue(session.checked.isEmpty)
    session.keepAwake = false; XCTAssertFalse(session.shouldPreventSleep)
    session.keepAwake = true; XCTAssertTrue(session.shouldPreventSleep)
    session.finish(); XCTAssertFalse(session.shouldPreventSleep)
    XCTAssertTrue(CookingSession().checked.isEmpty)
  }
}
