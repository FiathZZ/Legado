import SwiftUI
import UIKit

struct ReaderPageTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let textColor: UIColor
    let backgroundColor: UIColor
    let contentInsets: UIEdgeInsets
    let onPageNavigation: (ReaderPageGestureAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageNavigation: onPageNavigation)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.isUserInteractionEnabled = true
        textView.backgroundColor = backgroundColor
        textView.textContainerInset = contentInsets
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.heightTracksTextView = true
        textView.adjustsFontForContentSizeCategory = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didPan(_:)))
        pan.cancelsTouchesInView = false
        textView.addGestureRecognizer(pan)

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onPageNavigation = onPageNavigation
        let mutableText = NSMutableAttributedString(attributedString: attributedText)
        mutableText.addAttribute(
            .foregroundColor,
            value: textColor,
            range: NSRange(location: 0, length: mutableText.length)
        )
        uiView.attributedText = mutableText
        uiView.backgroundColor = backgroundColor
        uiView.tintColor = textColor
        uiView.textContainerInset = contentInsets
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }

    final class Coordinator: NSObject {
        var onPageNavigation: (ReaderPageGestureAction) -> Void

        init(onPageNavigation: @escaping (ReaderPageGestureAction) -> Void) {
            self.onPageNavigation = onPageNavigation
        }

        @objc func didPan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended,
                  let textView = recognizer.view as? UITextView else { return }
            let translation = recognizer.translation(in: textView)
            let action = ReaderPageGestureAction.resolve(
                translation: CGSize(width: translation.x, height: translation.y),
                location: recognizer.location(in: textView),
                in: textView.bounds.size
            )
            guard action == .previousPage || action == .nextPage else { return }
            onPageNavigation(action)
        }
    }
}
