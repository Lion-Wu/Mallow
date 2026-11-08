//
//  AppleSpeechSynthesisSession.swift
//  Mallow
//
//  Created by Codex on 2026/7/28.
//

import AVFoundation
import Foundation

enum AppleSpeechSynthesisError: LocalizedError, Equatable, Sendable {
    case cancelled
    case emptyText
    case voiceUnavailable
    case unexpectedBuffer
    case audioFileFailure
    case emptyAudio
    case synthesisFailed

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return NSLocalizedString("VOICE_SPEECH_CANCELLED", value: "Apple Speech synthesis was cancelled.", comment: "Apple speech synthesis cancellation")
        case .emptyText:
            return NSLocalizedString("VOICE_SPEECH_NO_TEXT", value: "There is no text to speak.", comment: "Apple speech synthesis received empty text")
        case .voiceUnavailable:
            return NSLocalizedString("VOICE_APPLE_VOICE_UNAVAILABLE", value: "The selected Apple voice is not installed or is unavailable.", comment: "Selected Apple speech voice cannot be used")
        case .unexpectedBuffer:
            return NSLocalizedString("VOICE_SPEECH_UNSUPPORTED_AUDIO_FORMAT", value: "Apple Speech returned an unsupported audio format.", comment: "Apple speech returned a non-PCM audio buffer")
        case .audioFileFailure:
            return NSLocalizedString("VOICE_SPEECH_AUDIO_PREPARATION_FAILED", value: "Apple Speech audio could not be prepared for playback.", comment: "Apple speech audio file conversion failed")
        case .emptyAudio:
            return NSLocalizedString("VOICE_SPEECH_NO_AUDIO", value: "Apple Speech did not produce any audio.", comment: "Apple speech synthesis returned no audio frames")
        case .synthesisFailed:
            return NSLocalizedString("VOICE_SPEECH_SYNTHESIS_FAILED", value: "Apple Speech could not complete speech synthesis.", comment: "The system speech synthesizer ended the request unexpectedly")
        }
    }

    var disposition: TTSFailureDisposition {
        switch self {
        case .cancelled:
            return .fatal
        case .emptyText, .voiceUnavailable, .synthesisFailed:
            return .fatal
        case .unexpectedBuffer, .audioFileFailure, .emptyAudio:
            return .transient
        }
    }
}

/// Owns one `AVSpeechSynthesizer.write` operation and converts its PCM buffers into
/// a self-contained CAF payload that the existing audio queue can play and seek.
final class AppleSpeechSynthesisSession: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    typealias Completion = @MainActor @Sendable (Result<Data, AppleSpeechSynthesisError>) -> Void

    private let lock = NSLock()
    private let temporaryURL: URL
    private let completion: Completion
    private var synthesizer: AVSpeechSynthesizer?
    private var audioFile: AVAudioFile?
    private var isCompleted = false
    private var wroteAudioFrames = false

    private init(completion: @escaping Completion) {
        self.completion = completion
        self.temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mallow-AppleSpeech-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        super.init()
    }

    static func start(
        text: String,
        voiceIdentifier: String?,
        provider: TTSProvider,
        completion: @escaping Completion
    ) -> AppleSpeechSynthesisSession {
        let session = AppleSpeechSynthesisSession(completion: completion)
        session.start(text: text, voiceIdentifier: voiceIdentifier, provider: provider)
        return session
    }

    func cancel() {
        lock.lock()
        let activeSynthesizer = synthesizer
        lock.unlock()

        // Claim user cancellation before stopSpeaking can call the delegate.
        finish(with: .failure(.cancelled))
        _ = activeSynthesizer?.stopSpeaking(at: .immediate)
    }

    private func start(
        text: String,
        voiceIdentifier: String?,
        provider: TTSProvider
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            finish(with: .failure(.emptyText))
            return
        }

        let selectedIdentifier = voiceIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let voice: AVSpeechSynthesisVoice?
        if let selectedIdentifier, !selectedIdentifier.isEmpty {
            voice = AVSpeechSynthesisVoice(identifier: selectedIdentifier)
        } else {
            voice = AVSpeechSynthesisVoice.speechVoices().first {
                !$0.voiceTraits.contains(.isPersonalVoice)
                    && $0.language == AVSpeechSynthesisVoice.currentLanguageCode()
            } ?? AVSpeechSynthesisVoice.speechVoices().first {
                !$0.voiceTraits.contains(.isPersonalVoice)
            }
        }

        guard let voice,
              (provider == .personalVoice) == voice.voiceTraits.contains(.isPersonalVoice) else {
            finish(with: .failure(.voiceUnavailable))
            return
        }

        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        let newSynthesizer = AVSpeechSynthesizer()
        newSynthesizer.delegate = self
        lock.lock()
        synthesizer = newSynthesizer
        lock.unlock()

        newSynthesizer.write(utterance) { [weak self] buffer in
            self?.consume(buffer)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // A terminal speech event also closes requests that return no final PCM
        // buffer, so a failed system synthesis cannot leave the queue in flight.
        finishFromAudioFile()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(with: .failure(.synthesisFailed))
    }

    private func consume(_ buffer: AVAudioBuffer) {
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
            finish(with: .failure(.unexpectedBuffer))
            return
        }

        guard pcmBuffer.frameLength > 0 else {
            finishFromAudioFile()
            return
        }

        var writeFailure: AppleSpeechSynthesisError?
        lock.lock()
        if !isCompleted {
            do {
                if audioFile == nil {
                    // A system fallback voice can return a different format than the selected voice.
                    let format = pcmBuffer.format
                    audioFile = try AVAudioFile(
                        forWriting: temporaryURL,
                        settings: format.settings,
                        commonFormat: format.commonFormat,
                        interleaved: format.isInterleaved
                    )
                }
                try audioFile?.write(from: pcmBuffer)
                wroteAudioFrames = true
            } catch {
                writeFailure = .audioFileFailure
            }
        }
        lock.unlock()

        if let writeFailure {
            finish(with: .failure(writeFailure))
        }
    }

    private func finishFromAudioFile() {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        guard wroteAudioFrames else {
            lock.unlock()
            finish(with: .failure(.emptyAudio))
            return
        }

        isCompleted = true
        audioFile = nil
        synthesizer = nil
        lock.unlock()

        let result: Result<Data, AppleSpeechSynthesisError>
        do {
            let data = try Data(contentsOf: temporaryURL)
            result = data.isEmpty ? .failure(.emptyAudio) : .success(data)
        } catch {
            result = .failure(.audioFileFailure)
        }
        removeTemporaryFile()
        deliver(result)
    }

    private func finish(with result: Result<Data, AppleSpeechSynthesisError>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        audioFile = nil
        synthesizer = nil
        lock.unlock()

        removeTemporaryFile()
        deliver(result)
    }

    private func deliver(_ result: Result<Data, AppleSpeechSynthesisError>) {
        Task { @MainActor [completion] in
            completion(result)
        }
    }

    private func removeTemporaryFile() {
        try? FileManager.default.removeItem(at: temporaryURL)
    }
}
