//
//  AudioPlayback.swift
//  Mallow
//
//  Created by Lion Wu on 2025/9/21.
//

import Foundation
import AVFoundation

@MainActor
extension GlobalAudioManager {
    private func playbackStateSnapshot() -> TTSPlaybackState {
        TTSPlaybackState(
            textSegmentCount: textSegments.count,
            audioChunkIsLoaded: audioChunks.map { $0 != nil },
            chunkDurations: chunkDurations,
            currentChunkIndex: currentChunkIndex,
            currentTime: currentTime,
            totalDuration: totalDuration,
            endEpsilon: endEpsilon,
            isRealtimeMode: isRealtimeMode,
            realtimeFinalized: realtimeFinalized
        )
    }

    // MARK: - Segment Time Helpers
    func findSegmentIndex(for time: TimeInterval) -> Int {
        playbackStateSnapshot().findSegmentIndex(for: time)
    }

    func startTime(forSegment idx: Int) -> TimeInterval {
        playbackStateSnapshot().startTime(forSegment: idx)
    }

    func allChunksLoaded() -> Bool {
        playbackStateSnapshot().allChunksLoaded
    }

    func playbackFinished() -> Bool {
        playbackStateSnapshot().playbackFinished
    }

    func playbackFinished(at playbackTime: TimeInterval) -> Bool {
        playbackStateSnapshot().playbackFinished(at: playbackTime)
    }

    func recalcTotalDuration() {
        totalDuration = playbackStateSnapshot().calculatedTotalDuration
    }

    // MARK: - Finish
    func finishPlayback() {
        currentPlayingIndex = max(0, audioChunks.count - 1)
        currentTime = max(currentTime, totalDuration)
        isPlaybackRequested = false
        isAudioPlaying = false
        isBuffering = false
        isSeeking = false
        seekTime = nil

        cancelPlaybackPreparation()
        audioPlayer?.stop()
        audioPlayer = nil

        stopAudioTimer()
        stopStallWatchdog()
        deactivateSystemPlaybackSession()
    }

    // MARK: - Prepare/Play
    func cancelPlaybackPreparation() {
        playbackPreparationTask?.cancel()
        playbackPreparationTask = nil
        nextPlaybackPreparationTask?.cancel()
        nextPlaybackPreparationTask = nil
        nextAudioPlayer?.stop()
        nextAudioPlayer = nil
    }

    func prepareNextAudioChunk(at index: Int) {
        nextPlaybackPreparationTask?.cancel()
        nextPlaybackPreparationTask = nil
        guard index == currentPlayingIndex + 1,
              let chunkOpt = audioChunks[safe: index], let data = chunkOpt else { return }
        let generationID = currentGenerationID
        let activation = playbackSessionTask
        nextPlaybackPreparationTask = Task { [weak self] in
            guard await activation?.value == true,
                  let self, !Task.isCancelled,
                  self.currentGenerationID == generationID else { return }
            do {
                let player = try await self.playbackWorker.preparePlayer(data: data)
                guard !Task.isCancelled, self.currentGenerationID == generationID,
                      index == self.currentPlayingIndex + 1 else { return }
                player.delegate = self
                self.nextAudioPlayer = player
                self.nextPlaybackPreparationTask = nil
            } catch {
                // Prefetch is optional. The current segment reports preparation
                // failures through the normal playback path when it is requested.
                guard !Task.isCancelled, self.currentGenerationID == generationID else { return }
                self.nextPlaybackPreparationTask = nil
            }
        }
    }

    func playAudioChunk(at index: Int, fromTime t: TimeInterval? = nil, shouldPlay: Bool = true) {
        cancelPlaybackPreparation()
        guard index >= 0, index < audioChunks.count else {
            if !shouldPlay { isPlaybackRequested = false }
            isBuffering = false
            return
        }
        guard let chunkOpt = audioChunks[safe: index], let data = chunkOpt else {
            isBuffering = shouldPlay
            stopAudioTimer()
            startStallWatchdog()
            isPlaybackRequested = shouldPlay
            isAudioPlaying = false
            if isRealtimeMode { isLoading = shouldPlay }
            return
        }
        guard !playbackFinished() else {
            finishPlayback()
            return
        }

        audioPlayer?.stop()
        audioPlayer = nil
        currentPlayingIndex = index
        isPlaybackRequested = shouldPlay
        isAudioPlaying = false
        isBuffering = shouldPlay
        isLoading = shouldPlay
        stopAudioTimer()
        startStallWatchdog()

        let generationID = currentGenerationID
        let activation = activateSystemPlaybackSession()
        playbackPreparationTask = Task { [weak self] in
            let activated = await activation.value
            guard let self, !Task.isCancelled,
                  self.currentGenerationID == generationID else { return }
            guard activated else {
                self.playbackPreparationTask = nil
                return
            }
            do {
                let player = try await self.playbackWorker.preparePlayer(data: data)
                guard !Task.isCancelled, self.currentGenerationID == generationID else { return }
                self.playbackPreparationTask = nil
                player.delegate = self
                let segStart = self.startTime(forSegment: index)
                let localTime = min(max(0, (t ?? segStart) - segStart), max(0, player.duration))
                if localTime >= max(0, player.duration - self.endEpsilon),
                   self.playbackFinished(at: segStart + localTime) {
                    self.finishPlayback()
                    return
                }
                player.currentTime = localTime
                self.audioPlayer = player
                self.isSeeking = false
                self.isBuffering = false
                self.isLoading = false

                if shouldPlay && self.isPlaybackRequested {
                    guard player.play() else {
                        self.isBuffering = true
                        self.isAudioPlaying = false
                        if self.isRealtimeMode { self.isLoading = true }
                        return
                    }
                    self.startAudioTimer()
                    self.isAudioPlaying = true
                }
                self.prepareNextAudioChunk(at: index + 1)
            } catch {
                guard !Task.isCancelled, self.currentGenerationID == generationID else { return }
                self.playbackPreparationTask = nil
                let message = String(format: NSLocalizedString("AUDIO_ERROR_PLAYBACK_START", value: "Failed to start audio playback: %@", comment: "Shown when AVAudioPlayer fails to start"), error.localizedDescription)
                self.surfaceTTSIssue(message, autoDismiss: 12)
                self.isBuffering = self.isPlaybackRequested
                self.isAudioPlaying = false
                self.isLoading = self.isPlaybackRequested
            }
        }
    }
}

/// Prepares each player away from the UI, then transfers its sole ownership to
/// the main actor. No player is accessed concurrently by both actors.
actor AudioPlaybackWorker {
    func preparePlayer(data: Data) throws -> sending AVAudioPlayer {
        try Task.checkCancellation()
        let player = try AVAudioPlayer(data: data)
        guard player.prepareToPlay() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        return player
    }

    func activateSession() async throws {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        let needsConfiguration = session.category != .playback
            || session.mode != .default || !session.categoryOptions.isEmpty
        if needsConfiguration {
            try session.setCategory(.playback, mode: .default, options: [])
        }
        if #available(iOS 27.0, visionOS 27.0, *) {
            guard try await session.activate(options: []) else {
                throw ActivationError.rejected
            }
        } else {
            try session.setActive(true, options: [])
        }
        #endif
    }

    func deactivateSession() async throws -> Bool {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27.0, visionOS 27.0, *) {
            return try await session.deactivate(options: .notifyOthersOnDeactivation)
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
        return true
    }

    private enum ActivationError: LocalizedError {
        case rejected

        var errorDescription: String? {
            NSLocalizedString(
                "AUDIO_SESSION_NOT_ACTIVATED", value: "The system did not activate the audio session.",
                comment: "Speech recognition audio-session activation error"
            )
        }
    }
}
