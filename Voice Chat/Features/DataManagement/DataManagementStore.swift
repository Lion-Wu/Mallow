import CryptoKit
import Foundation
import ImageIO
import SwiftData

nonisolated struct DataRecoveryIssue: Identifiable, Sendable {
    enum Reason: String, Sendable {
        case ownership, parent, identity, content, additionalSettings, database, metadata, selection
        var title: String {
            switch self {
            case .ownership: String(localized: "Missing Chat Ownership")
            case .parent: String(localized: "Invalid Message Chain")
            case .identity: String(localized: "Missing or Duplicate Identity")
            case .content: String(localized: "Unreadable Fields")
            case .additionalSettings: String(localized: "Additional Settings Record")
            case .database: String(localized: "Database Structure")
            case .metadata: String(localized: "Missing Request Metadata")
            case .selection: String(localized: "Invalid Branch Selection")
            }
        }
    }
    let entity: String
    let rowID: Int64
    let recordID: UUID?
    let name: String
    let date: Date?
    let reason: Reason
    var fields: [String] = []
    let fieldProblems: [String: String]
    var id: String { "\(entity):\(rowID):\(reason.rawValue)" }

    init(row: RecoveryRow, entity: String, name: String?, reason: Reason, fields: [String] = []) {
        self.entity = entity
        rowID = (try? row.integer("Z_PK")) ?? 0
        recordID = try? row.value("id", as: UUID.self)
        self.name = String((name ?? entity).prefix(160))
        date = try? row.value("createdAt", as: Date.self)
        self.reason = reason
        self.fields = fields
        fieldProblems = row.fieldProblems
    }

    var canDelete: Bool {
        recordID != nil && reason != .identity && reason != .selection &&
        ["ChatMessage", "ChatSession", "AppSettings", "ChatServerPreset", "VoiceServerPreset", "VoicePreset", "SystemPromptPreset"].contains(entity)
    }

    var explanation: String {
        switch reason {
        case .ownership: String(localized: "This message does not reference an existing chat.")
        case .parent: String(localized: "The preceding message is missing, belongs to another chat, or forms a circular chain.")
        case .content: String(localized: "Some stored fields cannot be read. Other parts of this record may still be readable.")
        case .identity: String(localized: "This record has a missing or duplicate identifier and cannot be safely selected for deletion.")
        case .additionalSettings: String(localized: "More than one global settings record exists.")
        case .metadata: String(localized: "The request metadata referenced by this message is missing.")
        case .selection: String(localized: "The selected branch no longer exists in this chat.")
        case .database: String(localized: "The database structure check reported an error.")
        }
    }

    static func fieldTitle(_ field: String) -> String {
        switch field {
        case "content": String(localized: "Message")
        case "imageAttachmentsData": String(localized: "Images and Attachments")
        case "assistantSegmentsData": String(localized: "Message Segments")
        case "toolActivityPlacementsData": String(localized: "Tool Positions")
        case "openAIResponsesConversationItemsData", "providerResponseIDsData", "providerResponseID", "requestPreviousResponseID", "requestContentSnapshot": String(localized: "Request Snapshots and Continuation Data")
        case "modelThinkingPreferencesJSON": String(localized: "Thinking Settings")
        case "modelImageInputOverrideJSON": String(localized: "Image Input Override")
        case "detectedAPIFormatsJSON", "apiFormatPreferenceRaw": String(localized: "API Format")
        default: field
        }
    }

}

nonisolated struct DataStorageMessage: Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID?
    let title: String
    let date: Date
    let bytes: Int64
    let imageBytes: Int64
    let contextBytes: Int64
    let model: String?
}

nonisolated struct DataStorageChat: Identifiable, Sendable {
    let id: UUID
    let title: String
    let date: Date
    let bytes: Int64
    let imageBytes: Int64
    let contextBytes: Int64
    let messageCount: Int
}

nonisolated struct DataModelPreference: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case thinking = "modelThinkingPreferencesJSON"
        case images = "modelImageInputOverrideJSON"
        case endpoint = "detectedAPIFormatsJSON"
        var title: String {
            switch self {
            case .thinking: String(localized: "Thinking Settings")
            case .images: String(localized: "Image Input Override")
            case .endpoint: String(localized: "API Format")
            }
        }
    }
    let settingsID: UUID
    let kind: Kind
    let key: String
    let value: String
    var presetID: UUID? = nil
    var source: String { presetID != nil || kind != .endpoint ? String(localized: "Manual") : String(localized: "Automatic") }
    var displayValue: String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) else { return value }
        if kind == .images, let enabled = object as? Bool { return enabled ? String(localized: "On") : String(localized: "Off") }
        if kind == .thinking, let raw = object as? String { return ModelThinkingOption(rawValue: raw).displayName }
        let raw = (object as? [String: String])?["style"] ?? (object as? String) ?? ""
        switch raw {
        case "openAIResponses": return String(localized: "OpenAI Responses")
        case "openAIChatCompletions": return String(localized: "OpenAI Chat Completions")
        case "anthropic", "anthropicMessages": return String(localized: "Anthropic Messages")
        case "lmStudio", "lmStudioRESTV1": return String(localized: "LM Studio REST v1")
        default: return raw.isEmpty ? value : raw
        }
    }
    var id: String { "\(settingsID):\(kind.rawValue):\(key)" }
}

nonisolated struct DataStorageCatalog: Sendable {
    let revision: SHA256.Digest
    let chats: [DataStorageChat]
    let messages: [DataStorageMessage]
    let preferences: [DataModelPreference]
    let sharedMetadataBytes: Int64
    let unassignedMessageBytes: Int64
    let checkedAt: Date
}

nonisolated struct DataCleanupReport: Sendable {
    let revision: SHA256.Digest
    let issues: [DataRecoveryIssue]
    let unreadableCategories: [String]
}

/// Reads lightweight sizes separately from the tolerant message cleanup scan.
nonisolated enum DataManagementStore {
    struct Snapshot: Sendable {
        let catalog: DataStorageCatalog?
        let thumbnails: [UUID: [DataAttachmentThumbnail]]?
        let cleanupReport: DataCleanupReport?
    }

    static func snapshot(at root: URL, includeCatalog: Bool, includeThumbnails: Bool, includeCleanupReport: Bool) throws -> Snapshot {
        let url = root.appendingPathComponent("default.store")
        // Capture the source bytes before any reader can checkpoint this private
        // copy. Every requested projection retains that same provenance.
        let revision = try AppDataBackup.sourceRevision(at: url)
        let catalog = includeCatalog ? try catalog(at: url, revision: revision) : nil
        let thumbnails = includeThumbnails ? try attachmentThumbnails(at: url) : nil
        let cleanupReport = includeCleanupReport ? try scanDatabase(at: url,
            keychain: Data(contentsOf: root.appendingPathComponent("Keychain.plist")),
            sourceRevision: revision) : nil
        return Snapshot(catalog: catalog, thumbnails: thumbnails, cleanupReport: cleanupReport)
    }

    private static func catalog(at url: URL, revision: SHA256.Digest) throws -> DataStorageCatalog {
        let reader = try RecoveryStoreReader(url: url, allowSidecarCreation: true)
        var sessions: [Int64: (UUID, String, Date, Int64)] = [:]
        let sessionSize = try reader.payloadSizeExpression(entity: "ChatSession")
        try reader.query("SELECT Z_PK, ZID, ZTITLE, ZCREATEDAT, \(sessionSize) AS BYTES FROM ZCHATSESSION") { row in
            sessions[try row.integer("Z_PK")] = (try row.value("id"), try row.value("title"), try row.value("createdAt"), try row.integer("BYTES"))
        }
        let total = try reader.payloadSizeExpression(entity: "ChatMessage")
        // Match the stored text/blob fields removed by clearContext. Shared request
        // metadata belongs to the database, not to every message referencing it.
        let contextFields = ["ZREQUESTCONTENTSNAPSHOT", "ZOPENAIRESPONSESCONVERSATIONITEMSDATA",
                             "ZPROVIDERRESPONSEIDSDATA", "ZPROVIDERRESPONSEID", "ZREQUESTPREVIOUSRESPONSEID"]
        let context = contextFields.map { "COALESCE(length(CAST(\($0) AS BLOB)),0)" }.joined(separator: "+")
        var messages: [DataStorageMessage] = []
        try reader.query("SELECT ZID,ZSESSION,ZCREATEDAT,ZMODELIDENTIFIER,substr(ZCONTENT,1,160) AS ZCONTENT,\(total) AS BYTES,COALESCE(length(ZIMAGEATTACHMENTSDATA),0) AS IMAGES,\(context) AS CONTEXT FROM ZCHATMESSAGE") { row in
            messages.append(DataStorageMessage(id: try row.value("id"), sessionID: try row.optionalInteger("ZSESSION").flatMap { sessions[$0]?.0 },
                title: try row.value("content"), date: try row.value("createdAt"), bytes: try row.integer("BYTES"),
                imageBytes: try row.integer("IMAGES"), contextBytes: try row.integer("CONTEXT"), model: row.recover("modelIdentifier", defaultValue: Optional<String>.none)))
        }
        let bySession = Dictionary(grouping: messages.compactMap { $0.sessionID == nil ? nil : $0 }, by: { $0.sessionID! })
        let chats = sessions.values.map { id, title, date, sessionBytes in
            let items = bySession[id] ?? []
            return DataStorageChat(id: id, title: title, date: date, bytes: items.reduce(sessionBytes) { $0 + $1.bytes },
                imageBytes: items.reduce(0) { $0 + $1.imageBytes }, contextBytes: items.reduce(0) { $0 + $1.contextBytes }, messageCount: items.count)
        }.sorted { $0.bytes > $1.bytes }
        var preferences: [DataModelPreference] = []
        _ = try reader.scan(entity: "AppSettings") { row in
            let id: UUID = try row.value("id")
            for kind in DataModelPreference.Kind.allCases {
                guard let raw: String = row.recover(kind.rawValue, defaultValue: Optional<String>.none) else { continue }
                guard let values = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw row.invalid(kind.rawValue) }
                for (key, value) in values {
                    let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
                    preferences.append(DataModelPreference(settingsID: id, kind: kind, key: key, value: String(decoding: data, as: UTF8.self)))
                }
            }
        }
        _ = try reader.scan(entity: "ChatServerPreset") { row in
            guard let raw: String = row.recover("apiFormatPreferenceRaw", defaultValue: Optional<String>.none),
                  !raw.isEmpty, raw != ChatAPIFormatPreference.automatic.rawValue else { return }
            let id: UUID = try row.value("id")
            let name: String = try row.value("name")
            let endpoint: String = try row.value("apiURL")
            let encoded = try JSONEncoder().encode(raw)
            preferences.append(DataModelPreference(settingsID: id, kind: .endpoint, key: name + " · " + endpoint,
                value: String(decoding: encoded, as: UTF8.self), presetID: id))
        }
        return DataStorageCatalog(revision: revision, chats: chats, messages: messages.sorted { $0.bytes > $1.bytes },
            preferences: preferences.sorted { $0.key < $1.key },
            sharedMetadataBytes: try reader.payloadSize(entity: "ChatRequestContextMetadata"),
            unassignedMessageBytes: messages.filter { $0.sessionID == nil }.reduce(0) { $0 + $1.bytes }, checkedAt: Date())
    }

    private static func scanDatabase(at url: URL, keychain: Data, sourceRevision: SHA256.Digest) throws -> DataCleanupReport {
        // Use the import parser so cleanup identifies the same unreadable records.
        let read = try AppDataBackup.recover(from: url, keychain: keychain, allowSourceSidecarCreation: true)
        let categories = read.categories.filter { $0.id != "Credentials" }
        return DataCleanupReport(revision: sourceRevision,
            issues: categories.flatMap(\.issues),
            unreadableCategories: categories.filter(\.hasUnknownLoss).map(\.title))
    }

    static func issueContent(at url: URL, issue: DataRecoveryIssue) throws -> String? {
        guard issue.entity == "ChatMessage", issue.rowID > 0 else { return nil }
        let reader = try RecoveryStoreReader(url: url, allowSidecarCreation: true)
        var content: String?
        try reader.query("SELECT ZCONTENT FROM ZCHATMESSAGE WHERE Z_PK=\(issue.rowID)") { row in
            content = try? row.value("content", as: String.self)
        }
        return content
    }

}

nonisolated enum DataManagementMutation: Sendable {
    case deleteChats(Set<UUID>)
    case deleteAttachments(messageID: UUID, attachmentIDs: Set<UUID>)
    case deleteAllAttachments(Set<UUID>)
    case deletePreference(DataModelPreference)
    case deleteModelData(preferences: [DataModelPreference], contextMessageIDs: Set<UUID>)
    case clearContext(Set<UUID>)
    case deleteIssues([DataRecoveryIssue])
    case recoverUnowned(Set<UUID>)

    var deletedChatIDs: Set<UUID> {
        switch self {
        case .deleteChats(let ids): ids
        case .deleteIssues(let issues): Set(issues.filter { $0.entity == "ChatSession" }.compactMap(\.recordID))
        default: []
        }
    }

    var changesSettings: Bool {
        switch self {
        case .deletePreference: true
        case .deleteModelData(let preferences, _): !preferences.isEmpty
        case .deleteIssues(let issues): issues.contains { $0.entity != "ChatMessage" && $0.entity != "ChatSession" }
        default: false
        }
    }

    /// The caller owns the live context and commits all changes in one save.
    func apply(in context: ModelContext, storeURL: URL) throws {
        if case .deleteIssues(let issues) = self {
            try DataManagementStore.deleteIssues(issues, at: storeURL, context: context)
            return
        }
        if case .deletePreference(let item) = self {
            try deletePreference(item, in: context)
            return
        }
        if case .deleteModelData(let preferences, let messageIDs) = self {
            for item in preferences { try deletePreference(item, in: context) }
            if !messageIDs.isEmpty {
                try Self.clearContext(messageIDs).apply(in: context, storeURL: storeURL)
            }
            return
        }
        let messages = try context.fetch(FetchDescriptor<ChatMessage>())
        let sessions = try context.fetch(FetchDescriptor<ChatSession>())
        func message(_ id: UUID) throws -> ChatMessage {
            let found = messages.filter { $0.id == id }
            guard found.count == 1 else { throw DataBackupError.dataChanged }
            return found[0]
        }
        switch self {
        case .deleteChats(let ids):
            let selected = sessions.filter { ids.contains($0.id) }
            guard selected.count == ids.count else { throw DataBackupError.dataChanged }
            for session in selected { context.delete(session) }
        case .deleteAllAttachments(let ids):
            for id in ids { try message(id).imageAttachmentsData = nil }
        case .deleteAttachments(let id, let ids):
            let model = try message(id)
            let attachments = try JSONDecoder().decode([ChatImageAttachment].self, from: model.imageAttachmentsData ?? Data("[]".utf8))
            guard Set(attachments.map(\.id)).isSuperset(of: ids) else { throw DataBackupError.dataChanged }
            let remaining = attachments.filter { !ids.contains($0.id) }
            model.imageAttachmentsData = remaining.isEmpty ? nil : try JSONEncoder().encode(remaining)
        case .deletePreference, .deleteModelData:
            // Model data mutations are handled before loading chats.
            break
        case .clearContext(let ids):
            for id in ids {
                let model = try message(id)
                model.requestContentSnapshot = nil
                model.openAIResponsesConversationItemsData = nil
                model.providerResponseID = nil
                model.providerResponseIDsData = nil
                model.requestPreviousResponseID = nil
                model.requestUsedPreviousResponseID = nil
            }
        case .deleteIssues:
            // Handled before materializing records that may contain invalid fields.
            break
        case .recoverUnowned(let ids):
            let children = Dictionary(grouping: messages.filter { $0.parentMessage != nil }, by: { $0.parentMessage!.id })
            var recovered = Set<UUID>()
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) where !recovered.contains(id) {
                var root = try message(id)
                var ancestors = Set<UUID>()
                while true {
                    guard root.session == nil, ancestors.insert(root.id).inserted else { throw DataBackupError.invalidRelationships }
                    guard let parent = root.parentMessage else { break }
                    root = parent
                }
                var component: [ChatMessage] = []
                var queue = [root]
                var visited = Set<UUID>()
                while let item = queue.popLast() {
                    guard item.session == nil, visited.insert(item.id).inserted else { throw DataBackupError.invalidRelationships }
                    component.append(item)
                    queue.append(contentsOf: children[item.id] ?? [])
                }
                let session = ChatSession(title: String(localized: "Recovered Message"))
                session.createdAt = root.createdAt
                context.insert(session)
                for item in component {
                    item.session = session
                    session.registerMessageActivity(item)
                }
                session.activeRootMessageID = root.id
                recovered.formUnion(visited)
            }

        }
    }

    private func deletePreference(_ item: DataModelPreference, in context: ModelContext) throws {
        if let id = item.presetID {
            let found = try context.fetch(FetchDescriptor<ChatServerPreset>(predicate: #Predicate { $0.id == id }))
            guard found.count == 1 else { throw DataBackupError.dataChanged }
            found[0].apiFormatPreferenceRaw = nil
            return
        }
        let found = try context.fetch(FetchDescriptor<AppSettings>()).filter { $0.id == item.settingsID }
        guard found.count == 1 else { throw DataBackupError.dataChanged }
        let model = found[0]
        let raw: String? = switch item.kind {
        case .thinking: model.modelThinkingPreferencesJSON
        case .images: model.modelImageInputOverrideJSON
        case .endpoint: model.detectedAPIFormatsJSON
        }
        guard var values = try JSONSerialization.jsonObject(with: Data((raw ?? "{}").utf8)) as? [String: Any], values.removeValue(forKey: item.key) != nil else { throw DataBackupError.dataChanged }
        let updated = String(decoding: try JSONSerialization.data(withJSONObject: values, options: .sortedKeys), as: UTF8.self)
        switch item.kind {
        case .thinking: model.modelThinkingPreferencesJSON = updated
        case .images: model.modelImageInputOverrideJSON = updated
        case .endpoint: model.detectedAPIFormatsJSON = updated
        }
    }
}

nonisolated struct DataMessageDetails: Sendable {
    let content: String
    let attachments: [ChatImageAttachment]
    let attachmentIssue: String?
}

extension DataManagementStore {
    static func messageDetails(at url: URL, id: UUID) throws -> DataMessageDetails {
        let reader = try RecoveryStoreReader(url: url, allowSidecarCreation: true)
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "")
        var result: DataMessageDetails?
        try reader.query("SELECT ZCONTENT,ZIMAGEATTACHMENTSDATA FROM ZCHATMESSAGE WHERE hex(ZID)='\(hex)'") { row in
            let content: String = try row.value("content")
            let raw: Data? = row.recover("imageAttachmentsData", defaultValue: Optional<Data>.none)
            let readable = try row.readableItems(raw, of: ChatImageAttachment.self, field: "imageAttachmentsData")
            result = DataMessageDetails(content: content, attachments: try readable.map { try JSONDecoder().decode([ChatImageAttachment].self, from: $0) } ?? [],
                attachmentIssue: row.fieldProblems["imageAttachmentsData"])
        }
        guard let result else { throw DataBackupError.dataChanged }
        return result
    }
}

extension DataManagementStore {
    /// Diagnostic row IDs are checked against UUIDs before deletion touches
    /// any live model. The caller commits deletions and summary changes together.
    static func deleteIssues(_ issues: [DataRecoveryIssue], at url: URL, context: ModelContext) throws {
        guard !issues.isEmpty, issues.allSatisfy(\.canDelete) else { throw DataBackupError.dataChanged }
        var messageIDs = Set<UUID>()
        var affectedSessionIDs = Set<UUID>()
        do {
            let reader = try RecoveryStoreReader(url: url, allowSidecarCreation: true)
            for issue in issues {
                var matches = false
                try reader.query("SELECT ZID FROM Z\(issue.entity.uppercased()) WHERE Z_PK=\(issue.rowID)") { row in
                    matches = (try row.value("id", as: UUID.self)) == issue.recordID
                }
                guard matches else { throw DataBackupError.dataChanged }
            }
            var rows: [(pk: Int64, id: UUID?, parent: Int64?, session: Int64?)] = []
            try reader.query("SELECT Z_PK,ZID,ZPARENTMESSAGE,ZSESSION FROM ZCHATMESSAGE") { row in
                rows.append((try row.integer("Z_PK"), try? row.value("id", as: UUID.self), try row.optionalInteger("ZPARENTMESSAGE"), try row.optionalInteger("ZSESSION")))
            }
            var deletedRows = Set(issues.filter { $0.entity == "ChatMessage" }.map(\.rowID))
            let deletedChats = Set(issues.filter { $0.entity == "ChatSession" }.map(\.rowID))
            deletedRows.formUnion(rows.filter { $0.session.map(deletedChats.contains) == true }.map(\.pk))
            let children = Dictionary(grouping: rows, by: \.parent)
            var queue = Array(deletedRows)
            while let parent = queue.popLast() {
                for child in children[parent] ?? [] where deletedRows.insert(child.pk).inserted { queue.append(child.pk) }
            }
            let selected = rows.filter { deletedRows.contains($0.pk) }
            let selectedIDs = selected.compactMap(\.id)
            let uniqueSelectedIDs = Set(selectedIDs)
            guard selectedIDs.count == selected.count,
                  uniqueSelectedIDs.count == selectedIDs.count,
                  rows.filter({ $0.id.map(uniqueSelectedIDs.contains) == true }).count == selectedIDs.count else {
                throw DataBackupError.invalidRelationships
            }
            messageIDs = Set(selectedIDs)
            let sessionPKs = Set(selected.compactMap(\.session))
            try reader.query("SELECT Z_PK,ZID FROM ZCHATSESSION") { row in
                if sessionPKs.contains(try row.integer("Z_PK")) { affectedSessionIDs.insert(try row.value("id")) }
            }
        }
        // SwiftData batch deletion cannot nullify the inverse of this message
        // tree. Delete registered objects so the context maintains relationships.
        func remove<T: PersistentModel>(_ type: T.Type, matching predicate: Predicate<T>) throws {
            for identifier in try context.fetchIdentifiers(FetchDescriptor<T>(predicate: predicate)) {
                guard let model = context.model(for: identifier) as? T else { throw DataBackupError.dataChanged }
                context.delete(model)
            }
        }
        let ids = Array(messageIDs)
        if !ids.isEmpty { try remove(ChatMessage.self, matching: #Predicate { ids.contains($0.id) }) }
        for (entity, records) in Dictionary(grouping: issues, by: \.entity) {
            let ids = records.compactMap(\.recordID)
            switch entity {
            case "ChatMessage": break
            case "ChatSession": try remove(ChatSession.self, matching: #Predicate { ids.contains($0.id) })
            case "AppSettings": try remove(AppSettings.self, matching: #Predicate { ids.contains($0.id) })
            case "ChatServerPreset": try remove(ChatServerPreset.self, matching: #Predicate { ids.contains($0.id) })
            case "VoiceServerPreset": try remove(VoiceServerPreset.self, matching: #Predicate { ids.contains($0.id) })
            case "VoicePreset": try remove(VoicePreset.self, matching: #Predicate { ids.contains($0.id) })
            case "SystemPromptPreset": try remove(SystemPromptPreset.self, matching: #Predicate { ids.contains($0.id) })
            default: throw DataBackupError.unsupportedFormat
            }
        }
        let deletedSessionIDs = Set(issues.filter { $0.entity == "ChatSession" }.compactMap(\.recordID))
        let sessionIDs = Array(affectedSessionIDs.subtracting(deletedSessionIDs))
        let sessions = try context.fetch(FetchDescriptor<ChatSession>(predicate: #Predicate { sessionIDs.contains($0.id) }))
        for session in sessions {
            let remaining = session.messages.filter { !messageIDs.contains($0.id) }
            if let root = session.activeRootMessageID, messageIDs.contains(root) { session.activeRootMessageID = nil }
            for message in remaining {
                if let child = message.activeChildMessageID, messageIDs.contains(child) { message.activeChildMessageID = nil }
            }
            let latest = remaining.sorted(by: ChatMessageBranchResolver.stableMessageOrder).last
            session.lastMessageID = latest?.id
            session.lastMessageAt = latest?.createdAt
            session.sidebarPreviewText = ChatSession.sidebarPreviewText(for: latest)
        }
    }
}

nonisolated struct DataChatPreview: Sendable {
    struct Message: Identifiable, Sendable {
        let id: UUID
        let content: String
        let reasoning: String?
        let isUser: Bool
        let date: Date
        let attachments: [ChatImageAttachment]
        let problems: [String]
    }
    struct Branch: Identifiable, Sendable {
        let id: UUID
        let messageIDs: [UUID]
        let date: Date
        let title: String
    }
    let messages: [UUID: Message]
    let branches: [Branch]
    let activeLeafID: UUID?
}

extension DataManagementStore {
    static func chatPreview(at url: URL, id: UUID) throws -> DataChatPreview {
        let reader = try RecoveryStoreReader(url: url, allowSidecarCreation: true)
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "")
        let session = ChatSession()
        session.id = id
        var sessionPK: Int64?
        try reader.query("SELECT Z_PK,ZACTIVEROOTMESSAGEID FROM ZCHATSESSION WHERE hex(ZID)='\(hex)'") { row in
            sessionPK = try row.integer("Z_PK")
            session.activeRootMessageID = row.recover("activeRootMessageID", defaultValue: Optional<UUID>.none)
        }
        guard let sessionPK else { throw DataBackupError.dataChanged }
        var messages: [Int64: ChatMessage] = [:]
        var parents: [Int64: Int64] = [:]
        var problems: [UUID: [String]] = [:]
        try reader.query("SELECT * FROM ZCHATMESSAGE WHERE ZSESSION=\(sessionPK)") { row in
            let pk = try row.integer("Z_PK")
            let message = try StartupDataRecovery.recoverMessage(row)
            messages[pk] = message
            problems[message.id] = row.lostFields.sorted().map { DataRecoveryIssue.fieldTitle($0) + ": " + (row.fieldProblems[$0] ?? "") }
            parents[pk] = try row.optionalInteger("ZPARENTMESSAGE")
        }
        var identities = Set<UUID>()
        for (pk, message) in messages {
            guard identities.insert(message.id).inserted else { throw DataBackupError.invalidRelationships }
            message.session = session
            if let parent = parents[pk] {
                guard let previous = messages[parent] else { throw DataBackupError.invalidRelationships }
                message.parentMessage = previous
            }
        }
        session.messages = Array(messages.values)
        let active = ChatMessageBranchResolver.activeBranchMessages(in: session).messages
        let parentPKs = Set(parents.values)
        let leaves = messages.filter { !parentPKs.contains($0.key) }.map(\.value)
            .sorted(by: ChatMessageBranchResolver.stableMessageOrder)
        var covered = Set<UUID>()
        let branches = try leaves.map { leaf -> DataChatPreview.Branch in
            guard let path = ChatMessageBranchResolver.messagesThrough(leaf, in: session) else { throw DataBackupError.invalidRelationships }
            covered.formUnion(path.map(\.id))
            return DataChatPreview.Branch(id: leaf.id, messageIDs: path.map(\.id), date: leaf.createdAt, title: String(leaf.content.prefix(80)))
        }
        guard covered == identities else { throw DataBackupError.invalidRelationships }
        let details = messages.values.map { message in
            DataChatPreview.Message(id: message.id, content: message.isUser ? message.content : message.assistantText,
                reasoning: message.isUser ? nil : message.assistantReasoningText, isUser: message.isUser,
                date: message.createdAt, attachments: message.imageAttachments, problems: problems[message.id] ?? [])
        }
        return DataChatPreview(messages: Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) }), branches: branches, activeLeafID: active.last?.id)
    }
}

nonisolated struct DataAttachmentThumbnail: Identifiable, Sendable {
    let id: UUID
    let image: CGImage?
}

extension DataManagementStore {
    static func attachmentThumbnails(at url: URL) throws -> [UUID: [DataAttachmentThumbnail]] {
        let reader = try RecoveryStoreReader(url: url, allowSidecarCreation: true)
        var result: [UUID: [DataAttachmentThumbnail]] = [:]
        try reader.query("SELECT ZID,ZIMAGEATTACHMENTSDATA FROM ZCHATMESSAGE WHERE length(ZIMAGEATTACHMENTSDATA)>0") { row in
            try Task.checkCancellation()
            let id: UUID = try row.value("id")
            let data: Data = try row.value("imageAttachmentsData")
            let readable = try row.readableItems(data, of: ChatImageAttachment.self, field: "imageAttachmentsData")
            let attachments = try readable.map { try JSONDecoder().decode([ChatImageAttachment].self, from: $0) } ?? []
            result[id] = try attachments.map { attachment in
                try Task.checkCancellation()
                let source = CGImageSourceCreateWithData(attachment.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
                let image = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160
                ] as CFDictionary) }
                return DataAttachmentThumbnail(id: attachment.id, image: image)
            }
        }
        return result
    }
}
