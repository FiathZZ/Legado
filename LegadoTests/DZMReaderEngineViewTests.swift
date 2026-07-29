import XCTest
import SwiftUI
@testable import Legado

@MainActor
final class DZMReaderEngineViewTests: XCTestCase {
    func testContinuousScrollNextChapterDoesNotBlockMainActorProvider() async {
        let providerCalled = expectation(description: "remote chapter provider called")
        let chapterDelivered = expectation(description: "remote chapter delivered")

        DZMAdjacentChapterRequest.request(
            isPersisted: false,
            sourceType: .network,
            loadPersistedOrLocal: {
                XCTFail("A network chapter must use the async provider")
                return nil
            },
            loadRemote: { completion in
                providerCalled.fulfill()
                Task { @MainActor in
                    let chapter = DZMReadChapterModel()
                    chapter.id = NSNumber(value: 2)
                    completion(chapter)
                }
            },
            completion: { chapter in
                XCTAssertEqual(chapter?.id, NSNumber(value: 2))
                chapterDelivered.fulfill()
            }
        )

        await fulfillment(of: [providerCalled, chapterDelivered], timeout: 1)
    }

    func testNativeReaderProvidesTheNextChapterToTheContinuousScrollReader() {
        let snapshot = DZMNativeReaderSnapshot(
            bookID: "book-id",
            bookName: "测试书",
            chapters: ["第一章", "第二章"],
            chapterIndex: 0,
            chapterTitle: "第一章",
            content: "第一章正文",
            restoredPosition: ReaderPosition(chapterIndex: 0)
        )
        var requestedIndex: Int?
        let model = DZMNativeReadModelFactory.makeModel(from: snapshot) { index, completion in
            requestedIndex = index
            completion("第二章正文")
        }

        var loadedChapter: DZMReadChapterModel?
        model.loadChapterModel?(NSNumber(value: 2)) { loadedChapter = $0 }

        XCTAssertEqual(requestedIndex, 1)
        XCTAssertEqual(loadedChapter?.id, NSNumber(value: 2))
        XCTAssertEqual(loadedChapter?.priority, NSNumber(value: 1))
        XCTAssertEqual(loadedChapter?.name, "第二章")
        XCTAssertFalse(loadedChapter?.pageModels.isEmpty ?? true)
    }

    func testNativeReaderOnlyReusesPaginationForMatchingContentAndLayout() {
        let chapter = DZMReadChapterModel()
        chapter.bookID = "book-id"
        chapter.id = NSNumber(value: 1)
        chapter.content = "  正文"
        chapter.fullContent = NSAttributedString(string: "第一章\n\n  正文")
        chapter.pageCount = NSNumber(value: 1)
        chapter.paginationSignature = "390|844|0|18|0"
        chapter.name = "第一章"
        chapter.priority = 0
        chapter.previousChapterID = nil
        chapter.nextChapterID = NSNumber(value: 2)
        chapter.pageModels = [DZMReadPageModel()]

        XCTAssertTrue(
            DZMNativeReadModelFactory.canReuseCachedPagination(
                chapter,
                title: "第一章",
                chapterIndex: 0,
                chapterCount: 2,
                content: "  正文",
                paginationSignature: "390|844|0|18|0"
            )
        )
        XCTAssertFalse(
            DZMNativeReadModelFactory.canReuseCachedPagination(
                chapter,
                title: "第一章",
                chapterIndex: 0,
                chapterCount: 2,
                content: "  更新后的正文",
                paginationSignature: "390|844|0|18|0"
            )
        )
        XCTAssertFalse(
            DZMNativeReadModelFactory.canReuseCachedPagination(
                chapter,
                title: "第一章",
                chapterIndex: 0,
                chapterCount: 2,
                content: "  正文",
                paginationSignature: "844|390|0|18|0"
            )
        )
    }

    func testNativeReaderReusesLastChapterPaginationWithNilNextChapterID() {
        let chapter = DZMReadChapterModel()
        chapter.bookID = "book-id"
        chapter.id = NSNumber(value: 2)
        chapter.name = "第二章"
        chapter.content = "  正文"
        chapter.fullContent = NSAttributedString(string: "第二章\n\n  正文")
        chapter.priority = 1
        chapter.previousChapterID = NSNumber(value: 1)
        chapter.nextChapterID = nil
        chapter.pageCount = NSNumber(value: 1)
        chapter.pageModels = [DZMReadPageModel()]
        chapter.paginationSignature = "390|844|0|18|0"

        XCTAssertTrue(
            DZMNativeReadModelFactory.canReuseCachedPagination(
                chapter,
                title: "第二章",
                chapterIndex: 1,
                chapterCount: 2,
                content: "  正文",
                paginationSignature: "390|844|0|18|0"
            )
        )
    }

    func testNativeReaderRejectsIncompleteLegacyPaginationArchive() {
        let incompleteChapter = DZMReadChapterModel()
        incompleteChapter.content = "  正文"
        incompleteChapter.paginationSignature = "390|844|0|18|0"
        incompleteChapter.pageModels = [DZMReadPageModel()]

        XCTAssertFalse(
            DZMNativeReadModelFactory.canReuseCachedPagination(
                incompleteChapter,
                title: "第一章",
                chapterIndex: 0,
                chapterCount: 2,
                content: "  正文",
                paginationSignature: "390|844|0|18|0"
            )
        )
    }

    func testScrollReaderKeepsControllerMenuTapAboveScrollContainer() {
        let renderModel = makeRenderModel()
        var receivedActions: [ReaderPageGestureAction] = []
        let controller = DZMReaderEngineController(
            renderModel: renderModel,
            displayedPageIndex: 0,
            flipMode: .scroll,
            backgroundColor: .white,
            onPageSelected: { _ in },
            onScrollOffsetChanged: { _ in },
            onNavigation: { receivedActions.append($0) }
        )

        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.children.count, 1)
        XCTAssertTrue(controller.view.gestureRecognizers?.contains(controller.menuTapRecognizer) == true)
        XCTAssertTrue(
            controller.gestureRecognizer(
                controller.menuTapRecognizer,
                shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()
            )
        )

        controller.routeMenuTap(at: CGPoint(x: 160, y: 320))

        XCTAssertEqual(receivedActions, [.toggleControls])
    }

    private func makeRenderModel() -> ReaderChapterRenderModel {
        ReaderChapterRenderingService().renderChapter(
            bookID: "dzm-reader-test",
            chapterID: "chapter-1",
            chapterIndex: 0,
            chapterTitle: "第一章",
            content: Array(repeating: "用于验证滚动阅读器菜单手势的正文。", count: 160).joined(separator: "\n"),
            configuration: ReaderLayoutConfiguration(
                viewportSize: CGSize(width: 320, height: 640),
                contentInsets: UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18),
                fontSize: 18,
                lineSpacing: 8,
                paragraphSpacing: 14
            )
        )
    }
}
