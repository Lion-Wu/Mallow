//
//  SpeechInputManager.swift
//  Mallow
//
//  Created by Lion Wu on 2025/9/20.
//

#if os(iOS) || os(macOS) || os(visionOS)

import Foundation
import Combine
import Speech

#if os(iOS) || os(visionOS)
import AVFoundation
#endif

@MainActor
final class SpeechInputManager: NSObject, ObservableObject {
    static let shared = SpeechInputManager()

    // MARK: - Language (two options only)
    enum DictationLanguage: String, CaseIterable, Identifiable {
        case english = "en-US"
        case simplifiedChinese = "zh-CN"
        case traditionalChinese = "zh-TW"
        case japanese = "ja-JP"

        var id: String { rawValue }

        var defaultDisplayName: String {
            switch self {
            case .english:
                return NSLocalizedString("LANGUAGE_ENGLISH", value: "English", comment: "Dictation language")
            case .simplifiedChinese:
                return NSLocalizedString("LANGUAGE_CHINESE_SIMPLIFIED", value: "Simplified Chinese", comment: "Dictation language")
            case .traditionalChinese:
                return NSLocalizedString("LANGUAGE_CHINESE_TRADITIONAL", value: "Traditional Chinese", comment: "Dictation language")
            case .japanese:
                return NSLocalizedString("LANGUAGE_JAPANESE", value: "Japanese", comment: "Dictation language")
            }
        }

        var locale: Locale { Locale(identifier: rawValue) }
    }

    // MARK: - Public State
    @Published private(set) var isRecording: Bool = false
    @Published var lastError: String?

    let inputMotionAudioSource = VoiceMicrophoneAudioSource()

    /// Currently selected dictation language.
    @Published var currentLanguage: DictationLanguage = .english

    /// When enabled, dictation will not auto-finalize on silence. The UI uses this to implement
    /// "hold-to-talk" (press and hold to keep listening; release to finalize).
    @Published private(set) var isHoldToSpeakActive: Bool = false

    /// True while the system permission prompt may be on-screen and we're awaiting user input.
    @Published private(set) var isRequestingPermissions: Bool = false

    // MARK: - Session ownership
    @MainActor
    private final class RecordingSession {
        let id = UUID()
        let onFinal: @MainActor (String) -> Void
        var lastStableText = ""
        var startTask: Task<Void, Never>?
        var stopTask: Task<Void, Never>?
        var finalizeOnStop = false

        init(onFinal: @escaping @MainActor (String) -> Void) {
            self.onFinal = onFinal
        }
    }

    private var currentSession: RecordingSession?
    private let worker = SpeechRecognizerWorker()

    // MARK: - API

    /// Starts realtime dictation after the previous session has released its resources.
    func startRecording(language: DictationLanguage? = nil,
                        onPartial: @escaping @MainActor (String) -> Void,
                        onFinal: @escaping @MainActor (String) -> Void,
                        onSpeechActivityStarted: @escaping @MainActor () -> Void = {}) async {
        guard !Task.isCancelled else { return }
        let previousStop = currentSession.map { stopSession($0, finalize: false) }
        let session = RecordingSession(onFinal: onFinal)
        currentSession = session
        lastError = nil
        let locale = (language ?? currentLanguage).locale

        let startTask = Task { [self] in
            await previousStop?.value
            guard acceptsCallbacks(for: session), !Task.isCancelled else { return }
            isRecording = false
            inputMotionAudioSource.reset()
            isRequestingPermissions = true
            let permissionOK = await requestPermissions()
            guard acceptsCallbacks(for: session), !Task.isCancelled else { return }
            isRequestingPermissions = false
            guard permissionOK else {
                lastError = NSLocalizedString("VOICE_RECOGNITION_PERMISSION_DENIED", value: "Speech recognition or microphone permission not granted", comment: "Shown when the app lacks microphone or speech recognition access")
                stopSession(session, finalize: false)
                return
            }

            do {
                try await worker.start(
                    sessionID: session.id,
                    locale: locale,
                    onPartial: { [weak self] text in
                        Task { @MainActor in
                            guard let self, self.acceptsCallbacks(for: session) else { return }
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            session.lastStableText = trimmed
                            onPartial(trimmed)
                        }
                    },
                    onFinal: { [weak self] text in
                        Task { @MainActor in
                            guard let self, self.acceptsCallbacks(for: session) else { return }
                            session.lastStableText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            self.stopSession(session, finalize: true)
                        }
                    },
                    onSpeechActivityStarted: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.acceptsCallbacks(for: session) else { return }
                            onSpeechActivityStarted()
                        }
                    },
                    motionAudioSource: inputMotionAudioSource,
                    onError: { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.acceptsCallbacks(for: session) else { return }
                            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            self.lastError = trimmed
                            self.stopSession(session, finalize: false)
                        }
                    }
                )
                guard acceptsCallbacks(for: session), !Task.isCancelled else { return }
                isRecording = true
            } catch {
                guard acceptsCallbacks(for: session), !Task.isCancelled else { return }
                if !(error is CancellationError) {
                    lastError = error.localizedDescription
                }
                stopSession(session, finalize: false)
            }
        }
        session.startTask = startTask

        await withTaskCancellationHandler {
            await startTask.value
        } onCancel: {
            startTask.cancel()
        }
        session.startTask = nil
        if Task.isCancelled {
            await stopSession(session, finalize: false).value
        } else {
            await session.stopTask?.value
        }
    }

    func stopRecording(finalize: Bool = true) {
        guard let session = currentSession else { return }
        stopSession(session, finalize: finalize)
    }

    private func acceptsCallbacks(for session: RecordingSession) -> Bool {
        currentSession === session && session.stopTask == nil
    }

    /// A session owns one teardown task, which waits for startup before releasing the microphone.
    @discardableResult
    private func stopSession(_ session: RecordingSession, finalize: Bool) -> Task<Void, Never> {
        if let stopTask = session.stopTask {
            if !finalize { session.finalizeOnStop = false }
            return stopTask
        }
        session.finalizeOnStop = finalize
        let startTask = session.startTask
        startTask?.cancel()
        if currentSession === session {
            isRequestingPermissions = false
        }

        let stopTask = Task { [weak self, worker] in
            await startTask?.value
            let workerText = await worker.stop(sessionID: session.id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, self.currentSession === session else { return }
            let stableText = session.lastStableText
            let bestText = workerText.count > stableText.count ? workerText : stableText
            if session.finalizeOnStop, !bestText.isEmpty {
                session.onFinal(bestText)
            }
            self.clearSession(ifCurrent: session)
        }
        session.stopTask = stopTask
        return stopTask
    }

    private func clearSession(ifCurrent session: RecordingSession) {
        guard currentSession === session else { return }
        currentSession = nil
        isRequestingPermissions = false
        isRecording = false
        inputMotionAudioSource.reset()
    }

    /// Toggles "hold-to-talk" behaviour for the active recording session.
    /// When enabled, silence-based termination is suspended so the recognizer keeps listening.
    func setHoldToSpeakActive(_ active: Bool) {
        isHoldToSpeakActive = active
        Task { await worker.setHoldToSpeakActive(active) }
    }

    // MARK: - Permissions

    private func requestPermissions() async -> Bool {
        let speechOK = await requestSpeechRecognitionPermission()

        #if os(iOS) || os(visionOS)
        let micOK = await requestMicrophonePermission()
        return speechOK && micOK
        #elseif os(macOS)
        // macOS exposes only speech recognition permission; microphone prompts are system-driven.
        return speechOK
        #endif
    }

    private func requestSpeechRecognitionPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                // TCC may invoke the callback on a background queue; detach to avoid tripping
                // main-actor isolation checks in Swift 6 and hop back only to resume.
                Task.detached {
                    SFSpeechRecognizer.requestAuthorization { status in
                        cont.resume(returning: status == .authorized)
                    }
                }
            }
        @unknown default:
            return false
        }
    }

    #if os(iOS) || os(visionOS)
    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                Task.detached {
                    AVAudioApplication.requestRecordPermission { ok in
                        cont.resume(returning: ok)
                    }
                }
            }
        @unknown default:
            return false
        }
    }
    #endif
}

#else

import Foundation
import Combine

@MainActor
final class SpeechInputManager: ObservableObject {
    static let shared = SpeechInputManager()

    enum DictationLanguage: String, CaseIterable, Identifiable {
        case english = "en-US"
        case simplifiedChinese = "zh-CN"
        case traditionalChinese = "zh-TW"
        case japanese = "ja-JP"

        var id: String { rawValue }
        var defaultDisplayName: String { "Unavailable" }
        var locale: Locale { Locale(identifier: rawValue) }
    }

    @Published private(set) var isRecording: Bool = false
    @Published var lastError: String? = NSLocalizedString("VOICE_INPUT_UNSUPPORTED", value: "Speech input is not supported on this platform.", comment: "Shown when speech input is unavailable")
    let inputMotionAudioSource = VoiceMicrophoneAudioSource()
    @Published var currentLanguage: DictationLanguage = .english
    @Published private(set) var isHoldToSpeakActive: Bool = false
    @Published private(set) var isRequestingPermissions: Bool = false

    func startRecording(language: DictationLanguage? = nil,
                        onPartial: @escaping @MainActor (String) -> Void,
                        onFinal:   @escaping @MainActor (String) -> Void,
                        onSpeechActivityStarted: @escaping @MainActor () -> Void = {}) async {
        lastError = NSLocalizedString("VOICE_INPUT_UNSUPPORTED", value: "Speech input is not supported on this platform.", comment: "Shown when speech input is unavailable")
    }

    func setHoldToSpeakActive(_ active: Bool) {
        isHoldToSpeakActive = active
    }

    nonisolated func stopRecording(finalize: Bool = true) {}
}

#endif
