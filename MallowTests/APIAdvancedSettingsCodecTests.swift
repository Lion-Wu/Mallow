import XCTest
@testable import Mallow

final class APIAdvancedSettingsCodecTests: XCTestCase {
    func testRoundTripsSanitizedSettings() throws {
        let settings = APIAdvancedSettings(
            openAIResponsesMaxOutputTokens: -10,
            anthropicMaxTokens: 0,
            anthropicMaxTokensEnabled: true,
            anthropicThinkingBudgetEnabled: true,
            anthropicThinkingBudget: 100
        )

        let json = try XCTUnwrap(APIAdvancedSettingsCodec.encode(settings))
        let decoded = APIAdvancedSettingsCodec.decode(from: json)

        XCTAssertEqual(decoded.openAIResponsesMaxOutputTokens, 0)
        XCTAssertEqual(decoded.anthropicMaxTokens, 0)
        XCTAssertEqual(decoded.anthropicThinkingBudget, 100)
        XCTAssertTrue(decoded.anthropicMaxTokensEnabled)
        XCTAssertTrue(decoded.anthropicThinkingBudgetEnabled)
    }

    func testInvalidJSONFallsBackToDefaults() {
        XCTAssertEqual(
            APIAdvancedSettingsCodec.decode(from: "not-json"),
            APIAdvancedSettings.defaults.sanitized
        )
    }
}
