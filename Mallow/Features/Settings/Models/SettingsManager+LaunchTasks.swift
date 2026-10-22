//
//  SettingsManager+LaunchTasks.swift
//  Mallow
//
//  Created by OpenAI on 2026.06.14.
//

import Foundation

extension SettingsManager {
    func applyPresetOnLaunchIfNeeded() async {
        await presetApplyController.applyOnLaunchIfNeeded {
            selectedPresetApplyRequest()
        }
    }

    func fetchAvailableChatModels(forceRefresh: Bool = false) {
        let requestedSettings = chatSettings
        let requestedFormat = chatModelCapabilities.selectedChatAPIFormatPreference()
        let isSameCatalog = modelCatalogController.requestedCatalog?.matches(
            settings: requestedSettings,
            format: requestedFormat
        ) == true
        guard forceRefresh || !isSameCatalog else { return }

        readyChatModelCatalog = nil
        let rawBase = requestedSettings.apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        modelCatalogController.fetch(
            request: SettingsModelCatalogRequest(
                apiURL: rawBase,
                apiKey: requestedSettings.apiKey,
                formatPreference: requestedFormat,
                detectedProvider: chatModelCapabilities.detectedProvider(for: rawBase),
                selectedModel: requestedSettings.selectedModel,
                detectedStyle: chatModelCapabilities.detectedRequestStyle(for: rawBase)
            ),
            currentState: isSameCatalog ? chatModelCatalogState : .empty,
            applyState: { [weak self] state in
                self?.chatModelCatalogState = state
            },
            applyDetection: { [weak self] detection in
                guard let self else { return }
                let catalog = ChatModelCatalogReadiness(
                    apiURL: rawBase,
                    apiKey: requestedSettings.apiKey,
                    formatPreference: requestedFormat,
                    modelIDs: detection.result.modelIDs
                )
                guard catalog.matches(
                    settings: self.chatSettings,
                    format: self.chatModelCapabilities.selectedChatAPIFormatPreference()
                ) else { return }

                let result = detection.result
                self.chatModelCapabilities.noteDetectedEndpoint(result.endpoint, for: rawBase)
                self.chatModelCapabilities.updateImageInputSupport(result.imageInputSupportByModelID, for: rawBase)
                self.chatModelCapabilities.updateThinkingCapabilities(result.thinkingCapabilitiesByModelID, for: rawBase)
                if !result.modelIDs.contains(self.chatSettings.selectedModel),
                   let firstModel = result.modelIDs.first {
                    self.updateChatSettings(apiURL: self.chatSettings.apiURL, selectedModel: firstModel)
                }
                self.readyChatModelCatalog = catalog
            }
        )
    }

    func applySelectedPreset() async {
        await presetApplyController.apply(selectedPresetApplyRequest())
    }
}
