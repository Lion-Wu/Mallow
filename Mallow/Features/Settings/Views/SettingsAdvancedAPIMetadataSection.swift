//
//  SettingsAdvancedAPIMetadataSection.swift
//  Mallow
//
//  Created by Codex on 2026/6/14.
//

import SwiftUI

struct SettingsAdvancedAPIMetadataSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var settingsManager: SettingsManager

    private var context: SettingsAdvancedAPIContext {
        SettingsAdvancedAPIContext(
            viewModel: viewModel,
            settingsManager: settingsManager
        )
    }

    var body: some View {
        Section {
            SettingsAdvancedAPIMetadataRow("MODEL_PROVIDER", context.currentProvider.displayName)
            SettingsAdvancedAPIMetadataRow("MESSAGE_REQUEST_STYLE", context.currentRequestStyleDisplayName)
            SettingsAdvancedAPIMetadataRow("SETTINGS_API_FORMAT", context.selectedAPIFormatDisplayName)
            SettingsAdvancedAPIMetadataRow("MODEL_FETCHED_LIST", "\(viewModel.availableModels.count)")
            if let endpoint = viewModel.lastModelFetchEndpoint {
                SettingsAdvancedAPIMetadataRow("SETTINGS_MODELS_ENDPOINT", endpoint.modelsURL.absoluteString)
                SettingsAdvancedAPIMetadataRow("SETTINGS_CHAT_ENDPOINT", endpoint.chatURL.absoluteString)
            } else {
                SettingsAdvancedAPIMetadataRow("SETTINGS_MODELS_ENDPOINT", String(localized: "MODEL_NOT_FETCHED", defaultValue: "Not fetched"))
            }

            if let metadata = context.selectedModelMetadata {
                SettingsAdvancedAPISelectedModelMetadataDisclosure(
                    metadata: metadata,
                    context: context
                )
            }

            if !viewModel.lastFetchedModelMetadata.isEmpty {
                SettingsAdvancedAPIFetchedModelsMetadataDisclosure(
                    models: viewModel.lastFetchedModelMetadata,
                    context: context
                )
            }
        } header: {
            SettingsAdvancedAPISectionHeader(title: "MODEL_LIST_METADATA")
        }
    }
}

private struct SettingsAdvancedAPISelectedModelMetadataDisclosure: View {
    let metadata: ModelInfo
    let context: SettingsAdvancedAPIContext

    var body: some View {
        DisclosureGroup("MODEL_SELECTED_METADATA") {
            SettingsAdvancedAPIMetadataRow("COMMON_ID", metadata.id)
            SettingsAdvancedAPIMetadataRow("DATA_OBJECT", metadata.object ?? context.localizedUnknown)
            SettingsAdvancedAPIMetadataRow("DATA_OWNER", metadata.owned_by ?? context.localizedUnknown)
            SettingsAdvancedAPIMetadataRow("COMMON_TYPE", metadata.type ?? metadata.arch ?? context.localizedUnknown)
            SettingsAdvancedAPIMetadataRow(
                "MODEL_INPUT_MODALITIES",
                context.joined(
                    metadata.architecture?.input_modalities ??
                        metadata.input_modalities ??
                        metadata.capabilities?.input_modalities
                )
            )
            SettingsAdvancedAPIMetadataRow("MODEL_MODALITIES", context.joined(metadata.modalities ?? metadata.capabilities?.modalities))
            SettingsAdvancedAPIMetadataRow("MODEL_SUPPORTED_PARAMETERS", context.joined(metadata.supported_parameters ?? metadata.capabilities?.supported_parameters))
            SettingsAdvancedAPIMetadataRow("MODEL_IMAGE_INPUT", context.optionalBool(metadata.supportsImageInputHint))
            if let thinking = metadata.thinkingCapabilityHint(
                provider: context.currentProvider,
                requestStyle: context.currentRequestStyle
            ) {
                SettingsAdvancedAPIMetadataRow(
                    "THINKING_OPTIONS",
                    thinking.hasKnownOptions
                        ? context.joined(thinking.options.filter { $0 != .serverDefault }.map(\.rawValue))
                        : String(localized: "COMMON_NOT_DETECTED", defaultValue: "Not detected")
                )
                SettingsAdvancedAPIMetadataRow("THINKING_PARAMETER", thinking.requestParameter?.rawValue ?? String(localized: "SETTINGS_PROVIDER_DEFAULT", defaultValue: "Provider default"))
            } else {
                SettingsAdvancedAPIMetadataRow("THINKING_OPTIONS", String(localized: "COMMON_NOT_DETECTED", defaultValue: "Not detected"))
            }
            SettingsAdvancedAPIRawJSONBlock(
                title: "MODEL_RAW_JSON",
                value: metadata.rawMetadata
            )
        }
    }
}

private struct SettingsAdvancedAPIFetchedModelsMetadataDisclosure: View {
    let models: [ModelInfo]
    let context: SettingsAdvancedAPIContext

    var body: some View {
        DisclosureGroup("MODEL_FETCHED_METADATA") {
            ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                SettingsAdvancedAPIFetchedModelMetadataDisclosure(
                    model: model,
                    context: context
                )
            }
        }
    }
}

private struct SettingsAdvancedAPIFetchedModelMetadataDisclosure: View {
    let model: ModelInfo
    let context: SettingsAdvancedAPIContext

    var body: some View {
        DisclosureGroup(model.id) {
            SettingsAdvancedAPIMetadataRow("DATA_OBJECT", model.object ?? context.localizedUnknown)
            SettingsAdvancedAPIMetadataRow("DATA_OWNER", model.owned_by ?? context.localizedUnknown)
            SettingsAdvancedAPIMetadataRow("COMMON_TYPE", model.type ?? model.arch ?? context.localizedUnknown)
            SettingsAdvancedAPIMetadataRow(
                "MODEL_INPUT_MODALITIES",
                context.joined(
                    model.architecture?.input_modalities ??
                        model.input_modalities ??
                        model.capabilities?.input_modalities
                )
            )
            SettingsAdvancedAPIMetadataRow("MODEL_SUPPORTED_PARAMETERS", context.joined(model.supported_parameters ?? model.capabilities?.supported_parameters))
            SettingsAdvancedAPIMetadataRow("MODEL_IMAGE_INPUT", context.optionalBool(model.supportsImageInputHint))
            SettingsAdvancedAPIRawJSONBlock(
                title: "METADATA_RAW_JSON",
                value: model.rawMetadata
            )
        }
    }
}

private struct SettingsAdvancedAPIRawJSONBlock: View {
    let title: LocalizedStringKey
    let value: JSONValue?

    var body: some View {
        RawJSONPreviewBlock(
            title: title,
            value: value,
            missingText: String(localized: "METADATA_NOT_CAPTURED", defaultValue: "Raw metadata was not captured.")
        )
    }
}
