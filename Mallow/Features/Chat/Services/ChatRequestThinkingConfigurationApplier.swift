//
//  ChatRequestThinkingConfigurationApplier.swift
//  Mallow
//
//  Created by Codex on 2026/6/14.
//

import Foundation

struct ChatRequestThinkingConfigurationApplier: Sendable {
    func apply(
        to requestBody: inout [String: Any],
        model: String,
        endpoint: ChatAPIEndpointCandidate,
        settings: APIAdvancedSettings,
        thinkingCapability: ModelThinkingCapability?,
        thinkingOption: ModelThinkingOption?
    ) {
        if endpoint.style == .anthropicMessages {
            applyAnthropic(to: &requestBody, settings: settings, capability: thinkingCapability,
                           option: thinkingOption)
            return
        }
        guard let option = thinkingOption, option != .serverDefault else { return }
        if let capability = thinkingCapability,
           !capability.isConfigurable {
            return
        }
        let requestParameter = thinkingCapability?.requestParameter

        switch endpoint.style {
        case .lmStudioRESTV1:
            requestBody["reasoning"] = lmStudioReasoningValue(for: option)

        case .anthropicMessages:
            break

        case .openAIResponses:
            requestBody["reasoning"] = [
                "effort": openAIReasoningEffort(for: option, capability: thinkingCapability)
            ]

        case .openAIChatCompletions:
            if let requestParameter {
                switch requestParameter {
                case .reasoningEffort:
                    requestBody["reasoning_effort"] = reasoningEffortValue(
                        for: option,
                        endpoint: endpoint,
                        capability: thinkingCapability
                    )
                case .reasoning:
                    requestBody["reasoning"] = [
                        "effort": reasoningEffortValue(
                            for: option,
                            endpoint: endpoint,
                            capability: thinkingCapability
                        )
                    ]
                case .thinking:
                    requestBody["thinking"] = ["type": option.isDisabled ? "disabled" : "enabled"]
                }
                return
            }

            switch endpoint.provider {
            case .openAI, .lmStudio, .unknown:
                requestBody["reasoning_effort"] = openAIReasoningEffort(
                    for: option,
                    capability: thinkingCapability
                )
            case .anthropic:
                break
            }
        }
    }

    private func reasoningEffortValue(
        for option: ModelThinkingOption,
        endpoint: ChatAPIEndpointCandidate,
        capability: ModelThinkingCapability?
    ) -> String {
        switch endpoint.provider {
        case .openAI, .lmStudio, .unknown, .anthropic:
            return openAIReasoningEffort(for: option, capability: capability)
        }
    }

    private func lmStudioReasoningValue(for option: ModelThinkingOption) -> String {
        if option == .none {
            return "off"
        }
        return option.rawValue
    }

    private func openAIReasoningEffort(
        for option: ModelThinkingOption,
        capability: ModelThinkingCapability?
    ) -> String {
        if option == .off {
            return "none"
        }
        return option.rawValue
    }

    private func applyAnthropic(
        to requestBody: inout [String: Any],
        settings: APIAdvancedSettings,
        capability: ModelThinkingCapability?,
        option: ModelThinkingOption?
    ) {
        guard capability?.options.isEmpty != true else { return }
        let modes = capability?.anthropicThinkingModes ?? []
        let mode: String?
        if !settings.anthropicThinkingModeOverride.isEmpty {
            mode = settings.anthropicThinkingModeOverride
        } else if option?.isDisabled == true, modes.contains("disabled") {
            mode = "disabled"
        } else if let option, option.isEffortLevel,
                  modes.contains("adaptive"),
                  capability?.anthropicEfforts?.contains(option) == true {
            mode = "adaptive"
        } else if option == .on, modes.contains("enabled") {
            mode = "enabled"
        } else if option == .on, modes.contains("adaptive") {
            mode = "adaptive"
        } else {
            mode = nil
        }
        if let mode {
            var thinking: [String: Any] = ["type": mode]
            if mode == "enabled" {
                let maximum = requestBody["max_tokens"] as? Int ?? APIAdvancedSettings.anthropicDefaultMaxTokens
                thinking["budget_tokens"] = settings.anthropicThinkingBudgetEnabled
                    ? settings.anthropicThinkingBudget : maximum - 1
            }
            requestBody["thinking"] = thinking
        }
        guard mode == "adaptive" else { return }
        if settings.anthropicThinkingModeOverride == "adaptive", !settings.anthropicEffortOverride.isEmpty {
            requestBody["output_config"] = ["effort": settings.anthropicEffortOverride]
        } else if let option, option.isEffortLevel,
                  capability?.anthropicEfforts?.contains(option) == true {
            requestBody["output_config"] = ["effort": option.rawValue]
        }
    }
}
