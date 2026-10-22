//
//  ChatProviderDescriptor.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import Foundation

struct ChatAPIFormatOption: Identifiable, Sendable {
    let preference: ChatAPIFormatPreference

    var id: String { preference.rawValue }

    var displayName: String {
        ChatProviderDescriptorRegistry.displayName(for: preference)
    }
}

enum ChatProviderDescriptorRegistry {
    static let apiFormatOptions: [ChatAPIFormatOption] = ChatAPIFormatPreference.allCases.map {
        ChatAPIFormatOption(preference: $0)
    }

    static func displayName(for preference: ChatAPIFormatPreference) -> String {
        switch preference {
        case .automatic:
            return NSLocalizedString("COMMON_AUTOMATIC", value: "Automatic", comment: "Automatic API format preference")
        case .openAIResponses:
            return NSLocalizedString("API_FORMAT_OPENAI_RESPONSES", value: "OpenAI Responses", comment: "API format preference")
        case .openAIChatCompletions:
            return NSLocalizedString("API_FORMAT_OPENAI_CHAT_COMPLETIONS", value: "OpenAI Chat Completions", comment: "API format preference")
        case .anthropic, .lmStudio:
            guard let provider = preference.providerHint else {
                return NSLocalizedString("COMMON_AUTOMATIC", value: "Automatic", comment: "Automatic API format preference")
            }
            return displayName(for: provider)
        }
    }

    static func displayName(for provider: ChatProvider) -> String {
        switch provider {
        case .openAI:
            return NSLocalizedString("PROVIDER_OPENAI", value: "OpenAI", comment: "Provider display name")
        case .anthropic:
            return NSLocalizedString("PROVIDER_ANTHROPIC", value: "Anthropic", comment: "Provider display name")
        case .lmStudio:
            return NSLocalizedString("PROVIDER_LM_STUDIO", value: "LM Studio", comment: "Provider display name")
        case .unknown:
            return NSLocalizedString("COMMON_UNKNOWN", value: "Unknown", comment: "Provider display name")
        }
    }
}
