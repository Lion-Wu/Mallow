import XCTest
@testable import Mallow

final class ChatResponseParsingTests: XCTestCase {
    func testSSEStreamParserKeepsPartialLinesAndEventTypes() {
        var parser = ChatSSEStreamParser(maxBufferedBytes: 256)

        XCTAssertEqual(
            parser.append("event: response.output_text.delta\ndata: {\"delta\":\"hel".data(using: .utf8)!),
            .frames([])
        )

        XCTAssertEqual(
            parser.append("lo\"}\n\n".data(using: .utf8)!),
            .frames([
                ChatSSEStreamFrame(payload: "{\"delta\":\"hello\"}", eventType: "response.output_text.delta")
            ])
        )

        parser.clearPendingEventType()
        XCTAssertEqual(
            parser.append("data: [DONE]\n".data(using: .utf8)!),
            .frames([
                ChatSSEStreamFrame(payload: "[DONE]", eventType: nil)
            ])
        )
    }

    func testSSEStreamParserPreservesUTF8ScalarsSplitAcrossNetworkChunks() {
        var parser = ChatSSEStreamParser(maxBufferedBytes: 512)
        let stream = "event: response.output_text.delta\ndata: {\"delta\":\"你🙂\"}\n\n"
        var frames: [ChatSSEStreamFrame] = []

        for byte in Data(stream.utf8) {
            guard case let .frames(newFrames) = parser.append(Data([byte])) else {
                return XCTFail("Unexpected buffer limit")
            }
            frames.append(contentsOf: newFrames)
        }

        XCTAssertEqual(frames, [
            ChatSSEStreamFrame(
                payload: "{\"delta\":\"你🙂\"}",
                eventType: "response.output_text.delta"
            )
        ])
    }

    func testSSEStreamParserReportsBufferLimit() {
        var parser = ChatSSEStreamParser(maxBufferedBytes: 8)

        XCTAssertEqual(
            parser.append("data: 123456789".data(using: .utf8)!),
            .exceededBufferLimit
        )
    }

    func testBufferedResponseParserRecoversOpenAITextAndMetadata() throws {
        let data = """
        {
          "id": "resp_buffered",
          "usage": {
            "output_tokens": 12,
            "output_tokens_details": { "reasoning_tokens": 2 }
          },
          "output": [
            {
              "type": "message",
              "content": [
                { "type": "output_text", "text": " buffered answer " }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let result = ChatBufferedResponseParser().parse(data, style: .openAIChatCompletions)

        XCTAssertEqual(result.text, "buffered answer")
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.metadata.providerResponseID, "resp_buffered")
        XCTAssertEqual(result.metadata.outputTokenCount, 12)
        XCTAssertEqual(result.metadata.reasoningOutputTokenCount, 2)
    }
}
