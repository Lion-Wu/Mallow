//
//  ChatAssistantStreamTelemetryCoordinator.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import Foundation

enum ChatStreamMetricValueSource: String {
    case local
    case provider
}

struct ChatAssistantStreamTelemetry {
    let streamID: UUID
    let startedAt: Date
    let modelIdentifier: String
    let apiBaseURL: String
    let thinkingOption: ModelThinkingOption?
    let developerPrompt: String?
    let includeImagesInUserContent: Bool
}

struct ChatAssistantStreamTelemetryRetryCheckpoint {
    fileprivate let activeTelemetry: ChatAssistantStreamTelemetry?
    fileprivate let pendingServerMetadata: ChatResponseMetadata
    fileprivate let pendingDeltaWriteBytes: Int
}

struct ChatAssistantStreamTelemetryCoordinator {
    private(set) var activeTelemetry: ChatAssistantStreamTelemetry?
    private var generationRounds: [ChatGenerationRound] = []
    private var pendingServerMetadata: ChatResponseMetadata = .empty
    private var pendingDeltaWriteBytes: Int = 0
    private let deltaPersistThreshold: Int

    init(deltaPersistThreshold: Int = 2048) {
        self.deltaPersistThreshold = deltaPersistThreshold
    }

    var activeDeveloperPrompt: String? {
        activeTelemetry?.developerPrompt
    }

    var activeIncludeImagesInUserContent: Bool {
        activeTelemetry?.includeImagesInUserContent ?? false
    }

    func makeRetryCheckpoint() -> ChatAssistantStreamTelemetryRetryCheckpoint {
        ChatAssistantStreamTelemetryRetryCheckpoint(
            activeTelemetry: activeTelemetry,
            pendingServerMetadata: pendingServerMetadata,
            pendingDeltaWriteBytes: pendingDeltaWriteBytes
        )
    }

    mutating func restoreRetryCheckpoint(_ checkpoint: ChatAssistantStreamTelemetryRetryCheckpoint) {
        var requestMetadata = ChatResponseMetadata.empty
        requestMetadata.continuationSeed = pendingServerMetadata.continuationSeed
        requestMetadata.requestUsedPreviousResponseID = pendingServerMetadata.requestUsedPreviousResponseID
        requestMetadata.requestPreviousResponseID = pendingServerMetadata.requestPreviousResponseID

        activeTelemetry = checkpoint.activeTelemetry
        pendingServerMetadata = checkpoint.pendingServerMetadata
        pendingDeltaWriteBytes = checkpoint.pendingDeltaWriteBytes
        pendingServerMetadata.merge(requestMetadata)
        // Retried requests retain their own statistics, even when their display text is rolled back.
        if let index = generationRounds.indices.last, generationRounds[index].endedAt == nil {
            generationRounds[index].outcome = "interrupted"
        }
    }

    mutating func mergeServerMetadata(_ metadata: ChatResponseMetadata) {
        if let round = metadata.generationRound {
            if let index = generationRounds.firstIndex(where: { $0.id == round.id }) {
                generationRounds[index] = round
            } else {
                generationRounds.append(round)
            }
        }
        pendingServerMetadata.merge(metadata)
    }

    func applyGenerationRounds(to message: ChatMessage) {
        guard !generationRounds.isEmpty else { return }
        message.generationRounds = generationRounds
        // Existing legacy measurements remain historical data; new requests never update them.
    }

    mutating func resetStreamingPersistenceState() {
        pendingDeltaWriteBytes = 0
    }

    mutating func recordStreamStart(
        using messages: [ChatMessage],
        configuration: ChatServiceConfiguration,
        developerPrompt: String?,
        includeImagesInUserContent: Bool,
        startedAt: Date = Date(),
        streamID: UUID = UUID()
    ) {
        resetStreamingPersistenceState()
        pendingServerMetadata = .empty
        let lastMessage = messages.last(where: { !$0.content.hasPrefix("!error:") })
        generationRounds = lastMessage?.isUser == false ? (lastMessage?.generationRounds ?? []) : []

        activeTelemetry = ChatAssistantStreamTelemetry(
            streamID: streamID,
            startedAt: startedAt,
            modelIdentifier: configuration.modelIdentifier,
            apiBaseURL: configuration.apiBaseURL,
            thinkingOption: configuration.thinkingOption,
            developerPrompt: developerPrompt,
            includeImagesInUserContent: includeImagesInUserContent
        )
    }

    mutating func applyStreamMetadata(
        to message: ChatMessage,
        fallbackConfiguration: ChatServiceConfiguration
    ) {
        if message.modelIdentifier == nil {
            message.modelIdentifier = activeTelemetry?.modelIdentifier ?? fallbackConfiguration.modelIdentifier
        }
        if message.apiBaseURL == nil {
            message.apiBaseURL = activeTelemetry?.apiBaseURL ?? fallbackConfiguration.apiBaseURL
        }
        if message.thinkingOptionRawValue == nil {
            message.thinkingOption = activeTelemetry?.thinkingOption ?? fallbackConfiguration.thinkingOption
        }
        if message.requestID == nil { message.requestID = activeTelemetry?.streamID }
        applyRequestTransportMetadata(to: message)
        applyGenerationRounds(to: message)
    }

    mutating func shouldForceImmediatePersist(afterAppending addedChars: Int) -> Bool {
        pendingDeltaWriteBytes += addedChars
        guard pendingDeltaWriteBytes >= deltaPersistThreshold else { return false }
        pendingDeltaWriteBytes = 0
        return true
    }

    @discardableResult
    mutating func finalizeActiveAssistantMessage(
        _ message: ChatMessage?,
        reason: String,
        finishedAt: Date,
        errorDescription: String?,
        fallbackConfiguration: ChatServiceConfiguration
    ) -> ChatMessage? {
        guard let message else {
            clearActiveStream()
            return nil
        }

        message.isActive = false
        if message.finishReason == nil {
            message.finishReason = reason
            if message.finishReasonSource == nil {
                message.finishReasonSource = ChatStreamMetricValueSource.local.rawValue
            }
        }
        if message.errorDescription == nil {
            message.errorDescription = errorDescription
        }

        if generationRounds.isEmpty, message.streamStartedAt == nil {
            message.streamStartedAt = activeTelemetry?.startedAt ?? message.createdAt
        }
        if message.modelIdentifier == nil {
            message.modelIdentifier = activeTelemetry?.modelIdentifier ?? fallbackConfiguration.modelIdentifier
        }
        if message.apiBaseURL == nil {
            message.apiBaseURL = activeTelemetry?.apiBaseURL ?? fallbackConfiguration.apiBaseURL
        }
        if message.requestID == nil {
            message.requestID = activeTelemetry?.streamID ?? UUID()
        }
        if generationRounds.isEmpty, message.streamCompletedAt == nil {
            message.streamCompletedAt = finishedAt
        }
        if let index = generationRounds.indices.last, generationRounds[index].endedAt == nil {
            if generationRounds[index].outcome != "interrupted" { generationRounds[index].endedAt = finishedAt }
            generationRounds[index].outcome = reason
        }
        applyServerMetadata(to: message)
        message.requestContextFingerprint = nil
        if reason == "completed", errorDescription == nil,
           let seed = pendingServerMetadata.continuationSeed,
           message.providerResponseID != nil {
            do {
                message.requestContextFingerprint = try seed.fingerprint(appending: message.requestSource)
            } catch {
                print("Cannot encode completed conversation fingerprint: \(error)")
            }
        }
        clearActiveStream()
        return message
    }

    func makeErrorMessage(
        errorText: String,
        fallbackErrorDescription: String,
        createdAt: Date,
        telemetry: ChatAssistantStreamTelemetry?,
        fallbackConfiguration: ChatServiceConfiguration,
        session: ChatSession
    ) -> ChatMessage {
        let content = "!error:\(errorText.isEmpty ? fallbackErrorDescription : errorText)"
        let message = ChatMessage(
            content: content, isUser: false, isActive: false, createdAt: createdAt,
            modelIdentifier: telemetry?.modelIdentifier ?? fallbackConfiguration.modelIdentifier,
            apiBaseURL: telemetry?.apiBaseURL ?? fallbackConfiguration.apiBaseURL,
            thinkingOptionRawValue: (telemetry?.thinkingOption ?? fallbackConfiguration.thinkingOption)?.rawValue,
            requestID: telemetry?.streamID,
            streamStartedAt: telemetry?.startedAt, streamCompletedAt: createdAt,
            finishReasonSource: ChatStreamMetricValueSource.local.rawValue,
            finishReason: "error",
            errorDescription: errorText.isEmpty ? fallbackErrorDescription : errorText,
            session: session
        )
        var rounds = generationRounds
        if let index = rounds.indices.last, rounds[index].endedAt == nil {
            rounds[index].endedAt = createdAt
            rounds[index].outcome = "error"
        }
        message.generationRounds = rounds
        if !rounds.isEmpty {
            message.streamStartedAt = nil
            message.streamCompletedAt = nil
        }
        return message
    }

    @discardableResult
    func finalizeDanglingActiveAssistantMessage(_ message: ChatMessage, now: Date) -> Bool {
        guard !message.isUser, message.isActive else { return false }
        message.isActive = false
        if message.finishReason == nil {
            message.finishReason = message.hasAssistantOutput ? "stopped" : "cancelled"
            if message.finishReasonSource == nil {
                message.finishReasonSource = ChatStreamMetricValueSource.local.rawValue
            }
        }
        if message.errorDescription == nil {
            message.errorDescription = interruptionDisplayText(for: message.finishReason)
        }
        if message.generationRounds.isEmpty {
            if message.streamStartedAt == nil { message.streamStartedAt = message.createdAt }
            if message.streamCompletedAt == nil { message.streamCompletedAt = now }
        }
        var rounds = message.generationRounds
        for index in rounds.indices where rounds[index].endedAt == nil {
            // After a process interruption, the actual network end time is unknown.
            rounds[index].outcome = "interrupted"
        }
        message.generationRounds = rounds
        return true
    }

    private func applyServerMetadata(to message: ChatMessage) {
        let metadata = pendingServerMetadata
        if let round = generationRounds.last {
            message.providerResponseID = round.providerResponseID
        } else if let responseID = metadata.providerResponseID,
                  !responseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message.providerResponseID = responseID
        }
        applyRequestTransportMetadata(to: message)
        if shouldPreserveLocalTerminalFinishReason(message.finishReason) {
            if message.finishReasonSource == nil {
                message.finishReasonSource = ChatStreamMetricValueSource.local.rawValue
            }
        } else if let finishReason = generationRounds.last?.finishReason ?? (generationRounds.isEmpty ? metadata.finishReason : nil),
                  !finishReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message.finishReason = finishReason
            message.finishReasonSource = ChatStreamMetricValueSource.provider.rawValue
        } else if message.finishReason != nil, message.finishReasonSource == nil {
            message.finishReasonSource = ChatStreamMetricValueSource.local.rawValue
        }

        applyGenerationRounds(to: message)
    }

    private func applyRequestTransportMetadata(to message: ChatMessage) {
        let metadata = pendingServerMetadata
        if let usedPreviousResponseID = metadata.requestUsedPreviousResponseID {
            message.requestUsedPreviousResponseID = usedPreviousResponseID
            if !usedPreviousResponseID {
                message.requestPreviousResponseID = nil
            }
        }
        if metadata.requestUsedPreviousResponseID != false,
           let previousResponseID = metadata.requestPreviousResponseID,
           !previousResponseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message.requestPreviousResponseID = previousResponseID
            if message.requestUsedPreviousResponseID == nil {
                message.requestUsedPreviousResponseID = true
            }
        }
    }

    private mutating func clearActiveStream() {
        activeTelemetry = nil
        pendingServerMetadata = .empty
        generationRounds.removeAll(keepingCapacity: true)
    }

    private func interruptionDisplayText(for finishReason: String?) -> String {
        if finishReason == "stopped" {
            return NSLocalizedString(
                "Stopped.",
                comment: "Shown when an assistant response is stopped after output starts"
            )
        }
        return NSLocalizedString(
            "Cancelled.",
            comment: "Shown when an active assistant response is cancelled before output starts"
        )
    }

    private func shouldPreserveLocalTerminalFinishReason(_ finishReason: String?) -> Bool {
        switch finishReason {
        case "error", "cancelled", "stopped", "superseded":
            return true
        default:
            return false
        }
    }

}
