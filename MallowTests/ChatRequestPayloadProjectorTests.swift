import XCTest
@testable import Mallow

final class ChatRequestPayloadProjectorTests: XCTestCase {
    func testRequestPayloadProjectorUsesAssistantTextSegmentsWithoutReasoning() throws {
        let payload = ChatRequestPayloadProjector().transformedMessagesForRequest(
            messages: [
                ChatRequestSourceMessage(
                    content: "<think>\nlegacy reasoning\n</think>\nlegacy body",
                    isUser: false,
                    assistantSegments: [
                        ChatAssistantSegment(kind: .reasoning, itemID: "r1", text: "structured reasoning"),
                        ChatAssistantSegment(kind: .text, itemID: "m1", text: "structured body")
                    ]
                )
            ],
            developerPrompt: nil,
            includeImagesInUserContent: false
        )

        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload[0]["role"] as? String, "assistant")
        XCTAssertEqual(payload[0]["content"] as? String, "structured body")
    }

    func testRequestPayloadProjectorFiltersErrorsAndAddsDeveloperPrompt() throws {
        let payload = ChatRequestPayloadProjector().transformedMessagesForRequest(
            messages: [
                ChatRequestSourceMessage(content: "hello", isUser: true),
                ChatRequestSourceMessage(content: "transient", isUser: false, isError: true),
                ChatRequestSourceMessage(content: "answer", isUser: false)
            ],
            developerPrompt: "  system  ",
            includeImagesInUserContent: true
        )

        XCTAssertEqual(payload.count, 3)
        XCTAssertEqual(payload[0]["role"] as? String, "developer")
        XCTAssertEqual(payload[0]["content"] as? String, "system")
        XCTAssertEqual(payload[1]["role"] as? String, "user")
        XCTAssertEqual(payload[1]["content"] as? String, "hello")
        XCTAssertEqual(payload[2]["role"] as? String, "assistant")
        XCTAssertEqual(payload[2]["content"] as? String, "answer")
    }

    func testRequestPayloadProjectorIncludesUserImagesWhenRequested() throws {
        let attachment = ChatImageAttachment(mimeType: "image/png", data: try XCTUnwrap("image".data(using: .utf8)))
        let payload = ChatRequestPayloadProjector().transformedMessagesForRequest(
            messages: [
                ChatRequestSourceMessage(content: "look", isUser: true, imageAttachments: [attachment])
            ],
            developerPrompt: nil,
            includeImagesInUserContent: true
        )
        let parts = try XCTUnwrap(payload.first?["content"] as? [[String: Any]])
        let imageURL = try XCTUnwrap(parts.last?["image_url"] as? [String: Any])

        XCTAssertEqual(payload.first?["role"] as? String, "user")
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        XCTAssertEqual(parts.first?["text"] as? String, "look")
        XCTAssertEqual(parts.last?["type"] as? String, "image_url")
        XCTAssertEqual(imageURL["url"] as? String, attachment.dataURLString)
    }

    func testRequestPayloadProjectorPreservesToolCallChronologyAcrossSegmentScopes() throws {
        let first = ChatToolActivityPlacement(
            activity: ChatToolActivity(
                id: "tool-a",
                toolName: "first_tool",
                title: "First Tool",
                phase: .succeeded
            ),
            scope: .body,
            offset: 100,
            assistantSegmentAnchor: ChatAssistantSegmentAnchor(
                segmentIndex: 0,
                characterOffset: 100
            )
        )
        let second = ChatToolActivityPlacement(
            activity: ChatToolActivity(
                id: "tool-b",
                toolName: "second_tool",
                title: "Second Tool",
                phase: .succeeded
            ),
            scope: .thinking,
            offset: 10,
            assistantSegmentAnchor: ChatAssistantSegmentAnchor(
                segmentIndex: 2,
                characterOffset: 10
            )
        )

        let payload = ChatRequestPayloadProjector().transformedMessagesForRequest(
            messages: [
                ChatRequestSourceMessage(
                    content: "Done.",
                    isUser: false,
                    toolActivityPlacements: [first, second]
                )
            ],
            developerPrompt: nil,
            includeImagesInUserContent: false
        )

        let content = try XCTUnwrap(payload.first?["content"] as? String)
        let firstRange = try XCTUnwrap(content.range(of: "First Tool"))
        let secondRange = try XCTUnwrap(content.range(of: "Second Tool"))
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
    }

    func testOpenRouterResponsesReplaysPersistedConversationItemsInOrder() throws {
        let items: [JSONValue] = [
            .object([
                "type": .string("reasoning"),
                "id": .string("rs_1"),
                "encrypted_content": .string("encrypted")
            ]),
            .object([
                "type": .string("function_call"),
                "id": .string("fc_1"),
                "call_id": .string("call_1"),
                "name": .string("system_get_time"),
                "arguments": .string("{}")
            ]),
            .object([
                "type": .string("function_call_output"),
                "call_id": .string("call_1"),
                "output": .string(#"{"time":"12:00"}"#)
            ]),
            .object([
                "type": .string("message"),
                "id": .string("msg_1"),
                "role": .string("assistant"),
                "status": .string("completed"),
                "content": .array([.object([
                    "type": .string("output_text"),
                    "text": .string("It is noon."),
                    "annotations": .array([])
                ])])
            ])
        ]
        let payload = ChatRequestPayloadProjector().transformedMessagesForRequest(
            messages: [
                ChatRequestSourceMessage(
                    content: "It is noon.",
                    isUser: false,
                    openAIResponsesConversationItems: items
                ),
                ChatRequestSourceMessage(content: "What about now?", isUser: true)
            ],
            developerPrompt: "Be concise.",
            includeImagesInUserContent: false,
            requestStyle: .openAIResponses
        )
        let endpoint = ChatAPIEndpointCandidate(
            provider: .openAI,
            style: .openAIResponses,
            chatURL: try XCTUnwrap(URL(string: "https://openrouter.ai/api/v1/responses")),
            modelsURL: try XCTUnwrap(URL(string: "https://openrouter.ai/api/v1/models"))
        )
        let body = ChatRequestBodyProviderEncoder.makeBaseRequestBody(
            model: "openai/gpt-oss-20b",
            messagePayload: payload,
            developerPrompt: nil,
            endpoint: endpoint,
            apiAdvancedSettings: .defaults
        )
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])

        XCTAssertEqual(input.compactMap { $0["type"] as? String }, [
            "reasoning", "function_call", "function_call_output", "message"
        ])
        XCTAssertEqual(input[0]["encrypted_content"] as? String, "encrypted")
        XCTAssertEqual(input[1]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[2]["call_id"] as? String, "call_1")
        XCTAssertEqual(input.last?["role"] as? String, "user")
        XCTAssertEqual(body["instructions"] as? String, "Be concise.")
        XCTAssertFalse(String(describing: input).contains("[Tool context]"))
    }

    func testRequestPayloadProjectorKeepsEnabledToolPayloadsInContext() throws {
        let call = ChatToolCallEnvelope(
            callID: "clipboard-1",
            name: ChatToolID.clipboardGetText.rawValue,
            argumentsJSON: #"{"query":"secret request"}"#,
            provider: nil
        )
        let sensitiveSummary = ChatToolDefinitions.activitySummary(
            for: call,
            resultSummary: "secret result"
        )
        let placement = ChatToolActivityPlacement(
            activity: ChatToolActivity(
                id: "clipboard-1",
                toolName: call.name,
                title: "Read clipboard",
                phase: .succeeded,
                summary: sensitiveSummary,
                authorizationRequest: ChatToolAuthorizationRequest(
                    id: "clipboard-1",
                    toolName: call.name,
                    title: "Read clipboard",
                    operationKind: .read,
                    argumentsSummary: "secret request"
                ),
                modelRequestPayload: ["query": .string("secret request")],
                resultPayload: ["text": .string("secret result")]
            ),
            scope: .body,
            offset: 0
        )
        let payload = ChatRequestPayloadProjector().transformedMessagesForRequest(
            messages: [
                ChatRequestSourceMessage(
                    content: "The clipboard contains secret result.",
                    isUser: false,
                    toolActivityPlacements: [placement]
                )
            ],
            developerPrompt: nil,
            includeImagesInUserContent: false
        )

        let content = try XCTUnwrap(payload.first?["content"] as? String)
        XCTAssertTrue(content.contains("The clipboard contains secret result."))
        XCTAssertTrue(content.contains("secret request"))
        XCTAssertTrue(content.contains("secret result"))
    }
}
