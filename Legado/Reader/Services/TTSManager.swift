import AVFoundation
import Combine
import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 系统 TTS 管理器
@MainActor
final class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isControlVisible: Bool = false
    @Published private(set) var selectedRate: Float
    @Published private(set) var currentChapterTitle: String = ""
    @Published var currentUtteranceRange: NSRange?

    var onChapterFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var remoteCommandsConfigured = false
    private var currentText: String = ""
    private var currentBookName: String = ""
    private var resumeLocation: Int = 0
    private var shouldResumeWithFreshUtterance = false
    private var pendingRestartLocation: Int?
    private var isRestartingCurrentUtterance = false
    private var isStopRequested = false
    private var allowNextProgrammaticChapterChange = false

    private static let userDefaultsKey = "reader.tts.rate"
    private static let supportedRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    override init() {
        let storedRate = UserDefaults.standard.float(forKey: Self.userDefaultsKey)
        self.selectedRate = Self.supportedRates.contains(storedRate) ? storedRate : 1.0
        super.init()
        synthesizer.delegate = self
    }
   

    func startReading(text: String, bookName: String, chapterTitle: String) {
        let normalizedText = Self.normalizeSpeechText(text)
        guard !normalizedText.isEmpty else { return }

        isStopRequested = false
        pendingRestartLocation = nil
        shouldResumeWithFreshUtterance = false
        currentText = normalizedText
        currentBookName = bookName
        currentChapterTitle = chapterTitle
        resumeLocation = 0
        currentUtteranceRange = nil
        isControlVisible = true

        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }

        configureAudioSession(active: true)
        configureRemoteCommandsIfNeeded()
        updateNowPlayingInfo(isPlaying: true)
        speakCurrentText(from: 0)
    }

    func pause() {
        guard synthesizer.isSpeaking else { return }
        _ = synthesizer.pauseSpeaking(at: .word)
        isPlaying = false
        updateNowPlayingInfo(isPlaying: false)
    }

    func resume() {
        if shouldResumeWithFreshUtterance {
            shouldResumeWithFreshUtterance = false
            configureAudioSession(active: true)
            speakCurrentText(from: resumeLocation)
            return
        }

        guard synthesizer.isPaused else { return }
        _ = synthesizer.continueSpeaking()
        isPlaying = true
        updateNowPlayingInfo(isPlaying: true)
    }

    func stop() {
        stopPlayback(resetSession: true)
    }

    func stopForUserNavigation() {
        stopPlayback(resetSession: true)
    }

    func setRate(_ rate: Float) {
        let clampedRate = Self.supportedRates.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1.0
        selectedRate = clampedRate
        UserDefaults.standard.set(clampedRate, forKey: Self.userDefaultsKey)

        if isControlVisible, !currentText.isEmpty {
            // 切倍速会重建当前 utterance，期间收到旧回调时不能误判为读完整章。
            isRestartingCurrentUtterance = true
        }

        if synthesizer.isSpeaking {
            pendingRestartLocation = currentUtteranceRange?.location ?? resumeLocation
            synthesizer.stopSpeaking(at: .immediate)
        } else if synthesizer.isPaused {
            resumeLocation = currentUtteranceRange?.location ?? resumeLocation
            shouldResumeWithFreshUtterance = true
        } else {
            updateNowPlayingInfo(isPlaying: false)
        }
    }

    func prepareForProgrammaticChapterChange() {
        allowNextProgrammaticChapterChange = true
    }

    func consumeProgrammaticChapterChangeAllowance() -> Bool {
        let allowed = allowNextProgrammaticChapterChange
        allowNextProgrammaticChapterChange = false
        return allowed
    }

    private func stopPlayback(resetSession: Bool) {
        pendingRestartLocation = nil
        isRestartingCurrentUtterance = false
        shouldResumeWithFreshUtterance = false
        isStopRequested = true
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        } else if resetSession {
            resetSessionState()
        }
    }

    private func speakCurrentText(from location: Int) {
        let safeLocation = min(max(location, 0), currentText.utf16.count)
        resumeLocation = safeLocation
        let speechText = substring(fromUTF16Offset: safeLocation, in: currentText)
        guard !speechText.isEmpty else {
            onChapterFinished?()
            return
        }

        let utterance = AVSpeechUtterance(string: speechText)
        utterance.rate = Self.avSpeechRate(for: selectedRate)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "zh-CN")
        utterance.prefersAssistiveTechnologySettings = true
        isRestartingCurrentUtterance = false
        synthesizer.speak(utterance)
        isPlaying = true
        updateNowPlayingInfo(isPlaying: true)
    }

    nonisolated static func normalizeSpeechText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func substring(fromUTF16Offset offset: Int, in text: String) -> String {
        guard offset < text.utf16.count else {
            return ""
        }
        let index = String.Index(utf16Offset: offset, in: text)
        return String(text[index...])
    }

    nonisolated static func avSpeechRate(for multiplier: Float) -> Float {
        let minRate = AVSpeechUtteranceMinimumSpeechRate
        let maxRate = AVSpeechUtteranceMaximumSpeechRate
        let normalized = max(0, min((multiplier - 0.5) / 1.5, 1))
        return minRate + (maxRate - minRate) * normalized
    }

    private func configureAudioSession(active: Bool) {
        let session = AVAudioSession.sharedInstance()
        if active {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowAirPlay])
            try? session.setActive(true)
            #if canImport(UIKit)
            UIApplication.shared.beginReceivingRemoteControlEvents()
            #endif
        } else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            #if canImport(UIKit)
            UIApplication.shared.endReceivingRemoteControlEvents()
            #endif
        }
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commandCenter.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stop() }
            return .success
        }
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlayingInfo(isPlaying: Bool) {
        guard isControlVisible, !currentBookName.isEmpty else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentChapterTitle.isEmpty ? currentBookName : currentChapterTitle,
            MPMediaItemPropertyAlbumTitle: currentBookName,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? NSNumber(value: selectedRate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: NSNumber(value: selectedRate)
        ]

        if #available(iOS 13.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
    }

    private func resetSessionState() {
        isPlaying = false
        isControlVisible = false
        currentUtteranceRange = nil
        currentText = ""
        currentBookName = ""
        currentChapterTitle = ""
        resumeLocation = 0
        pendingRestartLocation = nil
        isRestartingCurrentUtterance = false
        allowNextProgrammaticChapterChange = false
        isStopRequested = false
        updateNowPlayingInfo(isPlaying: false)
        configureAudioSession(active: false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        isPlaying = false
        updateNowPlayingInfo(isPlaying: false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        isPlaying = true
        updateNowPlayingInfo(isPlaying: true)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let location = resumeLocation + characterRange.location
        currentUtteranceRange = NSRange(location: location, length: characterRange.length)
        resumeLocation = location
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isPlaying = false
        currentUtteranceRange = nil
        updateNowPlayingInfo(isPlaying: false)
        guard !isRestartingCurrentUtterance, pendingRestartLocation == nil, !isStopRequested else { return }
        onChapterFinished?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if let location = pendingRestartLocation {
            pendingRestartLocation = nil
            configureAudioSession(active: true)
            speakCurrentText(from: location)
            return
        }

        if isStopRequested {
            resetSessionState()
        }
    }
}
