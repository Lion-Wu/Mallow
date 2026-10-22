//
//  ChatModelCapabilityStore.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import Foundation

struct ChatModelCapabilityStore: Equatable {
    private(set) var imageInputSupport: [String: Bool]
    private(set) var imageInputOverrides: [String: Bool]
    private(set) var thinkingCapabilities: [String: ModelThinkingCapability]
    private(set) var thinkingOptionOverrides: [String: [ModelThinkingOption]]
    private(set) var thinkingPreferences: [String: ModelThinkingOption]
    private(set) var detectedProviderHints: [String: ChatProvider]
    private(set) var detectedRequestStyleHints: [String: ChatRequestStyle]

    static func restoringPreferences(from settings: AppSettings) -> Self {
        let rawThinking: [String: String] = decodeDictionary(settings.modelThinkingPreferencesJSON)
        var store = Self(
            imageInputOverrides: decodeImageInputOverrides(from: settings.modelImageInputOverrideJSON),
            thinkingOptionOverrides: decodeDictionary(settings.modelThinkingOptionsJSON),
            thinkingPreferences: rawThinking.compactMapValues(ModelThinkingOption.normalized)
        )
        let records: [String: [String: String]] = decodeDictionary(settings.detectedAPIFormatsJSON)
        for (base, record) in records {
            guard let providerRaw = record["provider"], let provider = ChatProvider(rawValue: providerRaw),
                  let styleRaw = record["style"], let style = ChatRequestStyle(rawValue: styleRaw) else { continue }
            store.detectedProviderHints[base] = provider
            store.detectedRequestStyleHints[base] = style
        }
        return store
    }

    func savePreferences(to settings: AppSettings) throws {
        var records: [String: [String: String]] = [:]
        for (base, style) in detectedRequestStyleHints {
            guard let provider = detectedProviderHints[base] else { continue }
            records[base] = ["provider": provider.rawValue, "style": style.rawValue]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let formats = try encoder.encode(records)
        let thinking = try encoder.encode(thinkingPreferences.mapValues(\.rawValue))
        let overrides = imageInputOverrides.isEmpty ? nil : String(decoding: try encoder.encode(imageInputOverrides), as: UTF8.self)
        settings.detectedAPIFormatsJSON = String(decoding: formats, as: UTF8.self)
        settings.modelThinkingOptionsJSON = String(decoding: try encoder.encode(thinkingOptionOverrides), as: UTF8.self)
        settings.modelThinkingPreferencesJSON = String(decoding: thinking, as: UTF8.self)
        settings.modelImageInputOverrideJSON = overrides
    }

    init(
        imageInputSupport: [String: Bool] = [:],
        imageInputOverrides: [String: Bool] = [:],
        thinkingCapabilities: [String: ModelThinkingCapability] = [:],
        thinkingOptionOverrides: [String: [ModelThinkingOption]] = [:],
        thinkingPreferences: [String: ModelThinkingOption] = [:],
        detectedProviderHints: [String: ChatProvider] = [:],
        detectedRequestStyleHints: [String: ChatRequestStyle] = [:]
    ) {
        self.imageInputSupport = imageInputSupport
        self.imageInputOverrides = imageInputOverrides
        self.thinkingCapabilities = thinkingCapabilities
        self.thinkingOptionOverrides = thinkingOptionOverrides
        self.thinkingPreferences = thinkingPreferences
        self.detectedProviderHints = detectedProviderHints
        self.detectedRequestStyleHints = detectedRequestStyleHints
    }

    static func scopedKey(apiBaseURL: String, modelIdentifier: String) -> String? {
        let trimmedModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return nil }
        guard let endpointKey = ChatAPIEndpointResolver.normalizedAPIBaseKey(apiBaseURL) else { return nil }
        return "\(endpointKey)|\(trimmedModel)"
    }

    private static func decodeDictionary<Value: Decodable>(_ json: String?) -> [String: Value] {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: Value].self, from: data)) ?? [:]
    }

    static func decodeImageInputOverrides(from json: String?) -> [String: Bool] {
        decodeDictionary(json)
    }

    mutating func updateImageInputSupport(_ supportByModel: [String: Bool], for apiBaseURL: String) {
        guard let prefix = Self.scopedPrefix(for: apiBaseURL) else { return }

        imageInputSupport.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { imageInputSupport.removeValue(forKey: $0) }

        for (modelID, supportsImageInput) in supportByModel {
            guard let key = Self.scopedKey(apiBaseURL: apiBaseURL, modelIdentifier: modelID) else { continue }
            imageInputSupport[key] = supportsImageInput
        }
    }

    mutating func updateThinkingCapabilities(
        _ capabilitiesByModel: [String: ModelThinkingCapability],
        for apiBaseURL: String
    ) {
        guard let prefix = Self.scopedPrefix(for: apiBaseURL) else { return }

        thinkingCapabilities.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { thinkingCapabilities.removeValue(forKey: $0) }

        for (modelID, capability) in capabilitiesByModel {
            guard let key = Self.scopedKey(apiBaseURL: apiBaseURL, modelIdentifier: modelID) else { continue }
            thinkingCapabilities[key] = capability
        }
    }

    mutating func noteDetectedProvider(_ provider: ChatProvider, for apiBaseURL: String) {
        guard provider != .unknown else { return }
        guard let key = ChatAPIEndpointResolver.normalizedAPIBaseKey(apiBaseURL) else { return }
        detectedProviderHints[key] = provider
    }

    mutating func noteDetectedRequestStyle(_ style: ChatRequestStyle, for apiBaseURL: String) {
        guard let key = ChatAPIEndpointResolver.normalizedAPIBaseKey(apiBaseURL) else { return }
        detectedRequestStyleHints[key] = style
    }

    func detectedProvider(for apiBaseURL: String) -> ChatProvider? {
        guard let key = ChatAPIEndpointResolver.normalizedAPIBaseKey(apiBaseURL) else { return nil }
        return detectedProviderHints[key]
    }

    func detectedRequestStyle(for apiBaseURL: String) -> ChatRequestStyle? {
        guard let key = ChatAPIEndpointResolver.normalizedAPIBaseKey(apiBaseURL) else { return nil }
        return detectedRequestStyleHints[key]
    }

    static func preferenceKey(apiBaseURL: String, requestStyle: ChatRequestStyle?, modelIdentifier: String) -> String? {
        guard let requestStyle,
              let key = scopedKey(apiBaseURL: apiBaseURL, modelIdentifier: modelIdentifier) else { return nil }
        return "\(requestStyle.rawValue)|\(key)"
    }

    func imageInputManualOverride(for modelIdentifier: String, apiBaseURL: String, requestStyle: ChatRequestStyle?) -> Bool? {
        guard let key = Self.preferenceKey(apiBaseURL: apiBaseURL, requestStyle: requestStyle, modelIdentifier: modelIdentifier) else { return nil }
        return imageInputOverrides[key]
    }

    mutating func setImageInputManualOverride(_ enabled: Bool?, for modelIdentifier: String, apiBaseURL: String, requestStyle: ChatRequestStyle?) {
        guard let key = Self.preferenceKey(apiBaseURL: apiBaseURL, requestStyle: requestStyle, modelIdentifier: modelIdentifier) else { return }
        imageInputOverrides[key] = enabled
    }

    func isImageInputSupportUnknown(for modelIdentifier: String, apiBaseURL: String) -> Bool {
        !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            explicitImageInputSupport(for: modelIdentifier, apiBaseURL: apiBaseURL) == nil
    }

    func supportsImageInput(for modelIdentifier: String, apiBaseURL: String, requestStyle: ChatRequestStyle?) -> Bool {
        if let explicit = explicitImageInputSupport(for: modelIdentifier, apiBaseURL: apiBaseURL) { return explicit }
        return imageInputManualOverride(for: modelIdentifier, apiBaseURL: apiBaseURL, requestStyle: requestStyle) ?? false
    }

    func reportedThinkingCapability(for modelIdentifier: String, apiBaseURL: String) -> ModelThinkingCapability? {
        guard let key = Self.scopedKey(apiBaseURL: apiBaseURL, modelIdentifier: modelIdentifier) else { return nil }
        return thinkingCapabilities[key]
    }

    func manualThinkingOptions(for modelIdentifier: String, apiBaseURL: String, requestStyle: ChatRequestStyle?) -> [ModelThinkingOption]? {
        guard let key = Self.preferenceKey(apiBaseURL: apiBaseURL, requestStyle: requestStyle, modelIdentifier: modelIdentifier) else { return nil }
        return thinkingOptionOverrides[key]
    }

    mutating func setManualThinkingOptions(_ options: [ModelThinkingOption], for modelIdentifier: String, apiBaseURL: String, requestStyle: ChatRequestStyle?) {
        guard let key = Self.preferenceKey(apiBaseURL: apiBaseURL, requestStyle: requestStyle, modelIdentifier: modelIdentifier) else { return }
        thinkingOptionOverrides[key] = options
    }

    func thinkingCapability(for modelIdentifier: String, apiBaseURL: String, requestStyle: ChatRequestStyle?) -> ModelThinkingCapability? {
        let reported = reportedThinkingCapability(for: modelIdentifier, apiBaseURL: apiBaseURL)
        if reported?.hasKnownOptions == true { return reported }
        guard let requestStyle,
              let options = manualThinkingOptions(for: modelIdentifier, apiBaseURL: apiBaseURL, requestStyle: requestStyle) else { return reported }
        return ModelCapabilityResolver.applyingManualThinkingOptions(options, to: reported, style: requestStyle)
    }

    func selectedThinkingOption(
        for modelIdentifier: String,
        apiBaseURL: String,
        requestStyle: ChatRequestStyle?,
        capability: ModelThinkingCapability
    ) -> ModelThinkingOption? {
        guard let key = Self.preferenceKey(apiBaseURL: apiBaseURL, requestStyle: requestStyle, modelIdentifier: modelIdentifier) else {
            return nil
        }
        return capability.normalizedSelection(thinkingPreferences[key])
    }

    mutating func setSelectedThinkingOption(
        _ option: ModelThinkingOption?,
        for modelIdentifier: String,
        apiBaseURL: String,
        requestStyle: ChatRequestStyle?,
        capability: ModelThinkingCapability
    ) {
        guard let key = Self.preferenceKey(apiBaseURL: apiBaseURL, requestStyle: requestStyle, modelIdentifier: modelIdentifier) else {
            return
        }
        guard let normalized = capability.normalizedSelection(option) else { return }
        thinkingPreferences[key] = normalized
    }

    private func explicitImageInputSupport(for modelIdentifier: String, apiBaseURL: String) -> Bool? {
        guard let key = Self.scopedKey(apiBaseURL: apiBaseURL, modelIdentifier: modelIdentifier) else { return nil }
        return imageInputSupport[key]
    }

    private static func scopedPrefix(for apiBaseURL: String) -> String? {
        guard let endpointKey = ChatAPIEndpointResolver.normalizedAPIBaseKey(apiBaseURL) else { return nil }
        return "\(endpointKey)|"
    }
}
