import Foundation
import zlib

/// Reads the original-file archive shared by recovery and data management.
nonisolated enum DataBackupArchive {
    static func read(_ url: URL) throws -> DataBackupReadResult {
        let archive = try BackupZIPReader(url: url)
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("DataExport-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { remove(directory) }
        let prefix = RawDataExport.contentsName + "/"
        guard let manifest = archive.entries.first(where: { $0.name == prefix + "Manifest.json" }) else {
            throw DataBackupError.unsupportedFormat
        }
        let manifestURL = directory.appendingPathComponent("Manifest.json")
        try archive.extract(manifest, to: manifestURL)
        struct Manifest: Decodable { let formatVersion: Int }
        guard try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)).formatVersion == 1 else {
            throw DataBackupError.unsupportedFormat
        }
        guard !archive.entries.contains(where: { $0.name == prefix + "Stores/" + DataImportTransaction.fileName }) else {
            throw DataBackupError.unsupportedFormat
        }
        let storeName = "Stores/" + StartupPersistentStore.defaultURL.lastPathComponent
        let requiredNames = Set([storeName, storeName + "-wal", storeName + "-shm", "Keychain.plist"].map { prefix + $0 })
        for entry in archive.entries where requiredNames.contains(entry.name) {
            let relative = String(entry.name.dropFirst(prefix.count))
            try archive.extract(entry, to: directory.appendingPathComponent(relative))
        }
        let storeURL = directory.appendingPathComponent(storeName)
        guard manager.fileExists(atPath: storeURL.path) else { throw DataBackupError.unsupportedFormat }
        var result = try AppDataBackup.recover(from: storeURL, keychain: Data(contentsOf: directory.appendingPathComponent("Keychain.plist")), allowSourceSidecarCreation: true)
        let documents = archive.entries.filter { $0.name.hasPrefix(prefix + "Documents/") && !$0.name.hasSuffix("/") }
        if !documents.isEmpty {
            // Documents have no record identity in the app's merge model.
            // Preserve them in the archive and explicitly report that they were not imported.
            result.categories.append(DataRecoveryCategory(id: "Documents", title: String(localized: "STORAGE_DOCUMENTS", defaultValue: "Documents"),
                skipped: documents.count, skippedNames: documents.map { String($0.name.dropFirst(prefix.count)) }))
        }
        return result
    }

    private static func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { print("Could not remove backup workspace: \(error)") }
    }
}

/// Reads the stored/deflated ZIP entries emitted by NSFileCoordinator, including
/// ZIP64. Extraction never follows archive paths or links outside its workspace.
private nonisolated final class BackupZIPReader {
    struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt64
        let size: UInt64
        let offset: UInt64
    }
    let entries: [Entry]
    private let file: FileHandle
    private let length: UInt64

    init(url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        length = try file.seekToEnd()
        let tailLength = Int(min(length, 65_557))
        try file.seek(toOffset: length - UInt64(tailLength))
        let tail = try Self.read(file, count: tailLength)
        guard tail.count >= 22,
              let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
                  tail.u32($0) == 0x06054b50 && $0 + 22 + Int(tail.u16($0 + 20)) == tail.count
              }), tail.u16(end + 4) == 0, tail.u16(end + 6) == 0 else { throw DataBackupError.unsupportedFormat }
        var count = UInt64(tail.u16(end + 10))
        var directoryOffset = UInt64(tail.u32(end + 16))
        if count == 0xffff || directoryOffset == 0xffffffff || tail.u32(end + 12) == 0xffffffff {
            guard end >= 20, tail.u32(end - 20) == 0x07064b50,
                  tail.u32(end - 16) == 0, tail.u32(end - 4) == 1 else { throw DataBackupError.unsupportedFormat }
            let zip64Offset = tail.u64(end - 12)
            guard length >= 56, zip64Offset <= length - 56 else { throw DataBackupError.unsupportedFormat }
            try file.seek(toOffset: zip64Offset)
            let record = try Self.read(file, count: 56)
            guard record.u32(0) == 0x06064b50, record.u32(16) == 0, record.u32(20) == 0 else {
                throw DataBackupError.unsupportedFormat
            }
            count = record.u64(32)
            directoryOffset = record.u64(48)
        }
        guard directoryOffset < length, count <= (length - directoryOffset) / 46 else { throw DataBackupError.unsupportedFormat }
        try file.seek(toOffset: directoryOffset)
        var result: [Entry] = []
        var names = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            let header = try Self.read(file, count: 46)
            guard header.u32(0) == 0x02014b50, header.u16(8) & 1 == 0,
                  header.u16(34) == 0, [UInt16(0), 8].contains(header.u16(10)) else { throw DataBackupError.unsupportedFormat }
            let nameData = try Self.read(file, count: Int(header.u16(28)))
            let extra = try Self.read(file, count: Int(header.u16(30)))
            _ = try Self.read(file, count: Int(header.u16(32)))
            guard let name = String(data: nameData, encoding: .utf8), !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !name.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }), names.insert(name).inserted else {
                throw DataBackupError.unsupportedFormat
            }
            let mode = header.u32(38) >> 16 & 0xf000
            guard mode == 0 || mode == 0x8000 || mode == 0x4000 else { throw DataBackupError.unsupportedFormat }
            var size = UInt64(header.u32(24))
            var compressed = UInt64(header.u32(20))
            var offset = UInt64(header.u32(42))
            var position = 0
            while position + 4 <= extra.count {
                let tag = extra.u16(position)
                let end = position + 4 + Int(extra.u16(position + 2))
                guard end <= extra.count else { throw DataBackupError.unsupportedFormat }
                if tag == 1 {
                    var cursor = position + 4
                    func next() throws -> UInt64 {
                        guard cursor + 8 <= end else { throw DataBackupError.unsupportedFormat }
                        defer { cursor += 8 }
                        return extra.u64(cursor)
                    }
                    if size == 0xffffffff { size = try next() }
                    if compressed == 0xffffffff { compressed = try next() }
                    if offset == 0xffffffff { offset = try next() }
                }
                position = end
            }
            guard offset < directoryOffset, compressed <= length, size != 0xffffffff else { throw DataBackupError.unsupportedFormat }
            result.append(Entry(name: name, method: header.u16(10), crc: header.u32(16), compressedSize: compressed, size: size, offset: offset))
        }
        entries = result
    }

    deinit { try? file.close() }

    func extract(_ entry: Entry, to destination: URL) throws {
        let manager = FileManager.default
        if entry.name.hasSuffix("/") {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }
        try file.seek(toOffset: entry.offset)
        let header = try Self.read(file, count: 30)
        guard header.u32(0) == 0x04034b50, header.u16(8) == entry.method else { throw DataBackupError.unsupportedFormat }
        let start = entry.offset + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
        guard start <= length, entry.compressedSize <= length - start else { throw DataBackupError.unsupportedFormat }
        try file.seek(toOffset: start)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard manager.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var stream = z_stream()
        if entry.method == 8 {
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw DataBackupError.unsupportedFormat
            }
        }
        defer { if entry.method == 8 { inflateEnd(&stream) } }
        var remaining = entry.compressedSize
        var written: UInt64 = 0
        var checksum = crc32(0, nil, 0)
        var ended = false
        func write(_ bytes: Data) throws {
            guard UInt64(bytes.count) <= entry.size - written else { throw DataBackupError.unsupportedFormat }
            checksum = bytes.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)) }
            try output.write(contentsOf: bytes)
            written += UInt64(bytes.count)
        }
        while remaining > 0 {
            try Task.checkCancellation()
            var input = try Self.read(file, count: Int(min(remaining, 65_536)))
            remaining -= UInt64(input.count)
            if entry.method == 0 { try write(input); continue }
            guard !ended else { throw DataBackupError.unsupportedFormat }
            try input.withUnsafeMutableBytes { buffer in
                stream.next_in = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(buffer.count)
                repeat {
                    var chunk = Data(count: 65_536)
                    let status = chunk.withUnsafeMutableBytes { bytes in
                        stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(bytes.count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    if status == Z_BUF_ERROR && stream.avail_in == 0 { break }
                    guard status == Z_OK || status == Z_STREAM_END else { throw DataBackupError.unsupportedFormat }
                    chunk.count -= Int(stream.avail_out)
                    try write(chunk)
                    if status == Z_STREAM_END { ended = true; break }
                } while stream.avail_in > 0 || stream.avail_out == 0
                guard !ended || (stream.avail_in == 0 && remaining == 0) else { throw DataBackupError.unsupportedFormat }
            }
        }
        guard written == entry.size, UInt32(checksum) == entry.crc, entry.method == 0 || ended else { throw DataBackupError.unsupportedFormat }
    }

    private static func read(_ file: FileHandle, count: Int) throws -> Data {
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw DataBackupError.unsupportedFormat }
        return data
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
    func u64(_ offset: Int) -> UInt64 { UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32 }
}
