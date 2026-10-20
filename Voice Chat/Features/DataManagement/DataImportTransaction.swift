import Foundation

/// Database replacement is the commit point. This temporary journal restores
/// keychain writes interrupted before that point, including after a restart.
@MainActor
enum DataImportTransaction {
    nonisolated static let fileName = "DataImportTransaction.json"
    private struct Journal: Codable {
        let operationID: UUID
        let previousCredentials: [DataBackupCredential]
        let changedCredentials: [DataBackupCredential]
    }

    private static var journalURL: URL {
        StartupPersistentStore.defaultURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    static var hasPendingTransaction: Bool {
        FileManager.default.fileExists(atPath: journalURL.path)
    }

    static func recoverInterruptedImport() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        if try StartupPersistentStore.replacementID() != journal.operationID {
            try DataBackupCredentials.restore(journal.previousCredentials, changed: journal.changedCredentials)
        }
        try FileManager.default.removeItem(at: journalURL)
    }

    static func begin(operationID: UUID, credentials: [DataBackupCredential]) throws {
        try recoverInterruptedImport()
        guard !hasPendingTransaction else { throw CocoaError(.fileWriteFileExists) }
        let previous = try DataBackupCredentials.read(presetIDs: Set(credentials.map(\.presetID)))
        let journal = Journal(operationID: operationID, previousCredentials: previous, changedCredentials: credentials)
        let data = try JSONEncoder().encode(journal)
        #if os(iOS) || os(visionOS)
        try data.write(to: journalURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        #endif
        do { try DataBackupCredentials.write(credentials) }
        catch {
            try recoverInterruptedImport()
            throw error
        }
    }

    static func finish() throws {
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        guard try StartupPersistentStore.replacementID() == journal.operationID else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.removeItem(at: journalURL)
    }
}
