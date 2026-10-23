import XCTest
@testable import Mallow

@MainActor
final class ChatTextRequestRuntimeTests: XCTestCase {
    func testCompleteAfterErrorFinalizesInterruptedAssistantAndBuildsErrorMessage() {
        let runtime = makeRuntime()
        let session = ChatSession(title: "Example Conversation")
        let assistant = ChatMessage(content: "partial", isUser: false)
        session.messages.append(assistant)
        runtime.markActive(pendingParentMessageID: uuid(53))
        runtime.currentAssistantMessageID = assistant.id

        let completion = runtime.completeAfterError(
            LocalizedRuntimeError(message: "network down"),
            in: session,
            now: TestDate.reference
        )

        XCTAssertEqual(completion.errorText, "network down")
        XCTAssertEqual(completion.interruptedMessage?.id, assistant.id)
        XCTAssertEqual(completion.pendingParentMessageID, uuid(53))
        XCTAssertEqual(completion.errorMessage.content, "network down")
        XCTAssertTrue(completion.errorMessage.isError)
        XCTAssertEqual(runtime.interruptedAssistantMessageID, assistant.id)
        XCTAssertNil(runtime.currentAssistantMessageID)
        XCTAssertNil(runtime.pendingAssistantParentMessageID)
        XCTAssertFalse(runtime.hasActiveTextRequest)
        XCTAssertFalse(assistant.isActive)
        XCTAssertEqual(assistant.finishReason, "error")
    }

    func testCompleteSuccessfullyClearsActivityAndAssistantTracking() {
        let runtime = makeRuntime()
        let session = ChatSession(title: "Example Conversation")
        let assistant = ChatMessage(content: "done", isUser: false)
        session.messages.append(assistant)
        runtime.markActive(pendingParentMessageID: uuid(54))
        runtime.currentAssistantMessageID = assistant.id

        let completed = runtime.completeSuccessfully(
            in: session,
            finishedAt: TestDate.reference
        )

        XCTAssertEqual(completed?.id, assistant.id)
        XCTAssertFalse(runtime.hasActiveTextRequest)
        XCTAssertNil(runtime.currentAssistantMessageID)
        XCTAssertNil(runtime.pendingAssistantParentMessageID)
        XCTAssertFalse(assistant.isActive)
        XCTAssertEqual(assistant.finishReason, "completed")
    }

    func testCancelCurrentRequestReturnsAssistantIDForBranchRestoreAndClearsRuntimeState() {
        let runtime = makeRuntime()
        let session = ChatSession(title: "Example Conversation")
        let assistant = ChatMessage(content: "partial", isUser: false)
        session.messages.append(assistant)
        runtime.markActive(pendingParentMessageID: uuid(55))
        runtime.currentAssistantMessageID = assistant.id

        let completion = runtime.cancelCurrentRequest(
            in: session,
            finishedAt: TestDate.reference
        )

        XCTAssertNil(completion.assistantMessageIDForBranchRestore)
        XCTAssertFalse(runtime.hasActiveTextRequest)
        XCTAssertNil(runtime.currentAssistantMessageID)
        XCTAssertNil(runtime.pendingAssistantParentMessageID)
        XCTAssertFalse(assistant.isActive)
        XCTAssertEqual(assistant.finishReason, "stopped")
    }

    func testNewRequestRetryScopeStartsAtFirstRetryAfterEarlierRequestRecovered() {
        let runtime = makeRuntime()
        var states: [ChatStreamRetryStatusController.PublishedState] = []
        runtime.bindRetryState { states.append($0) }

        _ = runtime.planRetry(
            after: URLError(.timedOut),
            errorText: "first request failed",
            hasAssistantMessage: false
        )
        runtime.clearRetryStateAfterProgressIfNeeded()
        _ = runtime.planRetry(
            after: URLError(.timedOut),
            errorText: "first request failed again",
            hasAssistantMessage: true
        )

        runtime.beginRequestRetryScope()

        XCTAssertEqual(
            states.last,
            .init(isRetrying: false, retryAttempt: 0, retryLastError: nil)
        )

        let continuationRetry = runtime.planRetry(
            after: URLError(.timedOut),
            errorText: "continuation failed",
            hasAssistantMessage: true
        )
        XCTAssertEqual(continuationRetry.state.retryAttempt, 1)
        XCTAssertEqual(continuationRetry.state.retryLastError, "continuation failed")
    }

    private func makeRuntime(configuration: ChatServiceConfiguration? = nil) -> ChatTextRequestRuntime {
        ChatTextRequestRuntime(
            configuration: configuration ?? chatConfig(model: "runtime"),
            service: StubRuntimeChatService(),
            serviceFactory: { _ in StubRuntimeChatService() }
        )
    }

    private func chatConfig(model: String) -> ChatServiceConfiguration {
        ChatServiceConfiguration(
            apiBaseURL: "http://localhost:1234",
            modelIdentifier: model,
            apiKey: "key"
        )
    }
}

@MainActor
private final class StubRuntimeChatService: ChatStreamingService {
    var onDelta: (@MainActor (String) -> Void)?
    var onSegment: (@MainActor (AssistantStreamSegment) -> Void)?
    var onOpenAIResponsesConversationItems: (@MainActor ([JSONValue]) -> Void)?
    var onError: (@MainActor (Error) -> Void)?
    var onResponseMetadata: (@MainActor (ChatResponseMetadata) -> Void)?
    var onToolActivity: (@MainActor (ChatToolActivity) -> Void)?
    var onLongWaitNotice: (@MainActor (ChatStreamLongWaitNotice?) -> Void)?
    var onStreamFinished: (@MainActor () -> Void)?

    func fetchStreamedData(
        messages: [ChatMessage],
        developerPrompt: String?,
        includeImagesInUserContent: Bool
    ) {}

    func cancelStreaming() {}

    func cancelActiveStreamForManualRetry() -> Bool { false }

    func resolveToolAuthorization(requestID: String, allowed: Bool) {}
}

private struct LocalizedRuntimeError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
