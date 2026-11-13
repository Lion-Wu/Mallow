//
//  StartupDataGate.swift
//  Mallow
//
//  Created by OpenAI Codex on 2026/02/12.
//

import SwiftUI
import SwiftData
import Darwin
#if os(macOS)
import AppKit
#endif

@MainActor
final class StartupDataCoordinator: ObservableObject {
    typealias ContainerFactory = @Sendable () throws -> ModelContainer
    typealias ContainerPreparer = @MainActor (ModelContainer) -> Void

    enum LaunchState {
        case loading
        case ready(ModelContainer)
        case failed(String)
        case unavailable(String)
    }

    @Published private(set) var launchState: LaunchState = .loading
    @Published private(set) var isResettingStore = false
    @Published var resetError: String?
    @Published private(set) var isExporting = false
    @Published private(set) var isScanningRecovery = false
    @Published private(set) var recoveryPlan: DataRecoveryPlan?
    @Published private(set) var recoveryError: String?
    @Published private(set) var importCleanupError: String?
    private var recoveryTask: Task<Void, Never>?
    var isRecoveryActive: Bool { isScanningRecovery || recoveryPlan != nil }
    private var activeOperationID = UUID()
    private let containerFactory: ContainerFactory
    private let prepareContainer: ContainerPreparer
    private let ownershipDirectory: URL?
    private var storeOwnership: PersistentStoreOwnership?
    var onWillResetPersistentStore: (() -> Void)?
    var onWillClearAllAppData: (() -> Void)?

    init(prepareContainer: @escaping ContainerPreparer = { _ in }) {
        self.containerFactory = Self.makeContainer
        self.prepareContainer = prepareContainer
        ownershipDirectory = StartupPersistentStore.defaultURL.deletingLastPathComponent()
        beginPersistentContainerLoad()
    }

    init(
        containerFactory: @escaping ContainerFactory,
        ownershipDirectory: URL? = nil,
        prepareContainer: @escaping ContainerPreparer = { _ in }
    ) {
        self.containerFactory = containerFactory
        self.prepareContainer = prepareContainer
        self.ownershipDirectory = ownershipDirectory
        beginPersistentContainerLoad()
    }

    func reportPersistentStoreReadFailure(_ error: Error) {
        guard ownershipDirectory == nil || storeOwnership != nil else { return }
        guard !isResettingStore, !isRecoveryActive, !isExporting else { return }
        activeOperationID = UUID()
        launchState = .failed(Self.formatErrorMessage(error))
    }

    func resetDataAndRetry() {
        guard !isResettingStore, !isRecoveryActive, !isExporting else { return }
        let container: ModelContainer?
        switch launchState {
        case .ready(let current): container = current
        case .failed: container = nil
        case .loading, .unavailable: return
        }
        do { try AppDataReset.begin() }
        catch {
            resetError = Self.formatErrorMessage(error)
            return
        }
        resetError = nil
        isResettingStore = true
        activeOperationID = UUID()
        onWillClearAllAppData?()
        onWillResetPersistentStore?()
        container?.mainContext.autosaveEnabled = false
        container?.mainContext.rollback()
        launchState = .loading

        Task {
            do {
                // Invalidate the live store before removing any of its files.
                try container?.erase()
                try await Self.resetPersistentStoreAsync().get()
                isResettingStore = false
                beginPersistentContainerLoad()
            } catch {
                isResettingStore = false
                let template = String(localized: "RECOVERY_RESET_FAILED", defaultValue: "Reset data failed.\n%@")
                launchState = .failed(String.localizedStringWithFormat(template, Self.formatErrorMessage(error)))
            }
        }
    }

    func exportData() async throws -> RawDataExport {
        guard case .failed = launchState, !AppDataReset.isPending, !isResettingStore, !isRecoveryActive, !isExporting else {
            throw CocoaError(.userCancelled)
        }
        onWillResetPersistentStore?()
        isExporting = true
        do {
            return try await Task.detached(priority: .userInitiated) {
                try RawDataExport.applicationSnapshot()
            }.value
        } catch {
            isExporting = false
            throw error
        }
    }

    func finishExport(_ archive: RawDataExport?) {
        archive?.discardInBackground()
        isExporting = false
    }

    static func exitApplication() {
        #if os(macOS)
        NSApp.terminate(nil)
        #else
        exit(0)
        #endif
    }

    /// Opens the fixed application database.
    private nonisolated static func makeContainer() throws -> ModelContainer {
        try StartupPersistentStore.open(at: StartupPersistentStore.defaultURL)
    }

    func scanForRecoverableData() {
        guard !isResettingStore, !isRecoveryActive, !isExporting else { return }
        guard case .failed = launchState, !AppDataReset.isPending else { return }
        onWillResetPersistentStore?()
        recoveryError = nil
        importCleanupError = nil
        isScanningRecovery = true
        recoveryTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let plan = try StartupDataRecovery.prepare(
                    sourceURL: StartupPersistentStore.defaultURL
                )
                guard let self else {
                    plan.discard()
                    return
                }
                await self.finishRecoveryScan(.success(plan))
            } catch {
                await self?.finishRecoveryScan(.failure(error))
            }
        }
    }

    private func finishRecoveryScan(_ result: Result<DataRecoveryPlan, Error>) {
        guard !Task.isCancelled else {
            if case .success(let plan) = result { plan.discardInBackground() }
            return
        }
        recoveryTask = nil
        isScanningRecovery = false
        switch result {
        case .success(let plan): recoveryPlan = plan
        case .failure(let error): recoveryError = Self.formatErrorMessage(error)
        }
    }

    func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        isScanningRecovery = false
        recoveryPlan?.discardInBackground()
        recoveryPlan = nil
        recoveryError = nil
    }

    func confirmRecovery() async {
        guard case .failed = launchState,
              !isResettingStore, !isExporting,
              let plan = recoveryPlan, plan.recoveredCount > 0 else { return }
        recoveryPlan = nil
        recoveryError = nil
        defer { plan.discardInBackground() }
        do { try await replacePersistentStore(with: plan) }
        catch { recoveryError = Self.formatErrorMessage(error) }
    }

    func installImportedStore(_ plan: DataRecoveryPlan, credentials: [DataBackupCredential], validateSource: () throws -> Void) async throws {
        guard case .ready = launchState,
              !isResettingStore, !isRecoveryActive, !isExporting else { throw CocoaError(.userCancelled) }
        try Task.checkCancellation()
        try validateSource()
        importCleanupError = nil
        do { try DataImportTransaction.begin(operationID: plan.id, credentials: credentials) }
        catch {
            if DataImportTransaction.hasPendingTransaction {
                onWillResetPersistentStore?()
                launchState = .failed(Self.formatErrorMessage(error))
            }
            throw error
        }
        do { try await replacePersistentStore(with: plan) }
        catch {
            // Restore credentials only when replacement did not commit.
            // A committed replacement never restores the previous database.
            do { try DataImportTransaction.recoverInterruptedImport() }
            catch {
                launchState = .failed(Self.formatErrorMessage(error))
                throw error
            }
            throw error
        }
        do { try DataImportTransaction.finish() }
        catch { importCleanupError = Self.formatErrorMessage(error) }
    }

    private func replacePersistentStore(with plan: DataRecoveryPlan) async throws {
        onWillResetPersistentStore?()
        isResettingStore = true
        defer { isResettingStore = false }
        launchState = .loading
        do {
            // Once installation begins, wait for it even if the presenting task is
            // cancelled. The candidate files must outlive the database commit.
            let result = await Self.makeContainerAsync {
                try StartupPersistentStore.replace(with: plan)
                return try Self.makeContainer()
            }
            let container = try result.get()
            // Allow preparation to report a read failure for the new container.
            isResettingStore = false
            prepareContainer(container)
            guard case .loading = launchState else { throw CocoaError(.fileReadCorruptFile) }
            launchState = .ready(container)
        } catch {
            launchState = .failed(Self.formatErrorMessage(error))
            throw error
        }
    }

    private func beginPersistentContainerLoad() {
        if let ownershipDirectory, storeOwnership == nil {
            do { storeOwnership = try PersistentStoreOwnership(directory: ownershipDirectory) }
            catch {
                launchState = .unavailable(error.localizedDescription)
                return
            }
        }
        launchState = .loading
        let operationID = UUID()
        activeOperationID = operationID
        let factory = containerFactory
        let ownership = storeOwnership

        Task { [weak self] in
            defer { withExtendedLifetime(ownership) {} }
            if AppDataReset.isPending {
                let resetResult = await Self.resetPersistentStoreAsync()
                guard let self, self.activeOperationID == operationID else { return }
                if case .failure(let error) = resetResult {
                    self.launchState = .failed(Self.formatErrorMessage(error))
                    return
                }
            }
            // Complete the confirmed reset before an import can restore old keys.
            do { try DataImportTransaction.recoverInterruptedImport() }
            catch {
                self?.launchState = .failed(Self.formatErrorMessage(error))
                return
            }
            let result = await Self.makeContainerAsync(using: factory)
            guard let self, self.activeOperationID == operationID else { return }
            switch result {
            case .success(let container):
                self.prepareContainer(container)
                guard self.activeOperationID == operationID else { return }
                guard case .loading = self.launchState else { return }
                self.launchState = .ready(container)
            case .failure(let error):
                self.launchState = .failed(Self.formatErrorMessage(error))
            }
        }
    }

    func retryStoreAccess() {
        guard case .unavailable = launchState else { return }
        beginPersistentContainerLoad()
    }

    private nonisolated static func makeContainerAsync(
        using factory: @escaping ContainerFactory
    ) async -> Result<ModelContainer, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: .success(try factory()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    private static func resetPersistentStoreAsync() async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                try await AppDataReset.complete()
                return Result<Void, Error>.success(())
            } catch {
                return Result<Void, Error>.failure(error)
            }
        }.value
    }

    private nonisolated static func formatErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription)\n[\(nsError.domain): \(nsError.code)]"
    }
}

struct StartupDataGateView<LoadingContent: View, ReadyContent: View>: View {
    @ObservedObject private var coordinator: StartupDataCoordinator
    private let loadingContent: () -> LoadingContent
    private let readyContent: (ModelContainer) -> ReadyContent
    @State private var isShowingRecovery = false
    @State private var isShowingCleanupError = false
    @State private var exportArchive: RawDataExport?
    @State private var exportError: String?
    #if os(macOS)
    @State private var exportDocument: DataBackupDocument?
    #endif

    init(
        coordinator: StartupDataCoordinator,
        @ViewBuilder loadingContent: @escaping () -> LoadingContent,
        @ViewBuilder readyContent: @escaping (ModelContainer) -> ReadyContent
    ) {
        self.coordinator = coordinator
        self.loadingContent = loadingContent
        self.readyContent = readyContent
    }

    var body: some View {
        Group {
            switch coordinator.launchState {
            case .loading:
                loadingContent()
            case .unavailable(let message):
                ZStack {
                    AppBackgroundView()
                    VStack(spacing: 18) {
                        Image(systemName: "externaldrive.badge.person.crop")
                            .font(.system(size: 34))
                        Text("DATA_UNAVAILABLE").font(.title3.weight(.semibold))
                        Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack {
                            Button("COMMON_ACTION_EXIT") { StartupDataCoordinator.exitApplication() }.buttonStyle(.bordered)
                            Button("COMMON_ACTION_TRY_AGAIN") { coordinator.retryStoreAccess() }.buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 520)
                }
            case .failed(let errorMessage):
                StartupDataErrorView(
                    errorMessage: errorMessage,
                    isResetting: coordinator.isResettingStore,
                    isRecoveryActive: coordinator.isRecoveryActive,
                    isExporting: coordinator.isExporting,
                    hasPendingReset: AppDataReset.isPending,
                    onExit: { StartupDataCoordinator.exitApplication() },
                    onReset: { coordinator.resetDataAndRetry() },
                    onRecover: {
                        isShowingRecovery = true
                        coordinator.scanForRecoverableData()
                    },
                    onExport: {
                        Task {
                            do {
                                let archive = try await coordinator.exportData()
                                exportArchive = archive
                                #if os(macOS)
                                exportDocument = try await Task.detached(priority: .userInitiated) {
                                    DataBackupDocument(data: try Data(contentsOf: archive.url))
                                }.value
                                #endif
                            } catch {
                                #if os(macOS)
                                finishMacExport(error: error)
                                #else
                                exportError = error.localizedDescription
                                #endif
                            }
                        }
                    }
                )
            case .ready(let container):
                readyContent(container)
                    .id(ObjectIdentifier(container))
            }
        }
        #if os(macOS)
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { finishMacExport() } }
            ),
            document: exportDocument,
            contentType: .zip,
            defaultFilename: exportArchive?.url.deletingPathExtension().lastPathComponent
        ) { result in
            if case .failure(let error) = result { finishMacExport(error: error) }
            else { finishMacExport() }
        }
        #else
        .background {
            DataExportSharePresenter(url: exportArchive?.url) { _, error in
                if let error {
                    exportError = error.localizedDescription
                }
                coordinator.finishExport(exportArchive)
                exportArchive = nil
            }
            .frame(width: 1, height: 1)
        }
        #endif
        .alert("DATA_ACTION_CLEAR_APP_DATA", isPresented: Binding(
            get: { coordinator.resetError != nil },
            set: { if !$0 { coordinator.resetError = nil } }
        )) {
            Button("COMMON_ACTION_OK", role: .cancel) { coordinator.resetError = nil }
        } message: { Text(coordinator.resetError ?? "") }
        .alert("DATA_EXPORT", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("COMMON_ACTION_OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
        .sheet(isPresented: $isShowingRecovery, onDismiss: {
            coordinator.cancelRecovery()
            isShowingCleanupError = coordinator.importCleanupError != nil
        }) {
            DataRecoveryPreviewView(coordinator: coordinator)
        }
        .alert("DATA_IMPORT_CLEANUP_FAILED", isPresented: $isShowingCleanupError) {
            Button("COMMON_ACTION_OK", role: .cancel) {}
        } message: {
            Text("DATA_IMPORT_JOURNAL_CLEANUP_FAILED")
            Text(coordinator.importCleanupError ?? "")
        }
        .onChange(of: coordinator.importCleanupError, initial: true) { _, error in
            if error != nil, !isShowingRecovery { isShowingCleanupError = true }
        }
        .onChange(of: coordinator.recoveryPlan?.id) { oldValue, newValue in
            if oldValue != nil, newValue == nil { isShowingRecovery = false }
        }
    }

    #if os(macOS)
    private func finishMacExport(error: Error? = nil) {
        if let error, (error as? CocoaError)?.code != .userCancelled {
            exportError = error.localizedDescription
        }
        coordinator.finishExport(exportArchive)
        exportArchive = nil
        exportDocument = nil
    }
    #endif
}

struct StartupLoadingView: View {
    let title: LocalizedStringKey

    var body: some View {
        ZStack {
            AppBackgroundView()
            ProgressView(title)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Recovery view shown when startup cannot read the persistent store.
struct StartupDataErrorView: View {
    let errorMessage: String
    let isResetting: Bool
    var isRecoveryActive = false
    var isExporting = false
    var hasPendingReset = false
    let onExit: () -> Void
    let onReset: () -> Void
    let onRecover: () -> Void
    let onExport: () -> Void
    @State private var isConfirmingReset = false

    var body: some View {
        ZStack {
            AppBackgroundView()
            VStack(spacing: 18) {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.red)

                Text("DATA_ERROR")
                    .font(.title3.weight(.semibold))

                Text("STORAGE_STARTUP_READ_FAILED")
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(errorMessage)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 140)
                .appChromedContainer(cornerRadius: 12, shadowOpacity: 0.14)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { actions }
                    VStack(spacing: 12) { actions }
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .appChromedContainer(cornerRadius: 28, shadowOpacity: 0.32)
            .padding(.horizontal, 24)
        }
        .alert("DATA_CLEAR_CONFIRMATION", isPresented: $isConfirmingReset) {
            Button("COMMON_ACTION_CANCEL", role: .cancel) {}
            Button("DATA_ACTION_CLEAR_APP_DATA", role: .destructive, action: onReset)
                .disabled(isResetting || isRecoveryActive || isExporting)
        } message: {
            Text("DATA_CLEAR_WARNING")
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("COMMON_ACTION_EXIT", action: onExit)
            .buttonStyle(.bordered)
            .disabled(isResetting || isRecoveryActive || isExporting)

        Button(role: .destructive) {
            isConfirmingReset = true
        } label: {
            HStack(spacing: 8) {
                if isResetting { ProgressView().controlSize(.small) }
                Text(isResetting ? LocalizedStringKey("RECOVERY_RESETTING") : LocalizedStringKey("DATA_ACTION_CLEAR_APP_DATA"))
            }
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .foregroundStyle(.red)
        .disabled(isResetting || isRecoveryActive || isExporting)

        Button(action: onExport) {
            Text("DATA_ACTION_EXPORT")
                .opacity(isExporting ? 0 : 1)
                .overlay {
                    if isExporting { ProgressView().controlSize(.small) }
                }
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("DATA_ACTION_EXPORT"))
        .accessibilityValue(isExporting ? Text("COMMON_LOADING") : Text(""))
        .disabled(isResetting || isRecoveryActive || isExporting || hasPendingReset)

        Button("RECOVERY_ACTION_RECOVER", action: onRecover)
            .buttonStyle(.borderedProminent)
            .disabled(isResetting || isRecoveryActive || isExporting || hasPendingReset)
    }

}

#Preview("Startup Data Error") {
    StartupDataErrorView(
        errorMessage: "The file couldn't be opened because it is corrupted.\n[SwiftData: 42]",
        isResetting: false,
        onExit: {},
        onReset: {},
        onRecover: {},
        onExport: {}
    )
}

#Preview("Startup Data Error (Resetting)") {
    StartupDataErrorView(
        errorMessage: "Unable to read SQLite file.\n[NSSQLiteErrorDomain: 11]",
        isResetting: true,
        onExit: {},
        onReset: {},
        onRecover: {},
        onExport: {}
    )
}
