import XCTest
@testable import Legado

final class SearchMatchModeTests: XCTestCase {
    func testExactSearchOnlyMatchesTheCompleteBookName() {
        let exact = SearchBook(name: "青山")
        let longerTitle = SearchBook(name: "青山镇")
        let authorOnly = SearchBook(name: "别的书", author: "青山")

        XCTAssertTrue(SearchResultViewModel.matchesKeyword(exact, keyword: "青山", mode: .exact))
        XCTAssertFalse(SearchResultViewModel.matchesKeyword(longerTitle, keyword: "青山", mode: .exact))
        XCTAssertFalse(SearchResultViewModel.matchesKeyword(authorOnly, keyword: "青山", mode: .exact))
    }

    func testNormalSearchRetainsContainsMatching() {
        let longerTitle = SearchBook(name: "青山镇")
        let authorOnly = SearchBook(name: "别的书", author: "青山")

        XCTAssertTrue(SearchResultViewModel.matchesKeyword(longerTitle, keyword: "青山", mode: .contains))
        XCTAssertTrue(SearchResultViewModel.matchesKeyword(authorOnly, keyword: "青山", mode: .contains))
    }
}
