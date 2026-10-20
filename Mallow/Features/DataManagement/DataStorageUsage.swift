import Foundation
import CryptoKit

nonisolated enum DataCleanupCategory: Sendable {
    case networkCache, temporaryFiles
}

nonisolated struct DataStorageUsage: Sendable {
    let chats: Int64
    let images: Int64
    let settings: Int64
    let documents: Int64
    let temporaryFiles: Int64
    let caches: Int64
    let other: Int64
    let reclaimableTemporaryFiles: Int64
    let networkCache: Int64
    var total: Int64 { chats + images + settings + documents + temporaryFiles + caches + other }
    var reclaimable: Int64 { reclaimableTemporaryFiles + networkCache }
}

nonisolated enum DataStorageInspector {
    // A previous process cannot still be using its preview or synthesis files.
    // Files made during this launch are deliberately excluded from cleanup.
    static let launchDate = Date()

    static func measure() throws -> DataStorageUsage {
        let current = StartupPersistentStore.defaultURL
        let reader = try RecoveryStoreReader(url: current)
        let images = try reader.payloadSize(entity: "ChatMessage", only: "imageAttachmentsData")
        let chats = try reader.payloadSize(entity: "ChatMessage", excluding: "imageAttachmentsData")
            + reader.payloadSize(entity: "ChatSession")
            + reader.payloadSize(entity: "ChatRequestContextMetadata")
        let settings = try ["AppSettings", "ChatServerPreset", "VoiceServerPreset", "VoicePreset", "SystemPromptPreset"]
            .reduce(Int64(0)) { try $0 + reader.payloadSize(entity: $1) }

        let manager = FileManager.default
        let sources = StartupPersistentStore.exportSources()
        let stores = try sources.values.reduce(Int64(0)) { try $0 + size(of: $1) }
        let temporaryFiles = try temporaryItems().reduce(Int64(0)) { try $0 + size(of: $1) }
        let reclaimableTemporaryFiles = try cleanupCandidates().reduce(Int64(0)) { try $0 + size(of: $1) }
        let networkCache = Int64(URLCache.shared.currentDiskUsage)
        let documents: Int64
        let caches: Int64
        let library: Int64
        if hasPrivateContainer {
            documents = try size(of: manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            caches = try size(of: manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            library = try size(of: manager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
        } else {
            // Unsandboxed development builds must not count the user's shared Library or Documents.
            documents = 0
            caches = networkCache
            library = stores + caches
        }
        return DataStorageUsage(chats: chats, images: images, settings: settings,
                                documents: documents, temporaryFiles: temporaryFiles, caches: caches,
                                other: max(0, library - caches - chats - images - settings),
                                reclaimableTemporaryFiles: reclaimableTemporaryFiles, networkCache: networkCache)
    }

    static var hasPrivateContainer: Bool {
        #if os(macOS)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.lastPathComponent == "Data"
            && home.deletingLastPathComponent().lastPathComponent == Bundle.main.bundleIdentifier
        #else
        return true
        #endif
    }

    private static func temporaryItems() throws -> [URL] {
        let items = try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
                                                                includingPropertiesForKeys: nil)
        return hasPrivateContainer ? items : items.filter { isOwnedTemporaryItem($0.lastPathComponent) }
    }

    private static func isOwnedTemporaryItem(_ name: String) -> Bool {
        name.hasPrefix("Mallow-AppleSpeech-") || name.hasPrefix("mallow-motion-")
            || name.hasPrefix("DataExport-") || name.hasPrefix("DataPreparation-") || name == "MallowQuickLook"
    }

    static func clean(_ category: DataCleanupCategory) throws {
        switch category {
        case .networkCache:
            URLCache.shared.removeAllCachedResponses()
        case .temporaryFiles:
            for url in try cleanupCandidates() { try FileManager.default.removeItem(at: url) }
        }
    }

    private static func cleanupCandidates() throws -> [URL] {
        let manager = FileManager.default
        #if os(macOS)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard home.lastPathComponent == "Data",
              home.deletingLastPathComponent().lastPathComponent == Bundle.main.bundleIdentifier else { return [] }
        #endif
        let directory = manager.temporaryDirectory
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .contentModificationDateKey, .isRegularFileKey]
        let items = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        var result: [URL] = []
        for item in items {
            let name = item.lastPathComponent
            let isOwned = name.hasPrefix("Mallow-AppleSpeech-") || name.hasPrefix("mallow-motion-") || name.hasPrefix("DataExport-") || name.hasPrefix("DataPreparation-")
            if isOwned {
                let values = try item.resourceValues(forKeys: keys)
                if values.isSymbolicLink != true, let date = values.contentModificationDate, date < launchDate {
                    result.append(item)
                }
            } else if name == "MallowQuickLook" {
                guard try item.resourceValues(forKeys: keys).isSymbolicLink != true else { continue }
                for preview in try manager.contentsOfDirectory(at: item, includingPropertiesForKeys: Array(keys)) {
                    let values = try preview.resourceValues(forKeys: keys)
                    if preview.lastPathComponent.hasPrefix("attachment-"), values.isRegularFile == true,
                       values.isSymbolicLink != true, let date = values.contentModificationDate, date < launchDate {
                        result.append(preview)
                    }
                }
            }
        }
        return result
    }

    private static func size(of url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { return 0 }
        if values.isDirectory == true {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
                .reduce(Int64(0)) { try $0 + size(of: $1) }
        }
        return Int64(values.fileSize ?? 0)
    }
}


nonisolated struct DataUnusedFile: Identifiable, Sendable {
    let url: URL
    let bytes: Int64
    let isDirectory: Bool
    let fingerprint: SHA256.Digest
    var id: String { url.lastPathComponent }
}

/// Inventories unowned entries beside the live database, without following links.
nonisolated enum DataUnusedFileInspector {
    private static var protectedNames: Set<String> {
        let store = StartupPersistentStore.defaultURL
        return Set([store.lastPathComponent, store.lastPathComponent + "-wal",
                    store.lastPathComponent + "-shm", store.lastPathComponent + "-journal",
                    "." + store.deletingPathExtension().lastPathComponent + "_SUPPORT",
                    PersistentStoreOwnership.fileName, DataImportTransaction.fileName,
                    "AddressBook", "SyncServices", "CrashReporter", "iCloud", ".DS_Store"])
    }

    private static func directory() throws -> URL {
        guard DataStorageInspector.hasPrivateContainer else { throw CocoaError(.fileReadNoPermission) }
        let root = StartupPersistentStore.defaultURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        guard root.path.hasPrefix(home.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        return root
    }

    private static func isProtected(_ name: String) -> Bool {
        protectedNames.contains(name) || name.hasPrefix("com.apple.") || name.hasPrefix(".com.apple.")
    }

    static func scan() throws -> [DataUnusedFile] {
        let root = try directory()
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !isProtected($0.lastPathComponent) }
            .map { try inspect($0) }
            .sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }

    static func export(_ files: [DataUnusedFile]) throws -> RawDataExport {
        try validate(files)
        let archive = try RawDataExport.prepareFiles(files.map(\.url))
        do {
            try validate(files)
            return archive
        } catch {
            archive.discard()
            throw error
        }
    }

    static func delete(_ files: [DataUnusedFile]) throws {
        try validate(files)
        for file in files { try FileManager.default.removeItem(at: file.url) }
    }

    private static func validate(_ files: [DataUnusedFile]) throws {
        let root = try directory()
        // Validate the complete selection before exporting or removing anything.
        for file in files {
            guard file.url.deletingLastPathComponent().standardizedFileURL == root,
                  !isProtected(file.id), try inspect(file.url).fingerprint == file.fingerprint else {
                throw DataBackupError.dataChanged
            }
        }
    }

    private static func inspect(_ url: URL) throws -> DataUnusedFile {
        let manager = FileManager.default
        var digest = SHA256()
        var bytes: Int64 = 0
        func visit(_ item: URL, relativePath: String) throws {
            let attributes = try manager.attributesOfItem(atPath: item.path)
            guard let type = attributes[.type] as? FileAttributeType,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let created = attributes[.creationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let device = attributes[.systemNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
            let fields = [relativePath, type.rawValue, size.stringValue,
                          String(modified.timeIntervalSince1970), String(created.timeIntervalSince1970),
                          inode.stringValue, device.stringValue]
            digest.update(data: try JSONSerialization.data(withJSONObject: fields))
            if type == .typeDirectory {
                for child in try manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try visit(child, relativePath: relativePath + "/" + child.lastPathComponent)
                }
            } else {
                bytes += size.int64Value
            }
        }
        try visit(url, relativePath: url.lastPathComponent)
        let attributes = try manager.attributesOfItem(atPath: url.path)
        return DataUnusedFile(url: url, bytes: bytes, isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory,
                              fingerprint: digest.finalize())
    }
}
