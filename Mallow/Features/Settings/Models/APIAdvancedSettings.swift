//
//  APIAdvancedSettings.swift
//  Mallow
//
//  Created by Lion Wu on 2024.09.29.
//

import Foundation

struct APIAdvancedSettings: Codable, Equatable, Sendable {
    static let defaults = APIAdvancedSettings()

    var openAIResponsesMaxOutputTokens: Int
    var openAIResponsesSampling: APIAdvancedSamplingSettings
    var openAIChatMaxCompletionTokens: Int
    var openAIChatSampling: APIAdvancedSamplingSettings
    var lmStudioMaxTokens: Int
    var lmStudioSampling: APIAdvancedSamplingSettings
    var anthropicMaxTokens: Int
    var anthropicSampling: APIAdvancedSamplingSettings
    static let anthropicDefaultMaxTokens = 32_000
    var anthropicMaxTokensEnabled: Bool
    var anthropicThinkingModeOverride: String
    var anthropicThinkingBudgetEnabled: Bool
    var anthropicThinkingBudget: Int
    var anthropicEffortOverride: String

    init(
        openAIResponsesMaxOutputTokens: Int = 0,
        openAIResponsesSampling: APIAdvancedSamplingSettings = .defaults,
        openAIChatMaxCompletionTokens: Int = 0,
        openAIChatSampling: APIAdvancedSamplingSettings = .defaults,
        lmStudioMaxTokens: Int = 0,
        lmStudioSampling: APIAdvancedSamplingSettings = .defaults,
        anthropicMaxTokens: Int = Self.anthropicDefaultMaxTokens,
        anthropicSampling: APIAdvancedSamplingSettings = .defaults,
        anthropicMaxTokensEnabled: Bool = false,
        anthropicThinkingModeOverride: String = "",
        anthropicThinkingBudgetEnabled: Bool = false,
        anthropicThinkingBudget: Int = Self.anthropicDefaultMaxTokens - 1,
        anthropicEffortOverride: String = ""
    ) {
        self.openAIResponsesMaxOutputTokens = openAIResponsesMaxOutputTokens
        self.openAIResponsesSampling = openAIResponsesSampling
        self.openAIChatMaxCompletionTokens = openAIChatMaxCompletionTokens
        self.openAIChatSampling = openAIChatSampling
        self.lmStudioMaxTokens = lmStudioMaxTokens
        self.lmStudioSampling = lmStudioSampling
        self.anthropicMaxTokens = anthropicMaxTokens
        self.anthropicSampling = anthropicSampling
        self.anthropicMaxTokensEnabled = anthropicMaxTokensEnabled
        self.anthropicThinkingModeOverride = anthropicThinkingModeOverride
        self.anthropicThinkingBudgetEnabled = anthropicThinkingBudgetEnabled
        self.anthropicThinkingBudget = anthropicThinkingBudget
        self.anthropicEffortOverride = anthropicEffortOverride
    }

    var sanitized: APIAdvancedSettings {
        APIAdvancedSettings(
            openAIResponsesMaxOutputTokens: max(0, openAIResponsesMaxOutputTokens),
            openAIResponsesSampling: openAIResponsesSampling.sanitized,
            openAIChatMaxCompletionTokens: max(0, openAIChatMaxCompletionTokens),
            openAIChatSampling: openAIChatSampling.sanitized,
            lmStudioMaxTokens: max(0, lmStudioMaxTokens),
            lmStudioSampling: lmStudioSampling.sanitized,
            anthropicMaxTokens: anthropicMaxTokens,
            anthropicSampling: anthropicSampling,
            anthropicMaxTokensEnabled: anthropicMaxTokensEnabled,
            anthropicThinkingModeOverride: anthropicThinkingModeOverride,
            anthropicThinkingBudgetEnabled: anthropicThinkingBudgetEnabled,
            anthropicThinkingBudget: anthropicThinkingBudget,
            anthropicEffortOverride: anthropicEffortOverride
        )
    }

    private enum CodingKeys: String, CodingKey {
        case openAIResponsesMaxOutputTokens
        case openAIResponsesSampling
        case openAIChatMaxCompletionTokens
        case openAIChatSampling
        case lmStudioMaxTokens
        case lmStudioSampling
        case anthropicMaxTokens
        case anthropicSampling
        case anthropicMaxTokensEnabled
        case anthropicThinkingModeOverride
        case anthropicThinkingBudgetEnabled
        case anthropicThinkingBudget
        case anthropicEffortOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        openAIResponsesMaxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .openAIResponsesMaxOutputTokens) ?? openAIResponsesMaxOutputTokens
        openAIResponsesSampling = try container.decodeIfPresent(APIAdvancedSamplingSettings.self, forKey: .openAIResponsesSampling) ?? openAIResponsesSampling
        openAIChatMaxCompletionTokens = try container.decodeIfPresent(Int.self, forKey: .openAIChatMaxCompletionTokens) ?? openAIChatMaxCompletionTokens
        openAIChatSampling = try container.decodeIfPresent(APIAdvancedSamplingSettings.self, forKey: .openAIChatSampling) ?? openAIChatSampling
        lmStudioMaxTokens = try container.decodeIfPresent(Int.self, forKey: .lmStudioMaxTokens) ?? lmStudioMaxTokens
        lmStudioSampling = try container.decodeIfPresent(APIAdvancedSamplingSettings.self, forKey: .lmStudioSampling) ?? lmStudioSampling
        anthropicMaxTokens = try container.decodeIfPresent(Int.self, forKey: .anthropicMaxTokens) ?? anthropicMaxTokens
        anthropicSampling = try container.decodeIfPresent(APIAdvancedSamplingSettings.self, forKey: .anthropicSampling) ?? anthropicSampling
        anthropicMaxTokensEnabled = try container.decodeIfPresent(Bool.self, forKey: .anthropicMaxTokensEnabled) ?? anthropicMaxTokensEnabled
        anthropicThinkingModeOverride = try container.decodeIfPresent(String.self, forKey: .anthropicThinkingModeOverride) ?? anthropicThinkingModeOverride
        anthropicThinkingBudgetEnabled = try container.decodeIfPresent(Bool.self, forKey: .anthropicThinkingBudgetEnabled) ?? anthropicThinkingBudgetEnabled
        anthropicThinkingBudget = try container.decodeIfPresent(Int.self, forKey: .anthropicThinkingBudget) ?? anthropicThinkingBudget
        anthropicEffortOverride = try container.decodeIfPresent(String.self, forKey: .anthropicEffortOverride) ?? anthropicEffortOverride
    }

}

struct APIAdvancedSamplingSettings: Codable, Equatable, Sendable {
    static let defaults = APIAdvancedSamplingSettings()

    var temperatureEnabled: Bool
    var temperature: Double
    var topPEnabled: Bool
    var topP: Double
    var topKEnabled: Bool
    var topK: Int
    var minPEnabled: Bool
    var minP: Double
    var topAEnabled: Bool
    var topA: Double
    var presencePenaltyEnabled: Bool
    var presencePenalty: Double
    var frequencyPenaltyEnabled: Bool
    var frequencyPenalty: Double
    var repetitionPenaltyEnabled: Bool
    var repetitionPenalty: Double
    var seedEnabled: Bool
    var seed: Int
    var contextLengthEnabled: Bool
    var contextLength: Int
    var jsonModeEnabled: Bool
    var structuredOutputsEnabled: Bool
    var logprobsEnabled: Bool
    var topLogprobsEnabled: Bool
    var topLogprobs: Int
    var verbosityEnabled: Bool
    var verbosity: String

    init(
        temperatureEnabled: Bool = false,
        temperature: Double = 1,
        topPEnabled: Bool = false,
        topP: Double = 1,
        topKEnabled: Bool = false,
        topK: Int = 0,
        minPEnabled: Bool = false,
        minP: Double = 0,
        topAEnabled: Bool = false,
        topA: Double = 0,
        presencePenaltyEnabled: Bool = false,
        presencePenalty: Double = 0,
        frequencyPenaltyEnabled: Bool = false,
        frequencyPenalty: Double = 0,
        repetitionPenaltyEnabled: Bool = false,
        repetitionPenalty: Double = 1,
        seedEnabled: Bool = false,
        seed: Int = 0,
        contextLengthEnabled: Bool = false,
        contextLength: Int = 0,
        jsonModeEnabled: Bool = false,
        structuredOutputsEnabled: Bool = false,
        logprobsEnabled: Bool = false,
        topLogprobsEnabled: Bool = false,
        topLogprobs: Int = 0,
        verbosityEnabled: Bool = false,
        verbosity: String = "medium"
    ) {
        self.temperatureEnabled = temperatureEnabled
        self.temperature = temperature
        self.topPEnabled = topPEnabled
        self.topP = topP
        self.topKEnabled = topKEnabled
        self.topK = topK
        self.minPEnabled = minPEnabled
        self.minP = minP
        self.topAEnabled = topAEnabled
        self.topA = topA
        self.presencePenaltyEnabled = presencePenaltyEnabled
        self.presencePenalty = presencePenalty
        self.frequencyPenaltyEnabled = frequencyPenaltyEnabled
        self.frequencyPenalty = frequencyPenalty
        self.repetitionPenaltyEnabled = repetitionPenaltyEnabled
        self.repetitionPenalty = repetitionPenalty
        self.seedEnabled = seedEnabled
        self.seed = seed
        self.contextLengthEnabled = contextLengthEnabled
        self.contextLength = contextLength
        self.jsonModeEnabled = jsonModeEnabled
        self.structuredOutputsEnabled = structuredOutputsEnabled
        self.logprobsEnabled = logprobsEnabled
        self.topLogprobsEnabled = topLogprobsEnabled
        self.topLogprobs = topLogprobs
        self.verbosityEnabled = verbosityEnabled
        self.verbosity = verbosity
    }

    var sanitized: APIAdvancedSamplingSettings {
        APIAdvancedSamplingSettings(
            temperatureEnabled: temperatureEnabled,
            temperature: temperature.clamped(to: 0...2),
            topPEnabled: topPEnabled,
            topP: topP.clamped(to: 0...1),
            topKEnabled: topKEnabled,
            topK: max(0, topK),
            minPEnabled: minPEnabled,
            minP: minP.clamped(to: 0...1),
            topAEnabled: topAEnabled,
            topA: topA.clamped(to: 0...1),
            presencePenaltyEnabled: presencePenaltyEnabled,
            presencePenalty: presencePenalty.clamped(to: -2...2),
            frequencyPenaltyEnabled: frequencyPenaltyEnabled,
            frequencyPenalty: frequencyPenalty.clamped(to: -2...2),
            repetitionPenaltyEnabled: repetitionPenaltyEnabled,
            repetitionPenalty: repetitionPenalty.clamped(to: 0...2),
            seedEnabled: seedEnabled,
            seed: max(0, seed),
            contextLengthEnabled: contextLengthEnabled,
            contextLength: max(0, contextLength),
            jsonModeEnabled: jsonModeEnabled,
            structuredOutputsEnabled: structuredOutputsEnabled,
            logprobsEnabled: logprobsEnabled,
            topLogprobsEnabled: topLogprobsEnabled,
            topLogprobs: max(0, min(topLogprobs, 20)),
            verbosityEnabled: verbosityEnabled,
            verbosity: Self.sanitizedVerbosity(verbosity)
        )
    }

    private static func sanitizedVerbosity(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low":
            return "low"
        case "high":
            return "high"
        case "max":
            return "max"
        default:
            return "medium"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case temperatureEnabled
        case temperature
        case topPEnabled
        case topP
        case topKEnabled
        case topK
        case minPEnabled
        case minP
        case topAEnabled
        case topA
        case presencePenaltyEnabled
        case presencePenalty
        case frequencyPenaltyEnabled
        case frequencyPenalty
        case repetitionPenaltyEnabled
        case repetitionPenalty
        case seedEnabled
        case seed
        case contextLengthEnabled
        case contextLength
        case jsonModeEnabled
        case structuredOutputsEnabled
        case logprobsEnabled
        case topLogprobsEnabled
        case topLogprobs
        case verbosityEnabled
        case verbosity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            temperatureEnabled: try container.decode(Bool.self, forKey: .temperatureEnabled),
            temperature: try container.decode(Double.self, forKey: .temperature),
            topPEnabled: try container.decode(Bool.self, forKey: .topPEnabled),
            topP: try container.decode(Double.self, forKey: .topP),
            topKEnabled: try container.decode(Bool.self, forKey: .topKEnabled),
            topK: try container.decode(Int.self, forKey: .topK),
            minPEnabled: try container.decode(Bool.self, forKey: .minPEnabled),
            minP: try container.decode(Double.self, forKey: .minP),
            topAEnabled: try container.decode(Bool.self, forKey: .topAEnabled),
            topA: try container.decode(Double.self, forKey: .topA),
            presencePenaltyEnabled: try container.decode(Bool.self, forKey: .presencePenaltyEnabled),
            presencePenalty: try container.decode(Double.self, forKey: .presencePenalty),
            frequencyPenaltyEnabled: try container.decode(Bool.self, forKey: .frequencyPenaltyEnabled),
            frequencyPenalty: try container.decode(Double.self, forKey: .frequencyPenalty),
            repetitionPenaltyEnabled: try container.decode(Bool.self, forKey: .repetitionPenaltyEnabled),
            repetitionPenalty: try container.decode(Double.self, forKey: .repetitionPenalty),
            seedEnabled: try container.decode(Bool.self, forKey: .seedEnabled),
            seed: try container.decode(Int.self, forKey: .seed),
            contextLengthEnabled: try container.decode(Bool.self, forKey: .contextLengthEnabled),
            contextLength: try container.decode(Int.self, forKey: .contextLength),
            jsonModeEnabled: try container.decode(Bool.self, forKey: .jsonModeEnabled),
            structuredOutputsEnabled: try container.decode(Bool.self, forKey: .structuredOutputsEnabled),
            logprobsEnabled: try container.decode(Bool.self, forKey: .logprobsEnabled),
            topLogprobsEnabled: try container.decode(Bool.self, forKey: .topLogprobsEnabled),
            topLogprobs: try container.decode(Int.self, forKey: .topLogprobs),
            verbosityEnabled: try container.decode(Bool.self, forKey: .verbosityEnabled),
            verbosity: try container.decode(String.self, forKey: .verbosity)
        )
    }

    func encode(to encoder: Encoder) throws {
        let value = self
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.temperatureEnabled, forKey: .temperatureEnabled)
        try container.encode(value.temperature, forKey: .temperature)
        try container.encode(value.topPEnabled, forKey: .topPEnabled)
        try container.encode(value.topP, forKey: .topP)
        try container.encode(value.topKEnabled, forKey: .topKEnabled)
        try container.encode(value.topK, forKey: .topK)
        try container.encode(value.minPEnabled, forKey: .minPEnabled)
        try container.encode(value.minP, forKey: .minP)
        try container.encode(value.topAEnabled, forKey: .topAEnabled)
        try container.encode(value.topA, forKey: .topA)
        try container.encode(value.presencePenaltyEnabled, forKey: .presencePenaltyEnabled)
        try container.encode(value.presencePenalty, forKey: .presencePenalty)
        try container.encode(value.frequencyPenaltyEnabled, forKey: .frequencyPenaltyEnabled)
        try container.encode(value.frequencyPenalty, forKey: .frequencyPenalty)
        try container.encode(value.repetitionPenaltyEnabled, forKey: .repetitionPenaltyEnabled)
        try container.encode(value.repetitionPenalty, forKey: .repetitionPenalty)
        try container.encode(value.seedEnabled, forKey: .seedEnabled)
        try container.encode(value.seed, forKey: .seed)
        try container.encode(value.contextLengthEnabled, forKey: .contextLengthEnabled)
        try container.encode(value.contextLength, forKey: .contextLength)
        try container.encode(value.jsonModeEnabled, forKey: .jsonModeEnabled)
        try container.encode(value.structuredOutputsEnabled, forKey: .structuredOutputsEnabled)
        try container.encode(value.logprobsEnabled, forKey: .logprobsEnabled)
        try container.encode(value.topLogprobsEnabled, forKey: .topLogprobsEnabled)
        try container.encode(value.topLogprobs, forKey: .topLogprobs)
        try container.encode(value.verbosityEnabled, forKey: .verbosityEnabled)
        try container.encode(value.verbosity, forKey: .verbosity)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
