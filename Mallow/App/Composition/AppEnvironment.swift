//
//  AppEnvironment.swift
//  Mallow
//
//  Created by OpenAI Codex on 2025/03/16.
//

import Foundation
import CryptoKit
import SwiftUI
import SwiftData

@MainActor
private final class SettingsHapticFeedbackPolicy: HapticFeedbackPolicy {
    private let settingsManager: SettingsManager

    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
    }

    var isHapticFeedbackEnabled: Bool {
        settingsManager.hapticFeedbackEnabled
    }
}

/// Central place to build and share app-scoped dependencies.
@MainActor
final class AppEnvironment: ObservableObject {
    let audioManager: GlobalAudioManager
    let settingsManager: SettingsManager
    let chatSessionsViewModel: ChatSessionsViewModel
    let speechInputManager: SpeechInputManager
    let errorCenter: AppErrorCenter
    let voiceOverlayViewModel: MallowOverlayViewModel
    let reachabilityMonitor: ServerReachabilityMonitor
#if os(macOS)
    let realtimeVoiceWindowController: RealtimeVoiceWindowController
#endif

    private let chatRuntimeCoordinator: AppChatRuntimeCoordinator
    private let realtimeVoiceLockCoordinator: AppRealtimeVoiceLockCoordinator
    private let keepAwakeCoordinator: AppKeepAwakeCoordinator
    private var boundModelContainer: ModelContainer?
    private var settingsModelContext: ModelContext?
    private var sessionsModelContext: ModelContext?
    private var didStart = false

    init(
        audioManager: GlobalAudioManager? = nil,
        settingsManager: SettingsManager? = nil,
        chatSessionsViewModel: ChatSessionsViewModel? = nil,
        speechInputManager: SpeechInputManager? = nil,
        errorCenter: AppErrorCenter? = nil,
        reachabilityMonitor: ServerReachabilityMonitor? = nil
    ) {
        // Resolve defaults inside the main-actor initializer to avoid crossing actor boundaries
        // in Swift 6 default argument evaluation.
        self.audioManager = audioManager ?? .shared
        self.settingsManager = settingsManager ?? .shared
        self.speechInputManager = speechInputManager ?? .shared
        self.errorCenter = errorCenter ?? .shared
        self.reachabilityMonitor = reachabilityMonitor ?? .shared
        self.chatSessionsViewModel = chatSessionsViewModel ?? ChatSessionsViewModel(
            settingsManager: self.settingsManager,
            reachability: self.reachabilityMonitor,
            audioManager: self.audioManager,
            repository: SwiftDataChatSessionRepository(onSaveError: { [errorCenter = self.errorCenter] error in
                guard let error else {
                    errorCenter.clear(category: .dataSaving)
                    return
                }
                errorCenter.publishCritical(
                    title: String(localized: "DATA_SAVING_ISSUE", defaultValue: "Data Saving Issue"),
                    message: String(format: NSLocalizedString(
                        "CHAT_SAVE_FAILED", value: "Your latest chat changes could not be saved. They may be lost if you close the app.\n%@",
                        comment: "Chat save failure notice followed by the underlying error"
                    ), error.localizedDescription),
                    category: .dataSaving
                )
            })
        )
        AppHaptics.configure(
            feedbackPolicy: SettingsHapticFeedbackPolicy(settingsManager: self.settingsManager)
        )
        self.voiceOverlayViewModel = MallowOverlayViewModel(
            speechInputManager: self.speechInputManager,
            audioManager: self.audioManager,
            errorCenter: self.errorCenter,
            settingsManager: self.settingsManager,
            reachabilityMonitor: self.reachabilityMonitor
        )
        self.chatRuntimeCoordinator = AppChatRuntimeCoordinator(
            settingsManager: self.settingsManager,
            chatSessionsViewModel: self.chatSessionsViewModel,
            reachabilityMonitor: self.reachabilityMonitor
        )
        self.realtimeVoiceLockCoordinator = AppRealtimeVoiceLockCoordinator(
            voiceOverlayViewModel: self.voiceOverlayViewModel,
            audioManager: self.audioManager,
            chatSessionsViewModel: self.chatSessionsViewModel
        )
        self.keepAwakeCoordinator = AppKeepAwakeCoordinator(
            chatSessionsViewModel: self.chatSessionsViewModel,
            audioManager: self.audioManager,
            voiceOverlayViewModel: self.voiceOverlayViewModel
        )
#if os(macOS)
        self.realtimeVoiceWindowController = RealtimeVoiceWindowController(
            overlayViewModel: self.voiceOverlayViewModel,
            errorCenter: self.errorCenter
        )
#endif
        realtimeVoiceLockCoordinator.start()
        keepAwakeCoordinator.start()
    }

    /// Binds the only persistent container before the data-backed UI is published.
    func start(with container: ModelContainer) {
        guard bindModelContainer(container) else { return }

        guard !didStart else { return }
        didStart = true
        chatRuntimeCoordinator.start()
    }

    /// Reset Data replaces the container, so the same app-scoped environment
    /// must accept a new persistent container.
    @discardableResult
    func bindModelContainer(_ container: ModelContainer) -> Bool {
        guard boundModelContainer !== container else { return true }

        // Settings and conversations use isolated contexts backed by the same
        // container. A settings transaction can no longer flush or roll back a
        // throttled chat write, and separate app scenes cannot rebind each other.
        let settingsContext = ModelContext(container)
        guard settingsManager.attach(context: settingsContext) else { return false }

        let sessionsContext = ModelContext(container)
        guard chatSessionsViewModel.attach(context: sessionsContext) else {
            settingsManager.detachPersistentStore()
            return false
        }

        boundModelContainer = container
        settingsModelContext = settingsContext
        sessionsModelContext = sessionsContext
        chatSessionsViewModel.refreshChatConfigurationIfNeeded()
        return true
    }

    func stageRawDataExport() throws -> RawDataExport.StagedSnapshot {
        try flushForDataManagement()
        // All app-owned database writers run on the main actor. Copy the saved
        // files before yielding, then compress the private copy in the background.
        return try RawDataExport.stageApplicationSnapshot()
    }

    func stageDataManagementRead() throws -> RawDataExport.StagedSnapshot {
        try flushForDataManagement()
        let current = StartupPersistentStore.defaultURL
        let sources = Dictionary(uniqueKeysWithValues: ["", "-wal", "-shm"].map {
            ("default.store" + $0, URL(fileURLWithPath: current.path + $0))
        })
        return try RawDataExport.stage(sources: sources, keychain: RawDataExport.keychainSnapshot(service: Bundle.main.bundleIdentifier ?? "Mallow"))
    }

    func ownsDataManagementContext(_ context: ModelContext) -> Bool {
        context.container === boundModelContainer
    }

    func dataManagementSourceMatches(_ reviewed: DataBackupReadResult) throws -> Bool {
        try flushForDataManagement()
        guard try AppDataBackup.sourceRevision(at: StartupPersistentStore.defaultURL) == reviewed.sourceRevision else { return false }
        let keychain = try RawDataExport.keychainSnapshot(service: Bundle.main.bundleIdentifier ?? "Mallow")
        return DataBackupCredentials.recover(keychain, presetIDs: Set(reviewed.snapshot.chatServers.map(\.id))).values == reviewed.snapshot.credentials
    }

    func dataManagementSourceMatches(_ revision: SHA256.Digest) throws -> Bool {
        try flushForDataManagement()
        return try AppDataBackup.sourceRevision(at: StartupPersistentStore.defaultURL) == revision
    }

    private func flushForDataManagement() throws {
        guard boundModelContainer != nil else { throw ChatSessionRepositoryReadError.contextUnavailable }
        if let failure = settingsManager.settingsWriteFailure { throw NSError(domain: "DataTransferSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: failure.message]) }
        try chatSessionsViewModel.flushForDataTransfer()
        try settingsManager.persistence.saveContextOrThrow(label: "prepare data transfer")
    }

    func validateDataImportAvailability() throws {
        guard !chatSessionsViewModel.hasDataTransferBlockingActivity,
              !voiceOverlayViewModel.isPresented, !speechInputManager.isRecording,
              !audioManager.isAudioPlaying, !audioManager.hasPendingTTSSynthesisWork() else { throw DataBackupError.activityInProgress }
    }

    func applyDataManagementMutation(_ mutation: DataManagementMutation, revision: SHA256.Digest) throws {
        try validateDataImportAvailability()
        try flushForDataManagement()
        guard boundModelContainer != nil,
              let sessionsContext = sessionsModelContext,
              let settingsContext = settingsModelContext else { throw ChatSessionRepositoryReadError.contextUnavailable }
        let storeURL = StartupPersistentStore.defaultURL
        guard try AppDataBackup.sourceRevision(at: storeURL) == revision else { throw DataBackupError.dataChanged }
        let context: ModelContext
        switch mutation {
        case .deletePreference: context = settingsContext
        case .deleteModelData: context = settingsContext
        default: context = sessionsContext
        }
        let autosaveEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosaveEnabled }
        do {
            try mutation.apply(in: context, storeURL: storeURL)
            try Task.checkCancellation()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func synchronizeDataManagementChanges(_ mutation: DataManagementMutation) throws {
        guard let container = boundModelContainer else { throw ChatSessionRepositoryReadError.contextUnavailable }
        if mutation.changesSettings {
            // Replace the settings projection after a committed maintenance write.
            // Its editing-context identity also prevents stale settings forms from
            // writing their previous values back over the deletion.
            let updatedSettingsContext = ModelContext(container)
            guard settingsManager.attach(context: updatedSettingsContext) else {
                throw DataBackupError.integrityCheckFailed
            }
            settingsModelContext = updatedSettingsContext
        }
        switch mutation {
        case .deletePreference:
            // Preference-only writes do not modify chat records.
            break
        case .deleteModelData:
            break
        default:
            guard chatSessionsViewModel.didApplyDataManagementChanges(deletedIDs: mutation.deletedChatIDs) else {
                throw DataBackupError.integrityCheckFailed
            }
        }
        chatSessionsViewModel.refreshChatConfigurationIfNeeded()
    }

    func quiescePersistentStore() {
        chatSessionsViewModel.detachPersistentStore()
        settingsManager.detachPersistentStore()
        sessionsModelContext = nil
        settingsModelContext = nil
        boundModelContainer = nil
    }

    func updatePersistenceMode(for scenePhase: ScenePhase) {
        let shouldForceImmediateSaves = scenePhase != .active
        chatSessionsViewModel.setImmediatePersistenceEnabled(shouldForceImmediateSaves)
    }

}
