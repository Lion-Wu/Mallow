//
//  VoiceViewModel.swift
//  Mallow
//
//  Created by Lion Wu on 2024/1/8.
//

import Foundation
import AVFoundation

@MainActor
final class VoiceViewModel: ObservableObject {
    // MARK: - State
    @Published var text: String = String(localized: "VOICE_SAMPLE_TEXT", defaultValue: "Sample text.")
    @Published var connectionStatus: String = String(localized: "NETWORK_WAITING_CONNECTION", defaultValue: "Waiting for connection")
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false

    // MARK: - Audio Session
    func setupAudioSession() {
        #if os(iOS) || os(tvOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            let message = String(format: String(localized: "AUDIO_SESSION_SETUP_FAILED", defaultValue: "Unable to set up audio session: %@"), error.localizedDescription)
            self.errorMessage = message
        }
        #endif
        // On macOS, AVAudioSession is not used.
    }
}
