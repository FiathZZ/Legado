import SwiftUI

// MARK: - 朗读控制条
struct TTSControlBarView: View {
    @ObservedObject var manager: TTSManager

    let onPlayPause: () -> Void
    let onStop: () -> Void
    let onClose: () -> Void

    private let supportedRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.12), in: Circle())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("系统朗读")
                        .font(.headline)
                        .foregroundStyle(.white)
                    if !manager.currentChapterTitle.isEmpty {
                        Text(manager.currentChapterTitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                Button(action: onPlayPause) {
                    Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.16), in: Circle())
                }

                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.12), in: Circle())
                }
            }

            Picker(
                "朗读倍速",
                selection: Binding(
                    get: { manager.selectedRate },
                    set: { manager.setRate($0) }
                )
            ) {
                ForEach(supportedRates, id: \.self) { rate in
                    Text(String(format: "%.2gx", rate)).tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .colorScheme(.dark)
        }
        .padding(16)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 8)
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }
}
