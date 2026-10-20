import Foundation
import Security

nonisolated struct DataBackupCredential: Codable, Equatable, Sendable {
    let presetID: UUID
    let value: String
}

@MainActor
enum DataBackupCredentials {
    private static var service: String { Bundle.main.bundleIdentifier ?? "Mallow" }

    static func read(presetIDs: Set<UUID>) throws -> [DataBackupCredential] {
        let data = try RawDataExport.keychainSnapshot(service: service)
        return try decode(data, presetIDs: presetIDs)
    }

    nonisolated static func decode(_ data: Data, presetIDs: Set<UUID>) throws -> [DataBackupCredential] {
        guard let records = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            throw KeychainStoreError(status: errSecDecode)
        }
        let accounts = Dictionary(uniqueKeysWithValues: presetIDs.map { (ChatAPIKeyStore().account(forChatServerPresetID: $0), $0) })
        return try records.compactMap { record in
            guard let account = record[kSecAttrAccount as String] as? String, let id = accounts[account] else { return nil }
            guard let bytes = record[kSecValueData as String] as? Data, let value = String(data: bytes, encoding: .utf8) else {
                throw KeychainStoreError(status: errSecDecode)
            }
            return DataBackupCredential(presetID: id, value: value)
        }.sorted { $0.presetID.uuidString < $1.presetID.uuidString }
    }

    nonisolated static func recover(_ data: Data, presetIDs: Set<UUID>) -> (values: [DataBackupCredential], category: DataRecoveryCategory) {
        var category = DataRecoveryCategory(id: "Credentials", title: String(localized: "API Keys"))
        guard let records = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [Any] else {
            category.hasUnknownLoss = true
            category.problems.append(String(localized: "The API key file could not be read because its format is invalid."))
            return ([], category)
        }
        let accounts = Dictionary(uniqueKeysWithValues: presetIDs.map { (ChatAPIKeyStore().account(forChatServerPresetID: $0), $0) })
        let counts = Dictionary(records.compactMap { ($0 as? [String: Any])?[kSecAttrAccount as String] as? String }.map { ($0, 1) }, uniquingKeysWith: +)
        var values: [DataBackupCredential] = []
        for (index, record) in records.enumerated() {
            func skip(_ explanation: String) {
                category.skipped += 1
                category.problems.append(String(format: String(localized: "API key %lld: %@"), Int64(index + 1), explanation))
            }
            let item = record as? [String: Any]
            guard let account = item?[kSecAttrAccount as String] as? String, !account.isEmpty else {
                skip(String(localized: "This record has no valid account identifier."))
                continue
            }
            guard counts[account] == 1 else {
                skip(String(localized: "Multiple keys share this account, so the correct key cannot be determined."))
                continue
            }
            guard let id = accounts[account] else {
                skip(String(localized: "This key has no matching server preset, so it cannot be included in the merge."))
                continue
            }
            guard let bytes = item?[kSecValueData as String] as? Data,
                  let value = String(data: bytes, encoding: .utf8) else {
                skip(String(localized: "The key value is missing or unreadable."))
                continue
            }
            values.append(DataBackupCredential(presetID: id, value: value))
            category.recovered += 1
        }
        return (values.sorted { $0.presetID.uuidString < $1.presetID.uuidString }, category)
    }

    static func write(_ values: [DataBackupCredential]) throws {
        for credential in values {
            try KeychainStore.saveString(credential.value, service: service,
                account: ChatAPIKeyStore().account(forChatServerPresetID: credential.presetID)).get()
        }
    }

    static func restore(_ original: [DataBackupCredential], changed: [DataBackupCredential]) throws {
        let values = Dictionary(uniqueKeysWithValues: original.map { ($0.presetID, $0.value) })
        var errors: [String] = []
        for credential in changed {
            let account = ChatAPIKeyStore().account(forChatServerPresetID: credential.presetID)
            let result: Result<Void, KeychainStoreError>
            if let value = values[credential.presetID] {
                result = KeychainStore.saveString(value, service: service, account: account)
            } else {
                result = KeychainStore.delete(service: service, account: account)
            }
            if case .failure(let error) = result { errors.append(error.localizedDescription) }
        }
        if !errors.isEmpty { throw DataBackupError.credentialRollback(errors.joined(separator: "\n")) }
    }
}
