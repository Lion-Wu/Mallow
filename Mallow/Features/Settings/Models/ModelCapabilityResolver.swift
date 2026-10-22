import Foundation

enum ModelCapabilityResolver {
    static let manualThinkingOptions: [ModelThinkingOption] = [
        .off, .on, .minimal, .low, .medium, .high, .xhigh, .max, .ultra
    ]

    static func applyingManualThinkingOptions(
        _ options: [ModelThinkingOption],
        to reported: ModelThinkingCapability?,
        style: ChatRequestStyle
    ) -> ModelThinkingCapability {
        var capability = reported ?? ModelThinkingCapability(options: [], hasKnownOptions: false)
        let selectedOptions = options.filter {
            manualThinkingOptions.contains($0) && (capability.allowsDisabling != false || !$0.isDisabled)
        }
        capability.options = [.serverDefault] + selectedOptions
        capability.hasKnownOptions = true
        if style == .anthropicMessages {
            let reportedModes = reported?.anthropicThinkingModes ?? []
            let usesAdaptiveOn = reportedModes.contains("adaptive") && !reportedModes.contains("enabled")
            capability.anthropicThinkingModes = ["disabled", "enabled", "adaptive"].filter { mode in
                switch mode {
                case "disabled": selectedOptions.contains(.off)
                case "enabled": selectedOptions.contains(.on) && !usesAdaptiveOn
                default: selectedOptions.contains(where: \.isEffortLevel) || (selectedOptions.contains(.on) && usesAdaptiveOn)
                }
            }
            capability.anthropicEfforts = capability.options.filter(\.isEffortLevel)
        }
        return capability
    }
}
