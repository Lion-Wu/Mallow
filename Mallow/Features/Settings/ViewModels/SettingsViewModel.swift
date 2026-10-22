//
//  SettingsViewModel.swift
//  Mallow
//
//  Created by Lion Wu on 2024.10.09.
//

import Foundation
import Combine
import AVFoundation

struct AppleSpeechVoiceOption: Identifiable, Equatable {
    let id: String
    let name: String
    let language: String
    let localizedLanguage: String
    let quality: String
    let isPersonalVoice: Bool

    var displayName: String {
        let kind = isPersonalVoice
            ? NSLocalizedString("VOICE_PROVIDER_APPLE_PERSONAL", value: "Apple Personal Voice", comment: "Apple accessibility Personal Voice label")
            : quality
        return "\(name) — \(localizedLanguage) · \(kind)"
    }

    static func installedVoices(locale: Locale = .current) -> [AppleSpeechVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .map { voice in
                AppleSpeechVoiceOption(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    localizedLanguage: locale.localizedString(forIdentifier: voice.language) ?? voice.language,
                    quality: qualityName(for: voice.quality),
                    isPersonalVoice: voice.voiceTraits.contains(.isPersonalVoice)
                )
            }
            .sorted {
                if $0.isPersonalVoice != $1.isPersonalVoice {
                    return $0.isPersonalVoice
                }
                let languageComparison = $0.localizedLanguage.localizedStandardCompare($1.localizedLanguage)
                if languageComparison == .orderedSame {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return languageComparison == .orderedAscending
            }
    }

    private static func qualityName(for quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium:
            return NSLocalizedString("VOICE_QUALITY_PREMIUM", value: "Premium", comment: "Premium quality Apple speech voice")
        case .enhanced:
            return NSLocalizedString("THINKING_LEVEL_ENHANCED", value: "Enhanced", comment: "Enhanced quality Apple speech voice")
        default:
            return NSLocalizedString("VOICE_QUALITY_STANDARD", value: "Standard", comment: "Standard quality Apple speech voice")
        }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    private var cancellables: Set<AnyCancellable> = []
    let suppression = SettingsViewModelSuppressionController()
    private var didSyncAfterStoreLoad = false

    // MARK: - Settings
    // Text entry is kept as a UI draft and committed on submit/focus loss/settings close.
    // This avoids synchronous SwiftData/Keychain work for every typed character.
    @Published var serverAddress: String
    @Published var textLang: String

    @Published var apiURL: String
    @Published var selectedModel: String {
        didSet {
            guard !suppression.isActive(.autoSaves) else { return }
            commitChatServerEdits()
        }
    }
    @Published var chatAPIKey: String

    @Published var enableStreaming: Bool {
        didSet {
            guard !suppression.isActive(.autoSaves) else { return }
            saveVoiceSettings()
            if enableStreaming {
                // Force `cut0` when streaming is enabled.
                autoSplit = "cut0"
            }
        }
    }
    @Published var ttsProvider: TTSProvider {
        didSet {
            guard !suppression.isActive(.autoSaves) else { return }
            saveVoiceSettings()
            if ttsProvider == .personalVoice {
                activatePersonalVoiceProvider()
            }
        }
    }
    @Published var appleSpeechVoiceIdentifier: String? {
        didSet {
            guard !suppression.isActive(.autoSaves) else { return }
            saveVoiceSettings()
        }
    }
    @Published var personalVoiceIdentifier: String? {
        didSet {
            guard !suppression.isActive(.autoSaves) else { return }
            saveVoiceSettings()
        }
    }
    @Published private(set) var availableAppleSpeechVoices: [AppleSpeechVoiceOption] = []
    @Published private(set) var personalVoiceAuthorizationStatus: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus
    @Published private(set) var isRequestingPersonalVoiceAuthorization = false

    @Published var autoSplit: String {
        didSet {
            guard !suppression.isActive(.autoSaves) else { return }
            saveModelSettings()
        }
    }
    @Published var modelId: String { didSet { if !suppression.isActive(.autoSaves) { saveModelSettings() } } }
    @Published var language: String { didSet { if !suppression.isActive(.autoSaves) { saveModelSettings() } } }
    @Published var hapticFeedbackEnabled: Bool {
        didSet {
            guard !suppression.isActive(.autoSaves) else { return }
            saveHapticFeedbackSettings()
        }
    }
    @Published var apiAdvancedSettings: APIAdvancedSettings {
        didSet {
            guard !suppression.isActive(.autoSaves) else { return }
            saveAPIAdvancedSettings()
        }
    }
    @Published var toolUseSettings: ToolUseSettings {
        didSet {
            guard !suppression.isActive(.autoSaves) else { return }
            saveToolUseSettings()
        }
    }

    // MARK: - Model List (Networking)

    var availableModels: [String] { settingsManager.chatModelCatalogState.availableModels }
    var isLoadingModels: Bool { settingsManager.chatModelCatalogState.isLoadingModels }
    var isRetryingModels: Bool { settingsManager.chatModelCatalogState.isRetryingModels }
    var modelRetryAttempt: Int { settingsManager.chatModelCatalogState.modelRetryAttempt }
    var modelRetryLastError: String? { settingsManager.chatModelCatalogState.modelRetryLastError }
    var chatServerErrorMessage: String? { settingsManager.chatModelCatalogState.chatServerErrorMessage }
    var lastFetchedModelMetadata: [ModelInfo] { settingsManager.chatModelCatalogState.lastFetchedModelMetadata }
    var lastModelFetchEndpoint: ChatAPIEndpointCandidate? { settingsManager.chatModelCatalogState.lastModelFetchEndpoint }

    // MARK: - Preset bindings for the UI
    typealias PresetSummary = SettingsPresetSummary

    // MARK: - Voice server presets
    @Published var voiceServerPresetList: [PresetSummary] = []
    @Published var selectedVoiceServerPresetID: UUID? {
        didSet {
            if !suppression.isActive(.voiceServerPresetDidSet) {
                commitVoiceServerEdits()
                presetBindingController.selectVoiceServerPreset(selectedVoiceServerPresetID)
                refreshFromSettingsManager()
            }
        }
    }
    @Published var voiceServerPresetName: String = ""

    // MARK: - Chat server presets
    @Published var chatServerPresetList: [PresetSummary] = []
    @Published var selectedChatServerPresetID: UUID? {
        didSet {
            if !suppression.isActive(.chatServerPresetDidSet) {
                commitChatServerEdits()
                presetBindingController.selectChatServerPreset(selectedChatServerPresetID)
                refreshFromSettingsManager()
            }
        }
    }
    @Published var chatServerPresetName: String = ""
    @Published var selectedChatAPIFormatPreference: ChatAPIFormatPreference = .automatic {
        didSet {
            guard !suppression.isActive(.saveChatServerPresetFormat) else { return }
            commitChatServerEdits()
        }
    }

    @Published var presetList: [PresetSummary] = []
    @Published var selectedPresetID: UUID? {
        didSet {
            if !suppression.isActive(.voicePresetDidSet) {
                commitVoicePresetEdits()
                presetBindingController.selectVoicePreset(selectedPresetID, apply: true)
                // Reload the preset fields after switching selection.
                loadSelectedPresetFields()
            }
        }
    }

    @Published var presetName: String = ""
    @Published var presetRefAudioPath: String = ""
    @Published var presetPromptText: String = ""
    @Published var presetPromptLang: String = "auto"
    @Published var presetGPTWeightsPath: String = ""
    @Published var presetSoVITSWeightsPath: String = ""

    // MARK: - System prompt presets (normal / voice are separate)

    @Published var normalSystemPromptPresetList: [PresetSummary] = []
    @Published var selectedNormalSystemPromptPresetID: UUID? {
        didSet {
            if !suppression.isActive(.normalSystemPromptDidSet) {
                commitNormalSystemPromptEdits()
                presetBindingController.selectNormalSystemPromptPreset(selectedNormalSystemPromptPresetID)
                loadSelectedNormalSystemPromptPresetFields()
            }
        }
    }
    @Published var normalSystemPromptPresetName: String = ""
    @Published var normalSystemPromptPrompt: String = ""

    @Published var voiceSystemPromptPresetList: [PresetSummary] = []
    @Published var selectedVoiceSystemPromptPresetID: UUID? {
        didSet {
            if !suppression.isActive(.voiceSystemPromptDidSet) {
                commitVoiceSystemPromptEdits()
                presetBindingController.selectVoiceSystemPromptPreset(selectedVoiceSystemPromptPresetID)
                loadSelectedVoiceSystemPromptPresetFields()
            }
        }
    }
    @Published var voiceSystemPromptPresetName: String = ""
    @Published var voiceSystemPromptPrompt: String = ""

    // MARK: - Dependency
    let settingsManager: SettingsManager
    private var editingContextID: ObjectIdentifier?
    let presetBindingController: SettingsPresetBindingController

    func withSuppressed(
        _ flag: SettingsViewModelSuppressionController.Flag,
        perform body: () -> Void
    ) {
        suppression.withSuppressed(flag, perform: body)
    }

    func withSuppressed(
        _ flags: [SettingsViewModelSuppressionController.Flag],
        perform body: () -> Void
    ) {
        suppression.withSuppressed(flags, perform: body)
    }

    // MARK: - Init
    init(
        settingsManager: SettingsManager = .shared
    ) {
        self.settingsManager = settingsManager
        self.presetBindingController = SettingsPresetBindingController(settingsManager: settingsManager)
        // Seed values from the current in-memory state. A later SwiftData attach may update the manager,
        // so we also listen for the first post-load signal and resync.
        serverAddress = ""
        textLang = ""

        apiURL = ""
        selectedModel = ""
        chatAPIKey = ""
        selectedChatAPIFormatPreference = .automatic

        selectedVoiceServerPresetID = nil

        enableStreaming = true
        ttsProvider = .gptSoVITS
        appleSpeechVoiceIdentifier = nil
        personalVoiceIdentifier = nil
        personalVoiceAuthorizationStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus

        autoSplit = "cut0"
        modelId = ""
        language = "auto"
        hapticFeedbackEnabled = true
        apiAdvancedSettings = .defaults
        toolUseSettings = .defaults

        refreshFromSettingsManager()
        bindModelCatalogUpdates()
        bindInitialStoreSync()
        bindAppleSpeechVoiceChanges()
    }

    var shouldShowUnknownModelImageInputToggle: Bool {
        let model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSelectedModelCapabilityReady else { return false }
        return settingsManager.chatModelCapabilities.isImageInputSupportUnknown(for: model)
    }

    private var isSelectedModelCapabilityReady: Bool {
        settingsManager.isChatModelReady && !isLoadingModels &&
            selectedModel == settingsManager.chatSettings.selectedModel &&
            ChatAPIEndpointResolver.normalizedAPIBaseKey(apiURL) ==
                ChatAPIEndpointResolver.normalizedAPIBaseKey(settingsManager.chatSettings.apiURL)
    }

    var shouldShowUnknownModelThinkingOptions: Bool {
        isSelectedModelCapabilityReady &&
            settingsManager.chatModelCapabilities.isThinkingCapabilityUnknown(for: selectedModel)
    }

    var availableManualThinkingOptions: [ModelThinkingOption] {
        settingsManager.chatModelCapabilities.availableManualThinkingOptions(for: selectedModel)
    }

    var selectedManualThinkingOptions: [ModelThinkingOption] {
        settingsManager.chatModelCapabilities.manualThinkingOptions(for: selectedModel)
    }

    var selectedModelThinkingCapability: ModelThinkingCapability? {
        settingsManager.chatModelCapabilities.thinkingCapability(for: selectedModel)
    }

    var usesAnthropicFixedBudgetThinking: Bool {
        guard settingsManager.chatModelCapabilities.resolvedRequestStyle(for: settingsManager.chatSettings.apiURL) == .anthropicMessages else { return false }
        let modes = lastFetchedModelMetadata.first { $0.id == selectedModel }?
            .thinkingCapabilityHint(provider: .anthropic, requestStyle: .anthropicMessages)?
            .anthropicThinkingModes ?? []
        return modes.contains("enabled") || !modes.contains("adaptive")
    }

    func setManualThinkingOption(_ option: ModelThinkingOption, enabled: Bool) {
        var options = selectedManualThinkingOptions.filter { $0 != option }
        if enabled { options.append(option) }
        options = availableManualThinkingOptions.filter { options.contains($0) }
        settingsManager.chatModelCapabilities.setManualThinkingOptions(options, for: selectedModel)
        objectWillChange.send()
    }

    var toolUseStatusMessage: String? {
        nil
    }

    var openAIResponsesStatefulEndpoint: ChatAPIEndpointCandidate? {
        let trimmedAPIURL = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIURL.isEmpty else { return nil }
        let providerHint = selectedChatAPIFormatPreference.providerHint
            ?? settingsManager.chatModelCapabilities.detectedProvider(for: trimmedAPIURL)
            ?? ChatAPIEndpointResolver.officialProviderHint(for: trimmedAPIURL)
        let styleHint = selectedChatAPIFormatPreference.requestStyleHint
            ?? settingsManager.chatModelCapabilities.detectedRequestStyle(for: trimmedAPIURL)
        return DefaultChatEndpointResolver()
            .streamingCandidates(
                for: trimmedAPIURL,
                providerHint: providerHint,
                styleHint: styleHint
            )
            .first(where: ToolUseSettings.supportsProviderContinuationIDPreference)
    }

    var isOpenAIResponsesStatefulEndpointAvailable: Bool {
        openAIResponsesStatefulEndpoint != nil
    }

    var currentOpenAIResponsesStatefulEndpointURL: String? {
        guard let endpoint = openAIResponsesStatefulEndpoint else { return nil }
        return ToolUseSettings.providerContinuationIDPreferenceKey(for: endpoint)
    }

    var isCurrentOpenAIResponsesStatefulEndpointEnabled: Bool {
        guard let endpoint = openAIResponsesStatefulEndpoint else { return false }
        return toolUseSettings.isOpenAIResponsesStatefulChatEnabled(for: endpoint)
    }

    var openAIResponsesStatefulEndpointURLs: [String] {
        ToolUseSettings.normalizedOpenAIResponsesStatefulEndpointURLs(
            toolUseSettings.openAIResponsesStatefulEndpointURLs
        )
    }

    func enableStatefulChatForCurrentOpenAIResponsesEndpoint() {
        guard let endpoint = openAIResponsesStatefulEndpoint else { return }
        var next = toolUseSettings
        next.enableOpenAIResponsesStatefulChat(for: endpoint)
        toolUseSettings = next
    }

    func removeOpenAIResponsesStatefulEndpointURL(_ endpointURL: String) {
        var next = toolUseSettings
        next.removeOpenAIResponsesStatefulEndpointURL(endpointURL)
        toolUseSettings = next
    }

    var isSelectedUnknownModelImageInputEnabled: Bool {
        let model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return false }
        return settingsManager.chatModelCapabilities.imageInputManualOverride(for: model) == true
    }

    func setSelectedUnknownModelImageInputEnabled(_ enabled: Bool) {
        let model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        // Persist explicit per-model choice for unknown-capability models.
        settingsManager.chatModelCapabilities.setImageInputManualOverride(enabled, for: model)
        objectWillChange.send()
    }

    // MARK: - Networking (List Models)

    func fetchAvailableModels() {
        guard commitChatServerEdits() else { return }
        settingsManager.fetchAvailableChatModels(forceRefresh: true)
    }

    private func bindModelCatalogUpdates() {
        settingsManager.$chatModelCatalogState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        settingsManager.$chatSettings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let settings = self.settingsManager.chatSettings
                guard ChatAPIEndpointResolver.normalizedAPIBaseKey(self.apiURL) == ChatAPIEndpointResolver.normalizedAPIBaseKey(settings.apiURL),
                      self.chatAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) == settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                self.withSuppressed(.autoSaves) {
                    self.selectedModel = settings.selectedModel
                }
            }
            .store(in: &cancellables)
    }

    func refreshFromSettingsManager() {
        editingContextID = settingsManager.context.map(ObjectIdentifier.init)
        let s = settingsManager.serverSettings
        let c = settingsManager.chatSettings
        let v = settingsManager.voiceSettings
        let m = settingsManager.modelSettings

        withSuppressed(.autoSaves) {
            serverAddress = s.serverAddress
            textLang = s.textLang

            apiURL = c.apiURL
            selectedModel = c.selectedModel
            chatAPIKey = c.apiKey

            enableStreaming = v.enableStreaming
            ttsProvider = v.provider
            appleSpeechVoiceIdentifier = v.appleSpeechVoiceIdentifier
            personalVoiceIdentifier = v.personalVoiceIdentifier
            hapticFeedbackEnabled = settingsManager.hapticFeedbackEnabled
            apiAdvancedSettings = settingsManager.apiAdvancedSettings
            toolUseSettings = settingsManager.toolUseSettings

            autoSplit = m.autoSplit
            modelId = m.modelId
            language = m.language
        }

        reloadVoiceServerPresetListAndSelection()
        reloadChatServerPresetListAndSelection()
        reloadPresetListAndSelection()
        loadSelectedPresetFields()
        reloadSystemPromptPresetListsAndSelections()
        refreshAvailableAppleSpeechVoices()
    }

    private func bindInitialStoreSync() {
        settingsManager.$presets
            .receive(on: RunLoop.main)
            .sink { [weak self] presets in
                guard let self else { return }
                guard !self.didSyncAfterStoreLoad else { return }
                // Presets are only loaded from SwiftData after the model context is attached.
                guard !presets.isEmpty else { return }
                self.didSyncAfterStoreLoad = true
                self.refreshFromSettingsManager()
            }
            .store(in: &cancellables)
    }

    private func bindAppleSpeechVoiceChanges() {
        NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAvailableAppleSpeechVoices()
            }
            .store(in: &cancellables)
    }

    func refreshAvailableAppleSpeechVoices() {
        personalVoiceAuthorizationStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        availableAppleSpeechVoices = AppleSpeechVoiceOption.installedVoices()
        ensurePersonalVoiceSelection()
    }

    var availableSystemVoices: [AppleSpeechVoiceOption] {
        availableAppleSpeechVoices.filter { !$0.isPersonalVoice }
    }

    var availablePersonalVoices: [AppleSpeechVoiceOption] {
        availableAppleSpeechVoices.filter(\.isPersonalVoice)
    }

    private func activatePersonalVoiceProvider() {
        refreshAvailableAppleSpeechVoices()
        guard personalVoiceAuthorizationStatus == .notDetermined else {
            ensurePersonalVoiceSelection()
            return
        }
        requestPersonalVoiceAuthorization()
    }

    private func requestPersonalVoiceAuthorization() {
        guard ttsProvider == .personalVoice,
              !isRequestingPersonalVoiceAuthorization else { return }
        isRequestingPersonalVoiceAuthorization = true

        Task { [weak self] in
            let status = await AVSpeechSynthesizer.requestPersonalVoiceAuthorization()
            guard let self else { return }
            personalVoiceAuthorizationStatus = status
            isRequestingPersonalVoiceAuthorization = false
            refreshAvailableAppleSpeechVoices()
        }
    }

    private func ensurePersonalVoiceSelection() {
        guard ttsProvider == .personalVoice,
              personalVoiceAuthorizationStatus == .authorized else {
            return
        }
        if let personalVoiceIdentifier,
           availablePersonalVoices.contains(where: { $0.id == personalVoiceIdentifier }) {
            return
        }
        personalVoiceIdentifier = availablePersonalVoices.first?.id
    }

    // MARK: - Persist settings

    @discardableResult
    func commitVoiceServerEdits() -> Bool {
        guard !suppression.isActive(.autoSaves),
              !suppression.isActive(.saveVoiceServerPreset) else { return true }
        let didCommit = settingsManager.commitSelectedVoiceServerSettings(
            name: voiceServerPresetName,
            serverAddress: serverAddress,
            textLang: textLang
        )
        guard didCommit else {
            refreshFromSettingsManager()
            return false
        }
        let presets = presetBindingController.voiceServerBinding().presets
        if voiceServerPresetList != presets {
            voiceServerPresetList = presets
        }
        return true
    }

    func saveToolUseSettings() {
        settingsManager.updateToolUseSettings(toolUseSettings)
    }

    @discardableResult
    func commitChatServerEdits() -> Bool {
        guard !suppression.isActive(.autoSaves),
              !suppression.isActive(.saveChatServerPreset),
              !suppression.isActive(.saveChatServerPresetFormat) else { return true }
        let didCommit = settingsManager.commitSelectedChatServerSettings(
            name: chatServerPresetName,
            apiURL: apiURL,
            selectedModel: selectedModel,
            apiKey: chatAPIKey,
            apiFormatPreference: selectedChatAPIFormatPreference
        )
        guard didCommit else {
            refreshFromSettingsManager()
            return false
        }
        let presets = presetBindingController.chatServerBinding().presets
        if chatServerPresetList != presets {
            chatServerPresetList = presets
        }
        return true
    }

    func commitPendingEdits() {
        guard editingContextID == settingsManager.context.map(ObjectIdentifier.init) else {
            refreshFromSettingsManager()
            return
        }
        commitChatServerEdits()
        commitVoiceServerEdits()
        commitVoicePresetEdits()
        commitNormalSystemPromptEdits()
        commitVoiceSystemPromptEdits()
    }

    func saveVoiceSettings() {
        settingsManager.updateVoiceSettings(
            enableStreaming: enableStreaming,
            provider: ttsProvider,
            appleSpeechVoiceIdentifier: appleSpeechVoiceIdentifier,
            personalVoiceIdentifier: personalVoiceIdentifier
        )
    }

    func saveHapticFeedbackSettings() {
        settingsManager.updateHapticFeedbackEnabled(hapticFeedbackEnabled)
    }

    func saveAPIAdvancedSettings() {
        settingsManager.updateAPIAdvancedSettings(apiAdvancedSettings)
    }

    func resetAPIAdvancedSettingsToDefaults() {
        withSuppressed(.autoSaves) {
            apiAdvancedSettings = .defaults
        }
        settingsManager.resetAPIAdvancedSettingsToDefaults()
    }

    func resetDeveloperSettingsToDefaults() {
        withSuppressed(.autoSaves) {
            apiAdvancedSettings = .defaults
            toolUseSettings = toolUseSettings.resettingDeveloperRequestPolicyToDefaults()
        }
        settingsManager.resetDeveloperSettingsToDefaults()
    }

    func saveModelSettings() {
        settingsManager.updateModelSettings(
            modelId: modelId,
            language: language,
            autoSplit: autoSplit
        )
    }

}
