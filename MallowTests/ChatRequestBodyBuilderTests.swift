import XCTest
@testable import Mallow

final class ChatRequestBodyBuilderTests: XCTestCase {
    private let requestContextFingerprint = "history-v2:test-request-state"

    func testRequestBodyBuilderBuildsOpenAIChatMessagesBody() throws {
        let builder = ChatRequestBodyBuilder()
        let endpoint = ChatAPIEndpointCandidate(
            provider: .openAI,
            style: .openAIChatCompletions,
            chatURL: try XCTUnwrap(URL(string: "http://localhost:8000/v1/chat/completions")),
            modelsURL: try XCTUnwrap(URL(string: "http://localhost:8000/v1/models"))
        )

        let data = try builder.buildRequestBodyData(
            model: "test-model",
            messagePayload: [["role": "user", "content": "hello"]],
            developerPrompt: nil,
            endpoint: endpoint,
            apiAdvancedSettings: APIAdvancedSettings(openAIChatMaxCompletionTokens: 777),
            thinkingCapability: nil,
            thinkingOption: nil
        )
        let body = try decodedBody(from: data)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])

        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 777)
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "hello")
    }

    func testOpenAIResponsesUsesInstructionsInsteadOfDeveloperInputMessage() throws {
        let endpoint = ChatAPIEndpointCandidate(
            provider: .openAI,
            style: .openAIResponses,
            chatURL: try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses")),
            modelsURL: try XCTUnwrap(URL(string: "https://api.openai.com/v1/models"))
        )

        let data = try ChatRequestBodyBuilder().buildRequestBodyData(
            model: "gpt-test",
            messagePayload: [
                ["role": "developer", "content": "new system prompt"],
                ["role": "user", "content": "hello"]
            ],
            developerPrompt: "new system prompt",
            endpoint: endpoint,
            apiAdvancedSettings: APIAdvancedSettings(),
            thinkingCapability: nil,
            thinkingOption: nil
        )
        let body = try decodedBody(from: data)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])

        XCTAssertEqual(body["instructions"] as? String, "new system prompt")
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input.first?["role"] as? String, "user")
        XCTAssertFalse(String(describing: input).contains("new system prompt"))
    }

    func testRequestBodyBuilderBuildsAnthropicThinkingBody() throws {
        let builder = ChatRequestBodyBuilder()
        let endpoint = ChatAPIEndpointCandidate(
            provider: .anthropic,
            style: .anthropicMessages,
            chatURL: try XCTUnwrap(URL(string: "https://api.anthropic.com/v1/messages")),
            modelsURL: try XCTUnwrap(URL(string: "https://api.anthropic.com/v1/models"))
        )

        let data = try builder.buildRequestBodyData(
            model: "claude-test",
            messagePayload: [
                ["role": "developer", "content": "developer prompt"],
                ["role": "user", "content": "hello"]
            ],
            developerPrompt: "system prompt",
            endpoint: endpoint,
            apiAdvancedSettings: APIAdvancedSettings(
                anthropicMaxTokens: 1,
                anthropicSampling: APIAdvancedSamplingSettings(
                    temperatureEnabled: true,
                    temperature: 0.7,
                    topPEnabled: true,
                    topP: 0.5,
                    topKEnabled: true,
                    topK: 20
                ),
                anthropicMaxTokensEnabled: true,
                anthropicThinkingModeOverride: "enabled",
                anthropicThinkingBudgetEnabled: true,
                anthropicThinkingBudget: 1024
            ),
            thinkingCapability: nil,
            thinkingOption: .high
        )
        let body = try decodedBody(from: data)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])

        XCTAssertEqual(body["system"] as? String, "system prompt")
        XCTAssertEqual(body["max_tokens"] as? Int, 1)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertEqual(thinking["budget_tokens"] as? Int, 1024)
        XCTAssertEqual(body["temperature"] as? Double, 0.7)
        XCTAssertEqual(body["top_p"] as? Double, 0.5)
        XCTAssertEqual(body["top_k"] as? Int, 20)
    }

    func testRequestBodyBuilderBuildsLMStudioRESTMultimodalBody() throws {
        let builder = ChatRequestBodyBuilder()
        let endpoint = ChatAPIEndpointCandidate(
            provider: .lmStudio,
            style: .lmStudioRESTV1,
            chatURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/chat")),
            modelsURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/models"))
        )

        let dataURL = "data:image/png;base64,AAAA"
        let data = try builder.buildRequestBodyData(
            model: "local-model",
            messagePayload: [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "describe"],
                        ["type": "image_url", "image_url": ["url": dataURL]]
                    ]
                ]
            ],
            developerPrompt: "local system",
            endpoint: endpoint,
            apiAdvancedSettings: APIAdvancedSettings(lmStudioMaxTokens: 256),
            thinkingCapability: nil,
            thinkingOption: nil
        )
        let body = try decodedBody(from: data)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])

        XCTAssertEqual(body["model"] as? String, "local-model")
        XCTAssertEqual(body["system_prompt"] as? String, "local system")
        XCTAssertNil(body["store"])
        XCTAssertNil(body["previous_response_id"])
        XCTAssertEqual(body["max_output_tokens"] as? Int, 256)
        XCTAssertEqual(input.first?["type"] as? String, "text")
        XCTAssertEqual(input.first?["content"] as? String, "describe")
        XCTAssertEqual(input.last?["type"] as? String, "image")
        XCTAssertEqual(input.last?["data_url"] as? String, dataURL)
    }

    func testLMStudioMultiToolContinuationUsesLatestResponseIDAndOnlyLatestResult() throws {
        let endpoint = ChatAPIEndpointCandidate(
            provider: .lmStudio,
            style: .lmStudioRESTV1,
            chatURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/chat")),
            modelsURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/models"))
        )
        let firstCall = ChatToolCallEnvelope(
            callID: "call_time",
            name: ChatToolID.systemGetTime.rawValue,
            argumentsJSON: "{}",
            provider: .lmStudio
        )
        let firstResult = ChatToolResultEnvelope(
            callID: firstCall.callID,
            name: firstCall.name,
            status: .success,
            payload: ["local_iso8601": .string("2001-01-01T08:00:00+08:00")],
            summary: "Current time was read."
        )
        let firstPayload = ChatToolResultMessageEncoder.followUpPayload(
            for: endpoint,
            originalPayload: [["role": "user", "content": "Read time and device context."]],
            calls: [firstCall],
            results: [firstResult],
            previousResponseID: "resp_first_tool"
        )
        let secondCall = ChatToolCallEnvelope(
            callID: "call_device",
            name: ChatToolID.deviceContext.rawValue,
            argumentsJSON: "{}",
            provider: .lmStudio
        )
        let secondResult = ChatToolResultEnvelope(
            callID: secondCall.callID,
            name: secondCall.name,
            status: .success,
            payload: ["platform": .string("macOS")],
            summary: "Device context was read."
        )
        let secondPayload = ChatToolResultMessageEncoder.followUpPayload(
            for: endpoint,
            originalPayload: firstPayload,
            calls: [secondCall],
            results: [secondResult],
            previousResponseID: "resp_second_tool"
        )

        let data = try ChatRequestBodyBuilder().buildRequestBodyData(
            model: "local-model",
            messagePayload: secondPayload,
            developerPrompt: "local system",
            endpoint: endpoint,
            apiAdvancedSettings: APIAdvancedSettings(),
            toolUseSettings: ToolUseSettings(
                isEnabled: true,
                calendarEnabled: false,
                remindersEnabled: false,
                locationEnabled: false,
                motionEnabled: false,
                deviceContextEnabled: true
            ),
            previousResponseID: "resp_second_tool",
            thinkingCapability: nil,
            thinkingOption: nil
        )
        let body = try decodedBody(from: data)
        let input = try XCTUnwrap(body["input"] as? String)

        XCTAssertEqual(body["previous_response_id"] as? String, "resp_second_tool")
        XCTAssertNil(body["system_prompt"])
        XCTAssertTrue(input.contains("Device context was read."))
        XCTAssertFalse(input.contains("Current time was read."))
        XCTAssertFalse(input.contains("Read time and device context."))
        XCTAssertFalse(input.contains("<tool_call>"))
    }

    func testOpenAIResponsesToolContinuationUsesPreviousResponseIDAndToolOutputInput() throws {
        let endpoint = ChatAPIEndpointCandidate(
            provider: .openAI,
            style: .openAIResponses,
            chatURL: try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses")),
            modelsURL: try XCTUnwrap(URL(string: "https://api.openai.com/v1/models"))
        )

        let data = try ChatRequestBodyBuilder().buildRequestBodyData(
            model: "gpt-test",
            messagePayload: [
                [
                    "type": "function_call_output",
                    "call_id": "call_1",
                    "output": "{\"status\":\"success\"}"
                ]
            ],
            developerPrompt: nil,
            endpoint: endpoint,
            apiAdvancedSettings: APIAdvancedSettings(),
            previousResponseID: "resp_previous",
            thinkingCapability: nil,
            thinkingOption: nil
        )
        let body = try decodedBody(from: data)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])

        XCTAssertEqual(body["previous_response_id"] as? String, "resp_previous")
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input.first?["type"] as? String, "function_call_output")
        XCTAssertEqual(input.first?["call_id"] as? String, "call_1")
    }

    func testOpenAIResponsesPreviousResponseIDUsesMatchingAssistantBeforeLatestUser() throws {
        let endpoint = ChatAPIEndpointCandidate(
            provider: .openAI,
            style: .openAIResponses,
            chatURL: try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses")),
            modelsURL: try XCTUnwrap(URL(string: "https://api.openai.com/v1/models"))
        )

        let responseID = ChatService.previousResponseID(
            in: [
                ChatRequestSourceMessage(content: "first", isUser: true),
                ChatRequestSourceMessage(
                    content: "first answer",
                    isUser: false,
                    providerResponseID: "resp_first",
                    requestContextFingerprint: requestContextFingerprint,
                    createdAt: Date()
                ),
                ChatRequestSourceMessage(content: "follow up", isUser: true)
            ],
            endpoint: endpoint,
            currentRequestFingerprint: requestContextFingerprint
        )

        XCTAssertEqual(responseID, "resp_first")
    }

    func testPreviousResponseIDIsRejectedAfterModelSwitch() throws {
        let endpoint = ChatAPIEndpointCandidate(
            provider: .openAI,
            style: .openAIResponses,
            chatURL: try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses")),
            modelsURL: try XCTUnwrap(URL(string: "https://api.openai.com/v1/models"))
        )
        var request = URLRequest(url: endpoint.chatURL)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"model-a"}"#.utf8)
        let previousContext = try ChatContinuationSeed(
            configurationFingerprint: ChatRequestContextBuilder.fingerprint(
                request: request, endpoint: endpoint, includeImagesInUserContent: false
            ), history: []
        ).fingerprint()
        request.httpBody = Data(#"{"model":"model-b"}"#.utf8)
        let currentContext = try ChatContinuationSeed(
            configurationFingerprint: ChatRequestContextBuilder.fingerprint(
                request: request, endpoint: endpoint, includeImagesInUserContent: false
            ), history: []
        ).fingerprint()

        let responseID = ChatService.previousResponseID(
            in: [
                ChatRequestSourceMessage(content: "first", isUser: true),
                ChatRequestSourceMessage(
                    content: "first answer",
                    isUser: false,
                    providerResponseID: "resp_first",
                    requestContextFingerprint: previousContext,
                    createdAt: Date()
                ),
                ChatRequestSourceMessage(content: "follow up", isUser: true)
            ],
            endpoint: endpoint,
            currentRequestFingerprint: currentContext
        )

        XCTAssertNotEqual(previousContext, currentContext)
        XCTAssertNil(responseID)
    }

    func testLMStudioPreviousResponseIDRequiresMatchingRequestFingerprint() throws {
        let endpoint = ChatAPIEndpointCandidate(
            provider: .lmStudio,
            style: .lmStudioRESTV1,
            chatURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/chat")),
            modelsURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/models"))
        )

        let responseID = ChatService.previousResponseID(
            in: [
                ChatRequestSourceMessage(content: "first", isUser: true),
                ChatRequestSourceMessage(
                    content: "first answer",
                    isUser: false,
                    providerResponseID: "resp_first",
                    requestContextFingerprint: "history-v2:old-state",
                    createdAt: Date()
                ),
                ChatRequestSourceMessage(content: "follow up", isUser: true)
            ],
            endpoint: endpoint,
            currentRequestFingerprint: requestContextFingerprint
        )

        XCTAssertNil(responseID)
    }

    func testLMStudioPreviousResponseIDRequiresImmediatePreviousAssistant() throws {
        let endpoint = ChatAPIEndpointCandidate(
            provider: .lmStudio,
            style: .lmStudioRESTV1,
            chatURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/chat")),
            modelsURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/models"))
        )

        let responseID = ChatService.previousResponseID(
            in: [
                ChatRequestSourceMessage(content: "first", isUser: true),
                ChatRequestSourceMessage(
                    content: "first answer",
                    isUser: false,
                    providerResponseID: "resp_first",
                    requestContextFingerprint: requestContextFingerprint,
                    createdAt: Date()
                ),
                ChatRequestSourceMessage(content: "second without answer", isUser: true),
                ChatRequestSourceMessage(content: "third latest", isUser: true)
            ],
            endpoint: endpoint,
            currentRequestFingerprint: requestContextFingerprint
        )

        XCTAssertNil(responseID)
    }

    func testLMStudioPreviousResponseIDIgnoresPreviousErrorAssistantEvenWithResponseID() throws {
        let endpoint = ChatAPIEndpointCandidate(
            provider: .lmStudio,
            style: .lmStudioRESTV1,
            chatURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/chat")),
            modelsURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/models"))
        )

        let responseID = ChatService.previousResponseID(
            in: [
                ChatRequestSourceMessage(content: "first", isUser: true),
                ChatRequestSourceMessage(
                    content: "!error:network failed",
                    isUser: false,
                    isError: true,
                    providerResponseID: "resp_failed",
                    requestContextFingerprint: requestContextFingerprint,
                    createdAt: Date()
                ),
                ChatRequestSourceMessage(content: "continue after failure", isUser: true)
            ],
            endpoint: endpoint,
            currentRequestFingerprint: requestContextFingerprint
        )

        XCTAssertNil(responseID)
    }

    func testLMStudioPreviousResponseIDIgnoresAssistantOlderThanThirtyDays() throws {
        let endpoint = ChatAPIEndpointCandidate(
            provider: .lmStudio,
            style: .lmStudioRESTV1,
            chatURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/chat")),
            modelsURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/models"))
        )
        let now = TestDate.reference
        let oldAssistantDate = now.addingTimeInterval(-(31 * 24 * 60 * 60))

        let responseID = ChatService.previousResponseID(
            in: [
                ChatRequestSourceMessage(content: "first", isUser: true, createdAt: oldAssistantDate),
                ChatRequestSourceMessage(
                    content: "first answer",
                    isUser: false,
                    providerResponseID: "resp_old",
                    requestContextFingerprint: requestContextFingerprint,
                    createdAt: oldAssistantDate
                ),
                ChatRequestSourceMessage(content: "follow up", isUser: true, createdAt: now)
            ],
            endpoint: endpoint,
            currentRequestFingerprint: requestContextFingerprint,
            now: now
        )

        XCTAssertNil(responseID)
    }

    func testRequestBodyBuilderMapsOpenAIAndLMStudioAdvancedSettings() throws {
        let sampling = APIAdvancedSamplingSettings(
            temperatureEnabled: true,
            temperature: 1.5,
            topPEnabled: true,
            topP: 0.75,
            topKEnabled: true,
            topK: 40,
            minPEnabled: true,
            minP: 0.1,
            topAEnabled: true,
            topA: 0.2,
            presencePenaltyEnabled: true,
            presencePenalty: 0.3,
            frequencyPenaltyEnabled: true,
            frequencyPenalty: 0.4,
            repetitionPenaltyEnabled: true,
            repetitionPenalty: 1.1,
            seedEnabled: true,
            seed: 123,
            contextLengthEnabled: true,
            contextLength: 4096,
            jsonModeEnabled: true,
            structuredOutputsEnabled: true,
            logprobsEnabled: true,
            topLogprobsEnabled: true,
            topLogprobs: 9,
            verbosityEnabled: true,
            verbosity: "high"
        )
        let messagePayload = [["role": "user", "content": "hello"]]

        let openAIEndpoint = ChatAPIEndpointCandidate(
            provider: .openAI,
            style: .openAIChatCompletions,
            chatURL: try XCTUnwrap(URL(string: "https://api.openai.com/v1/chat/completions")),
            modelsURL: try XCTUnwrap(URL(string: "https://api.openai.com/v1/models"))
        )
        let openAIData = try ChatRequestBodyBuilder().buildRequestBodyData(
            model: "open-model",
            messagePayload: messagePayload,
            developerPrompt: nil,
            endpoint: openAIEndpoint,
            apiAdvancedSettings: APIAdvancedSettings(openAIChatMaxCompletionTokens: 404, openAIChatSampling: sampling),
            thinkingCapability: nil,
            thinkingOption: nil
        )
        let openAI = try decodedBody(from: openAIData)
        XCTAssertEqual(openAI["max_completion_tokens"] as? Int, 404)
        XCTAssertEqual(openAI["temperature"] as? Double, 1.5)
        XCTAssertEqual(openAI["top_p"] as? Double, 0.75)
        XCTAssertEqual(openAI["presence_penalty"] as? Double, 0.3)
        XCTAssertEqual(openAI["frequency_penalty"] as? Double, 0.4)
        XCTAssertEqual(openAI["top_logprobs"] as? Int, 9)

        let lmStudioNativeEndpoint = ChatAPIEndpointCandidate(
            provider: .lmStudio,
            style: .lmStudioRESTV1,
            chatURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/chat")),
            modelsURL: try XCTUnwrap(URL(string: "http://localhost:1234/api/v1/models"))
        )
        let lmStudioNativeData = try ChatRequestBodyBuilder().buildRequestBodyData(
            model: "local-native",
            messagePayload: messagePayload,
            developerPrompt: nil,
            endpoint: lmStudioNativeEndpoint,
            apiAdvancedSettings: APIAdvancedSettings(lmStudioMaxTokens: 606, lmStudioSampling: sampling),
            thinkingCapability: nil,
            thinkingOption: nil
        )
        let lmStudioNative = try decodedBody(from: lmStudioNativeData)
        XCTAssertEqual(lmStudioNative["max_output_tokens"] as? Int, 606)
        XCTAssertEqual(lmStudioNative["top_k"] as? Int, 40)
        XCTAssertEqual(lmStudioNative["repeat_penalty"] as? Double, 1.1)
    }
}
