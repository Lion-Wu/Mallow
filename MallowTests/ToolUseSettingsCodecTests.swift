import XCTest
@testable import Mallow

final class ToolUseSettingsCodecTests: XCTestCase {
    func testDefaultsKeepGlobalToolUseDisabledWhenNoSettingsExist() {
        let decoded = ToolUseSettingsCodec.decode(from: nil)

        XCTAssertFalse(decoded.isEnabled)
        XCTAssertFalse(decoded.calendarEnabled)
        XCTAssertFalse(decoded.remindersEnabled)
        XCTAssertFalse(decoded.locationEnabled)
        XCTAssertFalse(decoded.motionEnabled)
        XCTAssertFalse(decoded.deviceContextEnabled)
        XCTAssertFalse(decoded.clipboardEnabled)
        XCTAssertFalse(decoded.urlActionsEnabled)
        XCTAssertFalse(decoded.javaScriptRuntimeEnabled)
        XCTAssertFalse(decoded.timeEnabled)
        XCTAssertEqual(decoded.authorizationMode, .readOnly)
        XCTAssertFalse(decoded.allowHighRiskToolAutoExecution)
        XCTAssertTrue(decoded.useProviderContinuationIDs)
        XCTAssertEqual(decoded.openAIResponsesStatefulEndpointURLs, [
            "https://api.openai.com/v1/responses"
        ])
        XCTAssertTrue(decoded.enabledToolIDs.isEmpty)
    }

    func testDeveloperRuntimeSettingsOnlyApplyWhileDeveloperModeIsEnabled() {
        var advancedSettings = APIAdvancedSettings.defaults
        advancedSettings.openAIChatSampling.seedEnabled = true
        advancedSettings.openAIChatSampling.seed = 36

        var toolSettings = ToolUseSettings.defaults
        toolSettings.isEnabled = true
        toolSettings.timeEnabled = true
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
        XCTAssertTrue(disabledToolSettings.timeEnabled)
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
                endpoint: localEndpoint,
                expected: .ask
            )
        }
        cases += highRiskTools.map {
            AuthorizationDecisionCase(
                name: "Explicit automatic permission allows \($0.rawValue)",
                tool: $0,
                settings: automatic,
                endpoint: localEndpoint,
                expected: .allow
            )
        }
        cases.append(AuthorizationDecisionCase(
            name: "Ask-every-time overrides automatic permission",
            tool: .javaScriptRun,
            settings: askEveryTime,
            endpoint: localEndpoint,
            expected: .ask
        ))
        cases.append(AuthorizationDecisionCase(
            name: "Remote endpoint uses the same high-risk policy",
            tool: .systemOpenURL,
            settings: readWrite,
            endpoint: remoteEndpoint,
            expected: .ask
        ))

        assertAuthorizationDecisions(cases)
    }

    func testRemoteReadAuthorizationPolicyMatrix() {
        let settings = ToolUseSettings(
            isEnabled: true,
            calendarEnabled: true,
            remindersEnabled: false,
            locationEnabled: false,
            motionEnabled: false,
            deviceContextEnabled: true,
            timeEnabled: true
        )
        assertAuthorizationDecisions([
            .init(
                name: "Calendar read",
                tool: .calendarListEvents,
                settings: settings,
                endpoint: remoteEndpoint,
                expected: .allow
            ),
            .init(
                name: "Device context read",
                tool: .deviceContext,
                settings: settings,
                endpoint: remoteEndpoint,
                expected: .allow
            ),
            .init(
                name: "System time read",
                tool: .systemGetTime,
                settings: settings,
                endpoint: remoteEndpoint,
                expected: .allow
            )
        ])
    }

    private var localEndpoint: ChatAPIEndpointCandidate {
        ChatAPIEndpointCandidate(
            provider: .lmStudio,
            style: .lmStudioRESTV1,
            chatURL: URL(string: "http://localhost:1234/api/v1/chat")!,
            modelsURL: URL(string: "http://localhost:1234/api/v1/models")!
        )
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
            calendarEnabled: false,
            remindersEnabled: false,
            locationEnabled: true,
            motionEnabled: false,
            deviceContextEnabled: false,
            clipboardEnabled: true,
            urlActionsEnabled: true,
            javaScriptRuntimeEnabled: true,
            authorizationMode: mode,
            allowHighRiskToolAutoExecution: allowAutomatic
        )
    }

    private func assertAuthorizationDecisions(_ cases: [AuthorizationDecisionCase]) {
        for testCase in cases {
            XCTAssertTrue(
                testCase.settings.enabledToolIDs.contains(testCase.tool),
                testCase.name
            )
            XCTAssertEqual(
                ChatToolAuthorizationPolicy.decision(
                    for: testCase.tool,
                    settings: testCase.settings,
                    endpoint: testCase.endpoint
                ),
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
    let endpoint: ChatAPIEndpointCandidate
    let expected: ChatToolAuthorizationPolicy.Decision
}
