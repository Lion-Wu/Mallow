import CryptoKit
import Foundation
import SwiftData

enum ChatImageAttachmentLimits {
    static let maximumAttachmentCount = 9
}

/// A small, portable image reference. Encoded records never contain image bytes.
struct ChatImageAttachment: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let mimeType: String
    let byteCount: Int
    let digest: String
    private var payload: Data?
    private var fileURL: URL?
    private var lease: ChatImageFileLease?

    private enum CodingKeys: String, CodingKey { case id, mimeType, byteCount, digest }

    init(id: UUID = UUID(), mimeType: String, data: Data) {
        self.id = id
        self.mimeType = mimeType
        byteCount = data.count
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        payload = data
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        mimeType = try values.decode(String.self, forKey: .mimeType)
        byteCount = try values.decode(Int.self, forKey: .byteCount)
        digest = try values.decode(String.self, forKey: .digest)
        guard byteCount > 0, mimeType.hasPrefix("image/"),
              digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid image reference."))
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.mimeType == rhs.mimeType && lhs.byteCount == rhs.byteCount && lhs.digest == rhs.digest
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(mimeType); hasher.combine(byteCount); hasher.combine(digest)
    }

    func loadData() throws -> Data {
        if let payload { return payload }
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count == byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    func materialized() throws -> Self {
        var copy = self
        copy.payload = try loadData()
        copy.fileURL = nil
        copy.lease = nil
        return copy
    }

    func resolved(at storeURL: URL) -> Self {
        var copy = self
        copy.fileURL = ChatImageStore.directory(for: storeURL).appendingPathComponent(digest + ".image")
        if let fileURL = copy.fileURL { copy.lease = ChatImageFileLease(fileURL) }
        return copy
    }

    func persisted(at storeURL: URL, staging: Bool = false) throws -> Self {
        var copy = resolved(at: storeURL)
        guard let destination = copy.fileURL else { throw CocoaError(.fileWriteUnknown) }
        let existed = FileManager.default.fileExists(atPath: destination.path)
        if !staging { ChatImageFileLease.registry.preserve(destination) }
        if fileURL != destination || payload != nil {
            let bytes = try loadData()
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Immutable content names make copying before the database commit safe.
            // Replacing identical bytes also repairs an explicitly imported damaged file.
            try bytes.write(to: destination, options: .atomic)
        }
        copy.payload = nil
        if staging, !existed { try ChatImageFileLease.registry.removeWhenUnused(destination) }
        return copy
    }

    static func encodeList(_ attachments: [Self]) -> Data? {
        guard !attachments.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(attachments)
    }

    static func decodeList(from data: Data?, storeURL: URL? = nil) -> [Self] {
        guard let data else { return [] }
        let values = (try? JSONDecoder().decode([Self].self, from: data)) ?? []
        return storeURL.map { url in values.map { $0.resolved(at: url) } } ?? values
    }
}

/// The database and its adjacent image directory form one portable store.
/// Only metadata is read during list rendering and branch capability checks.
nonisolated enum ChatImageStore {
    static func directory(for storeURL: URL) -> URL { storeURL.appendingPathExtension("images") }

    struct ReadLease: Sendable {
        fileprivate let lease: ChatImageFileLease
    }

    /// Keep files referenced by a fixed database snapshot alive while they are copied.
    static func retainFiles(at storeURL: URL) -> ReadLease {
        ReadLease(lease: ChatImageFileLease(URL(fileURLWithPath: directory(for: storeURL).path, isDirectory: true)))
    }

    static func persistPending(in context: ModelContext) throws {
        for case let message as ChatMessage in context.insertedModelsArray + context.changedModelsArray {
            try message.persistImages()
        }
    }

    static func removeUnreferencedFiles(at storeURL: URL) throws {
        let root = directory(for: storeURL)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let names = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "image" }.map { $0.deletingPathExtension().lastPathComponent }
        try removeUnreferenced(Set(names), at: storeURL)
    }

    static func copy(from source: URL, to destination: URL) throws {
        let sourceDirectory = directory(for: source)
        let manager = FileManager.default
        guard manager.fileExists(atPath: sourceDirectory.path) else { return }
        let destinationDirectory = directory(for: destination)
        try manager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        for file in try manager.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                  file.pathExtension == "image" else { throw CocoaError(.fileReadCorruptFile) }
            let target = destinationDirectory.appendingPathComponent(file.lastPathComponent)
            ChatImageFileLease.registry.preserve(target)
            try Data(contentsOf: file, options: .mappedIfSafe).write(to: target, options: .atomic)
        }
    }

    /// Called only after a committed deletion, with the removed records' file names.
    /// Other images (including pending work) are never swept as a side effect.
    static func removeUnreferenced(_ digests: Set<String>, at storeURL: URL) throws {
        guard !digests.isEmpty else { return }
        var candidates = digests
        let reader = try RecoveryStoreReader(url: storeURL, allowSidecarCreation: true)
        try reader.query("SELECT ZIMAGEATTACHMENTREFERENCESDATA FROM ZCHATMESSAGE WHERE ZIMAGEATTACHMENTREFERENCESDATA IS NOT NULL") { row in
            let data: Data = try row.value("imageAttachmentReferencesData")
            let references = try JSONDecoder().decode([ChatImageAttachment].self, from: data)
            candidates.subtract(references.map(\.digest))
        }
        for digest in candidates {
            let file = directory(for: storeURL).appendingPathComponent(digest + ".image")
            try ChatImageFileLease.registry.removeWhenUnused(file)
        }
    }
}

/// Active drafts, previews, and request snapshots keep their files alive after a
/// message is deleted. Committed references are checked separately by the store.
fileprivate final class ChatImageFileLease: @unchecked Sendable {
    static let registry = Registry()
    let url: URL
    init(_ url: URL) { self.url = url; Self.registry.retain(url) }
    deinit { Self.registry.release(url) }

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [URL: Int] = [:]
        private var pendingRemoval = Set<URL>()

        func retain(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            counts[url, default: 0] += 1
        }
        func preserve(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            pendingRemoval.remove(url)
        }
        func removeWhenUnused(_ url: URL) throws {
            lock.lock(); defer { lock.unlock() }
            if isRetained(url) { pendingRemoval.insert(url); return }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        func release(_ url: URL) {
            lock.lock()
            let count = counts[url, default: 1] - 1
            if count > 0 { counts[url] = count; lock.unlock(); return }
            counts.removeValue(forKey: url)
            let candidates: [URL] = url.hasDirectoryPath
                ? pendingRemoval.filter { $0.deletingLastPathComponent() == url }
                : (pendingRemoval.contains(url) ? [url] : [])
            lock.unlock()
            guard !candidates.isEmpty else { return }
            DispatchQueue.global(qos: .utility).async {
                for candidate in candidates { self.removePendingFile(candidate) }
            }
        }

        private func isRetained(_ url: URL) -> Bool {
            counts[url, default: 0] > 0 || counts[url.deletingLastPathComponent(), default: 0] > 0
        }

        private func removePendingFile(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            guard !isRetained(url), pendingRemoval.remove(url) != nil else { return }
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } catch { print("Could not remove unused image: \(error)") }
        }
    }
}
