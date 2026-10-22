import Foundation
import CoreData
import SwiftData
import Darwin

/// A live store has one application writer. SQLite serializes transactions,
/// but cannot merge SwiftData relationship collections cached by another writer.
nonisolated final class PersistentStoreOwnership: Sendable {
    static let fileName = "store-writer.lock"
    private let descriptor: Int32

    struct AlreadyInUse: LocalizedError {
        var errorDescription: String? {
            String(localized: "Another instance of the app is using this data. Close that instance, then try again.")
        }
    }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { throw AlreadyInUse() }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        self.descriptor = descriptor
    }

    deinit {
        // Closing releases the lock even after a crash. Keep the lock file's
        // inode stable across imports, resets, and subsequent app launches.
        Darwin.close(descriptor)
    }
}

struct DataRecoveryCategory: Identifiable, Sendable {
    let id: String
    let title: String
    var recovered = 0
    var skipped = 0
    var hasUnknownLoss = false
    var hasPartialLoss = false
    var names: [String] = []
    var skippedNames: [String] = []
    var problems: [String] = []
    var issues: [DataRecoveryIssue] = []
}

struct DataRecoveryPlan: Identifiable, Sendable {
    let id: UUID
    let storeURL: URL
    let container: ModelContainer
    let categories: [DataRecoveryCategory]
    var directory: URL { storeURL.deletingLastPathComponent() }
    var recoveredCount: Int { categories.reduce(0) { $0 + $1.recovered } }

    func discard() { StartupDataRecovery.discard(container: container, directory: directory) }
}

/// The application always uses one fixed persistent store.
nonisolated enum StartupPersistentStore {
    static let schema = Schema([
        ChatSession.self, ChatMessage.self,
        AppSettings.self, ChatServerPreset.self, VoiceServerPreset.self,
        VoicePreset.self, SystemPromptPreset.self
    ])

    static var defaultURL: URL { ModelConfiguration().url }
    private static let replacementKey = "MallowImportID"

    static func open(at url: URL) throws -> ModelContainer {
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for message in try context.fetch(FetchDescriptor<ChatMessage>()) {
            guard let data = message.messageDocumentData else { throw CocoaError(.fileReadCorruptFile) }
            _ = try JSONDecoder().decode(ChatMessageDocument.self, from: data)
        }
        return container
    }

    static func replace(with plan: DataRecoveryPlan) throws {
        // The operation ID coordinates the database commit with keychain writes.
        var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: plan.storeURL)
        metadata[replacementKey] = plan.id.uuidString
        try NSPersistentStoreCoordinator.setMetadata(metadata, type: .sqlite, at: plan.storeURL)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
        try coordinator.replacePersistentStore(at: defaultURL, withPersistentStoreFrom: plan.storeURL, type: .sqlite)
    }

    static func replacementID() throws -> UUID? {
        guard FileManager.default.fileExists(atPath: defaultURL.path) else { return nil }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: defaultURL)
        guard let value = metadata[replacementKey] else { return nil }
        guard let string = value as? String, let id = UUID(uuidString: string) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return id
    }

    /// Keep storage ownership here rather than exporting the entire Library.
    static func exportSources(defaultStoreURL: URL = defaultURL) -> [String: URL] {
        let directory = defaultStoreURL.deletingLastPathComponent()
        let names = [defaultStoreURL.lastPathComponent, defaultStoreURL.lastPathComponent + "-wal",
                     defaultStoreURL.lastPathComponent + "-shm"]
        return Dictionary(uniqueKeysWithValues: names.map { ("Stores/" + $0, directory.appendingPathComponent($0)) })
    }

    /// An explicitly confirmed reset does not require readable database contents.
    static func reset(defaultStoreURL: URL = defaultURL) throws {
        let manager = FileManager.default
        let directory = defaultStoreURL.deletingLastPathComponent()
        try removeStoreFiles(at: defaultStoreURL)
        let journal = directory.appendingPathComponent(DataImportTransaction.fileName)
        if manager.fileExists(atPath: journal.path) { try manager.removeItem(at: journal) }
    }

    static func removeStoreFiles(at storeURL: URL) throws {
        let fileManager = FileManager.default
        let relatedURLs = [storeURL, URL(fileURLWithPath: storeURL.path + "-shm"), URL(fileURLWithPath: storeURL.path + "-wal")]
        var firstError: Error?
        for url in relatedURLs where fileManager.fileExists(atPath: url.path) {
            do { try fileManager.removeItem(at: url) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
}

nonisolated enum StartupDataRecovery {
    static func prepare(sourceURL: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory, allowSourceSidecarCreation: Bool = false) throws -> DataRecoveryPlan {
        let id = UUID()
        let directory = temporaryDirectory.appendingPathComponent("DataPreparation-" + id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var keepCandidate = false
        var container: ModelContainer?
        defer {
            if !keepCandidate { discard(container: container, directory: directory) }
        }
        let storeURL = directory.appendingPathComponent("prepared.store")
        let candidate = try StartupPersistentStore.open(at: storeURL)
        container = candidate
        let categories = try reconstruct(sourceURL: sourceURL, context: ModelContext(candidate), allowSourceSidecarCreation: allowSourceSidecarCreation)
        try Task.checkCancellation()
        keepCandidate = true
        return DataRecoveryPlan(id: id, storeURL: storeURL, container: candidate, categories: categories)
    }

    static func discard(container: ModelContainer?, directory: URL) {
        do {
            try container?.erase()
            try FileManager.default.removeItem(at: directory)
        }
        catch { print("Could not remove recovery preview: \(error)") }
    }

    static func reconstruct(sourceURL: URL, context: ModelContext, allowSourceSidecarCreation: Bool, persist: Bool = true) throws -> [DataRecoveryCategory] {
        let source = try RecoveryStoreReader(url: sourceURL, allowSidecarCreation: allowSourceSidecarCreation)
        context.autosaveEnabled = false
        var categories: [DataRecoveryCategory] = []
        var sessions: [Int64: ChatSession] = [:]
        var sessionRows: [UUID: RecoveryRow] = [:]
        var messages: [Int64: ChatMessage] = [:]
        var parents: [Int64: Int64] = [:]
        var messageRows: [Int64: RecoveryRow] = [:]

        func recover<M: PersistentModel>(
            _ entity: String, title: String,
            make: (RecoveryRow) throws -> M,
            identityField: String = "id",
            connect: (M, RecoveryRow) throws -> Void = { _, _ in }
        ) throws {
            var category = DataRecoveryCategory(id: entity, title: title)
            var rows: [RecoveryRow] = []
            do {
                category.hasUnknownLoss = try !source.scan(entity: entity) { rows.append($0) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                let error = error as NSError
                guard error.domain == "RecoverySQLite", [1, 11, 26].contains(error.code) else { throw error }
                category.hasUnknownLoss = true
            }
            func identity(_ row: RecoveryRow) -> String? {
                if identityField == "id" { return (try? row.value("id", as: UUID.self))?.uuidString }
                return try? row.value(identityField, as: String.self)
            }
            let identityCounts = Dictionary(rows.compactMap { identity($0).map { ($0, 1) } }, uniquingKeysWith: +)
            // Match the settings store's existing selection; never merge unrelated records.
            let selectedSettingsID = entity == "AppSettings" ? identityCounts.keys.min() : nil
            for row in rows {
                try Task.checkCancellation()
                let name = ["title", "name", "content"].compactMap { try? row.value($0, as: String.self) }.first
                do {
                    guard let id = identity(row), !id.isEmpty, identityCounts[id] == 1 else { throw row.invalid("identity") }
                    guard selectedSettingsID == nil || selectedSettingsID == id else { throw row.invalid("additionalSettings") }
                    let model = try make(row)
                    try connect(model, row)
                    context.insert(model)
                    category.recovered += 1
                    category.hasPartialLoss = category.hasPartialLoss || row.hasLoss
                    if let name { category.names.append(String(name.prefix(120))) }
                    if row.hasLoss {
                        category.issues.append(DataRecoveryIssue(row: row, entity: entity, name: name,
                            reason: .content, fields: row.lostFields.sorted()))
                    }
                } catch {
                    guard (error as NSError).domain == "RecoveryRecord" else { throw error }
                    category.skipped += 1
                    let field = (error as NSError).userInfo["field"] as? String ?? ""
                    let reason: DataRecoveryIssue.Reason = switch field {
                    case "ZSESSION", "session": .ownership
                    case "ZPARENTMESSAGE": .parent
                    case "identity": .identity
                    case "additionalSettings": .additionalSettings
                    default: .content
                    }
                    category.issues.append(DataRecoveryIssue(row: row, entity: entity, name: name, reason: reason, fields: [field]))
                    if let name { category.skippedNames.append(String(name.prefix(120))) }
                }
            }
            categories.append(category)
        }

        try recover("ChatSession", title: String(localized: "Chats"), make: recoverSession) { session, row in
            sessions[try row.integer("Z_PK")] = session
            sessionRows[session.id] = row
        }
        try recover("ChatMessage", title: String(localized: "Messages"), make: recoverMessage) { message, row in
            let key = try row.integer("Z_PK")
            let sessionKey = try row.integer("ZSESSION")
            guard let session = sessions[sessionKey] else { throw row.invalid("session") }
            let parent = try row.optionalInteger("ZPARENTMESSAGE")
            message.session = session
            parents[key] = parent
            messages[key] = message
            messageRows[key] = row
        }
        // Keep only original, unambiguous parent chains. Missing parents and cycles
        // invalidate their descendants; they never become new conversation roots.
        var validChains: [Int64: Bool] = [:]
        for key in messages.keys {
            var path: Set<Int64> = []
            var cursor = key
            var valid = true
            while let message = messages[cursor] {
                if let known = validChains[cursor] { valid = known; break }
                guard path.insert(cursor).inserted else { valid = false; break }
                guard let parent = parents[cursor] else { break }
                guard let parentMessage = messages[parent], parentMessage.session === message.session else {
                    valid = false
                    break
                }
                cursor = parent
            }
            for visited in path { validChains[visited] = valid }
        }
        for (key, message) in messages where validChains[key] == false {
            context.delete(message)
            categories[1].recovered -= 1
            categories[1].skipped += 1
            categories[1].skippedNames.append(String(message.content.prefix(120)))
            if let row = messageRows[key] {
                categories[1].issues.append(DataRecoveryIssue(row: row, entity: "ChatMessage", name: message.content, reason: .parent))
            }
        }
        messages = messages.filter { validChains[$0.key] == true }
        categories[1].names = messages.keys.sorted().compactMap { messages[$0].map { String($0.content.prefix(120)) } }
        for (key, message) in messages {
            message.parentMessage = parents[key].flatMap { messages[$0] }
        }
        // These are display selections and projections, not message ownership.
        let rowsByID = Dictionary(uniqueKeysWithValues: messages.compactMap { key, message in messageRows[key].map { (message.id, $0) } })
        let messagesBySession = Dictionary(grouping: messages.values, by: { $0.session?.id })
        for session in sessions.values {
            let surviving = messagesBySession[session.id] ?? []
            let lookup = Dictionary(uniqueKeysWithValues: surviving.map { ($0.id, $0) })
            if !surviving.contains(where: { $0.id == session.activeRootMessageID && $0.parentMessage == nil }) {
                if session.activeRootMessageID != nil, let row = sessionRows[session.id] {
                    categories[0].issues.append(DataRecoveryIssue(row: row, entity: "ChatSession", name: session.title, reason: .selection))
                    categories[0].hasPartialLoss = true
                }
                session.activeRootMessageID = nil
            }
            for message in surviving {
                if message.activeChildMessageID.flatMap({ lookup[$0] })?.parentMessage !== message {
                    if message.activeChildMessageID != nil, let row = rowsByID[message.id] {
                        categories[1].issues.append(DataRecoveryIssue(row: row, entity: "ChatMessage", name: message.content, reason: .selection))
                        categories[1].hasPartialLoss = true
                    }
                    message.activeChildMessageID = nil
                }
            }
            let latest = surviving.max(by: ChatMessageBranchResolver.stableMessageOrder)
            session.lastMessageID = latest?.id
            session.lastMessageAt = latest?.createdAt
            session.sidebarPreviewText = ChatSession.sidebarPreviewText(for: latest)
        }

        try recover("AppSettings", title: String(localized: "Settings"), make: AppSettingsStore.recover)
        try recover("ChatServerPreset", title: String(localized: "Chat Server Presets"), make: recoverChatServer)
        try recover("VoiceServerPreset", title: String(localized: "Voice Server Presets"), make: recoverVoiceServer)
        try recover("VoicePreset", title: String(localized: "Voice Presets"), make: recoverVoice)
        try recover("SystemPromptPreset", title: String(localized: "System Prompt Presets"), make: recoverPrompt)
        if persist {
            for message in try context.fetch(FetchDescriptor<ChatMessage>()) { try message.persistDocument() }
            try context.save()
        }
        return categories
    }

}

extension StartupDataRecovery {
    private static func recoverSession(_ row: RecoveryRow) throws -> ChatSession {
        let model = ChatSession()
        model.id = try row.value("id")
        model.title = try row.value("title")
        model.createdAt = try row.value("createdAt")
        model.updatedAt = row.recover("updatedAt", defaultValue: model.updatedAt)
        // Sidebar projections are rebuilt from the recovered messages.
        model.activeRootMessageID = row.recover("activeRootMessageID", defaultValue: model.activeRootMessageID)
        return model
    }

    static func recoverMessage(_ row: RecoveryRow) throws -> ChatMessage {
        let model = ChatMessage(content: "", isUser: false)
        model.id = try row.value("id")
        model.activeChildMessageID = row.recover("activeChildMessageID", defaultValue: model.activeChildMessageID)
        model.importSourceMessageID = row.recover("importSourceMessageID", defaultValue: model.importSourceMessageID)
        let documentData: Data = try row.value("messageDocumentData")
        model.imageAttachmentsData = row.recover("imageAttachmentsData", defaultValue: model.imageAttachmentsData)
        model.isUser = try row.value("isUser")
        model.isActive = row.recover("isActive", defaultValue: model.isActive)
        model.createdAt = row.recover("createdAt", defaultValue: Optional<Date>.none)
        model.modelIdentifier = row.recover("modelIdentifier", defaultValue: model.modelIdentifier)
        model.apiBaseURL = row.recover("apiBaseURL", defaultValue: model.apiBaseURL)
        model.thinkingOptionRawValue = row.recover("thinkingOptionRawValue", defaultValue: model.thinkingOptionRawValue)
        model.requestID = row.recover("requestID", defaultValue: model.requestID)
        model.providerResponseID = row.recover("providerResponseID", defaultValue: model.providerResponseID)
        model.requestContextFingerprint = row.recover("requestContextFingerprint", defaultValue: model.requestContextFingerprint)
        model.requestUsedPreviousResponseID = row.recover("requestUsedPreviousResponseID", defaultValue: model.requestUsedPreviousResponseID)
        model.requestPreviousResponseID = row.recover("requestPreviousResponseID", defaultValue: model.requestPreviousResponseID)
        model.streamStartedAt = row.recover("streamStartedAt", defaultValue: model.streamStartedAt)
        model.streamFirstTokenAt = row.recover("streamFirstTokenAt", defaultValue: model.streamFirstTokenAt)
        model.streamFirstTokenAtSource = row.recover("streamFirstTokenAtSource", defaultValue: model.streamFirstTokenAtSource)
        model.streamCompletedAt = row.recover("streamCompletedAt", defaultValue: model.streamCompletedAt)
        model.timeToFirstToken = row.recover("timeToFirstToken", defaultValue: model.timeToFirstToken)
        model.outputTokenCount = row.recover("outputTokenCount", defaultValue: model.outputTokenCount)
        model.reasoningOutputTokenCount = row.recover("reasoningOutputTokenCount", defaultValue: model.reasoningOutputTokenCount)
        model.tokensPerSecond = row.recover("tokensPerSecond", defaultValue: model.tokensPerSecond)
        model.tokenCountSource = row.recover("tokenCountSource", defaultValue: model.tokenCountSource)
        model.timeToFirstTokenSource = row.recover("timeToFirstTokenSource", defaultValue: model.timeToFirstTokenSource)
        model.tokensPerSecondSource = row.recover("tokensPerSecondSource", defaultValue: model.tokensPerSecondSource)
        model.finishReasonSource = row.recover("finishReasonSource", defaultValue: model.finishReasonSource)

        model.promptMessageCount = row.recover("promptMessageCount", defaultValue: model.promptMessageCount)
        model.promptCharacterCount = row.recover("promptCharacterCount", defaultValue: model.promptCharacterCount)
        model.finishReason = row.recover("finishReason", defaultValue: model.finishReason)
        model.errorDescription = row.recover("errorDescription", defaultValue: model.errorDescription)
        // Keep readable payloads unchanged. Invalid structured display data is
        // omitted; the normal renderer can still display the original body.
        model.imageAttachmentsData = try row.readableItems(model.imageAttachmentsData, of: ChatImageAttachment.self, field: "imageAttachmentsData")
        try recoverMessageDocument(documentData, into: model, row: row)
        return model
    }

    private static func recoverMessageDocument(_ data: Data, into model: ChatMessage, row: RecoveryRow) throws {
        do {
            try model.installDocument(data)
            return
        } catch let error as DecodingError {
            guard var document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rounds = document["generationRounds"], !(rounds is NSNull) else {
                row.decodingLoss("messageDocumentData", error: error)
                throw row.invalid("messageDocumentData")
            }
            // Statistics are independent of conversation content. Keep readable rounds;
            // never remove or reconstruct text, protocol items, or tool history.
            let encoded = try JSONSerialization.data(withJSONObject: rounds, options: [.fragmentsAllowed])
            let readable = try row.readableItems(encoded, of: ChatGenerationRound.self, field: "generationRounds")
            guard row.lostFields.contains("generationRounds") else {
                row.decodingLoss("messageDocumentData", error: error)
                throw row.invalid("messageDocumentData")
            }
            document["generationRounds"] = try readable.map { try JSONSerialization.jsonObject(with: $0) }
            let recovered = try JSONSerialization.data(withJSONObject: document)
            do {
                try model.installDocument(recovered)
            } catch let error as DecodingError {
                row.decodingLoss("messageDocumentData", error: error)
                throw row.invalid("messageDocumentData")
            }
        }
    }

    private static func recoverChatServer(_ row: RecoveryRow) throws -> ChatServerPreset {
        let model = ChatServerPreset(name: String(localized: "New Preset"))
        model.id = try row.value("id")
        model.name = try row.value("name")
        model.apiURL = try row.value("apiURL")
        model.selectedModel = try row.value("selectedModel")
        model.apiFormatPreferenceRaw = row.recover("apiFormatPreferenceRaw", defaultValue: model.apiFormatPreferenceRaw)
        model.createdAt = row.recover("createdAt", defaultValue: model.createdAt)
        model.updatedAt = row.recover("updatedAt", defaultValue: model.updatedAt)
        return model
    }

    private static func recoverVoiceServer(_ row: RecoveryRow) throws -> VoiceServerPreset {
        let model = VoiceServerPreset(name: String(localized: "New Preset"))
        model.id = try row.value("id")
        model.name = try row.value("name")
        model.serverAddress = try row.value("serverAddress")
        model.createdAt = row.recover("createdAt", defaultValue: model.createdAt)
        model.updatedAt = row.recover("updatedAt", defaultValue: model.updatedAt)
        return model
    }

    private static func recoverVoice(_ row: RecoveryRow) throws -> VoicePreset {
        let model = VoicePreset(name: String(localized: "New Preset"))
        model.id = try row.value("id")
        model.name = try row.value("name")
        model.refAudioPath = try row.value("refAudioPath")
        model.promptText = try row.value("promptText")
        model.promptLang = try row.value("promptLang")
        model.gptWeightsPath = try row.value("gptWeightsPath")
        model.sovitsWeightsPath = try row.value("sovitsWeightsPath")
        model.createdAt = row.recover("createdAt", defaultValue: model.createdAt)
        model.updatedAt = row.recover("updatedAt", defaultValue: model.updatedAt)
        return model
    }

    private static func recoverPrompt(_ row: RecoveryRow) throws -> SystemPromptPreset {
        let model = SystemPromptPreset(name: String(localized: "New Prompt Preset"))
        model.id = try row.value("id")
        model.name = try row.value("name")
        model.mode = try row.value("mode", as: String.self)
        model.normalPrompt = row.recover("normalPrompt", defaultValue: model.normalPrompt)
        model.voicePrompt = row.recover("voicePrompt", defaultValue: model.voicePrompt)
        model.createdAt = row.recover("createdAt", defaultValue: model.createdAt)
        model.updatedAt = row.recover("updatedAt", defaultValue: model.updatedAt)
        switch model.mode {
        case SystemPromptPresetStore.normalMode: model.normalPrompt = try row.value("normalPrompt")
        case SystemPromptPresetStore.voiceMode: model.voicePrompt = try row.value("voicePrompt")
        default: throw row.invalid("mode")
        }
        return model
    }


}
