//
//  ChatService+StreamingLifecycle.swift
//  Mallow
//
//  Created by OpenAI on 2026.06.14.
//

import Foundation

extension ChatService {
    /// Builds the request and starts the URLSession stream on the serial state queue.
    func startStreaming(endpoint: ChatAPIEndpointCandidate, requestBodyData: Data) {
        let request = requestFactory.makeStreamingRequest(
            endpoint: endpoint,
            requestBodyData: requestBodyData,
            apiKey: configurationProvider.apiKey
        )

        let body = (try? JSONSerialization.jsonObject(with: requestBodyData)) as? [String: Any]
        pendingResponseMetadata.generationRound = ChatGenerationRound(
            id: UUID(), requestStyle: endpoint.style,
            requestedModel: body?["model"] as? String ?? configurationProvider.modelIdentifier,
            requestURL: endpoint.chatURL.absoluteString,
            startedAt: Date(), previousResponseID: body?["previous_response_id"] as? String,
            requestedThinking: body.map { body in
                body.filter { ChatGenerationRound.thinkingParameterKeys.contains($0.key) }
                    .mapValues(JSONValue.normalized)
            }
        )
        deliverResponseMetadata(pendingResponseMetadata)
        let task = session.dataTask(with: request)
        activeStreamRequest = ChatActiveStreamRequest(task: task, endpoint: endpoint)

        isToolContinuationStarting = false
        updateLongWaitNotice(nil)
        beginBackgroundExecutionForCurrentRequest()
        startWatchdog()

        task.resume()
    }

    func resetStreamState() {
        beginNewStreamCallbackEpoch()
        cancelActiveToolExecution()
        isLegacyThinkStream = false
        sawAnyAssistantToken = false
        sawAnyPrimaryAssistantToken = false
        lmStudioSawAnyReasoningToken = false
        newFormatActive = false
        sentThinkOpen = false
        sentThinkClose = false
        isInsideLegacyThinkTag = false
        shouldTrimNextLegacyThinkLeadingNewline = false
        legacyThinkTagBuffer = ""
        streamFinishedEmitted = false
        lastProcessedSSESequenceNumber = nil
        reasoningDeltaItemIDs.removeAll(keepingCapacity: true)
        outputTextDeltaItemIDs.removeAll(keepingCapacity: true)
        openAIResponsesStreamItemState = .init()
        anthropicStreamState = .init()
        anthropicAssistantContentAccumulator.reset()
        sseParser.reset()
        updateLongWaitNotice(nil)
        httpStatusCode = nil
        errorResponseData.removeAll(keepingCapacity: true)
        successResponseData.removeAll(keepingCapacity: true)
        pendingLMStudioStreamErrorMessage = nil
        pendingResponseMetadata = .empty
        toolCallAccumulator.reset()
        openAIResponsesOutputItems.removeAll(keepingCapacity: true)
        openAIResponsesConversationItems.removeAll(keepingCapacity: true)
        openAIChatCompletionsReasoningDetails.removeAll(keepingCapacity: true)
        openAIChatCompletionsReasoningText = ""
        pendingToolCalls.removeAll(keepingCapacity: true)
        generatingToolActivities.removeAll(keepingCapacity: true)
        isToolContinuationStarting = false
        Task { await toolAuthorizationCoordinator.cancelAll() }
        resetPromptToolGate()
        endBackgroundExecutionForCurrentRequest()
    }

    func advanceRequestGeneration() {
        requestGeneration &+= 1
    }

    func cancelActiveToolExecution() {
        activeToolExecutionTask?.cancel()
        activeToolExecutionTask = nil
        activeToolExecutionID = nil
    }

    func beginNewStreamCallbackEpoch() {
        streamCallbackEpoch &+= 1
        streamCallbackAttempt = 1
        invalidatedStreamCallbackAttempts.removeAll(keepingCapacity: true)
    }

    func beginStreamCallbackAttempt(invalidatingCurrentAttempt: Bool) {
        if invalidatingCurrentAttempt, streamCallbackAttempt > 0 {
            invalidatedStreamCallbackAttempts.insert(streamCallbackAttempt)
        }
        streamCallbackAttempt &+= 1
    }

    private func currentStreamCallbackToken() -> ChatStreamCallbackToken {
        ChatStreamCallbackToken(epoch: streamCallbackEpoch, attempt: streamCallbackAttempt)
    }

    private func isValidStreamCallbackToken(_ token: ChatStreamCallbackToken) -> Bool {
        stateQueue.sync {
            token.epoch == streamCallbackEpoch &&
                !invalidatedStreamCallbackAttempts.contains(token.attempt)
        }
    }

    func deliverResponseMetadata(_ metadata: ChatResponseMetadata) {
        let token = currentStreamCallbackToken()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isValidStreamCallbackToken(token) {
                self.onResponseMetadata?(metadata)
            } else if let round = metadata.generationRound, round.endedAt != nil,
                      self.stateQueue.sync(execute: { token.epoch == self.streamCallbackEpoch }) {
                // Retrying invalidates text callbacks, not the completed attempt's measurements.
                self.onResponseMetadata?(ChatResponseMetadata(generationRound: round))
            }
        }
    }

    func deliverOpenAIResponsesConversationItems(_ items: [JSONValue]) {
        let token = currentStreamCallbackToken()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isValidStreamCallbackToken(token) else { return }
            self.onOpenAIResponsesConversationItems?(items)
        }
    }

    func deliverLongWaitNotice(_ notice: ChatStreamLongWaitNotice?) {
        let token = currentStreamCallbackToken()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isValidStreamCallbackToken(token) else { return }
            self.onLongWaitNotice?(notice)
        }
    }

    func deliverError(_ error: Error) {
        let token = currentStreamCallbackToken()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isValidStreamCallbackToken(token) else { return }
            self.onError?(error)
        }
    }

    private func deliverDelta(_ piece: String) {
        let token = currentStreamCallbackToken()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isValidStreamCallbackToken(token) else { return }
            self.onDelta?(piece)
        }
    }

    private func deliverSegment(_ segment: AssistantStreamSegment) {
        let token = currentStreamCallbackToken()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isValidStreamCallbackToken(token) else { return }
            self.onSegment?(segment)
        }
    }

    private func deliverStreamFinished() {
        let token = currentStreamCallbackToken()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isValidStreamCallbackToken(token) else { return }
            self.onStreamFinished?()
        }
    }

    private func deliverToolActivity(_ activity: ChatToolActivity) {
        let token = currentStreamCallbackToken()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isValidStreamCallbackToken(token) else { return }
            self.onToolActivity?(activity)
        }
    }

    func isCurrentRequestGeneration(_ generation: UInt64) -> Bool {
        !isCancelled && activeToolLoopContext?.requestGeneration == generation
    }

    func isCurrentRequestGenerationAsync(_ generation: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            stateQueue.async { [weak self] in
                continuation.resume(returning: self?.isCurrentRequestGeneration(generation) == true)
            }
        }
    }

    func captureGenerationMetadata(_ dictionary: [String: Any]) {
        guard var round = pendingResponseMetadata.generationRound else { return }
        let previous = round
        round.absorb(dictionary)
        let type = dictionary["type"] as? String ?? ""
        let delta = dictionary["delta"] as? [String: Any]
        let choices = dictionary["choices"] as? [[String: Any]] ?? []
        let hasToolOutput = type == "response.function_call_arguments.delta"
            || (dictionary["item"] as? [String: Any])?["type"] as? String == "function_call"
            || (dictionary["content_block"] as? [String: Any])?["type"] as? String == "tool_use"
            || delta?["type"] as? String == "input_json_delta"
            || choices.contains { ($0["delta"] as? [String: Any])?["tool_calls"] != nil }
        if hasToolOutput, round.firstOutputAt == nil { round.firstOutputAt = Date() }
        guard round != previous else { return }
        pendingResponseMetadata.generationRound = round
        deliverResponseMetadata(pendingResponseMetadata)
    }

    func markGenerationOutput() {
        guard var round = pendingResponseMetadata.generationRound, round.firstOutputAt == nil else { return }
        round.firstOutputAt = Date()
        pendingResponseMetadata.generationRound = round
        deliverResponseMetadata(pendingResponseMetadata)
    }

    func finishGenerationRound(outcome: String) {
        guard var round = pendingResponseMetadata.generationRound, round.endedAt == nil else { return }
        round.endedAt = Date()
        round.outcome = outcome
        pendingResponseMetadata.generationRound = round
        deliverResponseMetadata(pendingResponseMetadata)
    }

    func mergeResponseMetadata(_ update: ChatResponseMetadata) {
        pendingResponseMetadata.merge(update)
        let snapshot = pendingResponseMetadata
        deliverResponseMetadata(snapshot)
    }

    func failCurrentStreamWithServerError(
        _ message: String,
        statusCode: Int? = nil,
        includeHTTPStatus: Bool = true
    ) {
        let resolvedStatusCode = includeHTTPStatus ? (statusCode ?? httpStatusCode) : statusCode
        failCurrentStream(with: ChatNetworkError.serverError(
            statusCode: resolvedStatusCode,
            message: message
        ))
    }

    func failCurrentStream(with error: Error) {
        finishGenerationRound(outcome: "error")
        isCancelled = true
        updateLongWaitNotice(nil)
        advanceRequestGeneration()
        activeStreamRequest?.task.cancel()
        activeStreamRequest = nil
        cancelActiveToolExecution()
        stopWatchdog()
        activeToolLoopContext = nil
        Task { await toolAuthorizationCoordinator.cancelAll() }
        endBackgroundExecutionForCurrentRequest()
        deliverError(error)
    }

    func emitDelta(_ piece: String, marksPrimaryOutput: Bool = true) {
        guard !isCancelled else { return }
        waitMonitor?.markResponseProgress()
        updateLongWaitNotice(nil)
        if !piece.isEmpty && piece != "<think>\n" && piece != thinkCloseLine { markGenerationOutput() }
        deliverDelta(piece)
        sawAnyAssistantToken = true
        if marksPrimaryOutput {
            sawAnyPrimaryAssistantToken = true
        }
    }

    func emitSegment(_ segment: AssistantStreamSegment, marksPrimaryOutput: Bool) {
        guard !isCancelled else { return }
        waitMonitor?.markResponseProgress()
        updateLongWaitNotice(nil)
        markGenerationOutput()
        deliverSegment(segment)
        sawAnyAssistantToken = true
        if marksPrimaryOutput {
            sawAnyPrimaryAssistantToken = true
        }
    }

    func emitStreamFinishedOnce() {
        guard !isCancelled else { return }
        finishStreamOrRunPendingTools()
    }

    func finishStreamOrRunPendingTools() {
        guard !isCancelled, !isToolContinuationStarting else { return }
        finishGenerationRound(outcome: "completed")
        recordCurrentOpenAIResponsesOutputItemsIfNeeded()
        if shouldRunToolLoopInsteadOfFinishing() {
            runPendingToolCallsAndContinue()
            return
        }
        guard !isCancelled else { return }
        guard !streamFinishedEmitted else { return }
        streamFinishedEmitted = true
        updateLongWaitNotice(nil)
        activeToolLoopContext = nil
        advanceRequestGeneration()
        activeStreamRequest?.task.cancel()
        activeStreamRequest = nil
        stopWatchdog()
        endBackgroundExecutionForCurrentRequest()
        deliverStreamFinished()
    }

    func emitToolActivity(_ activity: ChatToolActivity) {
        deliverToolActivity(activity)
    }

    func emitToolActivity(_ activity: ChatToolActivity, requestGeneration: UInt64) {
        stateQueue.async { [weak self] in
            guard let self,
                  self.isCurrentRequestGeneration(requestGeneration) else {
                return
            }
            self.deliverToolActivity(activity)
        }
    }
}
