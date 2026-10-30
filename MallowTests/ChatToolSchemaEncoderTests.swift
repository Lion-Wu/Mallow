import XCTest
@testable import Mallow

final class ChatToolSchemaEncoderTests: XCTestCase {
    func testResponsesEndpointUsesResponsesFunctionShape() throws {
        var body: [String: Any] = ["model": "gpt-test"]

        ChatToolSchemaEncoder.applyToolSchemas(
            to: &body,
            endpoint: endpoint(style: .openAIResponses, chatURL: "https://api.openai.com/v1/responses"),
            definitions: try ChatToolCatalog.prepareBuiltIn(settings: ToolUseSettings(isEnabled: true, enabledGroups: ["deviceContext"])).definitions
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

    func testAnthropicToolsAddToolResultTrustInstructionToSystemPrompt() throws {
        var body: [String: Any] = ["model": "claude-test", "system": "Be concise."]

        ChatToolSchemaEncoder.applyToolSchemas(
            to: &body,
            endpoint: endpoint(style: .anthropicMessages, chatURL: "https://api.anthropic.com/v1/messages"),
            definitions: try ChatToolCatalog.prepareBuiltIn(settings: ToolUseSettings(isEnabled: true, enabledGroups: ["deviceContext"])).definitions
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
            definitions: try ChatToolCatalog.prepareBuiltIn(settings: ToolUseSettings(isEnabled: true, enabledGroups: ["deviceContext"])).definitions
        )

        let prompt = try XCTUnwrap(body["system_prompt"] as? String)
        XCTAssertTrue(prompt.contains(ChatToolID.deviceContext.rawValue))
        for disabledToolID in ChatToolRegistry.builtIn.definitions.map(\.id) where disabledToolID != .deviceContext {
            XCTAssertFalse(prompt.contains(disabledToolID.rawValue), disabledToolID.rawValue)
        }
    }

    func testDeleteToolSchemasRequireStableIdentifiers() throws {
        let calendarSchema = try XCTUnwrap(ChatToolRegistry.builtIn.registration(id: .calendarDeleteEvent)).definition.parametersSchema
        let reminderSchema = try XCTUnwrap(ChatToolRegistry.builtIn.registration(id: .remindersDeleteReminder)).definition.parametersSchema

        XCTAssertEqual(Self.requiredFields(in: calendarSchema), ["event_id"])
        XCTAssertEqual(Self.requiredFields(in: reminderSchema), ["reminder_id"])
    }

    func testDisabledSettingsDoNotAddSchemas() throws {
        var body: [String: Any] = ["model": "gpt-test"]

        ChatToolSchemaEncoder.applyToolSchemas(
            to: &body,
            endpoint: endpoint(style: .openAIChatCompletions, chatURL: "https://example.com/v1/chat/completions"),
            definitions: try ChatToolCatalog.prepareBuiltIn(settings: .defaults).definitions
        )

        XCTAssertNil(body["tools"])
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
