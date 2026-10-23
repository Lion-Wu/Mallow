import Foundation
import SwiftData

// Value records keep recovery and merging independent of SwiftData object identity.

nonisolated struct ChatSessionBackup: Equatable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var lastMessageAt: Date?
    var lastMessageID: UUID?
    var sidebarPreviewText: String
    var activeRootMessageID: UUID?

    init(_ model: ChatSession) {
        id = model.id
        title = model.title
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        lastMessageAt = model.lastMessageAt
        lastMessageID = model.lastMessageID
        sidebarPreviewText = model.sidebarPreviewText
        activeRootMessageID = model.activeRootMessageID
    }

    func makeModel() -> ChatSession {
        let model = ChatSession()
        model.id = id
        model.title = title
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        model.lastMessageAt = lastMessageAt
        model.lastMessageID = lastMessageID
        model.sidebarPreviewText = sidebarPreviewText
        model.activeRootMessageID = activeRootMessageID
        return model
    }
}

nonisolated struct ChatMessageBackup: Equatable, Sendable {
    var id: UUID
    var activeChildMessageID: UUID?
    var importSourceMessageID: UUID?
    var content: String
    var assistantSegmentsData: Data?
    var openAIResponsesConversationItemsData: Data?
    var imageAttachmentsData: Data?
    var isUser: Bool
    var isError: Bool
    var isActive: Bool
    var createdAt: Date?
    var modelIdentifier: String?
    var apiBaseURL: String?
    var thinkingOptionRawValue: String?
    var requestID: UUID?
    var providerResponseID: String?
    var requestContextFingerprint: String?
    var requestUsedPreviousResponseID: Bool?
    var requestPreviousResponseID: String?
    var streamStartedAt: Date?
    var streamFirstTokenAt: Date?
    var streamFirstTokenAtSource: String?
    var streamCompletedAt: Date?
    var timeToFirstToken: TimeInterval?
    var outputTokenCount: Int?
    var reasoningOutputTokenCount: Int?
    var tokensPerSecond: Double?
    var tokenCount: Int?
    var generationRounds: [ChatGenerationRound]
    var tokenCountSource: String?
    var timeToFirstTokenSource: String?
    var tokensPerSecondSource: String?
    var finishReasonSource: String?
    var promptMessageCount: Int?
    var promptCharacterCount: Int?
    var finishReason: String?
    var errorDescription: String?
    var toolActivityPlacementsData: Data?
    var sessionID: UUID
    var parentID: UUID?

    init(_ model: ChatMessage) throws {
        guard let sessionID = model.session?.id else { throw DataBackupError.invalidRelationships }
        id = model.id
        activeChildMessageID = model.activeChildMessageID
        importSourceMessageID = model.importSourceMessageID
        content = model.content
        assistantSegmentsData = model.assistantSegmentsData
        openAIResponsesConversationItemsData = model.openAIResponsesConversationItemsData
        imageAttachmentsData = model.imageAttachmentsData
        isUser = model.isUser
        isError = model.isError
        isActive = model.isActive
        createdAt = model.createdAt
        modelIdentifier = model.modelIdentifier
        apiBaseURL = model.apiBaseURL
        thinkingOptionRawValue = model.thinkingOptionRawValue
        requestID = model.requestID
        providerResponseID = model.providerResponseID
        requestContextFingerprint = model.requestContextFingerprint
        requestUsedPreviousResponseID = model.requestUsedPreviousResponseID
        requestPreviousResponseID = model.requestPreviousResponseID
        streamStartedAt = model.streamStartedAt
        streamFirstTokenAt = model.streamFirstTokenAt
        streamFirstTokenAtSource = model.streamFirstTokenAtSource
        streamCompletedAt = model.streamCompletedAt
        timeToFirstToken = model.timeToFirstToken
        outputTokenCount = model.outputTokenCount
        reasoningOutputTokenCount = model.reasoningOutputTokenCount
        tokensPerSecond = model.tokensPerSecond
        generationRounds = model.generationRounds
        tokenCount = model.tokenCount
        tokenCountSource = model.tokenCountSource
        timeToFirstTokenSource = model.timeToFirstTokenSource
        tokensPerSecondSource = model.tokensPerSecondSource
        finishReasonSource = model.finishReasonSource
        promptMessageCount = model.promptMessageCount
        promptCharacterCount = model.promptCharacterCount
        finishReason = model.finishReason
        errorDescription = model.errorDescription
        toolActivityPlacementsData = model.toolActivityPlacementsData
        self.sessionID = sessionID
        parentID = model.parentMessage?.id
    }

    func makeModel() -> ChatMessage {
        let model = ChatMessage(content: content, isUser: isUser, isError: isError)
        model.id = id
        model.activeChildMessageID = activeChildMessageID
        model.importSourceMessageID = importSourceMessageID
        model.content = content

        model.assistantSegmentsData = assistantSegmentsData
        model.openAIResponsesConversationItemsData = openAIResponsesConversationItemsData
        model.imageAttachmentsData = imageAttachmentsData
        model.isUser = isUser
        model.isActive = isActive
        model.createdAt = createdAt
        model.modelIdentifier = modelIdentifier
        model.apiBaseURL = apiBaseURL
        model.thinkingOptionRawValue = thinkingOptionRawValue
        model.requestID = requestID
        model.providerResponseID = providerResponseID
        model.requestContextFingerprint = requestContextFingerprint
        model.requestUsedPreviousResponseID = requestUsedPreviousResponseID
        model.requestPreviousResponseID = requestPreviousResponseID
        model.streamStartedAt = streamStartedAt
        model.streamFirstTokenAt = streamFirstTokenAt
        model.streamFirstTokenAtSource = streamFirstTokenAtSource
        model.streamCompletedAt = streamCompletedAt
        model.timeToFirstToken = timeToFirstToken
        model.outputTokenCount = outputTokenCount
        model.reasoningOutputTokenCount = reasoningOutputTokenCount
        model.tokensPerSecond = tokensPerSecond
        model.generationRounds = generationRounds
        model.tokenCountSource = tokenCountSource
        model.timeToFirstTokenSource = timeToFirstTokenSource
        model.tokensPerSecondSource = tokensPerSecondSource
        model.finishReasonSource = finishReasonSource

        model.promptMessageCount = promptMessageCount
        model.promptCharacterCount = promptCharacterCount
        model.finishReason = finishReason
        model.errorDescription = errorDescription
        model.toolActivityPlacementsData = toolActivityPlacementsData
        model.transientAssistantSegments = nil
        return model
    }

    func supplementing(_ existing: Self) -> Self {
        var result = self
        result.createdAt = createdAt ?? existing.createdAt
        if generationRounds.isEmpty { result.generationRounds = existing.generationRounds }
        result.assistantSegmentsData = assistantSegmentsData ?? existing.assistantSegmentsData
        result.openAIResponsesConversationItemsData = openAIResponsesConversationItemsData ?? existing.openAIResponsesConversationItemsData
        result.imageAttachmentsData = imageAttachmentsData ?? existing.imageAttachmentsData
        result.modelIdentifier = modelIdentifier ?? existing.modelIdentifier
        result.apiBaseURL = apiBaseURL ?? existing.apiBaseURL
        result.thinkingOptionRawValue = thinkingOptionRawValue ?? existing.thinkingOptionRawValue
        result.requestID = requestID ?? existing.requestID
        result.providerResponseID = providerResponseID ?? existing.providerResponseID
        result.requestContextFingerprint = requestContextFingerprint ?? existing.requestContextFingerprint
        result.requestUsedPreviousResponseID = requestUsedPreviousResponseID ?? existing.requestUsedPreviousResponseID
        result.requestPreviousResponseID = requestPreviousResponseID ?? existing.requestPreviousResponseID
        result.streamStartedAt = streamStartedAt ?? existing.streamStartedAt
        result.streamFirstTokenAt = streamFirstTokenAt ?? existing.streamFirstTokenAt
        result.streamFirstTokenAtSource = streamFirstTokenAtSource ?? existing.streamFirstTokenAtSource
        result.streamCompletedAt = streamCompletedAt ?? existing.streamCompletedAt
        result.timeToFirstToken = timeToFirstToken ?? existing.timeToFirstToken
        result.outputTokenCount = outputTokenCount ?? existing.outputTokenCount
        result.reasoningOutputTokenCount = reasoningOutputTokenCount ?? existing.reasoningOutputTokenCount
        result.tokensPerSecond = tokensPerSecond ?? existing.tokensPerSecond
        result.tokenCountSource = tokenCountSource ?? existing.tokenCountSource
        result.timeToFirstTokenSource = timeToFirstTokenSource ?? existing.timeToFirstTokenSource
        result.tokensPerSecondSource = tokensPerSecondSource ?? existing.tokensPerSecondSource
        result.finishReasonSource = finishReasonSource ?? existing.finishReasonSource
        result.promptMessageCount = promptMessageCount ?? existing.promptMessageCount
        result.promptCharacterCount = promptCharacterCount ?? existing.promptCharacterCount
        result.finishReason = finishReason ?? existing.finishReason
        result.errorDescription = errorDescription ?? existing.errorDescription
        result.toolActivityPlacementsData = toolActivityPlacementsData ?? existing.toolActivityPlacementsData
        return result
    }
}

nonisolated struct AppSettingsBackup: Equatable, Sendable {
    var id: UUID
    var serverAddress: String
    var textLang: String
    var modelId: String
    var language: String
    var autoSplit: String
    var apiURL: String
    var selectedModel: String
    var selectedChatServerPresetID: UUID?
    var selectedVoiceServerPresetID: UUID?
    var enableStreaming: Bool
    var ttsProviderRawValue: String
    var appleSpeechVoiceIdentifier: String?
    var personalVoiceIdentifier: String?
    var developerModeEnabled: Bool
    var hapticFeedbackEnabled: Bool
    var selectedPresetID: UUID?
    var selectedNormalSystemPromptPresetID: UUID?
    var selectedVoiceSystemPromptPresetID: UUID?
    var modelThinkingPreferencesJSON: String?
    var modelThinkingOptionsJSON: String?
    var detectedAPIFormatsJSON: String?
    var modelImageInputOverrideJSON: String?
    var apiAdvancedSettingsJSON: String?
    var toolUseSettingsJSON: String?

    init(_ model: AppSettings) {
        id = model.id
        serverAddress = model.serverAddress
        textLang = model.textLang
        modelId = model.modelId
        language = model.language
        autoSplit = model.autoSplit
        apiURL = model.apiURL
        selectedModel = model.selectedModel
        selectedChatServerPresetID = model.selectedChatServerPresetID
        selectedVoiceServerPresetID = model.selectedVoiceServerPresetID
        enableStreaming = model.enableStreaming
        ttsProviderRawValue = model.ttsProviderRawValue
        appleSpeechVoiceIdentifier = model.appleSpeechVoiceIdentifier
        personalVoiceIdentifier = model.personalVoiceIdentifier
        developerModeEnabled = model.developerModeEnabled
        hapticFeedbackEnabled = model.hapticFeedbackEnabled
        selectedPresetID = model.selectedPresetID
        selectedNormalSystemPromptPresetID = model.selectedNormalSystemPromptPresetID
        selectedVoiceSystemPromptPresetID = model.selectedVoiceSystemPromptPresetID
        modelThinkingPreferencesJSON = model.modelThinkingPreferencesJSON
        modelThinkingOptionsJSON = model.modelThinkingOptionsJSON
        detectedAPIFormatsJSON = model.detectedAPIFormatsJSON
        modelImageInputOverrideJSON = model.modelImageInputOverrideJSON
        apiAdvancedSettingsJSON = model.apiAdvancedSettingsJSON
        toolUseSettingsJSON = model.toolUseSettingsJSON
    }

    func makeModel() -> AppSettings {
        let model = AppSettings()
        model.id = id
        model.serverAddress = serverAddress
        model.textLang = textLang
        model.modelId = modelId
        model.language = language
        model.autoSplit = autoSplit
        model.apiURL = apiURL
        model.selectedModel = selectedModel
        model.selectedChatServerPresetID = selectedChatServerPresetID
        model.selectedVoiceServerPresetID = selectedVoiceServerPresetID
        model.enableStreaming = enableStreaming
        model.ttsProviderRawValue = ttsProviderRawValue
        model.appleSpeechVoiceIdentifier = appleSpeechVoiceIdentifier
        model.personalVoiceIdentifier = personalVoiceIdentifier
        model.developerModeEnabled = developerModeEnabled
        model.hapticFeedbackEnabled = hapticFeedbackEnabled
        model.selectedPresetID = selectedPresetID
        model.selectedNormalSystemPromptPresetID = selectedNormalSystemPromptPresetID
        model.selectedVoiceSystemPromptPresetID = selectedVoiceSystemPromptPresetID
        model.modelThinkingPreferencesJSON = modelThinkingPreferencesJSON
        model.modelThinkingOptionsJSON = modelThinkingOptionsJSON
        model.detectedAPIFormatsJSON = detectedAPIFormatsJSON
        model.modelImageInputOverrideJSON = modelImageInputOverrideJSON
        model.apiAdvancedSettingsJSON = apiAdvancedSettingsJSON
        model.toolUseSettingsJSON = toolUseSettingsJSON
        return model
    }
}

nonisolated struct ChatServerPresetBackup: Equatable, Sendable {
    var id: UUID
    var name: String
    var apiURL: String
    var selectedModel: String
    var apiFormatPreferenceRaw: String?
    var createdAt: Date
    var updatedAt: Date

    init(_ model: ChatServerPreset) {
        id = model.id
        name = model.name
        apiURL = model.apiURL
        selectedModel = model.selectedModel
        apiFormatPreferenceRaw = model.apiFormatPreferenceRaw
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    func makeModel() -> ChatServerPreset {
        let model = ChatServerPreset(name: name)
        model.id = id
        model.name = name
        model.apiURL = apiURL
        model.selectedModel = selectedModel
        model.apiFormatPreferenceRaw = apiFormatPreferenceRaw
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        return model
    }
}

nonisolated struct VoiceServerPresetBackup: Equatable, Sendable {
    var id: UUID
    var name: String
    var serverAddress: String
    var createdAt: Date
    var updatedAt: Date

    init(_ model: VoiceServerPreset) {
        id = model.id
        name = model.name
        serverAddress = model.serverAddress
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    func makeModel() -> VoiceServerPreset {
        let model = VoiceServerPreset(name: name)
        model.id = id
        model.name = name
        model.serverAddress = serverAddress
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        return model
    }
}

nonisolated struct VoicePresetBackup: Equatable, Sendable {
    var id: UUID
    var name: String
    var refAudioPath: String
    var promptText: String
    var promptLang: String
    var gptWeightsPath: String
    var sovitsWeightsPath: String
    var createdAt: Date
    var updatedAt: Date

    init(_ model: VoicePreset) {
        id = model.id
        name = model.name
        refAudioPath = model.refAudioPath
        promptText = model.promptText
        promptLang = model.promptLang
        gptWeightsPath = model.gptWeightsPath
        sovitsWeightsPath = model.sovitsWeightsPath
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    func makeModel() -> VoicePreset {
        let model = VoicePreset(name: name)
        model.id = id
        model.name = name
        model.refAudioPath = refAudioPath
        model.promptText = promptText
        model.promptLang = promptLang
        model.gptWeightsPath = gptWeightsPath
        model.sovitsWeightsPath = sovitsWeightsPath
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        return model
    }
}

nonisolated struct SystemPromptPresetBackup: Equatable, Sendable {
    var id: UUID
    var name: String
    var mode: String?
    var normalPrompt: String
    var voicePrompt: String
    var createdAt: Date
    var updatedAt: Date

    init(_ model: SystemPromptPreset) {
        id = model.id
        name = model.name
        mode = model.mode
        normalPrompt = model.normalPrompt
        voicePrompt = model.voicePrompt
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    func makeModel() -> SystemPromptPreset {
        let model = SystemPromptPreset(name: name)
        model.id = id
        model.name = name
        model.mode = mode
        model.normalPrompt = normalPrompt
        model.voicePrompt = voicePrompt
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        return model
    }
}
