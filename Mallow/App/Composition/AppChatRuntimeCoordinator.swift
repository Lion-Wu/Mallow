//
//  AppChatRuntimeCoordinator.swift
//  Mallow
//
//  Created by OpenAI Codex on 2026/06/13.
//

import Combine
import Foundation

@MainActor
final class AppChatRuntimeCoordinator {
    private struct ChatEndpointSignature: Equatable {
        let apiURL: String
        let apiKey: String
        let formatPreference: ChatAPIFormatPreference
    }

    private struct ChatRuntimeSignature: Equatable {
        let settings: ChatSettings
        let selectedPresetID: UUID?
        let apiFormatRaw: String?
    }

    private let settingsManager: SettingsManager
    private let chatSessionsViewModel: ChatSessionsViewModel
    private let reachabilityMonitor: ServerReachabilityMonitor
    private var cancellables: Set<AnyCancellable> = []
    private var reachabilityTask: Task<Void, Never>?
    private var didStart = false

    init(
        settingsManager: SettingsManager,
        chatSessionsViewModel: ChatSessionsViewModel,
        reachabilityMonitor: ServerReachabilityMonitor
    ) {
        self.settingsManager = settingsManager
        self.chatSessionsViewModel = chatSessionsViewModel
        self.reachabilityMonitor = reachabilityMonitor
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        observeSettingsChanges()
        startReachabilityMonitoring()
        startLaunchTasks()
    }

    private func startLaunchTasks() {
        Task { [settingsManager] in
            await settingsManager.applyPresetOnLaunchIfNeeded()
        }
        settingsManager.fetchAvailableChatModels()
    }

    private func observeSettingsChanges() {
        settingsManager.$chatSettings
            .combineLatest(
                settingsManager.$chatServerPresets,
                settingsManager.$selectedChatServerPresetID.removeDuplicates()
            )
            .map { settings, presets, selectedID in
                let rawFormat = presets
                    .first(where: { $0.id == selectedID })?
                    .apiFormatPreferenceRaw?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return ChatRuntimeSignature(
                    settings: settings,
                    selectedPresetID: selectedID,
                    apiFormatRaw: rawFormat?.isEmpty == false ? rawFormat : nil
                )
            }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.chatSessionsViewModel.refreshChatConfigurationIfNeeded()
            }
            .store(in: &cancellables)

        settingsManager.$chatSettings
            .map { $0.apiURL.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.kickReachabilityCheck()
            }
            .store(in: &cancellables)

        settingsManager.$chatSettings
            .combineLatest(settingsManager.$chatServerPresets, settingsManager.$selectedChatServerPresetID)
            .map { settings, presets, selectedID in
                ChatEndpointSignature(
                    apiURL: settings.apiURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    apiKey: settings.apiKey,
                    formatPreference: ChatServerPresetStore.apiFormatPreference(for: selectedID, in: presets)
                )
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [settingsManager] _ in
                Task { [settingsManager] in
                    settingsManager.fetchAvailableChatModels()
                }
            }
            .store(in: &cancellables)

        settingsManager.$apiAdvancedSettings
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.chatSessionsViewModel.refreshChatConfigurationIfNeeded()
            }
            .store(in: &cancellables)

        settingsManager.$developerModeEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.chatSessionsViewModel.refreshChatConfigurationIfNeeded()
            }
            .store(in: &cancellables)

        settingsManager.chatModelCapabilityChanges
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.chatSessionsViewModel.refreshChatConfigurationIfNeeded()
            }
            .store(in: &cancellables)

        settingsManager.$serverSettings
            .map { $0.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.kickReachabilityCheck()
            }
            .store(in: &cancellables)

        settingsManager.$voiceSettings
            .map(\.provider)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.kickReachabilityCheck()
            }
            .store(in: &cancellables)
    }

    private func startReachabilityMonitoring() {
        reachabilityMonitor.startMonitoring { [settingsManager] in
            settingsManager.serverReachabilitySnapshot
        }
    }

    private func kickReachabilityCheck() {
        reachabilityTask?.cancel()
        reachabilityTask = Task { [settingsManager, reachabilityMonitor] in
            await reachabilityMonitor.checkAll(snapshot: settingsManager.serverReachabilitySnapshot)
        }
    }
}
