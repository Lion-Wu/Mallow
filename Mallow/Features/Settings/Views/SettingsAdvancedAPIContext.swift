//
//  SettingsAdvancedAPIContext.swift
//  Mallow
//
//  Created by Codex on 2026/6/14.
//

import Foundation

@MainActor
struct SettingsAdvancedAPIContext {
    let viewModel: SettingsViewModel
    let settingsManager: SettingsManager

    var currentProvider: ChatProvider {
        let base = viewModel.apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.selectedChatAPIFormatPreference.providerHint
            ?? settingsManager.chatModelCapabilities.detectedProvider(for: base)
            ?? ChatAPIEndpointResolver.officialProviderHint(for: base)
            ?? .unknown
    }

    var currentRequestStyle: ChatRequestStyle {
        let base = viewModel.apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.selectedChatAPIFormatPreference.requestStyleHint
            ?? settingsManager.chatModelCapabilities.detectedRequestStyle(for: base)
            ?? SettingsAPIRequestStyleResolver.inferredStyle(
                for: base,
                providerHint: currentProvider
            )
            ?? .openAIResponses
    }

    var currentRequestStyleDisplayName: String {
        switch currentRequestStyle {
        case .openAIResponses:
            return currentProvider == .unknown
                ? String(localized: "SETTINGS_UNKNOWN_OPENAI_RESPONSES", defaultValue: "Unknown, using OpenAI Responses")
                : String(localized: "API_FORMAT_OPENAI_RESPONSES", defaultValue: "OpenAI Responses")
        case .openAIChatCompletions:
            return String(localized: "API_FORMAT_OPENAI_CHAT_COMPLETIONS", defaultValue: "OpenAI Chat Completions")
        case .lmStudioRESTV1:
            return String(localized: "API_FORMAT_LM_STUDIO_REST_V1", defaultValue: "LM Studio REST v1")
        case .anthropicMessages:
            return String(localized: "API_FORMAT_ANTHROPIC_MESSAGES", defaultValue: "Anthropic Messages")
        }
    }

    var selectedAPIFormatDisplayName: String {
        switch viewModel.selectedChatAPIFormatPreference {
        case .automatic:
            return String(localized: "COMMON_AUTOMATIC", defaultValue: "Automatic")
        case .openAIResponses:
            return String(localized: "API_FORMAT_OPENAI_RESPONSES", defaultValue: "OpenAI Responses")
        case .openAIChatCompletions:
            return String(localized: "API_FORMAT_OPENAI_CHAT_COMPLETIONS", defaultValue: "OpenAI Chat Completions")
        case .anthropic:
            return ChatProvider.anthropic.displayName
        case .lmStudio:
            return ChatProvider.lmStudio.displayName
        }
    }

    var selectedModelMetadata: ModelInfo? {
        viewModel.lastFetchedModelMetadata.first { $0.id == viewModel.selectedModel }
    }

    var localizedUnknown: String {
        String(localized: "COMMON_UNKNOWN", defaultValue: "Unknown")
    }

    func joined(_ values: [String]?) -> String {
        guard let values, !values.isEmpty else { return String(localized: "COMMON_NONE", defaultValue: "None") }
        return values.joined(separator: ", ")
    }

    func optionalBool(_ value: Bool?) -> String {
        guard let value else { return localizedUnknown }
        return value ? String(localized: "COMMON_YES", defaultValue: "Yes") : String(localized: "COMMON_NO", defaultValue: "No")
    }
}

enum SettingsAPIRequestStyleResolver {
    static func inferredStyle(
        for baseURL: String,
        providerHint: ChatProvider? = nil
    ) -> ChatRequestStyle? {
        DefaultChatEndpointResolver()
            .streamingCandidates(
                for: baseURL,
                providerHint: providerHint,
                styleHint: nil
            )
            .first?
            .style
    }
}
