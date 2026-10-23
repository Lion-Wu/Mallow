import XCTest
@testable import Mallow

final class ChatProviderStreamReducerTests: XCTestCase {
    func testOpenAIResponsesStreamItemReducerEmitsStructuredSegmentsWithoutThinkTags() throws {
        let reducer = OpenAIResponsesStreamItemReducer()
        var state = OpenAIResponsesStreamItemState()

        let reasoning = reducer.reduce(
            jsonData: try jsonData(#"{"type":"response.reasoning_text.delta","item_id":"r1","delta":"Need time."}"#),
            fallbackType: nil,
            state: &state
        )
        XCTAssertEqual(reasoning.actions, [
            .segment(.reasoning(id: "r1", text: "Need time."), marksPrimaryOutput: false)
        ])

        let toolArguments = reducer.reduce(
            jsonData: try jsonData(#"{"type":"response.function_call_arguments.delta","item_id":"fc1","delta":"{\"timezone\":\"Asia/Shanghai\""}"#),
            fallbackType: nil,
            state: &state
        )
        XCTAssertEqual(toolArguments.actions, [])

        let text = reducer.reduce(
            jsonData: try jsonData(#"{"type":"response.output_text.delta","item_id":"m1","delta":"现在是北京时间 12:34。"}"#),
            fallbackType: nil,
            state: &state
        )
        XCTAssertEqual(text.actions, [
            .segment(.text(id: "m1", text: "现在是北京时间 12:34。"), marksPrimaryOutput: true)
        ])
    }

    func testOpenAIResponsesReducerDoesNotRepeatOpenRouterContentPartDeltasAtItemDone() throws {
        let reducer = OpenAIResponsesStreamItemReducer()
        var state = OpenAIResponsesStreamItemState()

        let delta = reducer.reduce(
            jsonData: try jsonData(#"{"type":"response.content_part.delta","output_index":0,"content_index":0,"delta":"Once"}"#),
            fallbackType: nil,
            state: &state
        )
        let done = reducer.reduce(
            jsonData: try jsonData(#"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_abc123","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Once"}]}}"#),
            fallbackType: nil,
            state: &state
        )

        XCTAssertEqual(delta.actions, [
            .segment(.text(id: "output_index:0", text: "Once"), marksPrimaryOutput: true)
        ])
        XCTAssertTrue(done.actions.isEmpty)
    }

    func testOpenAIResponsesReducerFinishesToolOnlyResponse() throws {
        let reducer = OpenAIResponsesStreamItemReducer()
        var state = OpenAIResponsesStreamItemState()

        let completed = reducer.reduce(
            jsonData: try jsonData(#"{"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"type":"function_call","id":"fc_1","call_id":"call_1","name":"system_get_time","arguments":"{}"}]}}"#),
            fallbackType: nil,
            state: &state
        )

        XCTAssertTrue(completed.actions.contains(.finish))
    }

    func testOpenAIResponsesReducerMarksTypedRateLimitFailureRetryable() throws {
        let reducer = OpenAIResponsesStreamItemReducer()
        var state = OpenAIResponsesStreamItemState()

        let failed = reducer.reduce(
            jsonData: try jsonData(#"{"type":"response.failed","response":{"status":"failed","error":{"code":"rate_limit_exceeded","message":"try later"}}}"#),
            fallbackType: nil,
            state: &state
        )

        XCTAssertTrue(failed.actions.contains(.retryableFailure("try later", statusCode: 429)))
    }

    func testOpenAIChatCompletionsReducerDoesNotRetryNumericAuthenticationError() throws {
        let reducer = OpenAICompatibleStreamEventReducer()
        var state = OpenAICompatibleStreamEventState()

        let failed = reducer.reduce(
            jsonData: try jsonData(#"{"error":{"code":401,"message":"Invalid API key"}}"#),
            fallbackType: nil,
            state: &state
        )

        XCTAssertTrue(failed.actions.contains(.fail("Invalid API key")))
        XCTAssertFalse(failed.actions.contains { action in
            if case .retryableFailure = action { return true }
            return false
        })
    }

    func testAnthropicReducerMarksOverloadFailureRetryable() throws {
        let event = try JSONDecoder().decode(
            AnthropicStreamEvent.self,
            from: try jsonData(#"{"type":"error","error":{"type":"overloaded_error","message":"try later"}}"#)
        )
        var state = AnthropicStreamEventState()

        let actions = AnthropicStreamEventReducer().reduce(event, state: &state)

        XCTAssertTrue(actions.contains(.retryableFailure("try later", statusCode: 529)))
    }

    func testOpenAIResponsesReducerTreatsIncompleteAsFailureNotFinish() throws {
        let reducer = OpenAIResponsesStreamItemReducer()
        var state = OpenAIResponsesStreamItemState()

        let incomplete = reducer.reduce(
            jsonData: try jsonData(#"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"function_call","id":"fc_1","status":"incomplete","call_id":"call_1","name":"calendar_create_event","arguments":"{\"title\":\"Unsafe\"}"}]}}"#),
            fallbackType: nil,
            state: &state
        )

        let failures = incomplete.actions.compactMap { action -> (String, [AssistantStreamSegment])? in
            guard case let .incomplete(message, segments) = action else { return nil }
            return (message, segments)
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].0.contains("max_output_tokens"))
        XCTAssertTrue(failures[0].1.isEmpty)
        XCTAssertFalse(incomplete.actions.contains(.finish))
    }

    func testOpenAICompatibleStreamEventReducerDeduplicatesSSESequenceNumbers() throws {
        let reducer = OpenAICompatibleStreamEventReducer()
        var state = OpenAICompatibleStreamEventState()

        let first = reducer.reduce(
            jsonData: try jsonData(#"{"sequence_number":5,"type":"response.output_text.delta","delta":"hello"}"#),
            fallbackType: nil,
            state: &state
        )
        let duplicate = reducer.reduce(
            jsonData: try jsonData(#"{"sequence_number":5,"type":"response.output_text.delta","delta":"again"}"#),
            fallbackType: nil,
            state: &state
        )

        XCTAssertEqual(first.actions, [
            .segment(.text(id: nil, text: "hello"), marksPrimaryOutput: true)
        ])
        XCTAssertEqual(duplicate, OpenAICompatibleStreamReduction(handled: true))
        XCTAssertEqual(state.lastProcessedSSESequenceNumber, 5)
    }

    func testOpenAICompatibleStreamEventReducerNormalizesSplitLegacyThinkTagsFromChatDeltas() throws {
        let reducer = OpenAICompatibleStreamEventReducer()
        var state = OpenAICompatibleStreamEventState()

        let start = reducer.reduce(
            jsonData: try jsonData(#"{"choices":[{"index":0,"delta":{"content":"<thi"}}]}"#),
            fallbackType: nil,
            state: &state
        )
        let reasoning = reducer.reduce(
            jsonData: try jsonData(#"{"choices":[{"index":0,"delta":{"content":"nk>\nNeed time."}}]}"#),
            fallbackType: nil,
            state: &state
        )
        let answer = reducer.reduce(
            jsonData: try jsonData(#"{"choices":[{"index":0,"delta":{"content":"</think>\n现在是北京时间 12:34。"}}]}"#),
            fallbackType: nil,
            state: &state
        )

        XCTAssertTrue(start.actions.isEmpty)
        XCTAssertEqual(reasoning.actions, [
            .segment(.reasoning(id: nil, text: "Need time."), marksPrimaryOutput: false)
        ])
        XCTAssertEqual(answer.actions, [
            .segment(.text(id: nil, text: "\n现在是北京时间 12:34。"), marksPrimaryOutput: true)
        ])
        XCTAssertEqual(state.legacyThinkTagBuffer, "")
        XCTAssertFalse(state.isInsideLegacyThinkTag)
    }

    func testAnthropicStreamEventReducerWrapsThinkingAndFinishesWithMetadata() throws {
        let reducer = AnthropicStreamEventReducer()
        var state = AnthropicStreamEventState()

        let thinking = reducer.reduce(
            try decodedAnthropicEvent(#"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"plan"}}"#),
            state: &state
        )
        XCTAssertEqual(thinking, [
            .delta("<think>\n", marksPrimaryOutput: false),
            .delta("plan", marksPrimaryOutput: false)
        ])

        let text = reducer.reduce(
            try decodedAnthropicEvent(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"answer"}}"#),
            state: &state
        )
        XCTAssertEqual(text, [
            .delta("\n</think>\n", marksPrimaryOutput: false),
            .delta("answer", marksPrimaryOutput: true)
        ])

        let stop = reducer.reduce(
            try decodedAnthropicEvent("""
            {
              "type": "message_stop",
              "message": {
                "id": "msg_123",
                "stop_reason": "end_turn",
                "usage": {
                  "output_tokens": 42,
                  "output_tokens_details": { "thinking_tokens": 7 }
                }
              }
            }
            """),
            state: &state
        )

        var expectedMetadata = ChatResponseMetadata.empty
        expectedMetadata.providerResponseID = "msg_123"
        expectedMetadata.outputTokenCount = 42
        expectedMetadata.reasoningOutputTokenCount = 7
        expectedMetadata.finishReason = "end_turn"
        XCTAssertEqual(stop, [.metadata(expectedMetadata), .finish])
    }

    func testLMStudioStreamEventReducerHandlesOfficialToolEventsAndRecoversChatEndOutput() throws {
        let reducer = LMStudioStreamEventReducer()
        var state = LMStudioStreamEventState()

        let start = reducer.reduce(
            try decodedLMStudioEvent("""
            {
              "type": "tool_call.start",
              "tool": "model_search",
              "provider_info": {
                "type": "ephemeral_mcp",
                "server_label": "huggingface"
              }
            }
            """),
            fallbackType: nil,
            state: &state
        )
        let arguments = reducer.reduce(
            try decodedLMStudioEvent("""
            {
              "type": "tool_call.arguments",
              "tool": "model_search",
              "arguments": { "sort": "trendingScore", "limit": 1 }
            }
            """),
            fallbackType: nil,
            state: &state
        )
        let success = reducer.reduce(
            try decodedLMStudioEvent("""
            {
              "type": "tool_call.success",
              "tool": "model_search",
              "arguments": { "sort": "trendingScore", "limit": 1 },
              "output": "[{\\"type\\":\\"text\\",\\"text\\":\\"Showing first 1 models...\\"}]"
            }
            """),
            fallbackType: nil,
            state: &state
        )
        let end = reducer.reduce(
            try decodedLMStudioEvent("""
            {
              "type": "chat.end",
              "result": {
                "model_instance_id": "openai/gpt-oss-20b",
                "output": [
                  { "type": "reasoning", "content": "Need the tool result." },
                  {
                    "type": "tool_call",
                    "tool": "model_search",
                    "arguments": { "sort": "trendingScore", "limit": 1 },
                    "output": "[{\\"type\\":\\"text\\",\\"text\\":\\"Showing first 1 models...\\"}]"
                  },
                  { "type": "message", "content": "The model is ready." }
                ],
                "stats": {
                  "total_output_tokens": 12,
                  "reasoning_output_tokens": 4,
                  "tokens_per_second": 20.5,
                  "time_to_first_token_seconds": 0.5
                },
                "response_id": "resp_lmstudio_tool_1"
              }
            }
            """),
            fallbackType: nil,
            state: &state
        )

        XCTAssertTrue(start.isEmpty)
        XCTAssertTrue(arguments.isEmpty)
        XCTAssertTrue(success.isEmpty)

        var expectedMetadata = ChatResponseMetadata.empty
        expectedMetadata.providerResponseID = "resp_lmstudio_tool_1"
        expectedMetadata.outputTokenCount = 12
        expectedMetadata.reasoningOutputTokenCount = 4
        expectedMetadata.tokensPerSecond = 20.5
        expectedMetadata.timeToFirstTokenSeconds = 0.5
        XCTAssertEqual(end, [
            .metadata(expectedMetadata),
            .delta("<think>\n", marksPrimaryOutput: false),
            .delta("Need the tool result.", marksPrimaryOutput: false),
            .delta("\n</think>\n", marksPrimaryOutput: false),
            .delta("The model is ready.", marksPrimaryOutput: true),
            .finish
        ])
        XCTAssertTrue(state.sawAnyReasoningToken)
        XCTAssertTrue(state.sawAnyPrimaryAssistantToken)
    }

    func testLMStudioStreamEventReducerDefersOfficialToolFailureUntilChatEnd() throws {
        let reducer = LMStudioStreamEventReducer()
        var state = LMStudioStreamEventState()

        let failure = reducer.reduce(
            try decodedLMStudioEvent("""
            {
              "type": "tool_call.failure",
              "reason": "Cannot find tool with name open_browser.",
              "metadata": {
                "type": "invalid_name",
                "tool_name": "open_browser"
              }
            }
            """),
            fallbackType: nil,
            state: &state
        )
        let end = reducer.reduce(
            try decodedLMStudioEvent(#"{"type":"chat.end","result":{"output":[]}}"#),
            fallbackType: nil,
            state: &state
        )

        XCTAssertTrue(failure.isEmpty)
        XCTAssertEqual(end, [.fail("Cannot find tool with name open_browser.")])
    }
}
