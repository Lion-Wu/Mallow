import Foundation
import CryptoKit

nonisolated struct DataImportChange: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case added, updated, skipped, branch

    }
    let id = UUID()
    let kind: Kind
    let category: String
    let name: String
    var messageID: UUID?
    var sessionID: UUID?
}

nonisolated struct DataImportPreview: Identifiable, Sendable {
    let id = UUID()
    let original: DataBackupReadResult
    let incoming: DataBackupReadResult
    let merged: AppDataBackup
    let changes: [DataImportChange]

    func count(_ kind: DataImportChange.Kind) -> Int { changes.filter { $0.kind == kind }.count }
}

nonisolated enum DataBackupMerge {
    static func preview(current currentSource: DataBackupReadResult, incoming incomingSource: DataBackupReadResult) throws -> DataImportPreview {
        let current = currentSource.snapshot
        let incoming = incomingSource.snapshot
        try current.validateRelationships()
        try incoming.validateRelationships()
        var merged = current
        var changes: [DataImportChange] = []

        func merge<T: Equatable, ID: Hashable>(
            _ existing: [T], _ imported: [T], id: KeyPath<T, ID>, category: String, name: (T) -> String
        ) -> [T] {
            var result = existing
            var positions = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element[keyPath: id], $0.offset) })
            for value in imported {
                let kind: DataImportChange.Kind
                if let index = positions[value[keyPath: id]] {
                    kind = result[index] == value ? .skipped : .updated
                    result[index] = value
                } else {
                    kind = .added
                    positions[value[keyPath: id]] = result.count
                    result.append(value)
                }
                changes.append(DataImportChange(kind: kind, category: category, name: name(value)))
            }
            return result
        }

        var sessions = Dictionary(uniqueKeysWithValues: current.sessions.map { ($0.id, $0) })
        for session in incoming.sessions { sessions[session.id] = session }
        merged.sessions = sessions.values.sorted { $0.id.uuidString < $1.id.uuidString }
        merged.chatServers = merge(current.chatServers, incoming.chatServers, id: \.id, category: String(localized: "DATA_CHAT_SERVER_PRESETS", defaultValue: "Chat Server Presets"), name: { $0.name })
        merged.voiceServers = merge(current.voiceServers, incoming.voiceServers, id: \.id, category: String(localized: "DATA_VOICE_SERVER_PRESETS", defaultValue: "Voice Server Presets"), name: { $0.name })
        merged.voicePresets = merge(current.voicePresets, incoming.voicePresets, id: \.id, category: String(localized: "DATA_VOICE_PRESETS", defaultValue: "Voice Presets"), name: { $0.name })
        merged.prompts = merge(current.prompts, incoming.prompts, id: \.id, category: String(localized: "DATA_SYSTEM_PROMPT_PRESETS", defaultValue: "System Prompt Presets"), name: { $0.name })
        merged.credentials = merge(current.credentials, incoming.credentials, id: \.presetID, category: String(localized: "DATA_API_KEYS", defaultValue: "API Keys"), name: { credential in
            merged.chatServers.first { $0.id == credential.presetID }?.name ?? credential.presetID.uuidString
        })
        if var imported = incoming.settings.first {
            // App settings are a singleton even when two installations assigned different IDs.
            if let existing = current.settings.first { imported.id = existing.id }
            merged.settings = merge(current.settings, [imported], id: \.id, category: String(localized: "SETTINGS_TITLE", defaultValue: "Settings"), name: { _ in String(localized: "SETTINGS_TITLE", defaultValue: "Settings") })
        }

        var messages = Dictionary(uniqueKeysWithValues: current.messages.map { ($0.id, $0) })
        let incomingMessages = Dictionary(uniqueKeysWithValues: incoming.messages.map { ($0.id, $0) })
        var mappedIDs: [UUID: UUID] = [:]
        struct Parent: Hashable {
            let sessionID: UUID
            let messageID: UUID?
        }
        var occupiedParents = Set(current.messages.map { Parent(sessionID: $0.sessionID, messageID: $0.parentID) })
        let currentSessionIDs = Set(current.sessions.map(\.id))
        struct Origin: Hashable {
            let sessionID: UUID
            let messageID: UUID
            let parentID: UUID?
        }
        func origin(_ message: ChatMessageBackup) -> Origin {
            Origin(sessionID: message.sessionID, messageID: message.importSourceMessageID ?? message.id, parentID: message.parentID)
        }
        var versions = Dictionary(grouping: current.messages, by: origin).mapValues { $0.map(\.id) }
        var importedIDs: [UUID] = []
        var importedIDSet = Set<UUID>()
        var branchIDs = Set<UUID>()

        func importMessage(_ original: ChatMessageBackup) throws {
            guard mappedIDs[original.id] == nil else { return }
            // Iterative parent traversal handles long conversations without recursive stack growth.
            var path: [ChatMessageBackup] = []
            var cursor: ChatMessageBackup? = original
            while let message = cursor, mappedIDs[message.id] == nil {
                path.append(message)
                cursor = message.parentID.flatMap { incomingMessages[$0] }
            }
            for source in path.reversed() {
                var value = source
                value.parentID = source.parentID.flatMap { mappedIDs[$0] }
                var isConflictBranch = false
                let sourceIdentity = source.importSourceMessageID ?? source.id
                // A branch can travel back from another installation with a
                // different copy ID. Only shared provenance permits matching;
                // independently generated messages never merge by text alone.
                if let equivalent = versions[origin(value)]?.compactMap({ messages[$0] }).first(where: { sameContent($0, value) }) {
                    value.id = equivalent.id
                    value.importSourceMessageID = equivalent.importSourceMessageID
                } else if let existing = messages[value.id] {
                    guard existing.sessionID == value.sessionID else { throw DataBackupError.invalidRelationships }
                    if !sameContent(existing, value) || existing.parentID != value.parentID {
                        value.id = try branchID(for: source, parentID: value.parentID)
                        value.importSourceMessageID = sourceIdentity
                        isConflictBranch = true
                    }
                }
                if let existing = messages[value.id] {
                    guard existing.sessionID == value.sessionID, existing.parentID == value.parentID,
                          sameContent(existing, value) else { throw DataBackupError.duplicateIdentity }
                    value = value.supplementing(existing)
                    // Active selections are remapped after every imported child has an identity.
                    value.activeChildMessageID = existing.activeChildMessageID
                } else {
                    let siblings = occupiedParents.contains(Parent(sessionID: value.sessionID, messageID: value.parentID))
                    if isConflictBranch || (currentSessionIDs.contains(value.sessionID) && siblings) { branchIDs.insert(value.id) }
                    value.activeChildMessageID = nil
                    versions[origin(value), default: []].append(value.id)
                }
                mappedIDs[source.id] = value.id
                occupiedParents.insert(Parent(sessionID: value.sessionID, messageID: value.parentID))
                messages[value.id] = value
                if importedIDSet.insert(value.id).inserted { importedIDs.append(value.id) }
            }
        }

        for message in incoming.messages { try importMessage(message) }
        for source in incoming.messages {
            guard let id = mappedIDs[source.id] else { continue }
            let child = source.activeChildMessageID.flatMap { mappedIDs[$0] }
            if let child, messages[child]?.parentID == id { messages[id]?.activeChildMessageID = child }
        }
        let incomingSessions = Dictionary(uniqueKeysWithValues: incoming.sessions.map { ($0.id, $0) })
        for index in merged.sessions.indices {
            if let source = incomingSessions[merged.sessions[index].id], let root = source.activeRootMessageID {
                merged.sessions[index].activeRootMessageID = mappedIDs[root]
            }
        }
        let oldMessages = Dictionary(uniqueKeysWithValues: current.messages.map { ($0.id, $0) })
        for id in importedIDs {
            guard let value = messages[id] else { continue }
            let kind: DataImportChange.Kind
            if let previous = oldMessages[id] { kind = previous == value ? .skipped : .updated }
            else { kind = branchIDs.contains(id) ? .branch : .added }
            changes.append(DataImportChange(kind: kind, category: String(localized: "MESSAGE_LIST", defaultValue: "Messages"),
                name: String(value.content.prefix(160)), messageID: id, sessionID: value.sessionID))
        }
        merged.messages = messages.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let messagesBySession = Dictionary(grouping: merged.messages, by: \.sessionID)
        let originalSessions = Dictionary(uniqueKeysWithValues: current.sessions.map { ($0.id, $0) })
        for index in merged.sessions.indices {
            let latest = messagesBySession[merged.sessions[index].id]?.max {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
            }
            merged.sessions[index].lastMessageID = latest?.id
            merged.sessions[index].lastMessageAt = latest?.createdAt
            // Keep the canonical projection until materializing the candidate;
            // preview equality compares user-owned fields, not derived summaries.
            if let original = originalSessions[merged.sessions[index].id] {
                merged.sessions[index].sidebarPreviewText = original.sidebarPreviewText
            }
            if incomingSessions[merged.sessions[index].id] != nil {
                let value = merged.sessions[index]
                let kind: DataImportChange.Kind = originalSessions[value.id].map { $0 == value ? .skipped : .updated } ?? .added
                changes.append(DataImportChange(kind: kind, category: String(localized: "CHAT_LIST_TITLE", defaultValue: "Chats"), name: value.title, sessionID: value.id))
            }
        }
        try merged.validateRelationships()
        return DataImportPreview(original: currentSource, incoming: incomingSource, merged: merged, changes: changes)
    }

    private static func sameContent(_ lhs: ChatMessageBackup, _ rhs: ChatMessageBackup) -> Bool {
        lhs.content == rhs.content && lhs.isUser == rhs.isUser && lhs.imageAttachmentsData == rhs.imageAttachmentsData
    }

    private static func branchID(for message: ChatMessageBackup, parentID: UUID?) throws -> UUID {
        struct Identity: Encodable {
            let source: UUID
            let session: UUID
            let parent: UUID?
            let content: String
            let isUser: Bool
            let images: Data?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(Identity(source: message.importSourceMessageID ?? message.id, session: message.sessionID, parent: parentID,
                                               content: message.content, isUser: message.isUser, images: message.imageAttachmentsData))
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
