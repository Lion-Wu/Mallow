import XCTest
@testable import Mallow

final class ChatToolSchemaEncoderTests: XCTestCase {
    func testResponsesEndpointUsesResponsesFunctionShape() throws {
        var body: [String: Any] = ["model": "gpt-test"]

        ChatToolSchemaEncoder.applyToolSchemas(
            to: &body,
            endpoint: endpoint(style: .openAIResponses, chatURL: "https://api.openai.com/v1/responses"),
            settings: enabledSettings(
                calendar: false,
                reminders: false,
                location: false,
                motion: false,
                device: true
            )
        )

        let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(tool["type"] as? String, "function")
        XCTAssertEqual(tool["name"] as? String, ChatToolID.deviceContext.rawValue)
        XCTAssertFalse((tool["name"] as? String)?.contains(".") == true)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        XCTAssertTrue((body["instructions"] as? String)?.contains(ChatToolDefinitions.untrustedResultInstruction) == true)
        XCTAssertNil(body["parallel_tool_calls"])
        XCTAssertNil(tool["strict"])
    }

    func testAnthropicToolsAddToolResultTrustInstructionToSystemPrompt() {
        var body: [String: Any] = ["model": "claude-test", "system": "Be concise."]

        ChatToolSchemaEncoder.applyToolSchemas(
            to: &body,
            endpoint: endpoint(style: .anthropicMessages, chatURL: "https://api.anthropic.com/v1/messages"),
            settings: enabledSettings(
                calendar: false,
                reminders: false,
                location: false,
                motion: false,
                device: true
            )
        )

        let system = body["system"] as? String
        XCTAssertTrue(system?.hasPrefix("Be concise.") == true)
        XCTAssertTrue(system?.contains(ChatToolDefinitions.untrustedResultInstruction) == true)
    }

    func testPromptToolProtocolDoesNotDescribeDisabledTools() throws {
        var body: [String: Any] = ["model": "local"]
        ChatToolSchemaEncoder.applyToolSchemas(
            to: &body,
            endpoint: endpoint(style: .lmStudioRESTV1, chatURL: "http://localhost:1234/api/v1/chat"),
            settings: enabledSettings(
                calendar: false,
                reminders: false,
                location: false,
                motion: false,
                device: true
            )
        )

        let prompt = try XCTUnwrap(body["system_prompt"] as? String)
        XCTAssertTrue(prompt.contains(ChatToolID.deviceContext.rawValue))
        for disabledToolID in ChatToolID.allCases where disabledToolID != .deviceContext {
            XCTAssertFalse(prompt.contains(disabledToolID.rawValue), disabledToolID.rawValue)
        }
    }

    func testDeleteToolSchemasRequireStableIdentifiers() {
        let calendarSchema = ChatToolDefinitions.definition(for: .calendarDeleteEvent).parametersSchema
        let reminderSchema = ChatToolDefinitions.definition(for: .remindersDeleteReminder).parametersSchema

        XCTAssertEqual(Self.requiredFields(in: calendarSchema), ["event_id"])
        XCTAssertEqual(Self.requiredFields(in: reminderSchema), ["reminder_id"])
    }

    func testDisabledSettingsDoNotAddSchemas() {
        var body: [String: Any] = ["model": "gpt-test"]

        ChatToolSchemaEncoder.applyToolSchemas(
            to: &body,
            endpoint: endpoint(style: .openAIChatCompletions, chatURL: "https://example.com/v1/chat/completions"),
            settings: .defaults
        )

        XCTAssertNil(body["tools"])
    }

    private func enabledSettings(
        calendar: Bool = true,
        reminders: Bool = true,
        location: Bool = true,
        motion: Bool = true,
        device: Bool = true
    ) -> ToolUseSettings {
        ToolUseSettings(
            isEnabled: true,
            calendarEnabled: calendar,
            remindersEnabled: reminders,
            locationEnabled: location,
            motionEnabled: motion,
            deviceContextEnabled: device
        )
    }

    private func endpoint(style: ChatRequestStyle, chatURL: String) -> ChatAPIEndpointCandidate {
        ChatAPIEndpointCandidate(
            provider: .openAI,
            style: style,
            chatURL: URL(string: chatURL)!,
            modelsURL: URL(string: "https://example.com/v1/models")!
        )
    }

    private static func requiredFields(in schema: JSONValue) -> [String] {
        guard case let .object(root) = schema,
              case let .array(values)? = root["required"] else {
            return []
        }
        return values.compactMap { value in
            guard case let .string(field) = value else { return nil }
            return field
        }
    }
}
