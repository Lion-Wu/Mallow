//
//  SettingsAdvancedAPIParameterControls.swift
//  Mallow
//
//  Created by Codex on 2026/6/14.
//

import SwiftUI

struct SettingsAdvancedAPIParameterControls: View {
    @ObservedObject var viewModel: SettingsViewModel
    let profile: SettingsAdvancedAPIParameterProfile

    private var showsAnthropicFixedBudget: Bool {
        let mode = viewModel.apiAdvancedSettings.anthropicThinkingModeOverride
        if !mode.isEmpty { return mode == "enabled" }
        return viewModel.selectedModelThinkingCapability?.anthropicThinkingModes?.contains("enabled") == true
    }

    var body: some View {
        switch profile {
        case .openAIResponses:
            SettingsAdvancedAPIIntegerField(
                title: "SETTINGS_PARAMETER_MAX_OUTPUT_TOKENS",
                value: $viewModel.apiAdvancedSettings.openAIResponsesMaxOutputTokens
            )
            SettingsAdvancedAPISamplingControls(
                sampling: $viewModel.apiAdvancedSettings.openAIResponsesSampling,
                includePenalties: false,
                includeSeed: false,
                includeJSONMode: true,
                includeLogprobs: false
            )
            SettingsAdvancedAPIVerbosityControl(
                sampling: $viewModel.apiAdvancedSettings.openAIResponsesSampling,
                title: "SETTINGS_PARAMETER_TEXT_VERBOSITY",
                options: ["low", "medium", "high"]
            )
        case .openAIChat:
            SettingsAdvancedAPIIntegerField(
                title: "SETTINGS_PARAMETER_MAX_COMPLETION_TOKENS",
                value: $viewModel.apiAdvancedSettings.openAIChatMaxCompletionTokens
            )
            SettingsAdvancedAPISamplingControls(sampling: $viewModel.apiAdvancedSettings.openAIChatSampling)
        case .anthropic:
            SettingsAdvancedAPIIntegerToggleField(
                title: "SETTINGS_PARAMETER_MAX_TOKENS",
                enabled: $viewModel.apiAdvancedSettings.anthropicMaxTokensEnabled,
                value: $viewModel.apiAdvancedSettings.anthropicMaxTokens
            )
            Picker("THINKING_TYPE", selection: $viewModel.apiAdvancedSettings.anthropicThinkingModeOverride) {
                Text("COMMON_DEFAULT").tag("")
                Text(verbatim: "disabled").tag("disabled")
                Text(verbatim: "adaptive").tag("adaptive")
                Text(verbatim: "enabled").tag("enabled")
            }
            if showsAnthropicFixedBudget {
                SettingsAdvancedAPIIntegerToggleField(
                    title: "THINKING_BUDGET_TOKENS",
                    enabled: $viewModel.apiAdvancedSettings.anthropicThinkingBudgetEnabled,
                    value: $viewModel.apiAdvancedSettings.anthropicThinkingBudget
                )
                if !viewModel.apiAdvancedSettings.anthropicThinkingBudgetEnabled {
                    Text("THINKING_BUDGET_AUTOMATIC")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.apiAdvancedSettings.anthropicThinkingModeOverride == "adaptive" {
                TextField("THINKING_OUTPUT_EFFORT", text: $viewModel.apiAdvancedSettings.anthropicEffortOverride,
                          prompt: Text("COMMON_DEFAULT"))
            }
            SettingsAdvancedAPISamplingControls(
                sampling: $viewModel.apiAdvancedSettings.anthropicSampling,
                includeTopK: true,
                includePenalties: false,
                includeSeed: false,
                includeJSONMode: false,
                includeLogprobs: false
            )
        case .lmStudioREST:
            SettingsAdvancedAPIIntegerField(
                title: "SETTINGS_PARAMETER_MAX_OUTPUT_TOKENS",
                value: $viewModel.apiAdvancedSettings.lmStudioMaxTokens
            )
            SettingsAdvancedAPIIntegerToggleField(
                title: "SETTINGS_PARAMETER_CONTEXT_LENGTH",
                enabled: $viewModel.apiAdvancedSettings.lmStudioSampling.contextLengthEnabled,
                value: $viewModel.apiAdvancedSettings.lmStudioSampling.contextLength
            )
            SettingsAdvancedAPISamplingControls(
                sampling: $viewModel.apiAdvancedSettings.lmStudioSampling,
                includeTopK: true,
                includeMinP: true,
                includePenalties: false,
                includeRepetitionPenalty: true,
                repetitionPenaltyTitle: "SETTINGS_PARAMETER_REPEAT_PENALTY",
                includeSeed: false,
                includeJSONMode: false,
                includeLogprobs: false
            )
        }
    }
}

struct SettingsAdvancedAPISamplingControls: View {
    @Binding var sampling: APIAdvancedSamplingSettings
    var includeTopK = false
    var includeMinP = false
    var includeTopA = false
    var includePenalties = true
    var includeRepetitionPenalty = false
    var repetitionPenaltyTitle: LocalizedStringKey = "SETTINGS_PARAMETER_REPETITION_PENALTY"
    var includeSeed = true
    var includeJSONMode = true
    var includeStructuredOutputs = false
    var includeLogprobs = true

    var body: some View {
        SettingsAdvancedAPIDoubleToggleField(
            title: "SETTINGS_PARAMETER_TEMPERATURE",
            enabled: $sampling.temperatureEnabled,
            value: $sampling.temperature
        )
        SettingsAdvancedAPIDoubleToggleField(
            title: "SETTINGS_PARAMETER_TOP_P",
            enabled: $sampling.topPEnabled,
            value: $sampling.topP
        )
        if includeTopK {
            SettingsAdvancedAPIIntegerToggleField(
                title: "SETTINGS_PARAMETER_TOP_K",
                enabled: $sampling.topKEnabled,
                value: $sampling.topK
            )
        }
        if includeMinP {
            SettingsAdvancedAPIDoubleToggleField(
                title: "SETTINGS_PARAMETER_MIN_P",
                enabled: $sampling.minPEnabled,
                value: $sampling.minP
            )
        }
        if includeTopA {
            SettingsAdvancedAPIDoubleToggleField(
                title: "SETTINGS_PARAMETER_TOP_A",
                enabled: $sampling.topAEnabled,
                value: $sampling.topA
            )
        }
        if includePenalties {
            SettingsAdvancedAPIDoubleToggleField(
                title: "SETTINGS_PARAMETER_PRESENCE_PENALTY",
                enabled: $sampling.presencePenaltyEnabled,
                value: $sampling.presencePenalty
            )
            SettingsAdvancedAPIDoubleToggleField(
                title: "SETTINGS_PARAMETER_FREQUENCY_PENALTY",
                enabled: $sampling.frequencyPenaltyEnabled,
                value: $sampling.frequencyPenalty
            )
        }
        if includeRepetitionPenalty {
            SettingsAdvancedAPIDoubleToggleField(
                title: repetitionPenaltyTitle,
                enabled: $sampling.repetitionPenaltyEnabled,
                value: $sampling.repetitionPenalty
            )
        }
        if includeSeed {
            SettingsAdvancedAPIIntegerToggleField(
                title: "SETTINGS_PARAMETER_SEED",
                enabled: $sampling.seedEnabled,
                value: $sampling.seed
            )
        }
        if includeJSONMode {
            SettingsAdvancedAPIBooleanToggleField(
                title: "SETTINGS_JSON_MODE",
                isOn: $sampling.jsonModeEnabled
            )
        }
        if includeStructuredOutputs {
            SettingsAdvancedAPIBooleanToggleField(
                title: "SETTINGS_PARAMETER_STRUCTURED_OUTPUTS",
                isOn: $sampling.structuredOutputsEnabled
            )
        }
        if includeLogprobs {
            SettingsAdvancedAPIBooleanToggleField(
                title: "SETTINGS_PARAMETER_LOGPROBS",
                isOn: $sampling.logprobsEnabled
            )
            if sampling.logprobsEnabled {
                SettingsAdvancedAPIIntegerToggleField(
                    title: "SETTINGS_PARAMETER_TOP_LOGPROBS",
                    enabled: $sampling.topLogprobsEnabled,
                    value: $sampling.topLogprobs
                )
            }
        }
    }
}
