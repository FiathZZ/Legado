import XCTest
import SwiftUI
@testable import Legado

final class ReaderEngineTests: XCTestCase {
    private let service = ReaderChapterRenderingService()

    func testReaderEnginePaginatesLongChapterIntoMultiplePages() {
        let configuration = ReaderLayoutConfiguration(
            viewportSize: CGSize(width: 220, height: 320),
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            fontSize: 18,
            lineSpacing: 8,
            paragraphSpacing: 16
        )

        let content = Array(repeating: "这是一个很长的测试段落，用来验证新的阅读内核分页逻辑。", count: 120)
            .joined(separator: "\n")

        let render = service.renderChapter(
            bookID: "book-1",
            chapterID: "chapter-1",
            chapterIndex: 0,
            chapterTitle: "第一章",
            content: content,
            configuration: configuration
        )

        XCTAssertGreaterThan(render.pageCount, 1)
        XCTAssertEqual(render.pages.first?.pageIndex, 0)
        XCTAssertEqual(render.pages.last?.pageIndex, render.pageCount - 1)
        XCTAssertEqual(render.pages.first?.chapterID, "chapter-1")
    }

    func testReaderEngineRepaginatesWhenFontSizeChanges() {
        let compact = ReaderLayoutConfiguration(
            viewportSize: CGSize(width: 220, height: 320),
            fontSize: 16,
            lineSpacing: 6,
            paragraphSpacing: 12
        )
        let expanded = ReaderLayoutConfiguration(
            viewportSize: CGSize(width: 220, height: 320),
            fontSize: 24,
            lineSpacing: 10,
            paragraphSpacing: 18
        )

        let content = Array(repeating: "分页配置变化后应该触发重排。", count: 120)
            .joined(separator: "\n")

        let compactRender = service.renderChapter(
            bookID: "book-1",
            chapterID: "chapter-2",
            chapterIndex: 1,
            chapterTitle: "第二章",
            content: content,
            configuration: compact
        )
        let expandedRender = service.renderChapter(
            bookID: "book-1",
            chapterID: "chapter-2",
            chapterIndex: 1,
            chapterTitle: "第二章",
            content: content,
            configuration: expanded
        )

        XCTAssertGreaterThanOrEqual(expandedRender.pageCount, compactRender.pageCount)
        XCTAssertNotEqual(expandedRender.pages.first?.contentRange.length, compactRender.pages.first?.contentRange.length)
    }

    func testReaderEngineClampsReadingPositionToValidPageRange() {
        let configuration = ReaderLayoutConfiguration(
            viewportSize: CGSize(width: 240, height: 360)
        )
        let content = Array(repeating: "位置需要被正确夹紧。", count: 80)
            .joined(separator: "\n")

        let render = service.renderChapter(
            bookID: "book-1",
            chapterID: "chapter-3",
            chapterIndex: 2,
            chapterTitle: "第三章",
            content: content,
            configuration: configuration
        )

        let clamped = render.clampedPosition(
            ReadingPosition(chapterIndex: 99, pageIndex: 999, utf16Offset: Int.max)
        )

        XCTAssertEqual(clamped.chapterIndex, 2)
        XCTAssertEqual(clamped.pageIndex, max(render.pageCount - 1, 0))
        XCTAssertLessThanOrEqual(clamped.utf16Offset, render.pages[clamped.pageIndex].contentRange.location + render.pages[clamped.pageIndex].contentRange.length)
    }

    func testReaderAndEnginePositionsBridgeWithoutDataLoss() {
        let readerPosition = ReaderPosition(chapterIndex: 3, pageIndex: 7, utf16Offset: 512)
        let enginePosition = readerPosition.enginePosition

        XCTAssertEqual(enginePosition, ReadingPosition(chapterIndex: 3, pageIndex: 7, utf16Offset: 512))
        XCTAssertEqual(ReaderPosition(enginePosition: enginePosition), readerPosition)
    }

    @MainActor
    func testReaderProgressServiceRestoresPersistedPagePosition() {
        let service = ReaderProgressService()
        let bookURL = "reader-engine-test-book"
        let chapters = [
            BookChapter(title: "第一章", url: "chapter-1", bookUrl: bookURL),
            BookChapter(title: "第二章", url: "chapter-2", bookUrl: bookURL)
        ]
        let position = ReaderPosition(chapterIndex: 1, pageIndex: 3, utf16Offset: 128)

        service.saveReadingProgress(
            bookEntity: nil,
            chapters: chapters,
            currentIndex: 0,
            currentPosition: position,
            bookURL: bookURL,
            modelContext: nil
        )

        let restored = service.restoreReadingProgress(bookURL: bookURL, fallbackChapterIndex: 0)
        XCTAssertEqual(restored, position)

        UserDefaults.standard.removeObject(forKey: "reader.progress.position.\(bookURL)")
    }

    func testReaderAppearanceSettingsBuildsLayoutConfiguration() {
        let settings = ReaderAppearanceSettings(
            theme: .mist,
            flipMode: .slide,
            fontName: "Georgia",
            fontSize: 22,
            lineSpacing: 10,
            paragraphSpacing: 16,
            paragraphIndentCount: 2,
            horizontalPadding: 28,
            verticalPadding: 20,
            letterSpacing: 0.2
        )

        let layout = settings.makeLayoutConfiguration(
            viewportSize: CGSize(width: 320, height: 480),
            safeAreaInsets: EdgeInsets(top: 12, leading: 4, bottom: 8, trailing: 6)
        )

        XCTAssertEqual(layout.fontName, "Georgia")
        XCTAssertEqual(layout.fontSize, 22)
        XCTAssertEqual(layout.lineSpacing, 10)
        XCTAssertEqual(layout.paragraphSpacing, 16)
        XCTAssertEqual(layout.paragraphIndentCount, 2)
        XCTAssertEqual(layout.contentInsets.left, 32)
        XCTAssertEqual(layout.contentInsets.top, 32)
        XCTAssertEqual(layout.contentInsets.bottom, 28)
        XCTAssertEqual(layout.contentInsets.right, 34)
    }

    func testReaderFontOptionsIncludeRegisteredLibraryFonts() {
        let bundled = ThemeFontLibraryItem(
            displayName: "霞鹜文楷",
            postScriptName: "LXGWWenKai-Regular",
            fileName: "霞鹜文楷.ttf",
            relativePath: nil,
            source: .bundled,
            previewText: "霞鹜文楷预览 Legado"
        )

        let options = ReaderFontOption.available(libraryItems: [bundled])

        XCTAssertTrue(options.contains(where: { $0.fontName == "LXGWWenKai-Regular" }))
    }

    func testReaderAppearanceDefaultsUseZeroVerticalAndSixteenHorizontalContentMargins() {
        let layout = ReaderAppearanceSettings.default.makeLayoutConfiguration(
            viewportSize: CGSize(width: 320, height: 480),
            safeAreaInsets: EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        )

        XCTAssertEqual(layout.contentInsets.left, 16)
        XCTAssertEqual(layout.contentInsets.right, 16)
        XCTAssertEqual(layout.contentInsets.top, 0)
        XCTAssertEqual(layout.contentInsets.bottom, 0)
    }
}
