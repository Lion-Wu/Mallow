//
//  ChatService.swift
//  Mallow
//
//  Created by Lion Wu on 2024/1/8.
//

import Foundation

final class ChatService: NSObject, @unchecked Sendable {
    @MainActor private var requestPreparation: Task<Void, Never>?
    @MainActor private var preparationID = UUID()

    let configurationProvider: ChatServiceConfiguring
    private let endpointResolver: ChatEndpointResolving
    private let requestPayloadProjector: ChatRequestPayloadProjecting
    let requestBodyBuilder: ChatRequestBodyBuilding
    let requestFactory: ChatStreamingRequestBuilding
    private let responseTextExtractor: ChatResponseTextExtracting
    let bufferedResponseParser: ChatBufferedResponseParsing
    let streamPayloadExtractor: ChatStreamPayloadExtracting
    let openAICompatibleStreamReducer: OpenAICompatibleStreamEventReducer
    let openAIResponsesStreamItemReducer: OpenAIResponsesStreamItemReducer
    let anthropicStreamReducer = AnthropicStreamEventReducer()
    let lmStudioStreamReducer: LMStudioStreamEventReducer
    let toolExecutor: ChatToolExecuting
    let toolAuthorizationCoordinator = ChatToolAuthorizationCoordinator()

    let stateQueue: DispatchQueue
    private let sessionQueue: OperationQueue
    private let delegateProxy: ChatServiceDelegateProxy

    let session: URLSession
    var activeStreamRequest: ChatActiveStreamRequest?

    /// Callbacks are explicitly constrained to run on the main actor.
    @MainActor var onDelta: (@MainActor (String) -> Void)?
    @MainActor var onSegment: (@MainActor (AssistantStreamSegment) -> Void)?
    @MainActor var onOpenAIResponsesConversationItems: (@MainActor ([JSONValue]) -> Void)?
    @MainActor var onError: (@MainActor (Error) -> Void)?
    @MainActor var onResponseMetadata: (@MainActor (ChatResponseMetadata) -> Void)?
    @MainActor var onToolActivity: (@MainActor (ChatToolActivity) -> Void)?
    @MainActor var onLongWaitNotice: (@MainActor (ChatStreamLongWaitNotice?) -> Void)?
    @MainActor var onStreamFinished: (@MainActor () -> Void)?

    // Reasoning / body state tracking
    var isLegacyThinkStream = false
    var sawAnyAssistantToken = false
    var sawAnyPrimaryAssistantToken = false
    var lmStudioSawAnyReasoningToken = false
    var newFormatActive = false
    var sentThinkOpen = false
    var sentThinkClose = false
    var isInsideLegacyThinkTag = false
    var shouldTrimNextLegacyThinkLeadingNewline = false
    var legacyThinkTagBuffer = ""
    var streamFinishedEmitted = false
    var lastProcessedSSESequenceNumber: Int?
    var reasoningDeltaItemIDs = Set<String>()
    var outputTextDeltaItemIDs = Set<String>()
    var openAIResponsesStreamItemState = OpenAIResponsesStreamItemState()

    var sseParser = ChatSSEStreamParser()
    let thinkCloseLine = "\n</think>\n"
    let decoder = JSONDecoder()

    // Connection establishment is fatal; long response waits are advisory only.
    var activeLongWaitNotice: ChatStreamLongWaitNotice?
    var waitMonitor: NetworkRequestWaitMonitor?

    // Cancel flag to ignore any residual deltas after stopping.
    var isCancelled: Bool = false

    // HTTP status/error accumulation for non-2xx responses.
    var httpStatusCode: Int?
    let errorBodyCaptureLimit = 32 * 1024
    var errorResponseData = Data()
    let successBodyCaptureLimit = 2 * 1024 * 1024
    var successResponseData = Data()
    var anthropicStreamState = AnthropicStreamEventState()
    var anthropicAssistantContentAccumulator = AnthropicAssistantContentAccumulator()
    var pendingLMStudioStreamErrorMessage: String?
    var pendingResponseMetadata = ChatResponseMetadata.empty
    var backgroundExecutionCoordinator: ChatServiceBackgroundExecutionCoordinator?
    var toolCallAccumulator = ChatToolCallAccumulator()
    var openAIResponsesOutputItems: [[String: Any]] = []
    var openAIResponsesConversationItems: [JSONValue] = []
    var openAIChatCompletionsReasoningDetails: [JSONValue] = []
    var openAIChatCompletionsReasoningText = ""
    var pendingToolCalls: [ChatToolCallEnvelope] = []
    var generatingToolActivities: [String: ChatToolActivity] = [:]
    var activeToolLoopContext: ChatToolLoopContext?
    var activeToolExecutionID: UUID?
    var activeToolExecutionTask: Task<Void, Never>?
    var isToolContinuationStarting = false
    var requestGeneration: UInt64 = 0
    var streamCallbackEpoch: UInt64 = 0
    var streamCallbackAttempt: UInt64 = 0
    var invalidatedStreamCallbackAttempts = Set<UInt64>()
    var promptToolBufferedDeltas: [PromptToolBufferedDelta] = []
    var promptToolPrimaryText = ""
    var promptToolStreamDecision = PromptToolStreamDecision.undecided
    var promptToolPendingThinkClose: String?
    var promptToolKeepsThinkOpen = false
    var promptToolPreviewActivityID: String?

    init(
        configurationProvider: ChatServiceConfiguring,
        endpointResolver: ChatEndpointResolving = DefaultChatEndpointResolver(),
        requestPayloadProjector: ChatRequestPayloadProjecting = ChatRequestPayloadProjector(),
        requestBodyBuilder: ChatRequestBodyBuilding = ChatRequestBodyBuilder(),
        requestFactory: ChatStreamingRequestBuilding = ChatStreamingRequestFactory(),
        responseMetadataExtractor: ChatResponseMetadataExtracting = ChatResponseMetadataExtractor(),
        responseTextExtractor: ChatResponseTextExtracting = ChatResponseTextExtractor(),
        bufferedResponseParser: ChatBufferedResponseParsing? = nil,
        streamPayloadExtractor: ChatStreamPayloadExtracting? = nil,
        toolExecutor: ChatToolExecuting = ChatToolExecutor()
    ) {
        self.configurationProvider = configurationProvider
        self.endpointResolver = endpointResolver
        self.requestPayloadProjector = requestPayloadProjector
        self.requestBodyBuilder = requestBodyBuilder
        self.requestFactory = requestFactory
        self.responseTextExtractor = responseTextExtractor
        self.bufferedResponseParser = bufferedResponseParser ?? ChatBufferedResponseParser(
            metadataExtractor: responseMetadataExtractor,
            textExtractor: responseTextExtractor
        )
        let resolvedStreamPayloadExtractor = streamPayloadExtractor ?? ChatStreamPayloadExtractor(textExtractor: responseTextExtractor)
        self.streamPayloadExtractor = resolvedStreamPayloadExtractor
        self.openAICompatibleStreamReducer = OpenAICompatibleStreamEventReducer(
            metadataExtractor: responseMetadataExtractor,
            textExtractor: responseTextExtractor,
            payloadExtractor: resolvedStreamPayloadExtractor
        )
        self.openAIResponsesStreamItemReducer = OpenAIResponsesStreamItemReducer(
            metadataExtractor: responseMetadataExtractor,
            textExtractor: responseTextExtractor,
            payloadExtractor: resolvedStreamPayloadExtractor
        )
        self.lmStudioStreamReducer = LMStudioStreamEventReducer(metadataExtractor: responseMetadataExtractor)
        self.toolExecutor = toolExecutor
        self.stateQueue = DispatchQueue(label: "Mallow.ChatService.state", qos: .userInitiated)
        let queue = OperationQueue()
        queue.name = "Mallow.ChatService.session"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        queue.underlyingQueue = self.stateQueue
        self.sessionQueue = queue
        let delegateProxy = ChatServiceDelegateProxy()
        self.delegateProxy = delegateProxy
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        // Connection establishment is bounded by the dedicated watchdog. Once
        // connected, an active stream remains open until it finishes, fails, or
        // the user cancels it; long response waits are advisory UI only.
        configuration.timeoutIntervalForRequest = .infinity
        configuration.timeoutIntervalForResource = .infinity
        configuration.httpMaximumConnectionsPerHost = 1
        self.session = URLSession(configuration: configuration, delegate: delegateProxy, delegateQueue: queue)
        super.init()
        delegateProxy.owner = self
        self.backgroundExecutionCoordinator = ChatServiceBackgroundExecutionCoordinator { [weak self] message in
            self?.handleBackgroundExecutionInterruption(message)
        }
    }

    deinit {
        activeToolExecutionTask?.cancel()
        session.invalidateAndCancel()
        stopWatchdog()
        let authorizationCoordinator = toolAuthorizationCoordinator
        Task { await authorizationCoordinator.cancelAll() }
        backgroundExecutionCoordinator?.endSynchronouslyIfNeeded()
    }

    /// Called on the main actor to avoid crossing actor boundaries with SwiftData models.
    @MainActor
    func fetchStreamedData(messages: [ChatMessage], developerPrompt: String?, includeImagesInUserContent: Bool) {
        let base = configurationProvider.apiBaseURL
        let endpointCandidates = endpointResolver.streamingCandidates(
            for: base,
            providerHint: configurationProvider.providerHint,
            styleHint: configurationProvider.requestStyleHint
        )
        guard let firstEndpoint = endpointCandidates.first else {
            onError?(ChatNetworkError.invalidURL)
            return
        }

        do {
            try startStreamedRequest(
                messages: messages,
                developerPrompt: developerPrompt,
                includeImagesInUserContent: includeImagesInUserContent,
                endpoint: firstEndpoint
            )
        } catch {
            onError?(error)
        }
    }

    @MainActor
    private func startStreamedRequest(
        messages: [ChatMessage],
        developerPrompt: String?,
        includeImagesInUserContent: Bool,
        endpoint: ChatAPIEndpointCandidate
    ) throws {
        guard let lastMessageIndex = messages.lastIndex(where: { !$0.isError }) else {
            throw ChatNetworkError.invalidRequestHistory
        }

        let continuesAssistantMessage = !messages[lastMessageIndex].isUser
        let sourceMessages = messages.enumerated().map { index, message in
            let isContinuationTarget = continuesAssistantMessage && index == lastMessageIndex
            return ChatRequestSourceMessage(
                content: message.content,
                isUser: message.isUser,
                isError: message.isError,
                imageAttachments: message.imageAttachments,
                providerResponseID: isContinuationTarget ? nil : message.providerResponseID,
                requestContextFingerprint: message.requestContextFingerprint,
                assistantSegments: message.assistantSegments,
                openAIResponsesConversationItems: isContinuationTarget
                    ? ChatRequestPayloadProjector.continuationItems(for: message)
                    : message.openAIResponsesConversationItems,
                toolActivityPlacements: message.toolActivityPlacements,
                createdAt: message.createdAt
            )
        }
        let configuration = ChatServiceConfiguration(
            apiBaseURL: configurationProvider.apiBaseURL,
            modelIdentifier: configurationProvider.modelIdentifier,
            apiKey: configurationProvider.apiKey,
            providerHint: configurationProvider.providerHint,
            requestStyleHint: configurationProvider.requestStyleHint,
            thinkingCapability: configurationProvider.thinkingCapability,
            thinkingOption: configurationProvider.thinkingOption,
            apiAdvancedSettings: configurationProvider.apiAdvancedSettings,
            toolUseSettings: configurationProvider.toolUseSettings)
        requestPreparation?.cancel()
        let id = UUID()
        preparationID = id
        let generation = stateQueue.sync {
            self.activeStreamRequest?.task.cancel()
            self.activeStreamRequest = nil
            self.cancelActiveToolExecution()
            self.stopWatchdog()
            self.isCancelled = true
            self.advanceRequestGeneration()
            self.beginNewStreamCallbackEpoch()
            return self.requestGeneration
        }
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try await prepareRequest(sourceMessages: sourceMessages, lastMessageIndex: lastMessageIndex,
                continuesAssistantMessage: continuesAssistantMessage, configuration: configuration,
                developerPrompt: developerPrompt, includeImagesInUserContent: includeImagesInUserContent,
                endpoint: endpoint)
        }
        requestPreparation = Task { [weak self] in
            do {
                let prepared = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.preparationID == id,
                      self.stateQueue.sync(execute: { self.requestGeneration == generation }) else { return }
                self.requestPreparation = nil
                self.onResponseMetadata?(ChatResponseMetadata(
                    continuationSeed: prepared.continuationSeed,
                    requestUsedPreviousResponseID: prepared.previousResponseID != nil,
                    requestPreviousResponseID: prepared.previousResponseID))
                self.stateQueue.async { [weak self] in
                    guard let self, self.requestGeneration == generation else { return }
                    self.activeStreamRequest?.task.cancel()
                    self.activeStreamRequest = nil
                    self.cancelActiveToolExecution()
                    self.stopWatchdog()
                    self.resetStreamState()
                    self.openAIResponsesConversationItems = prepared.continuationItems
                    self.advanceRequestGeneration()
                    var activeContext = prepared.toolContext
                    activeContext.requestGeneration = self.requestGeneration
                    self.activeToolLoopContext = activeContext
                    self.isCancelled = false
                    self.startStreaming(endpoint: endpoint, requestBodyData: prepared.body, toolRegistry: prepared.toolContext.toolRegistry)
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.preparationID == id, !Task.isCancelled,
                      self.stateQueue.sync(execute: { self.requestGeneration == generation }) else { return }
                self.requestPreparation = nil
                self.onError?(error)
            }
        }
    }

    private struct PreparedImageRequest: Sendable {
        let body: Data
        let toolContext: ChatToolLoopContext
        let continuationItems: [JSONValue]
        let continuationSeed: ChatContinuationSeed
        let previousResponseID: String?
    }

    private func prepareRequest(
        sourceMessages: [ChatRequestSourceMessage], lastMessageIndex: Int,
        continuesAssistantMessage: Bool, configuration: ChatServiceConfiguration,
        developerPrompt: String?, includeImagesInUserContent: Bool,
        endpoint: ChatAPIEndpointCandidate
    ) async throws -> PreparedImageRequest {
        try Task.checkCancellation()
        let toolRegistry = try await toolExecutor.prepareTools(settings: configuration.toolUseSettings)
        let model = configuration.modelIdentifier
        let initialPayload = try projectedRequestPayload(
            sourceMessages: sourceMessages,
            developerPrompt: developerPrompt,
            includeImagesInUserContent: includeImagesInUserContent,
            endpoint: endpoint
        )
        let payload = initialPayload.messages
        let fullBody = try requestBodyBuilder.buildRequestBodyData(
            model: model, messagePayload: payload, developerPrompt: developerPrompt,
            endpoint: endpoint, apiAdvancedSettings: configuration.apiAdvancedSettings,
            toolUseSettings: configuration.toolUseSettings,
            toolDefinitions: toolRegistry.definitions,
            previousResponseID: nil,
            thinkingCapability: configuration.thinkingCapability,
            thinkingOption: configuration.thinkingOption
        )
        let configurationFingerprint = try ChatRequestContextBuilder.fingerprint(
            request: requestFactory.makeStreamingRequest(
                endpoint: endpoint, requestBodyData: fullBody, apiKey: configuration.apiKey
            ),
            endpoint: endpoint,
            includeImagesInUserContent: includeImagesInUserContent
        )
        let history = try sourceMessages.map(ChatContinuationSeed.historyItem)
        let prefix = ChatContinuationSeed(
            configurationFingerprint: configurationFingerprint,
            history: Array(history.dropLast())
        )
        let previousResponseID = continuesAssistantMessage ? nil : Self.previousResponseID(
            in: sourceMessages, endpoint: endpoint,
            currentRequestFingerprint: try prefix.fingerprint(),
            useProviderContinuationIDs: configuration.toolUseSettings.useProviderContinuationIDs(for: endpoint)
        )
        let continuationSeed = ChatContinuationSeed(
            configurationFingerprint: configurationFingerprint,
            history: continuesAssistantMessage ? Array(history.dropLast()) : history
        )
        // A logical assistant message may span several transport attempts. Seed its
        // native history with the same complete prefix sent for this continuation.
        let continuationItems: [JSONValue]
        if continuesAssistantMessage, endpoint.style == .openAIResponses {
            continuationItems = try requestPayloadProjector.transformedMessagesForRequest(
                messages: [sourceMessages[lastMessageIndex]],
                developerPrompt: nil,
                includeImagesInUserContent: false,
                requestStyle: endpoint.style
            ).map { .normalized($0) }
        } else {
            continuationItems = []
        }
        let toolContext = ChatToolLoopContext(
            currentPayload: initialPayload,
            developerPrompt: developerPrompt,
            includeImagesInUserContent: includeImagesInUserContent,
            model: model,
            endpoint: endpoint,
            iteration: 0,
            previousResponseID: previousResponseID,
            toolRegistry: toolRegistry
        )

        let requestBodyData: Data
        if previousResponseID == nil {
            requestBodyData = fullBody
        } else {
            requestBodyData = try requestBodyBuilder.buildRequestBodyData(
                model: model,
                messagePayload: payload,
                developerPrompt: developerPrompt,
                endpoint: endpoint,
                apiAdvancedSettings: configuration.apiAdvancedSettings,
                toolUseSettings: configuration.toolUseSettings,
                toolDefinitions: toolRegistry.definitions,
                previousResponseID: previousResponseID,
                thinkingCapability: configuration.thinkingCapability,
                thinkingOption: configuration.thinkingOption
            )
        }
        try Task.checkCancellation()
        return PreparedImageRequest(body: requestBodyData, toolContext: toolContext,
            continuationItems: continuationItems, continuationSeed: continuationSeed,
            previousResponseID: previousResponseID)
    }

    static func previousResponseID(
        in sourceMessages: [ChatRequestSourceMessage],
        endpoint: ChatAPIEndpointCandidate,
        currentRequestFingerprint: String? = nil,
        useProviderContinuationIDs: Bool = true,
        now: Date = Date()
    ) -> String? {
        guard useProviderContinuationIDs else {
            return nil
        }
        guard ChatRequestBodyProviderEncoder.supportsPreviousResponseContinuation(endpoint) else {
            return nil
        }

        guard let latestUserIndex = sourceMessages.indices.last,
              sourceMessages[latestUserIndex].isUser,
              latestUserIndex > sourceMessages.startIndex else {
            return nil
        }

        let previousIndex = sourceMessages.index(before: latestUserIndex)
        let previousMessage = sourceMessages[previousIndex]
        let currentRequestFingerprint = currentRequestFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousFingerprint = previousMessage.requestContextFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previousMessage.isUser,
              !previousMessage.isError,
              let createdAt = previousMessage.createdAt,
              now.timeIntervalSince(createdAt) <= Self.previousResponseIDMaxAge,
              let currentRequestFingerprint,
              currentRequestFingerprint.hasPrefix("history-v2:"),
              previousFingerprint == currentRequestFingerprint,
              let responseID = ChatRequestBodyProviderEncoder.normalizedPreviousResponseID(
                previousMessage.providerResponseID,
                endpoint: endpoint
              ) else {
            return nil
        }
        return responseID
    }

    static let previousResponseIDMaxAge: TimeInterval = 30 * 24 * 60 * 60
    func projectedRequestPayload(
        sourceMessages: [ChatRequestSourceMessage],
        developerPrompt: String?,
        includeImagesInUserContent: Bool,
        endpoint: ChatAPIEndpointCandidate
    ) throws -> ChatToolLoopPayload {
        ChatToolLoopPayload(messages: try requestPayloadProjector.transformedMessagesForRequest(
            messages: sourceMessages,
            developerPrompt: developerPrompt,
            includeImagesInUserContent: includeImagesInUserContent,
            requestStyle: endpoint.style
        ))
    }

    /// Cancels the current streaming request.
    @MainActor
    func cancelStreaming() {
        requestPreparation?.cancel()
        requestPreparation = nil
        preparationID = UUID()
        let metadata = stateQueue.sync {
            if var round = self.pendingResponseMetadata.generationRound, round.endedAt == nil {
                round.endedAt = Date()
                round.outcome = "stopped"
                self.pendingResponseMetadata.generationRound = round
            }
            let metadata = self.pendingResponseMetadata
            self.isCancelled = true
            self.advanceRequestGeneration()
            self.activeStreamRequest?.task.cancel()
            self.activeStreamRequest = nil
            self.stopWatchdog()
            Task { await self.toolAuthorizationCoordinator.cancelAll() }
            self.resetStreamState()
            self.activeToolLoopContext = nil
            return metadata
        }
        onResponseMetadata?(metadata)
    }

}

struct PromptToolBufferedDelta: Equatable {
    let piece: String
    let marksPrimaryOutput: Bool
}

enum PromptToolStreamDecision: Equatable {
    case undecided
    case normalAnswer
    case toolCall
}

struct ChatToolLoopContext: Sendable {
    var currentPayload: ChatToolLoopPayload
    let developerPrompt: String?
    let includeImagesInUserContent: Bool
    let model: String
    var endpoint: ChatAPIEndpointCandidate
    var iteration: Int
    var previousResponseID: String?
    let toolRegistry: ChatToolRegistry
    var requestGeneration: UInt64 = 0
    var didRetryWithoutPreviousResponseID = false
}

struct ChatToolLoopPayload: @unchecked Sendable {
    let messages: [[String: Any]]
}

struct ChatActiveStreamRequest {
    let task: URLSessionDataTask
    let endpoint: ChatAPIEndpointCandidate
    let toolRegistry: ChatToolRegistry
}

struct ChatStreamCallbackToken: Hashable, Sendable {
    let epoch: UInt64
    let attempt: UInt64
}

// MARK: - Protocol Conformance

extension ChatService: ChatStreamingService {}
