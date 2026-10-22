import Foundation
import CryptoKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum DataBackupError: LocalizedError {
    case integrityCheckFailed
    case unsupportedFormat
    case duplicateIdentity
    case invalidRelationships
    case activityInProgress
    case dataChanged
    case credentialRollback(String)

    var errorDescription: String? {
        switch self {
        case .integrityCheckFailed: String(localized: "RECOVERY_DATABASE_CHECK_FAILED", defaultValue: "The database structure check failed. Export the original data before attempting recovery.")
        case .unsupportedFormat: String(localized: "DATA_BACKUP_UNSUPPORTED", defaultValue: "This file is not a supported Mallow backup.")
        case .duplicateIdentity: String(localized: "DATA_BACKUP_DUPLICATE_RECORDS", defaultValue: "The backup contains ambiguous duplicate records.")
        case .invalidRelationships: String(localized: "DATA_BACKUP_INVALID_RELATIONSHIPS", defaultValue: "The backup contains invalid conversation relationships.")
        case .activityInProgress: String(localized: "DATA_IMPORT_ACTIVE_TASKS_ERROR", defaultValue: "Finish active chat and voice tasks before importing data.")
        case .dataChanged: String(localized: "DATA_IMPORT_PREVIEW_CHANGED", defaultValue: "Your data changed. Review the updated import preview before continuing.")
        case .credentialRollback(let detail): String(localized: "DATA_IMPORT_API_KEY_ROLLBACK_FAILED", defaultValue: "Some API keys could not be restored after the import failed.") + "\n" + detail
        }
    }
}

nonisolated struct DataBackupReadResult: Sendable {
    let snapshot: AppDataBackup
    var categories: [DataRecoveryCategory]
    let sourceRevision: SHA256.Digest


}

nonisolated struct AppDataBackup: Equatable, Sendable {
    var sessions: [ChatSessionBackup]
    var messages: [ChatMessageBackup]
    var settings: [AppSettingsBackup]
    var chatServers: [ChatServerPresetBackup]
    var voiceServers: [VoiceServerPresetBackup]
    var voicePresets: [VoicePresetBackup]
    var prompts: [SystemPromptPresetBackup]
    var credentials: [DataBackupCredential]

    static func recover(from url: URL, keychain: Data, allowSourceSidecarCreation: Bool = false) throws -> DataBackupReadResult {
        // Opening a private copy can checkpoint its WAL when the reader closes.
        // Keep the revision of the original staged bytes for the live-store check.
        let revision = try sourceRevision(at: url)
        let configuration = ModelConfiguration(schema: StartupPersistentStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: StartupPersistentStore.schema, configurations: [configuration])
        let context = ModelContext(container)
        let categories = try StartupDataRecovery.reconstruct(sourceURL: url, context: context,
            allowSourceSidecarCreation: allowSourceSidecarCreation, persist: false)
        var snapshot = try AppDataBackup(context: context, credentials: [])
        let credentials = DataBackupCredentials.recover(keychain, presetIDs: Set(snapshot.chatServers.map(\.id)))
        snapshot.credentials = credentials.values
        return DataBackupReadResult(snapshot: snapshot, categories: categories + [credentials.category], sourceRevision: revision)
    }

    static func sourceRevision(at url: URL) throws -> SHA256.Digest {
        let manager = FileManager.default
        // Compare the saved source, including skipped records, when confirming an
        // import. Recovery defaults and SQLite shared-memory locks are not edits.
        var revision = SHA256()
        for suffix in ["", "-wal"] {
            revision.update(data: Data(suffix.utf8))
            let file = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: file.path) else { continue }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                revision.update(data: chunk)
            }
        }
        return revision.finalize()
    }

    init(context: ModelContext, credentials: [DataBackupCredential]) throws {
        sessions = try context.fetch(FetchDescriptor<ChatSession>()).map(ChatSessionBackup.init).sorted { $0.id.uuidString < $1.id.uuidString }
        messages = try context.fetch(FetchDescriptor<ChatMessage>()).map(ChatMessageBackup.init).sorted { $0.id.uuidString < $1.id.uuidString }
        settings = try context.fetch(FetchDescriptor<AppSettings>()).map(AppSettingsBackup.init).sorted { $0.id.uuidString < $1.id.uuidString }
        chatServers = try context.fetch(FetchDescriptor<ChatServerPreset>()).map(ChatServerPresetBackup.init).sorted { $0.id.uuidString < $1.id.uuidString }
        voiceServers = try context.fetch(FetchDescriptor<VoiceServerPreset>()).map(VoiceServerPresetBackup.init).sorted { $0.id.uuidString < $1.id.uuidString }
        voicePresets = try context.fetch(FetchDescriptor<VoicePreset>()).map(VoicePresetBackup.init).sorted { $0.id.uuidString < $1.id.uuidString }
        prompts = try context.fetch(FetchDescriptor<SystemPromptPreset>()).map(SystemPromptPresetBackup.init).sorted { $0.id.uuidString < $1.id.uuidString }
        self.credentials = credentials
        try validate()
    }

    func validate() throws {
        try validateRelationships()
        for message in messages {
            try Task.checkCancellation()
            try validatePayload(message.assistantSegmentsData, as: [ChatAssistantSegment].self)
            try validatePayload(message.openAIResponsesConversationItemsData, as: [JSONValue].self)
            try validatePayload(message.imageAttachmentsData, as: [ChatImageAttachment].self)
            try validatePayload(message.toolActivityPlacementsData, as: [ChatToolActivityPlacement].self)
        }
    }

    // Merging changes identities and links, but carries validated payload bytes
    // unchanged. Rechecking those bytes would decode every image repeatedly.
    func validateRelationships() throws {
        func unique<T: Hashable>(_ values: [T]) throws {
            guard Set(values).count == values.count else { throw DataBackupError.duplicateIdentity }
        }
        try unique(sessions.map(\.id)); try unique(messages.map(\.id))
        try unique(settings.map(\.id)); try unique(chatServers.map(\.id))
        try unique(voiceServers.map(\.id)); try unique(voicePresets.map(\.id))
        try unique(prompts.map(\.id))
        try unique(credentials.map(\.presetID))
        guard settings.count <= 1 else { throw DataBackupError.duplicateIdentity }
        let sessionIDs = Set(sessions.map(\.id))
        let lookup = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var verified = Set<UUID>()
        for message in messages {
            try Task.checkCancellation()
            guard sessionIDs.contains(message.sessionID) else { throw DataBackupError.invalidRelationships }
            var path = Set<UUID>()
            var cursor: ChatMessageBackup? = message
            while let node = cursor, !verified.contains(node.id) {
                guard path.insert(node.id).inserted else { throw DataBackupError.invalidRelationships }
                if let parentID = node.parentID {
                    guard let parent = lookup[parentID], parent.sessionID == node.sessionID else {
                        throw DataBackupError.invalidRelationships
                    }
                    cursor = parent
                } else { cursor = nil }
            }
            verified.formUnion(path)
            if let child = message.activeChildMessageID {
                guard lookup[child]?.parentID == message.id else { throw DataBackupError.invalidRelationships }
            }
        }
        for session in sessions {
            if let root = session.activeRootMessageID {
                guard let message = lookup[root], message.sessionID == session.id, message.parentID == nil else {
                    throw DataBackupError.invalidRelationships
                }
            }
        }
        let presets = Set(chatServers.map(\.id))
        guard credentials.allSatisfy({ presets.contains($0.presetID) }) else { throw DataBackupError.invalidRelationships }
    }

    private func validatePayload<T: Decodable>(_ data: Data?, as type: T.Type) throws {
        if let data { _ = try JSONDecoder().decode(type, from: data) }
    }

    func prepareStore() throws -> DataRecoveryPlan {
        try validate()
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DataPreparation-" + id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("prepared.store")
        var container: ModelContainer?
        var complete = false
        defer { if !complete { StartupDataRecovery.discard(container: container, directory: directory) } }
        let candidate = try StartupPersistentStore.open(at: url)
        container = candidate
        let context = ModelContext(candidate)
        context.autosaveEnabled = false
        var sessionModels: [UUID: ChatSession] = [:]
        var messageModels: [UUID: ChatMessage] = [:]
        for record in sessions {
            try Task.checkCancellation()
            let model = record.makeModel()
            context.insert(model)
            sessionModels[record.id] = model
        }
        for record in messages {
            try Task.checkCancellation()
            let model = record.makeModel()
            model.session = sessionModels[record.sessionID]
            context.insert(model)
            messageModels[record.id] = model
        }
        for record in messages { messageModels[record.id]?.parentMessage = record.parentID.flatMap { messageModels[$0] } }
        for session in sessionModels.values {
            let latest = session.messages.max(by: ChatMessageBranchResolver.stableMessageOrder)
            session.lastMessageID = latest?.id
            session.lastMessageAt = latest?.createdAt
            session.sidebarPreviewText = ChatSession.sidebarPreviewText(for: latest)
        }
        for record in settings { context.insert(record.makeModel()) }
        for record in chatServers { context.insert(record.makeModel()) }
        for record in voiceServers { context.insert(record.makeModel()) }
        for record in voicePresets { context.insert(record.makeModel()) }
        for record in prompts { context.insert(record.makeModel()) }
        try Task.checkCancellation()
        for message in messageModels.values { try message.persistDocument() }
        try context.save()
        complete = true
        return DataRecoveryPlan(id: id, storeURL: url, container: candidate, categories: [])
    }
}

nonisolated struct DataBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw DataBackupError.unsupportedFormat }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
