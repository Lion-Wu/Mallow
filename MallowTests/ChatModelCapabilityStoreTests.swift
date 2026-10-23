import SwiftData
import XCTest
@testable import Mallow

@MainActor
final class ChatModelCapabilityStoreTests: XCTestCase {
    func testImageSupportRespectsEndpointAndFormatAndProviderMetadata() {
        var store = ChatModelCapabilityStore()
        let base = "http://localhost:1234"
        let model = "plain-text-model"
        store.setImageInputManualOverride(true, for: model, apiBaseURL: base, requestStyle: .openAIResponses)

        XCTAssertTrue(store.supportsImageInput(for: model, apiBaseURL: base, requestStyle: .openAIResponses))
        XCTAssertFalse(store.supportsImageInput(for: model, apiBaseURL: base, requestStyle: .openAIChatCompletions))
        XCTAssertFalse(store.supportsImageInput(for: model, apiBaseURL: "http://other-host:1234", requestStyle: .openAIResponses))

        store.updateImageInputSupport([model: false], for: base)
        XCTAssertFalse(store.supportsImageInput(for: model, apiBaseURL: base, requestStyle: .openAIResponses))
    }

    func testDetectionHintsAndThinkingPreferencesPersistThroughDedicatedStore() throws {
        var store = ChatModelCapabilityStore()
        store.noteDetectedProvider(.anthropic, for: "https://api.anthropic.com")
        store.noteDetectedRequestStyle(.anthropicMessages, for: "https://api.anthropic.com")
        store.noteDetectedProvider(.unknown, for: "https://ignored.example")

        XCTAssertEqual(store.detectedProvider(for: "https://api.anthropic.com"), .anthropic)
        XCTAssertEqual(store.detectedRequestStyle(for: "https://api.anthropic.com"), .anthropicMessages)
        XCTAssertNil(store.detectedProvider(for: "https://ignored.example"))

        let capability = ModelThinkingCapability(options: [.low, .high], defaultOption: .low)
        store.setSelectedThinkingOption(
            .high,
            for: "reasoning-model",
            apiBaseURL: "https://api.example.com/v1",
            requestStyle: .openAIResponses,
            capability: capability
        )
        let container = try ModelContainer(for: AppSettings.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let settings = AppSettings()
        context.insert(settings)
        try store.savePreferences(to: settings)
        try context.save()
        let reloaded = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<AppSettings>()).first)
        let restored = ChatModelCapabilityStore.restoringPreferences(from: reloaded)
        XCTAssertEqual(restored.detectedProviderHints, store.detectedProviderHints)
        XCTAssertEqual(restored.detectedRequestStyleHints, store.detectedRequestStyleHints)
        XCTAssertEqual(restored.thinkingPreferences, store.thinkingPreferences)
    }
}
