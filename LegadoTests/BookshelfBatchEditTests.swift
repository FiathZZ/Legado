import SwiftData
import XCTest
@testable import Legado

@MainActor
final class BookshelfBatchEditTests: XCTestCase {
    func testCustomInfoOverridesFallbackFields() {
        let book = BookEntity(
            bookUrl: "https://book.example/1",
            name: "测试书籍",
            author: "作者",
            coverUrl: "https://img.example/original.jpg",
            intro: "原始简介",
            sourceUrl: "https://source.example"
        )

        XCTAssertEqual(book.effectiveCoverUrl, "https://img.example/original.jpg")
        XCTAssertEqual(book.effectiveIntro, "原始简介")
        XCTAssertNil(book.effectiveTag)

        book.customCoverUrl = " https://img.example/custom.jpg "
        book.customIntro = " 自定义简介 "
        book.customTag = " 必读 "

        XCTAssertEqual(book.effectiveCoverUrl, "https://img.example/custom.jpg")
        XCTAssertEqual(book.effectiveIntro, "自定义简介")
        XCTAssertEqual(book.effectiveTag, "必读")

        book.customCoverUrl = "   "
        book.customIntro = "\n"
        book.customTag = ""

        XCTAssertEqual(book.effectiveCoverUrl, "https://img.example/original.jpg")
        XCTAssertEqual(book.effectiveIntro, "原始简介")
        XCTAssertNil(book.effectiveTag)
    }

    func testCustomInfoAndGroupsPersistAcrossSaveAndReload() throws {
        let container = try LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let firstBook = BookEntity(
            bookUrl: "https://book.example/1",
            name: "甲书",
            author: "作者甲",
            sourceUrl: "https://source.example"
        )
        let secondBook = BookEntity(
            bookUrl: "https://book.example/2",
            name: "乙书",
            author: "作者乙",
            sourceUrl: "https://source.example"
        )

        firstBook.customCoverUrl = "https://img.example/cover.jpg"
        firstBook.customIntro = "自定义简介"
        firstBook.customTag = "收藏"
        firstBook.addGroup(1)
        firstBook.addGroup(4)
        secondBook.addGroup(4)

        context.insert(firstBook)
        context.insert(secondBook)
        try context.save()

        let reloadedBooks = try context.fetch(
            FetchDescriptor<BookEntity>(
                sortBy: [SortDescriptor(\.bookUrl, order: .forward)]
            )
        )

        XCTAssertEqual(reloadedBooks.count, 2)

        let reloadedFirstBook = try XCTUnwrap(reloadedBooks.first)
        XCTAssertEqual(reloadedFirstBook.customCoverUrl, "https://img.example/cover.jpg")
        XCTAssertEqual(reloadedFirstBook.customIntro, "自定义简介")
        XCTAssertEqual(reloadedFirstBook.customTag, "收藏")
        XCTAssertEqual(reloadedFirstBook.group, 5)
        XCTAssertTrue(reloadedFirstBook.hasGroup(1))
        XCTAssertTrue(reloadedFirstBook.hasGroup(4))

        let reloadedSecondBook = try XCTUnwrap(reloadedBooks.last)
        XCTAssertTrue(reloadedSecondBook.hasGroup(4))
        XCTAssertFalse(reloadedSecondBook.hasGroup(1))

        reloadedFirstBook.removeGroup(1)
        try context.save()

        let updatedFirstBook = try XCTUnwrap(
            context.fetch(FetchDescriptor<BookEntity>()).first(where: { $0.bookUrl == firstBook.bookUrl })
        )
        XCTAssertEqual(updatedFirstBook.group, 4)
        XCTAssertFalse(updatedFirstBook.hasGroup(1))
        XCTAssertTrue(updatedFirstBook.hasGroup(4))
    }
}
