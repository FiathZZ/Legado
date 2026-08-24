import CoreText
import SwiftUI
import UIKit

/// UIKit reader surface modelled after DZMeBookRead's controller hierarchy.
///
/// DZMeBookRead keeps a page controller for horizontal reading, a table-backed controller for
/// continuous reading, and one controller-level menu gesture. This adapter retains that proven
/// interaction boundary while delegating content loading, positions, and persistence to Legado's
/// existing ReaderPaginatorViewModel and ReaderViewModel.
struct DZMReaderEngineView: UIViewControllerRepresentable {
    let renderModel: ReaderChapterRenderModel
    let displayedPageIndex: Int
    let flipMode: ReaderFlipMode
    let backgroundColor: UIColor
    let onPageSelected: (Int) -> Void
    let onScrollOffsetChanged: (Int) -> Void
    let onNavigation: (ReaderPageGestureAction) -> Void

    func makeUIViewController(context: Context) -> DZMReaderEngineController {
        DZMReaderEngineController(
            renderModel: renderModel,
            displayedPageIndex: displayedPageIndex,
            flipMode: flipMode,
            backgroundColor: backgroundColor,
            onPageSelected: onPageSelected,
            onScrollOffsetChanged: onScrollOffsetChanged,
            onNavigation: onNavigation
        )
    }

    func updateUIViewController(_ controller: DZMReaderEngineController, context: Context) {
        controller.apply(
            renderModel: renderModel,
            displayedPageIndex: displayedPageIndex,
            flipMode: flipMode,
            backgroundColor: backgroundColor,
            onPageSelected: onPageSelected,
            onScrollOffsetChanged: onScrollOffsetChanged,
            onNavigation: onNavigation
        )
    }
}

/// The menu recognizer intentionally lives above the page and scroll containers. This is the
/// same ownership boundary used by DZMeBookRead: text rendering never owns the reader menu tap.
final class DZMReaderEngineController: UIViewController {
    private var renderModel: ReaderChapterRenderModel
    private var flipMode: ReaderFlipMode
    private var displayedPageIndex: Int
    private var onPageSelected: (Int) -> Void
    private var onScrollOffsetChanged: (Int) -> Void
    private var onNavigation: (ReaderPageGestureAction) -> Void

    private var pageController: DZMReaderPageController?
    private var scrollController: DZMReaderScrollController?
    private(set) lazy var menuTapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleMenuTap(_:))
    )

    init(
        renderModel: ReaderChapterRenderModel,
        displayedPageIndex: Int,
        flipMode: ReaderFlipMode,
        backgroundColor: UIColor,
        onPageSelected: @escaping (Int) -> Void,
        onScrollOffsetChanged: @escaping (Int) -> Void,
        onNavigation: @escaping (ReaderPageGestureAction) -> Void
    ) {
        self.renderModel = renderModel
        self.displayedPageIndex = displayedPageIndex
        self.flipMode = flipMode
        self.onPageSelected = onPageSelected
        self.onScrollOffsetChanged = onScrollOffsetChanged
        self.onNavigation = onNavigation
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = backgroundColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        menuTapRecognizer.cancelsTouchesInView = false
        menuTapRecognizer.delegate = self
        view.addGestureRecognizer(menuTapRecognizer)
        rebuildReaderContainer()
    }

    func apply(
        renderModel: ReaderChapterRenderModel,
        displayedPageIndex: Int,
        flipMode: ReaderFlipMode,
        backgroundColor: UIColor,
        onPageSelected: @escaping (Int) -> Void,
        onScrollOffsetChanged: @escaping (Int) -> Void,
        onNavigation: @escaping (ReaderPageGestureAction) -> Void
    ) {
        let contentChanged = self.renderModel != renderModel
        let modeChanged = self.flipMode != flipMode
        self.renderModel = renderModel
        self.displayedPageIndex = displayedPageIndex
        self.flipMode = flipMode
        self.onPageSelected = onPageSelected
        self.onScrollOffsetChanged = onScrollOffsetChanged
        self.onNavigation = onNavigation
        view.backgroundColor = backgroundColor

        guard isViewLoaded else { return }
        if contentChanged || modeChanged {
            rebuildReaderContainer()
            return
        }
        pageController?.show(pageIndex: displayedPageIndex, animated: false)
        scrollController?.show(pageIndex: displayedPageIndex, animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pageController?.view.frame = view.bounds
        scrollController?.view.frame = view.bounds
    }

    private func rebuildReaderContainer() {
        pageController?.removeFromParent()
        pageController?.view.removeFromSuperview()
        pageController = nil
        scrollController?.removeFromParent()
        scrollController?.view.removeFromSuperview()
        scrollController = nil

        if flipMode == .scroll {
            let controller = DZMReaderScrollController(
                renderModel: renderModel,
                initialPageIndex: displayedPageIndex,
                onVisiblePageChanged: { [weak self] page in
                    self?.onScrollOffsetChanged(page.contentRange.location)
                }
            )
            addChild(controller)
            view.addSubview(controller.view)
            controller.view.frame = view.bounds
            controller.didMove(toParent: self)
            scrollController = controller
        } else {
            let controller = DZMReaderPageController(
                renderModel: renderModel,
                initialPageIndex: displayedPageIndex,
                prefersPageCurl: flipMode == .fade,
                onPageSelected: { [weak self] page in
                    self?.onPageSelected(page.pageIndex)
                }
            )
            addChild(controller)
            view.addSubview(controller.view)
            controller.view.frame = view.bounds
            controller.didMove(toParent: self)
            pageController = controller
        }
    }

    @objc private func handleMenuTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        routeMenuTap(at: recognizer.location(in: view))
    }

    /// Keeps reader menu routing at the controller boundary, above the page and scroll children.
    /// Tests use this seam to verify the same action produced by the installed tap recognizer.
    func routeMenuTap(at location: CGPoint) {
        onNavigation(ReaderPageGestureAction.resolveTap(
            location: location,
            in: view.bounds.size
        ))
    }
}

extension DZMReaderEngineController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === menuTapRecognizer else { return false }
        return otherGestureRecognizer is UIPanGestureRecognizer
    }
}

/// DZMeBookRead's horizontal controller pattern, with Legado-owned ReaderPage models instead of
/// DZMe's archived chapter models.
private final class DZMReaderPageController: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private let renderModel: ReaderChapterRenderModel
    private var currentPageIndex: Int
    private let onPageSelected: (ReaderPage) -> Void

    init(
        renderModel: ReaderChapterRenderModel,
        initialPageIndex: Int,
        prefersPageCurl: Bool,
        onPageSelected: @escaping (ReaderPage) -> Void
    ) {
        self.renderModel = renderModel
        self.currentPageIndex = min(max(initialPageIndex, 0), max(renderModel.pageCount - 1, 0))
        self.onPageSelected = onPageSelected
        super.init(
            transitionStyle: prefersPageCurl ? .pageCurl : .scroll,
            navigationOrientation: .horizontal,
            options: nil
        )
        dataSource = self
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        show(pageIndex: currentPageIndex, animated: false)
    }

    func show(pageIndex: Int, animated: Bool) {
        let clampedIndex = min(max(pageIndex, 0), max(renderModel.pageCount - 1, 0))
        guard clampedIndex != currentPageIndex || viewControllers?.isEmpty != false else { return }
        let direction: UIPageViewController.NavigationDirection = clampedIndex >= currentPageIndex ? .forward : .reverse
        currentPageIndex = clampedIndex
        setViewControllers([makePageController(at: clampedIndex)], direction: direction, animated: animated)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? DZMReaderPageContentController,
              page.pageIndex > 0 else { return nil }
        return makePageController(at: page.pageIndex - 1)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? DZMReaderPageContentController,
              page.pageIndex + 1 < renderModel.pageCount else { return nil }
        return makePageController(at: page.pageIndex + 1)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard finished,
              completed,
              let page = viewControllers?.first as? DZMReaderPageContentController else { return }
        currentPageIndex = page.pageIndex
        onPageSelected(renderModel.pages[page.pageIndex])
    }

    private func makePageController(at index: Int) -> DZMReaderPageContentController {
        DZMReaderPageContentController(page: renderModel.pages[index], layout: renderModel.layout)
    }
}

/// DZMeBookRead's vertical table-controller pattern. Each Legado page is a table row so native
/// scrolling and tap recognition are separated exactly as in the reference reader.
private final class DZMReaderScrollController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let renderModel: ReaderChapterRenderModel
    private let initialPageIndex: Int
    private let onVisiblePageChanged: (ReaderPage) -> Void
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var lastReportedIndex = -1

    init(
        renderModel: ReaderChapterRenderModel,
        initialPageIndex: Int,
        onVisiblePageChanged: @escaping (ReaderPage) -> Void
    ) {
        self.renderModel = renderModel
        self.initialPageIndex = min(max(initialPageIndex, 0), max(renderModel.pageCount - 1, 0))
        self.onVisiblePageChanged = onVisiblePageChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.showsHorizontalScrollIndicator = false
        tableView.register(DZMReaderScrollCell.self, forCellReuseIdentifier: DZMReaderScrollCell.reuseIdentifier)
        view.addSubview(tableView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
        if tableView.contentSize.height == 0 {
            tableView.reloadData()
            show(pageIndex: initialPageIndex, animated: false)
        }
    }

    func show(pageIndex: Int, animated: Bool) {
        guard renderModel.pageCount > 0 else { return }
        let index = min(max(pageIndex, 0), renderModel.pageCount - 1)
        tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: animated)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        renderModel.pageCount
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: DZMReaderScrollCell.reuseIdentifier,
            for: indexPath
        ) as! DZMReaderScrollCell
        cell.configure(page: renderModel.pages[indexPath.row], layout: renderModel.layout)
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        max(tableView.bounds.height, 1)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportVisiblePage()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        reportVisiblePage(force: true)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reportVisiblePage(force: true)
    }

    private func reportVisiblePage(force: Bool = false) {
        guard let firstVisible = tableView.indexPathsForVisibleRows?.min(),
              firstVisible.row < renderModel.pageCount,
              force || firstVisible.row != lastReportedIndex else { return }
        lastReportedIndex = firstVisible.row
        onVisiblePageChanged(renderModel.pages[firstVisible.row])
    }
}

private final class DZMReaderPageContentController: UIViewController {
    let pageIndex: Int
    private let page: ReaderPage
    private let layout: ReaderLayoutConfiguration

    init(page: ReaderPage, layout: ReaderLayoutConfiguration) {
        self.pageIndex = page.pageIndex
        self.page = page
        self.layout = layout
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = DZMReaderCoreTextView(page: page, layout: layout)
    }
}

private final class DZMReaderScrollCell: UITableViewCell {
    static let reuseIdentifier = "DZMReaderScrollCell"
    private var readerView: DZMReaderCoreTextView?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(page: ReaderPage, layout: ReaderLayoutConfiguration) {
        readerView?.removeFromSuperview()
        let nextReaderView = DZMReaderCoreTextView(page: page, layout: layout)
        contentView.addSubview(nextReaderView)
        nextReaderView.frame = contentView.bounds
        nextReaderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        readerView = nextReaderView
    }
}

/// A small CoreText surface derived from DZMeBookRead's DZMReadView. It draws the already
/// paginated Legado attributed page, avoiding UITextView's touch and scrolling implementation.
private final class DZMReaderCoreTextView: UIView {
    private let page: ReaderPage
    private let layout: ReaderLayoutConfiguration
    private var frameRef: CTFrame?

    init(page: ReaderPage, layout: ReaderLayoutConfiguration) {
        self.page = page
        self.layout = layout
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        frameRef = makeFrame()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let frameRef else { return }
        context.textMatrix = .identity
        let textRect = CGRect(origin: textOrigin, size: layout.textBounds)
        context.translateBy(x: textRect.minX, y: textRect.maxY)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frameRef, context)
    }

    private var textOrigin: CGPoint {
        CGPoint(x: layout.contentInsets.left, y: layout.contentInsets.top)
    }

    private func makeFrame() -> CTFrame {
        let framesetter = CTFramesetterCreateWithAttributedString(page.attributedText)
        let path = CGPath(rect: CGRect(origin: .zero, size: layout.textBounds), transform: nil)
        return CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
    }
}
