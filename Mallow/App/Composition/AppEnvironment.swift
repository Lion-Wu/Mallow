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
        self.settingsManager.modelCatalogController.connectionReporter = { [reachabilityMonitor = self.reachabilityMonitor] observation in
            reachabilityMonitor.record(observation, for: .chat)
        }
        self.settingsManager.presetApplyController.connectionReporter = { [reachabilityMonitor = self.reachabilityMonitor] observation in
            reachabilityMonitor.record(observation, for: .tts)
        }
        self.audioManager.connectionReporter = { [reachabilityMonitor = self.reachabilityMonitor] observation in
            DispatchQueue.main.async {
                reachabilityMonitor.record(observation, for: .tts)
            }
        }
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

    func stageRawDataExport() async throws -> RawDataExport.StagedSnapshot {
        return try await stageDataSnapshot(sources: RawDataExport.applicationSources())
    }

    func stageDataManagementRead() async throws -> RawDataExport.StagedSnapshot {
        let current = StartupPersistentStore.defaultURL
        let sources = Dictionary(uniqueKeysWithValues: ["", "-wal", "-shm", ".images"].map {
            ("default.store" + $0, URL(fileURLWithPath: current.path + $0))
        })
        return try await stageDataSnapshot(sources: sources)
    }

    private func stageDataSnapshot(sources: [String: URL]) async throws -> RawDataExport.StagedSnapshot {
        try flushForDataManagement()
        guard let containerID = boundModelContainer.map(ObjectIdentifier.init) else { throw ChatSessionRepositoryReadError.contextUnavailable }
        let lease = ChatImageStore.retainFiles(at: StartupPersistentStore.defaultURL)
        let imageDirectoryPath = ChatImageStore.directory(for: StartupPersistentStore.defaultURL).path
        let backgroundSources = sources.filter { $0.key == "Documents" || $0.value.path == imageDirectoryPath }
        // Fix the database and keychain before yielding to another app-owned writer.
        // Images are immutable and the lease defers deletion until copying finishes.
        let staged = try RawDataExport.stage(sources: sources.filter { backgroundSources[$0.key] == nil },
            keychain: RawDataExport.keychainSnapshot(service: Bundle.main.bundleIdentifier ?? "Mallow"))
        let worker = Task.detached(priority: .userInitiated) {
            try withExtendedLifetime(lease) { try staged.append(sources: backgroundSources) }
        }
        do {
            try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard boundModelContainer.map(ObjectIdentifier.init) == containerID else { throw DataBackupError.dataChanged }
            return staged
        } catch {
            staged.discardInBackground()
            throw error
        }
    }

    func ownsDataManagementContext(_ context: ModelContext) -> Bool {
        context.container === boundModelContainer
    }

    struct DataManagementReadVersion {
        fileprivate let containerID: ObjectIdentifier
        fileprivate let files: DataStoreFileVersion
        fileprivate let lease: ChatImageStore.ReadLease
    }

    func validatedDataImportSource(_ reviewed: DataBackupReadResult) async throws -> DataManagementReadVersion? {
        guard let version = try await validatedDataManagementSource(reviewed.sourceRevision),
              try dataManagementCredentialsMatch(reviewed) else { return nil }
        return version
    }

    private func dataManagementCredentialsMatch(_ reviewed: DataBackupReadResult) throws -> Bool {
        let keychain = try RawDataExport.keychainSnapshot(service: Bundle.main.bundleIdentifier ?? "Mallow")
        return DataBackupCredentials.recover(keychain, presetIDs: Set(reviewed.snapshot.chatServers.map(\.id))).values == reviewed.snapshot.credentials
    }

    private func validatedDataManagementSource(_ revision: SHA256.Digest) async throws -> DataManagementReadVersion? {
        try flushForDataManagement()
        guard let containerID = boundModelContainer.map(ObjectIdentifier.init) else { throw ChatSessionRepositoryReadError.contextUnavailable }
        let storeURL = StartupPersistentStore.defaultURL
        let lease = ChatImageStore.retainFiles(at: storeURL)
        let version = DataManagementReadVersion(containerID: containerID, files: try DataStoreFileVersion(at: storeURL), lease: lease)
        let worker = Task.detached(priority: .userInitiated) {
            try withExtendedLifetime(lease) { try AppDataBackup.sourceRevision(at: storeURL) }
        }
        let actual = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        try flushForDataManagement()
        guard boundModelContainer.map(ObjectIdentifier.init) == containerID,
              try DataStoreFileVersion(at: storeURL) == version.files,
              actual == revision else { return nil }
        return version
    }

    private func requireCurrentDataManagementSource(_ version: DataManagementReadVersion) throws {
        try flushForDataManagement()
        guard boundModelContainer.map(ObjectIdentifier.init) == version.containerID,
              try DataStoreFileVersion(at: StartupPersistentStore.defaultURL) == version.files else {
            throw DataBackupError.dataChanged
        }
    }

    func requireCurrentDataImportSource(_ version: DataManagementReadVersion, reviewed: DataBackupReadResult) throws {
        try validateDataImportAvailability()
        try requireCurrentDataManagementSource(version)
        guard try dataManagementCredentialsMatch(reviewed) else { throw DataBackupError.dataChanged }
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

    func applyDataManagementMutation(_ mutation: DataManagementMutation, revision: SHA256.Digest) async throws {
        guard let version = try await validatedDataManagementSource(revision) else { throw DataBackupError.dataChanged }
        try validateDataImportAvailability()
        try requireCurrentDataManagementSource(version)
        guard boundModelContainer != nil,
              let sessionsContext = sessionsModelContext,
              let settingsContext = settingsModelContext else { throw ChatSessionRepositoryReadError.contextUnavailable }
        let storeURL = StartupPersistentStore.defaultURL
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
            try ChatImageStore.persistPending(in: context)
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
        switch mutation {
        case .deletePreference, .deleteModelData: break
        default: try ChatImageStore.removeUnreferencedFiles(at: StartupPersistentStore.defaultURL)
        }
    }

    func quiescePersistentStore() {
        chatSessionsViewModel.detachPersistentStore()
        settingsManager.detachPersistentStore()
        sessionsModelContext = nil
        settingsModelContext = nil
        boundModelContainer = nil
    }

    func updateConnectionMonitoring(for scenePhase: ScenePhase) {
        let active = scenePhase == .active
        reachabilityMonitor.setActive(active)
        if !active {
            voiceOverlayViewModel.cancelConnectivityTask()
        } else if voiceOverlayViewModel.isPresented, voiceOverlayViewModel.state == .connecting {
            voiceOverlayViewModel.beginConnectivityPreflight()
        }
    }

    func updatePersistenceMode(for scenePhase: ScenePhase) {
        let shouldForceImmediateSaves = scenePhase != .active
        chatSessionsViewModel.setImmediatePersistenceEnabled(shouldForceImmediateSaves)
    }

}
