import Foundation

// MARK: - AudioChapter
/// 音频章节播放模型。
struct AudioChapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let url: URL
}
