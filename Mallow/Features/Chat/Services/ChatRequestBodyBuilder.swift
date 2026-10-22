//
//  ChatRequestBodyBuilder.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import Foundation

protocol ChatRequestBodyBuilding: Sendable {
    func buildRequestBodyData(
        model: String,
        messagePayload: [[String: Any]],
        developerPrompt: String?,
        endpoint: ChatAPIEndpointCandidate,
        apiAdvancedSettings: APIAdvancedSettings,
        toolUseSettings: ToolUseSettings,
        previousResponseID: String?,
        thinkingCapability: ModelThinkingCapability?,
        thinkingOption: ModelThinkingOption?
    ) throws -> Data
}

struct ChatRequestBodyBuilder: ChatRequestBodyBuilding, Sendable {
    private let advancedConfigurationApplier: ChatRequestAdvancedConfigurationApplier
    private let thinkingConfigurationApplier: ChatRequestThinkingConfigurationApplier

    init(
        advancedConfigurationApplier: ChatRequestAdvancedConfigurationApplier = ChatRequestAdvancedConfigurationApplier(),
        thinkingConfigurationApplier: ChatRequestThinkingConfigurationApplier = ChatRequestThinkingConfigurationApplier()
    ) {
        self.advancedConfigurationApplier = advancedConfigurationApplier
        self.thinkingConfigurationApplier = thinkingConfigurationApplier
    }

    func buildRequestBodyData(
        model: String,
        messagePayload: [[String: Any]],
        developerPrompt: String?,
        endpoint: ChatAPIEndpointCandidate,
        apiAdvancedSettings: APIAdvancedSettings,
        toolUseSettings: ToolUseSettings = .defaults,
        previousResponseID: String? = nil,
        thinkingCapability: ModelThinkingCapability?,
        thinkingOption: ModelThinkingOption?
    ) throws -> Data {
        let settings = apiAdvancedSettings.sanitized
        let effectivePreviousResponseID = toolUseSettings.useProviderContinuationIDs(for: endpoint)
            ? ChatRequestBodyProviderEncoder.normalizedPreviousResponseID(previousResponseID, endpoint: endpoint)
            : nil
        var requestBody = ChatRequestBodyProviderEncoder.makeBaseRequestBody(
            model: model,
            messagePayload: messagePayload,
            developerPrompt: developerPrompt,
            endpoint: endpoint,
            apiAdvancedSettings: settings,
            previousResponseID: effectivePreviousResponseID
        )
        if endpoint.style == .anthropicMessages, !settings.anthropicMaxTokensEnabled,
           let maximum = thinkingCapability?.maxOutputTokens {
            requestBody["max_tokens"] = maximum
        }
        advancedConfigurationApplier.apply(to: &requestBody, model: model, endpoint: endpoint, settings: settings)
        thinkingConfigurationApplier.apply(
            to: &requestBody,
            model: model,
            endpoint: endpoint,
            settings: settings,
            thinkingCapability: thinkingCapability,
            thinkingOption: thinkingOption
        )
        ChatToolSchemaEncoder.applyToolSchemas(
            to: &requestBody,
            endpoint: endpoint,
            settings: toolUseSettings,
            previousResponseID: effectivePreviousResponseID,
            allowedToolIDs: nil
        )
        ChatToolResultMessageEncoder.applyResponsesPreviousResponseID(
            effectivePreviousResponseID,
            to: &requestBody,
            endpoint: endpoint
        )
        return try JSONSerialization.data(withJSONObject: requestBody, options: [.sortedKeys])
    }
}
