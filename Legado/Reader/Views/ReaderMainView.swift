import SwiftUI
import UIKit

enum ReaderPageGestureAction: Equatable {
    case previousPage
    case toggleControls
    case nextPage
    case none

    static func resolve(translation: CGSize, location: CGPoint, in size: CGSize) -> Self {
        let horizontalDistance = abs(translation.width)
        let verticalDistance = abs(translation.height)

        if horizontalDistance >= 16, horizontalDistance > verticalDistance {
            return translation.width < 0 ? .nextPage : .previousPage
        }

        guard max(horizontalDistance, verticalDistance) < 16, size.width > 0 else {
            return .none
        }

        if location.x < size.width / 3 {
            return .previousPage
        }
        if location.x > size.width * 2 / 3 {
            return .nextPage
        }
        return .toggleControls
    }

    static func resolveTap(location: CGPoint, in size: CGSize) -> Self {
        guard size.width > 0, size.height > 0 else { return .none }
        let centerRegion = CGRect(
            x: size.width / 3,
            y: size.height / 3,
            width: size.width / 3,
            height: size.height / 3
        )
        if centerRegion.contains(location) {
            return .toggleControls
        }
        return location.x < size.width / 2 ? .previousPage : .nextPage
    }
}

struct ReaderMainView: View {
    @State private var pendingSliderPage: Double = 0
    @State private var isDraggingSlider = false
    @State private var isAppearanceSheetPresented = false
    @State private var deviceSafeAreaInsets = EdgeInsets()

    @ObservedObject var paginator: ReaderPaginatorViewModel
    @ObservedObject var readerViewModel: ReaderViewModel
    let onBackRequested: () -> Void
    let onReadingPositionChanged: (ReaderPosition) -> Void
    let onToolRouteRequested: (ReaderToolRoute) -> Void

    init(
        paginator: ReaderPaginatorViewModel,
        readerViewModel: ReaderViewModel,
        onBackRequested: @escaping () -> Void,
        onReadingPositionChanged: @escaping (ReaderPosition) -> Void,
        onToolRouteRequested: @escaping (ReaderToolRoute) -> Void
    ) {
        self.paginator = paginator
        self.readerViewModel = readerViewModel
        self.onBackRequested = onBackRequested
        self.onReadingPositionChanged = onReadingPositionChanged
        self.onToolRouteRequested = onToolRouteRequested
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                paginator.appearance.theme.backgroundColor
                    .ignoresSafeArea()

                pageLayer(in: proxy)

                if let errorMessage = paginator.errorMessage {
                    ReaderErrorCard(
                        message: errorMessage,
                        theme: paginator.appearance.theme
                    ) {
                        Task { @MainActor in
                            await paginator.refreshCurrentChapter()
                        }
                    }
                }

                if paginator.isControlsVisible {
                    readerOverlay(safeAreaInsets: resolvedSafeAreaInsets(from: proxy))
                }
            }
            .background(
                ReaderWindowSafeAreaReader { insets in
                    deviceSafeAreaInsets = insets
                }
                .allowsHitTesting(false)
            )
            .task {
                await paginator.prepareIfNeeded()
            }
            .task(id: proxy.size) {
                await paginator.updateViewport(size: proxy.size, safeAreaInsets: resolvedSafeAreaInsets(from: proxy))
            }
            .task(id: deviceSafeAreaInsets.top + deviceSafeAreaInsets.bottom + deviceSafeAreaInsets.leading + deviceSafeAreaInsets.trailing) {
                await paginator.updateViewport(size: proxy.size, safeAreaInsets: resolvedSafeAreaInsets(from: proxy))
            }
        }
        .onChange(of: paginator.readingPosition) { _, newValue in
            pendingSliderPage = Double(newValue.pageIndex)
            onReadingPositionChanged(newValue)
        }
        .onChange(of: readerViewModel.currentIndex) { _, newValue in
            Task { @MainActor in
                await paginator.syncToExternalChapterIfNeeded(newValue)
            }
        }
        .sheet(isPresented: $isAppearanceSheetPresented) {
            ReaderAppearanceSheet(
                initialSettings: paginator.appearance,
                onChange: { settings in
                    Task { @MainActor in
                        await paginator.replaceAppearance(with: settings)
                    }
                }
            )
            .presentationDetents([.height(560)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
    }

    @ViewBuilder
    private func pageLayer(in proxy: GeometryProxy) -> some View {
        if let renderModel = paginator.renderModel {
            DZMReaderEngineView(
                renderModel: renderModel,
                displayedPageIndex: paginator.readingPosition.pageIndex,
                flipMode: paginator.appearance.flipMode,
                backgroundColor: paginator.appearance.theme.uiBackgroundColor,
                onPageSelected: { pageIndex in
                    paginator.jumpToPage(pageIndex)
                },
                onScrollOffsetChanged: { offset in
                    paginator.syncScrollPosition(utf16Offset: offset)
                },
                onNavigation: handleReaderTap
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "book.closed")
                    .font(.system(size: 30, weight: .medium))
                Text("等待章节内容")
                    .font(.headline)
            }
            .foregroundStyle(paginator.appearance.theme.secondaryTextColor)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func readerOverlay(safeAreaInsets: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            ReaderTopBar(
                chapterTitle: paginator.currentChapterTitle,
                theme: paginator.appearance.theme,
                safeAreaInsets: safeAreaInsets,
                onBack: onBackRequested,
                onTOC: { paginator.openRoute(.toc, handler: onToolRouteRequested) },
                onBookmarks: { paginator.openRoute(.bookmarkList, handler: onToolRouteRequested) },
                onSearch: { paginator.openRoute(.bookSearch, handler: onToolRouteRequested) },
                onChangeSource: { paginator.openRoute(.changeSource, handler: onToolRouteRequested) }
            )

            Spacer()

            ReaderBottomBar(
                chapterProgressText: paginator.chapterProgressText,
                pageProgressText: paginator.pageProgressText,
                totalProgressText: paginator.totalProgressText,
                theme: paginator.appearance.theme,
                safeAreaInsets: safeAreaInsets,
                sliderValue: Binding(
                    get: { isDraggingSlider ? pendingSliderPage : Double(paginator.readingPosition.pageIndex) },
                    set: { pendingSliderPage = $0 }
                ),
                sliderUpperBound: Double(max(paginator.pageCount - 1, 1)),
                onSliderEditingChanged: { editing in
                    isDraggingSlider = editing
                    guard !editing else { return }
                    paginator.jumpToPage(Int(pendingSliderPage.rounded()))
                },
                onPreviousChapter: {
                    Task { @MainActor in
                        await paginator.jumpToChapter(index: max(paginator.chapterIndex - 1, 0))
                    }
                },
                onNextChapter: {
                    Task { @MainActor in
                        await paginator.jumpToChapter(index: min(paginator.chapterIndex + 1, paginator.chapterCount - 1))
                    }
                },
                onSettings: {
                    paginator.isControlsVisible = false
                    isAppearanceSheetPresented = true
                },
                onBookmark: {
                    _ = readerViewModel.addBookmark(
                        position: paginator.readingPosition,
                        pageText: paginator.currentPageSnippet()
                    )
                }
            )
        }
        .transition(.opacity)
    }

    private func handleReaderTap(_ action: ReaderPageGestureAction) {
        switch action {
        case .previousPage:
            Task { @MainActor in
                await paginator.previousPage()
            }
        case .toggleControls:
            paginator.toggleControls()
        case .nextPage:
            Task { @MainActor in
                await paginator.nextPage()
            }
        case .none:
            break
        }
    }

    private func resolvedSafeAreaInsets(from proxy: GeometryProxy) -> EdgeInsets {
        if deviceSafeAreaInsets != EdgeInsets() {
            return deviceSafeAreaInsets
        }
        return proxy.safeAreaInsets
    }
}

private struct ReaderWindowSafeAreaReader: UIViewRepresentable {
    let onChange: (EdgeInsets) -> Void

    func makeUIView(context: Context) -> ReaderSafeAreaProbeView {
        let view = ReaderSafeAreaProbeView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReaderSafeAreaProbeView, context: Context) {
        uiView.onChange = onChange
        uiView.reportCurrentInsets()
    }
}

private final class ReaderSafeAreaProbeView: UIView {
    var onChange: ((EdgeInsets) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportCurrentInsets()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        reportCurrentInsets()
    }

    func reportCurrentInsets() {
        let resolvedInsets = window?.safeAreaInsets ?? safeAreaInsets
        onChange?(
            EdgeInsets(
                top: resolvedInsets.top,
                leading: resolvedInsets.left,
                bottom: resolvedInsets.bottom,
                trailing: resolvedInsets.right
            )
        )
    }
}

private struct ReaderTopBar: View {
    let chapterTitle: String
    let theme: ReaderThemePreset
    let safeAreaInsets: EdgeInsets
    let onBack: () -> Void
    let onTOC: () -> Void
    let onBookmarks: () -> Void
    let onSearch: () -> Void
    let onChangeSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chapterTitle.isEmpty ? "阅读中" : chapterTitle)
                .font(.headline)
                .foregroundStyle(theme.textColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                actionButton("返回", systemImage: "chevron.left", action: onBack)
                actionButton("目录", systemImage: "list.bullet.rectangle", action: onTOC)
                actionButton("换源", systemImage: "arrow.triangle.2.circlepath", action: onChangeSource)
                actionButton("收藏", systemImage: "bookmark", action: onBookmarks)
                actionButton("搜索", systemImage: "magnifyingglass", action: onSearch)
            }
        }
        .padding(.top, safeAreaInsets.top + 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .background(theme.chromeColor)
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ReaderBottomBar: View {
    let chapterProgressText: String
    let pageProgressText: String
    let totalProgressText: String
    let theme: ReaderThemePreset
    let safeAreaInsets: EdgeInsets
    let sliderValue: Binding<Double>
    let sliderUpperBound: Double
    let onSliderEditingChanged: (Bool) -> Void
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void
    let onSettings: () -> Void
    let onBookmark: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("章节 \(chapterProgressText)")
                Spacer()
                Text("页码 \(pageProgressText)")
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.88))

            Slider(
                value: sliderValue,
                in: 0...sliderUpperBound,
                step: 1,
                onEditingChanged: onSliderEditingChanged
            )
            .tint(.white)

            HStack(spacing: 12) {
                readerActionButton("设置", systemImage: "textformat.size", action: onSettings)
                readerActionButton("上一章", systemImage: "chevron.left", action: onPreviousChapter)
                readerActionButton("下一章", systemImage: "chevron.right", action: onNextChapter)
            }

            Button(action: onBookmark) {
                Label("收藏当前位置", systemImage: "bookmark.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .buttonStyle(.plain)

            Text("总进度 \(totalProgressText)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.74))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, safeAreaInsets.bottom + 12)
        .background(theme.chromeColor)
    }

    private func readerActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ReaderErrorCard: View {
    let message: String
    let theme: ReaderThemePreset
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("重试", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .foregroundStyle(theme.textColor)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 32)
    }
}

struct ReaderAppearanceSheet: View {
    @ObservedObject private var fontLibrary = ThemeFontLibrary.shared
    @State private var draft: ReaderAppearanceSettings
    @State private var isFontSelectorPresented = false

    let onChange: (ReaderAppearanceSettings) -> Void

    init(
        initialSettings: ReaderAppearanceSettings,
        onChange: @escaping (ReaderAppearanceSettings) -> Void
    ) {
        self.onChange = onChange
        _draft = State(initialValue: initialSettings)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    appearanceCard(title: "主题") {
                        Picker("阅读底色", selection: $draft.theme) {
                            ForEach(ReaderThemePreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    appearanceCard(title: "翻页") {
                        Picker("翻页动画", selection: $draft.flipMode) {
                            ForEach(ReaderFlipMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    appearanceCard(title: "字体") {
                        Button {
                            isFontSelectorPresented = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("当前字体")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(selectedFontOption.displayName)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                }
                                Spacer()
                                Text(selectedFontOption.sourceTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)

                        Divider()

                        Stepper("字号 \(Int(draft.fontSize))", value: $draft.fontSize, in: 14...34, step: 1)
                        Stepper("字距 \(draft.letterSpacing, specifier: "%.2f")", value: $draft.letterSpacing, in: 0...1, step: 0.02)
                    }

                    appearanceCard(title: "排版") {
                        Stepper("行距 \(Int(draft.lineSpacing))", value: $draft.lineSpacing, in: 0...16, step: 1)
                        Divider()
                        Stepper("段距 \(Int(draft.paragraphSpacing))", value: $draft.paragraphSpacing, in: 0...20, step: 1)
                        Divider()
                        Stepper("段首缩进 \(draft.paragraphIndentCount) 字", value: $draft.paragraphIndentCount, in: 0...4, step: 1)
                        Divider()
                        Stepper("左右边距 \(Int(draft.horizontalPadding))", value: $draft.horizontalPadding, in: 0...42, step: 1)
                        Divider()
                        Stepper("上下边距 \(Int(draft.verticalPadding))", value: $draft.verticalPadding, in: 0...48, step: 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(uiColor: .systemGroupedBackground))
            .onAppear {
                fontLibrary.reload()
            }
            .onChange(of: draft) { _, newValue in
                onChange(newValue)
            }
            .sheet(isPresented: $isFontSelectorPresented) {
                ReaderFontSelectionView(
                    options: fontOptions,
                    selectedFontName: draft.fontName,
                    onSelect: { option in
                        draft.fontName = option.fontName
                        isFontSelectorPresented = false
                    }
                )
            }
        }
    }

    private var fontOptions: [ReaderFontOption] {
        ReaderFontOption.available(libraryItems: fontLibrary.availableFonts)
    }

    private var selectedFontOption: ReaderFontOption {
        draft.resolvedFontOption(in: fontOptions)
    }

    @ViewBuilder
    private func appearanceCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ReaderFontSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let options: [ReaderFontOption]
    let selectedFontName: String?
    let onSelect: (ReaderFontOption) -> Void

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(filteredOptions) { option in
                Button {
                    onSelect(option)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.displayName)
                                .font(option.previewFont(size: 17, weight: .medium))
                                .foregroundStyle(.primary)
                            Text(option.fontName ?? "system")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(option.previewText)
                                .font(option.previewFont(size: 14))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 6) {
                            Text(option.sourceTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if option.fontName == selectedFontName || (option.fontName == nil && selectedFontName == nil) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("选择字体")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索字体名称")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var filteredOptions: [ReaderFontOption] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return options }
        return options.filter { option in
            option.displayName.localizedCaseInsensitiveContains(trimmed)
                || (option.fontName?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }
}

private extension ReaderFontOption {
    func previewFont(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        guard let fontName, let uiFont = UIFont(name: fontName, size: size) else {
            return .system(size: size, weight: weight ?? .regular)
        }
        return Font(uiFont)
    }
}
