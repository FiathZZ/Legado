import Foundation
import UIKit

/// A single paginated page produced by the new reader engine.
struct ReaderPage: Equatable, Sendable {
    var chapterID: String
    var pageIndex: Int
    var contentRange: NSRange
    var attributedText: NSAttributedString
    var contentSize: CGSize
    var extraHeaderHeight: CGFloat

    var isEmpty: Bool {
        attributedText.length == 0
    }
}
