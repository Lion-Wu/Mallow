//
//  SettingsView.swift
//  Mallow
//
//  Created by Lion Wu on 2024.09.22.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

enum SettingsDeletionTarget: String, Identifiable {
    case voicePreset
    case chatServerPreset
    case voiceServerPreset
    case normalPromptPreset
    case voicePromptPreset

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .voicePreset, .chatServerPreset, .voiceServerPreset:
            return "PRESET_DELETE_CONFIRMATION"
        case .normalPromptPreset, .voicePromptPreset:
            return "PROMPT_PRESET_DELETE_CONFIRMATION"
        }
    }
}

private enum SettingsNavigationDestination: Hashable {
    case advancedAPISettings
    case dataManagement
}

#if os(macOS)
private enum MacSettingsTab: Hashable {
    case servers
    case chat
    case voiceOutput
    case developer
}
#endif

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: SettingsViewModel
    @ObservedObject private var settingsManager: SettingsManager
    @State private var pendingDeletionTarget: SettingsDeletionTarget?
    @Environment(\.dismiss) private var dismiss
#if os(macOS)
    @State private var measuredContentSize: CGSize = .zero
    @State private var macSelectedSettingsTab: MacSettingsTab = .servers
    @State private var showingDataManagement = false
    @State private var macShowingAdvancedAPIResetConfirmation = false
    @State private var macShowingDeveloperDefaultsConfirmation = false
#endif

    init(settingsManager: SettingsManager = .shared) {
        _settingsManager = ObservedObject(wrappedValue: settingsManager)
        _viewModel = StateObject(wrappedValue: SettingsViewModel(settingsManager: settingsManager))
    }

    private var detectedChatAPIFormatName: String {
        let base = viewModel.apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedProvider = settingsManager.chatModelCapabilities.detectedProvider(for: base)
            ?? ChatAPIEndpointResolver.officialProviderHint(for: base)
        let detectedStyle = settingsManager.chatModelCapabilities.detectedRequestStyle(for: base)
            ?? SettingsAPIRequestStyleResolver.inferredStyle(
                for: base,
                providerHint: detectedProvider
            )
        return detectedAPIFormatName(provider: detectedProvider, requestStyle: detectedStyle)
    }

    private func detectedAPIFormatName(provider: ChatProvider?, requestStyle: ChatRequestStyle?) -> String {
        switch requestStyle {
        case .openAIResponses:
            return provider == .unknown
                ? NSLocalizedString("SETTINGS_UNKNOWN_OPENAI_RESPONSES", value: "Unknown, using OpenAI Responses", comment: "Detected API format name")
                : NSLocalizedString("API_FORMAT_OPENAI_RESPONSES", value: "OpenAI Responses", comment: "Detected API format name")
        case .openAIChatCompletions:
            return NSLocalizedString("API_FORMAT_OPENAI_CHAT_COMPLETIONS", value: "OpenAI Chat Completions", comment: "Detected API format name")
        case .anthropicMessages:
            return ChatProvider.anthropic.displayName
        case .lmStudioRESTV1:
            return ChatProvider.lmStudio.displayName
        case nil:
            if let provider, provider != .unknown {
                return provider.displayName
            }
            return NSLocalizedString("COMMON_UNKNOWN", value: "Unknown", comment: "Provider display name")
        }
    }

    var body: some View {
        #if os(macOS)
        applyCommonModifiers(
            macSettingsContent
                .overlay(WindowSizeReader().allowsHitTesting(false))
        )
        .sheet(isPresented: $showingDataManagement) {
            NavigationStack {
                DataManagementView(commitEdits: viewModel.commitPendingEdits)
            }
            .frame(minWidth: 720, idealWidth: 780, minHeight: 600, idealHeight: 680)
        }
        .onPreferenceChange(WindowSizePreferenceKey.self) { newSize in
            updateWindowSizeIfNeeded(newSize)
        }
        #else
        applyCommonModifiers(
            NavigationStack {
                Form {
                    chatSection()
                    serverSection()
                    chatModelSection()
                    toolUseSection()
                    systemPromptSection()
                    presetSection()
                    voiceOutputSection()
                    developerSection()
                    applicationInfoSection
                }
                .navigationBarTitle("SETTINGS_TITLE", displayMode: .inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("COMMON_ACTION_CLOSE") { dismiss() }
                    }
                }
                .navigationDestination(for: SettingsNavigationDestination.self) { destination in
                    switch destination {
                    case .advancedAPISettings:
                        advancedAPISettingsView
                    case .dataManagement:
                        DataManagementView(commitEdits: viewModel.commitPendingEdits)
                    }
                }
            }
        )
        #endif
    }

    @ViewBuilder
    private func applyCommonModifiers<Content: View>(_ content: Content) -> some View {
        content
            .background(AppBackgroundView())
            .task {
                viewModel.refreshFromSettingsManager()
            }
            .onDisappear {
                viewModel.commitPendingEdits()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    viewModel.commitPendingEdits()
                }
            }
            .alert(
                pendingDeletionTarget?.title ?? LocalizedStringKey("COMMON_ACTION_DELETE"),
                isPresented: deletionAlertBinding
            ) {
                Button("COMMON_ACTION_DELETE", role: .destructive, action: performPendingDeletion)
                Button("COMMON_ACTION_CANCEL", role: .cancel) {
                    pendingDeletionTarget = nil
                }
            } message: {
                Text("COMMON_IRREVERSIBLE_WARNING")
            }
            .alert("COMMON_ERROR_TITLE", isPresented: settingsWriteFailureAlertBinding) {
                Button("COMMON_ACTION_CLOSE") {
                    settingsManager.clearSettingsWriteFailure()
                }
            } message: {
                Text(settingsManager.settingsWriteFailure?.message ?? "")
            }
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletionTarget != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletionTarget = nil
                }
            }
        )
    }

    private var settingsWriteFailureAlertBinding: Binding<Bool> {
        Binding(
            get: { settingsManager.settingsWriteFailure != nil },
            set: { isPresented in
                if !isPresented {
                    settingsManager.clearSettingsWriteFailure()
                }
            }
        )
    }

    private func requestDeletion(_ target: SettingsDeletionTarget) {
        pendingDeletionTarget = target
    }

    private func performPendingDeletion() {
        guard let target = pendingDeletionTarget else { return }
        pendingDeletionTarget = nil

        switch target {
        case .voicePreset:
            viewModel.deleteCurrentPreset()
        case .chatServerPreset:
            viewModel.deleteSelectedChatServerPreset()
        case .voiceServerPreset:
            viewModel.deleteSelectedVoiceServerPreset()
        case .normalPromptPreset:
            viewModel.deleteSelectedNormalSystemPromptPreset()
        case .voicePromptPreset:
            viewModel.deleteSelectedVoiceSystemPromptPreset()
        }
    }

    // MARK: - Sections

    #if !os(macOS)
    private var applicationInfoSection: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                Text(LocalizedStringResource("ABOUT_TITLE", defaultValue: "About \(ApplicationInformation.name)"))
            }
        }
    }
    #endif

#if os(macOS)
    @ViewBuilder
    private var macSettingsContent: some View {
        macSettingsTabs
            .frame(
                width: MacSettingsLayout.topLevelContentSize.width,
                height: MacSettingsLayout.topLevelContentSize.height,
                alignment: .top
            )
    }

    private var macSettingsTabs: some View {
        TabView(selection: $macSelectedSettingsTab) {
            macServersTab
                .tag(MacSettingsTab.servers)
            macChatTab
                .tag(MacSettingsTab.chat)
            macVoiceOutputTab
                .tag(MacSettingsTab.voiceOutput)
            macDeveloperTab
                .tag(MacSettingsTab.developer)
        }
        .scenePadding()
    }

    private var macServersTab: some View {
        Form {
            chatSection()
            serverSection()
        }
        .formStyle(.grouped)
        .tabItem {
            Label("SETTINGS_SERVERS", systemImage: "server.rack")
        }
    }

    private var macVoiceOutputTab: some View {
        Form {
            presetSection()
            voiceOutputSection()
        }
        .formStyle(.grouped)
        .tabItem {
            Label("SETTINGS_VOICE_SETTINGS", systemImage: "speaker.wave.3.fill")
        }
    }

    private var macChatTab: some View {
        Form {
            chatModelSection()
            toolUseSection()
            systemPromptSection()
        }
        .formStyle(.grouped)
        .tabItem {
            Label("CHAT_TITLE", systemImage: "text.bubble.fill")
        }
    }

    private var macDeveloperTab: some View {
        macDeveloperSettingsPage
        .tabItem {
            Label("SETTINGS_ADVANCED", systemImage: "wrench.and.screwdriver")
        }
    }

    private var macDeveloperSettingsPage: some View {
        Form {
            developerSection()
        }
        .formStyle(.grouped)
    }
#endif

    @ViewBuilder
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        #if os(macOS)
        Text(title)
            .font(.headline)
            .textCase(.none)
        #else
        Text(title)
        #endif
    }

    @ViewBuilder
    private func serverSection(hideHeader: Bool = false) -> some View {
        Section {
            #if os(macOS)
            LabeledContent("VOICE_SPEECH_PROVIDER") {
                Picker("", selection: $viewModel.ttsProvider) {
                    ForEach(TTSProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
            }
            #else
            Picker("VOICE_SPEECH_PROVIDER", selection: $viewModel.ttsProvider) {
                ForEach(TTSProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            #endif

            if viewModel.ttsProvider == .gptSoVITS {
                #if os(macOS)
                LabeledContent("PRESET_TITLE") {
                    Picker("", selection: $viewModel.selectedVoiceServerPresetID) {
                        ForEach(viewModel.voiceServerPresetList) { p in
                            Text(p.name).tag(Optional.some(p.id))
                        }
                    }
                    .labelsHidden()
                }

                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            viewModel.addVoiceServerPreset()
                        } label: {
                            Label("COMMON_ACTION_ADD", systemImage: "plus.circle.fill")
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .help("PRESET_ACTION_ADD")

                        Button(role: .destructive) {
                            requestDeletion(.voiceServerPreset)
                        } label: {
                            Label("COMMON_ACTION_DELETE", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .help("PRESET_ACTION_DELETE_SELECTED")
                        .disabled(viewModel.voiceServerPresetList.count <= 1 || viewModel.selectedVoiceServerPresetID == nil)
                    }
                }
                #else
                Picker("PRESET_TITLE", selection: $viewModel.selectedVoiceServerPresetID) {
                    ForEach(viewModel.voiceServerPresetList) { p in
                        Text(p.name).tag(Optional.some(p.id))
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 16) {
                    Button {
                        viewModel.addVoiceServerPreset()
                    } label: {
                        Label("COMMON_ACTION_ADD", systemImage: "plus.circle.fill")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())

                    Button(role: .destructive) {
                        requestDeletion(.voiceServerPreset)
                    } label: {
                        Label("COMMON_ACTION_DELETE", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(viewModel.voiceServerPresetList.count <= 1 || viewModel.selectedVoiceServerPresetID == nil)
                }
                #endif

                LabeledTextField(
                    label: "PRESET_NAME",
                    placeholder: "PRESET_NAME_PLACEHOLDER",
                    text: $viewModel.voiceServerPresetName,
                    onCommit: { viewModel.commitVoiceServerEdits() }
                )

                LabeledTextField(
                    label: "SETTINGS_SERVER_URL",
                    placeholder: "SETTINGS_VOICE_SERVER_URL_PLACEHOLDER",
                    text: $viewModel.serverAddress,
                    onCommit: { viewModel.commitVoiceServerEdits() }
                )
            }
        } header: {
            if hideHeader {
                EmptyView()
            } else {
                sectionHeader("SETTINGS_VOICE_SERVER")
            }
        }
    }

    @ViewBuilder
    private func presetSection(hideHeader: Bool = false) -> some View {
        SettingsVoicePresetSection(
            viewModel: viewModel,
            settingsManager: settingsManager,
            hideHeader: hideHeader,
            requestDeletion: requestDeletion(_:)
        )
    }

    @ViewBuilder
    private func voiceOutputSection(hideHeader: Bool = false) -> some View {
        Section {
            if viewModel.ttsProvider == .gptSoVITS {
                LabeledTextField(
                    label: "VOICE_TEXT_LANGUAGE",
                    placeholder: "VOICE_LANGUAGE_PLACEHOLDER",
                    text: $viewModel.textLang,
                    onCommit: { viewModel.commitVoiceServerEdits() }
                )
            }

            #if os(macOS)
            Toggle("SETTINGS_STREAMING", isOn: $viewModel.enableStreaming)
            if viewModel.ttsProvider == .gptSoVITS {
                LabeledContent("VOICE_SPLIT_METHOD") {
                    Picker("", selection: $viewModel.autoSplit) {
                        Text("VOICE_SPLIT_NONE").tag("cut0")
                        Text("VOICE_SPLIT_FOUR_SENTENCES").tag("cut1")
                        Text("VOICE_SPLIT_FIFTY_CHARACTERS").tag("cut2")
                        Text("VOICE_SPLIT_CHINESE_PERIOD").tag("cut3")
                        Text("VOICE_SPLIT_ENGLISH_PERIOD").tag("cut4")
                        Text("VOICE_SPLIT_PUNCTUATION").tag("cut5")
                    }
                    .labelsHidden()
                    .disabled(viewModel.enableStreaming)
                }
            }
            #else
            Toggle("SETTINGS_STREAMING", isOn: $viewModel.enableStreaming)
            if viewModel.ttsProvider == .gptSoVITS {
                Picker("VOICE_SPLIT_METHOD", selection: $viewModel.autoSplit) {
                    Text("VOICE_SPLIT_NONE").tag("cut0")
                    Text("VOICE_SPLIT_FOUR_SENTENCES").tag("cut1")
                    Text("VOICE_SPLIT_FIFTY_CHARACTERS").tag("cut2")
                    Text("VOICE_SPLIT_CHINESE_PERIOD").tag("cut3")
                    Text("VOICE_SPLIT_ENGLISH_PERIOD").tag("cut4")
                    Text("VOICE_SPLIT_PUNCTUATION").tag("cut5")
                }
                .disabled(viewModel.enableStreaming)
            }
            #endif
        } header: {
            if hideHeader {
                EmptyView()
            } else {
                sectionHeader("SETTINGS_VOICE_SETTINGS")
            }
        }
    }

    @ViewBuilder
    private func chatSection(hideHeader: Bool = false) -> some View {
        SettingsChatServerSection(
            viewModel: viewModel,
            hideHeader: hideHeader,
            detectedChatAPIFormatName: detectedChatAPIFormatName,
            requestDeletion: requestDeletion(_:)
        )
    }

    @ViewBuilder
    private func chatModelSection(hideHeader: Bool = false) -> some View {
        SettingsChatModelSection(viewModel: viewModel, hideHeader: hideHeader)
    }

    @ViewBuilder
    private func toolUseSection(hideHeader: Bool = false) -> some View {
        SettingsToolUseSection(viewModel: viewModel, hideHeader: hideHeader)
    }

    @ViewBuilder
    private func developerSection(hideHeader: Bool = false) -> some View {
        Section {
            #if !os(macOS)
            Toggle("SETTINGS_HAPTIC_FEEDBACK", isOn: $viewModel.hapticFeedbackEnabled)
            #endif
            #if os(macOS)
            Button { showingDataManagement = true } label: {
                HStack {
                    Label("DATA_MANAGEMENT", systemImage: "externaldrive")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #else
            NavigationLink(value: SettingsNavigationDestination.dataManagement) {
                Label("DATA_MANAGEMENT", systemImage: "externaldrive")
            }
            #endif
        } header: {
            if hideHeader {
                EmptyView()
            } else {
                sectionHeader("SETTINGS_ADVANCED")
            }
        }

        Section {
            Toggle(
                "SETTINGS_DEVELOPER_MODE",
                isOn: Binding(
                    get: { settingsManager.developerModeEnabled },
                    set: { settingsManager.updateDeveloperModeEnabled($0) }
                )
            )
        }

        #if os(macOS)
        if settingsManager.developerModeEnabled {
            SettingsDeveloperRequestPolicySection(viewModel: viewModel)
            SettingsDeveloperToolUseSection(viewModel: viewModel)
            SettingsAdvancedAPISectionsContent(
                viewModel: viewModel,
                settingsManager: settingsManager,
                showingResetConfirmation: $macShowingAdvancedAPIResetConfirmation,
                includeDefaultsSection: false
            )
            SettingsDeveloperDefaultsSection(
                viewModel: viewModel,
                showingResetConfirmation: $macShowingDeveloperDefaultsConfirmation
            )
        }
        #else
        advancedAPIEntrySection()
        #endif
    }

    @ViewBuilder
    private func advancedAPIEntrySection() -> some View {
        if settingsManager.developerModeEnabled {
            Section {
                NavigationLink(value: SettingsNavigationDestination.advancedAPISettings) {
                    Label("SETTINGS_ADVANCED_OPTIONS", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private var advancedAPISettingsView: some View {
        SettingsAdvancedAPIView(
            viewModel: viewModel,
            settingsManager: settingsManager,
            includeDeveloperSections: settingsManager.developerModeEnabled
        )
    }

    private func systemPromptSection() -> some View {
        SettingsSystemPromptSection(
            viewModel: viewModel,
            onDeleteNormalPromptPreset: { requestDeletion(.normalPromptPreset) },
            onDeleteVoicePromptPreset: { requestDeletion(.voicePromptPreset) }
        )
    }

#if os(macOS)
    private func updateWindowSizeIfNeeded(_ newSize: CGSize) {
        if newSize.width > 0, newSize.height > 0 {
            measuredContentSize = newSize
        }

        SettingsWindowSizer.updateWindowSizeIfNeeded()
    }
#endif
}

#Preview {
    SettingsView(settingsManager: .shared)
}
