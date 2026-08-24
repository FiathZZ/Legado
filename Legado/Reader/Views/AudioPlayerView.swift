import SwiftUI
import AVFoundation

// MARK: - AudioPlayerView
/// 最小音频章节播放界面。
struct AudioPlayerView: View {
    @ObservedObject var viewModel: ReaderViewModel
    var onBack: (() -> Void)? = nil
    @State private var player: AVPlayer? = nil
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Label("返回", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(.horizontal)

            Text(viewModel.currentChapter?.title ?? viewModel.bookName)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let audio = viewModel.currentAudioChapter {
                Text(audio.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            } else {
                ProgressView()
            }

            HStack(spacing: 24) {
                Button("上一章") {
                    Task { await viewModel.goPrev() }
                }
                .disabled(viewModel.currentIndex == 0)

                Button(isPlaying ? "暂停" : "播放") {
                    togglePlayback()
                }
                .disabled(viewModel.currentAudioChapter == nil)

                Button("下一章") {
                    Task { await viewModel.goNext() }
                }
                .disabled(viewModel.currentIndex >= viewModel.chapters.count - 1)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding(.top, 40)
        .task(id: viewModel.currentIndex) {
            await viewModel.loadCurrentChapter()
            refreshPlayer()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func refreshPlayer() {
        guard let audio = viewModel.currentAudioChapter else {
            player?.pause()
            player = nil
            isPlaying = false
            return
        }

        player = AVPlayer(url: audio.url)
        if isPlaying {
            player?.play()
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
}
