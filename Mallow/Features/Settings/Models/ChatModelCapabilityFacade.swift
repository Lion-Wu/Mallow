//
//  ChatModelCapabilityFacade.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import Foundation

@MainActor
struct ChatModelCapabilityFacade {
    var store: ChatModelCapabilityStore
    var chatSettings: ChatSettings
    var chatServerPresets: [ChatServerPreset]
    var selectedChatServerPresetID: UUID?

    mutating func updateImageInputSupport(_ supportByModel: [String: Bool], for apiBaseURL: String) {
        store.updateImageInputSupport(supportByModel, for: apiBaseURL)
    }

    mutating func updateThinkingCapabilities(
        _ capabilitiesByModel: [String: ModelThinkingCapability],
        for apiBaseURL: String
    ) {
        store.updateThinkingCapabilities(capabilitiesByModel, for: apiBaseURL)
    }

    mutating func noteDetectedProvider(_ provider: ChatProvider, for apiBaseURL: String) {
        store.noteDetectedProvider(provider, for: apiBaseURL)
    }

    mutating func noteDetectedRequestStyle(_ style: ChatRequestStyle, for apiBaseURL: String) {
        store.noteDetectedRequestStyle(style, for: apiBaseURL)
    }

    mutating func noteDetectedEndpoint(_ endpoint: ChatAPIEndpointCandidate, for apiBaseURL: String) {
        store.noteDetectedProvider(endpoint.provider == .unknown ? .openAI : endpoint.provider, for: apiBaseURL)
        store.noteDetectedRequestStyle(endpoint.style, for: apiBaseURL)
    }

    func detectedProvider(for apiBaseURL: String) -> ChatProvider? {
        store.detectedProvider(for: apiBaseURL)
    }

    func detectedRequestStyle(for apiBaseURL: String) -> ChatRequestStyle? {
        store.detectedRequestStyle(for: apiBaseURL)
    }

    func chatAPIFormatPreference(for presetID: UUID?) -> ChatAPIFormatPreference {
        ChatServerPresetStore.apiFormatPreference(for: presetID, in: chatServerPresets)
    }

    func selectedChatAPIFormatPreference() -> ChatAPIFormatPreference {
        chatAPIFormatPreference(for: selectedChatServerPresetID)
    }

    func resolvedProvider(for apiBaseURL: String) -> ChatProvider? {
        if let manualPreference = manualChatAPIFormatPreference(for: apiBaseURL),
           let provider = manualPreference.providerHint {
            return provider
        }
        return detectedProvider(for: apiBaseURL)
    }

    func resolvedRequestStyle(for apiBaseURL: String) -> ChatRequestStyle? {
        if let manualPreference = manualChatAPIFormatPreference(for: apiBaseURL),
           let style = manualPreference.requestStyleHint {
            return style
        }
        return detectedRequestStyle(for: apiBaseURL)
    }

    func imageInputManualOverride(for modelIdentifier: String) -> Bool? {
        store.imageInputManualOverride(for: modelIdentifier, apiBaseURL: chatSettings.apiURL, requestStyle: resolvedRequestStyle(for: chatSettings.apiURL))
    }

    mutating func setImageInputManualOverride(_ enabled: Bool?, for modelIdentifier: String) {
        store.setImageInputManualOverride(enabled, for: modelIdentifier, apiBaseURL: chatSettings.apiURL, requestStyle: resolvedRequestStyle(for: chatSettings.apiURL))
    }

    func isImageInputSupportUnknown(for modelIdentifier: String) -> Bool {
        store.isImageInputSupportUnknown(
            for: modelIdentifier,
            apiBaseURL: chatSettings.apiURL
        )
    }

    func supportsImageInput(for modelIdentifier: String) -> Bool {
        store.supportsImageInput(
            for: modelIdentifier,
            apiBaseURL: chatSettings.apiURL,
            requestStyle: resolvedRequestStyle(for: chatSettings.apiURL)
        )
    }

    func thinkingCapability(for modelIdentifier: String) -> ModelThinkingCapability? {
        let trimmed = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let requestStyle = resolvedRequestStyle(for: chatSettings.apiURL)
        return store.thinkingCapability(
            for: trimmed,
            apiBaseURL: chatSettings.apiURL,
            requestStyle: requestStyle
        )
    }

    func isThinkingCapabilityUnknown(for modelIdentifier: String) -> Bool {
        store.reportedThinkingCapability(for: modelIdentifier, apiBaseURL: chatSettings.apiURL)?.hasKnownOptions != true
    }

    func availableManualThinkingOptions(for modelIdentifier: String) -> [ModelThinkingOption] {
        guard resolvedRequestStyle(for: chatSettings.apiURL) != nil,
              isThinkingCapabilityUnknown(for: modelIdentifier) else { return [] }
        let reported = store.reportedThinkingCapability(for: modelIdentifier, apiBaseURL: chatSettings.apiURL)
        return ModelCapabilityResolver.manualThinkingOptions.filter {
            reported?.allowsDisabling != false || !$0.isDisabled
        }
    }

    func manualThinkingOptions(for modelIdentifier: String) -> [ModelThinkingOption] {
        let options = store.manualThinkingOptions(for: modelIdentifier, apiBaseURL: chatSettings.apiURL,
                                                 requestStyle: resolvedRequestStyle(for: chatSettings.apiURL)) ?? []
        let available = availableManualThinkingOptions(for: modelIdentifier)
        return options.filter { available.contains($0) }
    }

    mutating func setManualThinkingOptions(_ options: [ModelThinkingOption], for modelIdentifier: String) {
        store.setManualThinkingOptions(options, for: modelIdentifier, apiBaseURL: chatSettings.apiURL,
                                       requestStyle: resolvedRequestStyle(for: chatSettings.apiURL))
    }

    func selectedThinkingOption(for modelIdentifier: String? = nil) -> ModelThinkingOption? {
        let model = (modelIdentifier ?? chatSettings.selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, let capability = thinkingCapability(for: model) else { return nil }
        return store.selectedThinkingOption(
            for: model,
            apiBaseURL: chatSettings.apiURL,
            requestStyle: resolvedRequestStyle(for: chatSettings.apiURL),
            capability: capability
        )
    }

    mutating func setSelectedThinkingOption(_ option: ModelThinkingOption?, for modelIdentifier: String? = nil) -> Bool {
        let model = (modelIdentifier ?? chatSettings.selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty,
              let capability = thinkingCapability(for: model) else {
            return false
        }
        store.setSelectedThinkingOption(
            option,
            for: model,
            apiBaseURL: chatSettings.apiURL,
            requestStyle: resolvedRequestStyle(for: chatSettings.apiURL),
            capability: capability
        )
        return true
    }

    mutating func toggleSelectedThinking(for modelIdentifier: String? = nil) -> Bool {
        let model = (modelIdentifier ?? chatSettings.selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, let capability = thinkingCapability(for: model) else { return false }
        let next = capability.toggledSelection(from: selectedThinkingOption(for: model))
        return setSelectedThinkingOption(next, for: model)
    }

    private func manualChatAPIFormatPreference(for apiBaseURL: String) -> ChatAPIFormatPreference? {
        guard let presetID = selectedChatServerPresetID,
              let preset = chatServerPresets.first(where: { $0.id == presetID }) else {
            return nil
        }
        let selectedBase = ChatAPIEndpointResolver.normalizedAPIBaseKey(preset.apiURL)
        let requestedBase = ChatAPIEndpointResolver.normalizedAPIBaseKey(apiBaseURL)
        guard selectedBase != nil, selectedBase == requestedBase else { return nil }

        let preference = chatAPIFormatPreference(for: presetID)
        return preference == .automatic ? nil : preference
    }
}
