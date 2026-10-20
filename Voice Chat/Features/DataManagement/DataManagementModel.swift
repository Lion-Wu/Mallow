import Foundation
import Combine
import CryptoKit
import SwiftData

@MainActor
final class DataManagementModel: ObservableObject {
    enum OperationKind {
        case loadUsage, loadCatalog, exportBackup, exportUnusedFiles, readImport, mergeImport
        case cleanNetworkCache, cleanTemporaryFiles, scanData, deleteUnusedFiles
        case deleteChats, deleteAttachments, deletePreference, deleteModelData, clearContext, deleteIssues, recoverMessages
    }

    struct OperationProgress {
        let kind: OperationKind
        var message: String
    }

    @Published private(set) var usage: DataStorageUsage?
    @Published private(set) var progress: OperationProgress?
    var isBusy: Bool { progress != nil }
    @Published var errorMessage: String?
    @Published private(set) var preparedExport: DataPreparedExport?
    @Published var preview: DataImportPreview? {
        didSet { if preview == nil { updateStoredDataIfNeeded() } }
    }
    @Published private(set) var catalog: DataStorageCatalog?
    @Published private(set) var cleanupReport: DataCleanupReport?
    @Published private(set) var unusedFiles: [DataUnusedFile]?
    @Published private(set) var attachmentThumbnails: [UUID: [DataAttachmentThumbnail]]?
    private var operation: Task<Void, Never>?
    private weak var observedEnvironment: AppEnvironment?
    private var storageSubscriptions = Set<AnyCancellable>()
    private var needsStorageUpdate = false

    func observeStorage(environment: AppEnvironment) {
        guard observedEnvironment !== environment else { return }
        storageSubscriptions.removeAll()
        observedEnvironment = environment
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak environment] notification in
                guard let self, let environment,
                      let context = notification.object as? ModelContext,
                      environment.ownsDataManagementContext(context) else { return }
                self.needsStorageUpdate = true
                self.updateStoredDataIfNeeded()
            }
            .store(in: &storageSubscriptions)
        environment.chatSessionsViewModel.$hasActiveTextRequests
            .combineLatest(environment.chatSessionsViewModel.$isRealtimeVoiceLocked)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStoredDataIfNeeded() }
            .store(in: &storageSubscriptions)
    }

    private func updateStoredDataIfNeeded() {
        guard needsStorageUpdate, !isBusy, preview == nil,
              let environment = observedEnvironment,
              !environment.chatSessionsViewModel.hasDataTransferBlockingActivity else { return }
        run(.loadCatalog, clearsError: false) {
            if self.catalog != nil || self.cleanupReport != nil {
                try await self.readStoredData(environment: environment)
            } else {
                self.needsStorageUpdate = false
            }
            self.usage = try await Self.background { try DataStorageInspector.measure() }
        }
    }

    func progressMessage(for kind: OperationKind) -> String? {
        progress?.kind == kind ? progress?.message : nil
    }

    func refreshUsage() {
        run(.loadUsage) {
            self.usage = try await Self.background { try DataStorageInspector.measure() }
        }
    }

    func clean(_ category: DataCleanupCategory) {
        run(category == .networkCache ? .cleanNetworkCache : .cleanTemporaryFiles) {
            self.usage = try await Self.background {
                try DataStorageInspector.clean(category)
                return try DataStorageInspector.measure()
            }
        }
    }

    func exportBackup(environment: AppEnvironment, commitEdits: @escaping () -> Void) {
        run(.exportBackup, message: String(localized: "Preparing Export...")) {
            commitEdits()
            let snapshot = try environment.stageRawDataExport()
            self.progress?.message = String(localized: "Compressing Data...")
            do {
                self.preparedExport = try await Self.background {
                    try DataPreparedExport(archive: snapshot.archive(), source: .backup)
                }
            } catch {
                snapshot.discard()
                throw error
            }
        }
    }

    func exportUnusedFiles(_ files: [DataUnusedFile]) {
        guard !files.isEmpty else { return }
        run(.exportUnusedFiles, message: String(localized: "Preparing Export...")) {
            self.preparedExport = try await Self.background {
                try DataPreparedExport(archive: DataUnusedFileInspector.export(files), source: .unusedFiles)
            }
        }
    }

    func finishExport(source: DataPreparedExport.Source, error: Error? = nil) {
        if preparedExport?.source == source { preparedExport = nil }
        if let error, (error as? CocoaError)?.code != .userCancelled {
            errorMessage = error.localizedDescription
        }
    }

    func importBackup(_ url: URL, environment: AppEnvironment, commitEdits: @escaping () -> Void) {
        run(.readImport, message: String(localized: "Reading Import File...")) {
            let incoming = try await Self.background {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?
                var result: Result<DataBackupReadResult, Error> = .failure(DataBackupError.unsupportedFormat)
                NSFileCoordinator().coordinate(readingItemAt: url, error: &coordinationError) { readableURL in
                    result = Result {
                        try DataBackupArchive.read(readableURL)
                    }
                }
                if let coordinationError { throw coordinationError }
                return try result.get()
            }
            commitEdits()
            self.progress?.message = String(localized: "Comparing Data...")
            let current = try await self.readCurrentData(environment: environment)
            self.preview = try await Self.background { try DataBackupMerge.preview(current: current, incoming: incoming) }
        }
    }

    func confirmImport(environment: AppEnvironment, coordinator: StartupDataCoordinator, commitEdits: @escaping () -> Void) {
        guard let reviewed = preview else { return }
        run(.mergeImport, message: String(localized: "Checking for Changes...")) {
            commitEdits()
            try environment.validateDataImportAvailability()
            guard try environment.dataManagementSourceMatches(reviewed.original) else {
                let current = try await self.readCurrentData(environment: environment)
                self.preview = try await Self.background { try DataBackupMerge.preview(current: current, incoming: reviewed.incoming) }
                throw DataBackupError.dataChanged
            }
            self.progress?.message = String(localized: "Merging Data...")
            let worker = Task.detached(priority: .userInitiated) { try reviewed.merged.prepareStore() }
            let plan = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            defer { plan.discard() }
            try Task.checkCancellation()
            try environment.validateDataImportAvailability()
            guard try environment.dataManagementSourceMatches(reviewed.original) else {
                let latest = try await self.readCurrentData(environment: environment)
                self.preview = try await Self.background { try DataBackupMerge.preview(current: latest, incoming: reviewed.incoming) }
                throw DataBackupError.dataChanged
            }
            let changedCredentials = reviewed.merged.credentials.filter { !reviewed.original.snapshot.credentials.contains($0) }
            try coordinator.installImportedStore(plan, credentials: changedCredentials)
            self.preview = nil
        }
    }

    func loadCatalog(environment: AppEnvironment, commitEdits: @escaping () -> Void, includeAttachmentThumbnails: Bool = false) {
        run(.loadCatalog) {
            commitEdits()
            try await self.readStoredData(environment: environment, includeCatalog: true, includeThumbnails: includeAttachmentThumbnails)
        }
    }

    func scanData(environment: AppEnvironment, commitEdits: @escaping () -> Void) {
        run(.scanData, message: String(localized: "Checking Data...")) {
            self.cleanupReport = nil
            self.unusedFiles = nil
            do { self.unusedFiles = try await Self.background { try DataUnusedFileInspector.scan() } }
            catch { self.errorMessage = error.localizedDescription }
            commitEdits()
            try await self.readStoredData(environment: environment, includeCleanupReport: true)
        }
    }

    func deleteUnusedFiles(_ files: [DataUnusedFile]) {
        guard !files.isEmpty else { return }
        run(.deleteUnusedFiles, message: String(localized: "Removing Files...")) {
            // Once deletion starts, always finish reading the actual disk state,
            // including when only part of the selection could be removed.
            let result = await Task.detached(priority: .userInitiated) {
                var errors: [String] = []
                do { try DataUnusedFileInspector.delete(files) }
                catch { errors.append(error.localizedDescription) }
                var remaining: [DataUnusedFile]?
                var usage: DataStorageUsage?
                do { remaining = try DataUnusedFileInspector.scan() }
                catch { errors.append(error.localizedDescription) }
                do { usage = try DataStorageInspector.measure() }
                catch { errors.append(error.localizedDescription) }
                return (remaining, usage, errors)
            }.value
            self.unusedFiles = result.0
            self.usage = result.1
            if !result.2.isEmpty { self.errorMessage = result.2.joined(separator: "\n") }
        }
    }

    func apply(_ mutation: DataManagementMutation, revision: SHA256.Digest,
               environment: AppEnvironment, commitEdits: @escaping () -> Void,
               completion: @escaping () -> Void) {
        let kind: OperationKind = switch mutation {
        case .deleteChats: .deleteChats
        case .deleteAttachments, .deleteAllAttachments: .deleteAttachments
        case .deletePreference: .deletePreference
        case .deleteModelData: .deleteModelData
        case .clearContext: .clearContext
        case .deleteIssues: .deleteIssues
        case .recoverUnowned: .recoverMessages
        }
        run(kind, message: String(localized: "Applying Data Changes...")) {
            commitEdits()
            do {
                try environment.applyDataManagementMutation(mutation, revision: revision)
            } catch is CancellationError {
                throw CancellationError()
            } catch DataBackupError.dataChanged {
                // Refresh the reviewed data, never replay a destructive operation
                // against a version that the user has not confirmed.
                try await self.readStoredData(environment: environment)
                self.errorMessage = String(localized: "Your data changed. Review the updated list before continuing. No data was deleted.")
                return
            } catch {
                self.errorMessage = String(localized: "Changes could not be saved. No data was deleted.") + "\n" + error.localizedDescription
                return
            }
            do {
                try environment.synchronizeDataManagementChanges(mutation)
                try await self.readStoredData(environment: environment)
                self.usage = try await Self.background { try DataStorageInspector.measure() }
                completion()
            } catch {
                self.errorMessage = String(localized: "Changes were saved, but the updated data could not be displayed.") + "\n" + error.localizedDescription
            }
        }
    }

    func cancel() { operation?.cancel() }

    private func readStoredData(environment: AppEnvironment, includeCatalog: Bool = false, includeThumbnails: Bool = false, includeCleanupReport: Bool = false) async throws {
        let catalog = includeCatalog || self.catalog != nil
        let thumbnails = includeThumbnails || attachmentThumbnails != nil
        let cleanup = includeCleanupReport || cleanupReport != nil
        needsStorageUpdate = false
        let staged = try environment.stageDataManagementRead()
        defer { staged.discard() }
        let snapshot = try await Self.background {
            try DataManagementStore.snapshot(at: staged.directory.appendingPathComponent("Voice Chat Data"),
                includeCatalog: catalog, includeThumbnails: thumbnails, includeCleanupReport: cleanup)
        }
        self.catalog = snapshot.catalog
        attachmentThumbnails = snapshot.thumbnails
        cleanupReport = snapshot.cleanupReport
    }

    private func readCurrentData(environment: AppEnvironment) async throws -> DataBackupReadResult {
        let staged = try environment.stageDataManagementRead()
        defer { staged.discard() }
        return try await Self.background {
            let contents = staged.directory.appendingPathComponent("Voice Chat Data")
            return try AppDataBackup.recover(from: contents.appendingPathComponent("default.store"),
                keychain: Data(contentsOf: contents.appendingPathComponent("Keychain.plist")), allowSourceSidecarCreation: true)
        }
    }

    private func run(_ kind: OperationKind, message: String = String(localized: "Processing Data..."), clearsError: Bool = true, _ work: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        progress = OperationProgress(kind: kind, message: message)
        if clearsError { errorMessage = nil }
        operation = Task {
            defer {
                self.progress = nil
                self.operation = nil
                self.updateStoredDataIfNeeded()
            }
            do { try await work() }
            catch is CancellationError { }
            catch { self.errorMessage = error.localizedDescription }
        }
    }

    static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try work()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

nonisolated final class DataPreparedExport: Sendable {
    enum Source: Sendable { case backup, unusedFiles }

    let source: Source
    let archive: RawDataExport
    #if os(macOS)
    let document: DataBackupDocument
    #endif

    init(archive: RawDataExport, source: Source) throws {
        self.archive = archive
        self.source = source
        #if os(macOS)
        do {
            document = DataBackupDocument(data: try Data(contentsOf: archive.url))
        } catch {
            archive.discard()
            throw error
        }
        #endif
    }

    deinit { archive.discard() }
}
