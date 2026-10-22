//
//  SettingsAdvancedAPIModels.swift
//  Mallow
//
//  Created by Codex on 2026/6/14.
//

import SwiftUI

enum AdvancedAPISettingsSectionID: String, CaseIterable, Identifiable {
    case metadata
    case currentBackend
    case backendOverrides
    case defaults

    var id: String { rawValue }
}

enum AdvancedAPIBackendOverrideID: String, CaseIterable, Identifiable {
    case openAIResponses
    case openAIChat
    case anthropic
    case lmStudioREST

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .openAIResponses:
            return "API_FORMAT_OPENAI_RESPONSES"
        case .openAIChat:
            return "API_FORMAT_OPENAI_CHAT_COMPLETIONS"
        case .anthropic:
            return "API_FORMAT_ANTHROPIC_MESSAGES"
        case .lmStudioREST:
            return "API_FORMAT_LM_STUDIO_REST_V1"
        }
    }
}

enum SettingsAdvancedAPIParameterProfile {
    case openAIResponses
    case openAIChat
    case anthropic
    case lmStudioREST

    init(override backend: AdvancedAPIBackendOverrideID) {
        switch backend {
        case .openAIResponses:
            self = .openAIResponses
        case .openAIChat:
            self = .openAIChat
        case .anthropic:
            self = .anthropic
        case .lmStudioREST:
            self = .lmStudioREST
        }
    }

    @MainActor
    init(current context: SettingsAdvancedAPIContext) {
        switch context.currentRequestStyle {
        case .anthropicMessages:
            self = .anthropic
        case .lmStudioRESTV1:
            self = .lmStudioREST
        case .openAIResponses:
            self = .openAIResponses
        case .openAIChatCompletions:
            self = .openAIChat
        }
    }
}
