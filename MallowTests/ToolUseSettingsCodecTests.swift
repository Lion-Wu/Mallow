import XCTest
@testable import Mallow

final class ToolUseSettingsCodecTests: XCTestCase {
    func testDefaultsKeepGlobalToolUseDisabledWhenNoSettingsExist() {
        let decoded = ToolUseSettingsCodec.decode(from: nil)

        XCTAssertFalse(decoded.isEnabled)
        for group in ChatToolRegistry.builtIn.groups {
            XCTAssertFalse(decoded.isGroupEnabled(group.id))
        }
        XCTAssertEqual(decoded.authorizationMode, .readOnly)
        XCTAssertFalse(decoded.allowHighRiskToolAutoExecution)
        XCTAssertTrue(decoded.useProviderContinuationIDs)
        XCTAssertEqual(decoded.openAIResponsesStatefulEndpointURLs, [
            "https://api.openai.com/v1/responses"
        ])
        XCTAssertTrue(decoded.enabledGroups.isEmpty)
    }

    func testDeveloperRuntimeSettingsOnlyApplyWhileDeveloperModeIsEnabled() {
        var advancedSettings = APIAdvancedSettings.defaults
        advancedSettings.openAIChatSampling.seedEnabled = true
        advancedSettings.openAIChatSampling.seed = 36

        var toolSettings = ToolUseSettings.defaults
        toolSettings.isEnabled = true
        toolSettings.setGroup("time", enabled: true)
        toolSettings.useProviderContinuationIDs = false
        toolSettings.openAIResponsesStatefulEndpointURLs = ["https://example.com/v1/responses"]

        let disabledAdvancedSettings = DeveloperRuntimeSettingsPolicy.apiAdvancedSettings(
            configured: advancedSettings,
            developerModeEnabled: false
        )
        let disabledToolSettings = DeveloperRuntimeSettingsPolicy.toolUseSettings(
            configured: toolSettings,
            developerModeEnabled: false
        )

        XCTAssertFalse(disabledAdvancedSettings.openAIChatSampling.seedEnabled)
        XCTAssertEqual(disabledAdvancedSettings.openAIChatSampling.seed, 0)
        XCTAssertTrue(disabledToolSettings.isEnabled)
        XCTAssertTrue(disabledToolSettings.isGroupEnabled("time"))
        XCTAssertEqual(disabledToolSettings.useProviderContinuationIDs, ToolUseSettings.defaults.useProviderContinuationIDs)
        XCTAssertEqual(
            disabledToolSettings.openAIResponsesStatefulEndpointURLs,
            ToolUseSettings.defaults.openAIResponsesStatefulEndpointURLs
        )

        var disabledRequestBody: [String: Any] = [:]
        ChatRequestAdvancedConfigurationApplier().apply(
            to: &disabledRequestBody,
            model: "test-model",
            endpoint: remoteEndpoint,
            settings: disabledAdvancedSettings
        )
        XCTAssertNil(disabledRequestBody["seed"])

        var enabledRequestBody: [String: Any] = [:]
        ChatRequestAdvancedConfigurationApplier().apply(
            to: &enabledRequestBody,
            model: "test-model",
            endpoint: remoteEndpoint,
            settings: advancedSettings
        )
        XCTAssertEqual(enabledRequestBody["seed"] as? Int, 36)

        let customResponsesEndpoint = ChatAPIEndpointCandidate(
            provider: .openAI,
            style: .openAIResponses,
            chatURL: URL(string: "https://example.com/v1/responses")!,
            modelsURL: URL(string: "https://example.com/v1/models")!
        )
        let lmStudioEndpoint = ChatAPIEndpointCandidate(
            provider: .lmStudio,
            style: .lmStudioRESTV1,
            chatURL: URL(string: "http://localhost:1234/api/v1/chat")!,
            modelsURL: URL(string: "http://localhost:1234/api/v1/models")!
        )
        XCTAssertFalse(disabledToolSettings.useProviderContinuationIDs(for: customResponsesEndpoint))
        XCTAssertTrue(toolSettings.useProviderContinuationIDs(for: customResponsesEndpoint))
        XCTAssertTrue(disabledToolSettings.useProviderContinuationIDs(for: lmStudioEndpoint))
        XCTAssertFalse(toolSettings.useProviderContinuationIDs(for: lmStudioEndpoint))

        XCTAssertEqual(
            DeveloperRuntimeSettingsPolicy.apiAdvancedSettings(
                configured: advancedSettings,
                developerModeEnabled: true
            ),
            advancedSettings
        )
        XCTAssertEqual(
            DeveloperRuntimeSettingsPolicy.toolUseSettings(
                configured: toolSettings,
                developerModeEnabled: true
            ),
            toolSettings
        )
    }

    func testHighRiskAuthorizationPolicyMatrix() {
        let readWrite = highRiskSettings(mode: .readWrite, allowAutomatic: false)
        let automatic = highRiskSettings(mode: .readWrite, allowAutomatic: true)
        let askEveryTime = highRiskSettings(mode: .askEveryTime, allowAutomatic: true)
        let highRiskTools: [ChatToolID] = [
            .locationCurrent,
            .clipboardGetText,
            .clipboardSetText,
            .systemOpenURL,
            .javaScriptRun
        ]
        var cases = highRiskTools.map {
            AuthorizationDecisionCase(
                name: "Read-write still asks for \($0.rawValue)",
                tool: $0,
                settings: readWrite,
                expected: .ask
            )
        }
        cases += highRiskTools.map {
            AuthorizationDecisionCase(
                name: "Explicit automatic permission allows \($0.rawValue)",
                tool: $0,
                settings: automatic,
                expected: .allow
            )
        }
        cases.append(AuthorizationDecisionCase(
            name: "Ask-every-time overrides automatic permission",
            tool: .javaScriptRun,
            settings: askEveryTime,
            expected: .ask
        ))

        assertAuthorizationDecisions(cases)
    }

    func testReadAuthorizationPolicyMatrix() {
        let settings = ToolUseSettings(
            isEnabled: true,
            enabledGroups: ["calendar", "deviceContext", "time"]
        )
        assertAuthorizationDecisions([
            .init(
                name: "Calendar read",
                tool: .calendarListEvents,
                settings: settings,
                expected: .allow
            ),
            .init(
                name: "Device context read",
                tool: .deviceContext,
                settings: settings,
                expected: .allow
            ),
            .init(
                name: "System time read",
                tool: .systemGetTime,
                settings: settings,
                expected: .allow
            )
        ])
    }

    private var remoteEndpoint: ChatAPIEndpointCandidate {
        ChatAPIEndpointCandidate(
            provider: .openAI,
            style: .openAIChatCompletions,
            chatURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
            modelsURL: URL(string: "https://api.openai.com/v1/models")!
        )
    }

    private func highRiskSettings(
        mode: ToolAuthorizationMode,
        allowAutomatic: Bool
    ) -> ToolUseSettings {
        ToolUseSettings(
            isEnabled: true,
            enabledGroups: ["location", "clipboard", "urlActions", "javaScriptRuntime"],
            authorizationMode: mode,
            allowHighRiskToolAutoExecution: allowAutomatic
        )
    }

    private func assertAuthorizationDecisions(_ cases: [AuthorizationDecisionCase]) {
        for testCase in cases {
            guard let registration = ChatToolRegistry.builtIn.registration(id: testCase.tool) else {
                XCTFail("Missing tool registration: \(testCase.tool.rawValue)")
                continue
            }
            XCTAssertTrue(testCase.settings.isEnabled && registration.isEnabled(testCase.settings), testCase.name)
            XCTAssertEqual(
                ChatToolAuthorizationPolicy.decision(for: registration.definition, settings: testCase.settings),
                testCase.expected,
                testCase.name
            )
        }
    }
}

private struct AuthorizationDecisionCase {
    let name: String
    let tool: ChatToolID
    let settings: ToolUseSettings
    let expected: ChatToolAuthorizationPolicy.Decision
}
