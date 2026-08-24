import SwiftUI
import UIKit

/// Continuous chapter reader backed by UITextView so scrolling can report a stable text offset.
struct ReaderScrollTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let textColor: UIColor
    let backgroundColor: UIColor
    let contentInsets: UIEdgeInsets
    let initialUTF16Offset: Int
    let contentIdentity: String
    let onVisibleUTF16OffsetChanged: (Int) -> Void
    let onCenterTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onVisibleUTF16OffsetChanged: onVisibleUTF16OffsetChanged)
    }

    func makeUIView(context: Context) -> ReaderScrollTextViewHostView {
        let hostView = ReaderScrollTextViewHostView(onCenterTap: onCenterTap)
        let textView = hostView.textView
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = backgroundColor
        textView.delegate = context.coordinator
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.adjustsFontForContentSizeCategory = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.alwaysBounceVertical = true
        // UIScrollView normally delays or cancels subview touch delivery while it decides whether
        // a drag is beginning. The reader's tap recognizer belongs to this text view, so disable
        // those delays to let stationary taps reach the recognizer immediately after scrolling.
        textView.delaysContentTouches = false
        textView.canCancelContentTouches = false

        return hostView
    }

    func updateUIView(_ hostView: ReaderScrollTextViewHostView, context: Context) {
        let textView = hostView.textView
        context.coordinator.onVisibleUTF16OffsetChanged = onVisibleUTF16OffsetChanged
        hostView.onCenterTap = onCenterTap
        textView.backgroundColor = backgroundColor
        textView.tintColor = textColor
        textView.textContainerInset = contentInsets

        guard context.coordinator.contentIdentity != contentIdentity else { return }
        context.coordinator.contentIdentity = contentIdentity
        context.coordinator.lastReportedOffset = -1

        let text = NSMutableAttributedString(attributedString: attributedText)
        text.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: 0, length: text.length))
        textView.attributedText = text
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        context.coordinator.scrollToCharacter(initialUTF16Offset, in: textView)
        context.coordinator.reportVisibleOffset(from: textView, force: true)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onVisibleUTF16OffsetChanged: (Int) -> Void
        var contentIdentity: String?
        var lastReportedOffset = -1

        init(onVisibleUTF16OffsetChanged: @escaping (Int) -> Void) {
            self.onVisibleUTF16OffsetChanged = onVisibleUTF16OffsetChanged
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            reportVisibleOffset(from: textView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate, let textView = scrollView as? UITextView else { return }
            reportVisibleOffset(from: textView, force: true)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            reportVisibleOffset(from: textView, force: true)
        }

        func scrollToCharacter(_ offset: Int, in textView: UITextView) {
            guard textView.textStorage.length > 0 else { return }
            let characterIndex = min(max(offset, 0), textView.textStorage.length - 1)
            let glyphIndex = textView.layoutManager.glyphIndexForCharacter(at: characterIndex)
            let rect = textView.layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textView.textContainer)
            let targetY = max(-textView.adjustedContentInset.top, rect.minY - textView.adjustedContentInset.top)
            textView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        }

        func reportVisibleOffset(from textView: UITextView, force: Bool = false) {
            let point = CGPoint(
                x: textView.contentOffset.x + textView.textContainerInset.left + 1,
                y: textView.contentOffset.y + textView.adjustedContentInset.top + 1
            )
            let characterOffset = textView.layoutManager.characterIndex(
                for: point,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            guard force || abs(characterOffset - lastReportedOffset) >= 24 else { return }
            lastReportedOffset = characterOffset
            onVisibleUTF16OffsetChanged(characterOffset)
        }
    }
}

/// Hosts the native scrollable text view and recognises stationary reader taps on that exact
/// view. UIKit continues to own the text view's pan recognizer and scrolling lifecycle.
final class ReaderScrollTextViewHostView: UIView, UIGestureRecognizerDelegate {
    let textView = UITextView()
    private(set) lazy var centerTapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleTextViewTap(_:))
    )
    var onCenterTap: () -> Void

    init(onCenterTap: @escaping () -> Void) {
        self.onCenterTap = onCenterTap
        super.init(frame: .zero)
        addSubview(textView)
        centerTapRecognizer.cancelsTouchesInView = false
        centerTapRecognizer.delegate = self
        textView.addGestureRecognizer(centerTapRecognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
    }

    /// The recognizer reports coordinates in UITextView's scrolling bounds. Normalize them back
    /// to the visible viewport before resolving left, center, and right reader tap regions.
    @objc private func handleTextViewTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        handleTap(at: recognizer.location(in: textView))
    }

    func handleTap(at location: CGPoint) {
        guard textView.bounds.contains(location) else { return }
        let visibleLocation = CGPoint(
            x: location.x - textView.bounds.minX,
            y: location.y - textView.bounds.minY
        )
        guard ReaderPageGestureAction.resolveTap(
            location: visibleLocation,
            in: textView.bounds.size
        ) == .toggleControls else {
            return
        }
        onCenterTap()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === centerTapRecognizer else { return false }
        return otherGestureRecognizer === textView.panGestureRecognizer
    }
}
