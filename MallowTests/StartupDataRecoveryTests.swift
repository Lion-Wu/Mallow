import XCTest
import SwiftData
import SQLite3
import Security
@testable import Mallow

@MainActor
final class StartupDataRecoveryTests: XCTestCase {
    func testHealthyStoreRoundTripsEveryEntityAndAcceptsNewWrites() throws {
        try withFixture { fixture in
            let attachment = XCTAttachment(contentsOfFile: fixture.source)
            attachment.name = "healthy-recovery-fixture.store"
            attachment.lifetime = .keepAlways
            add(attachment)
            let plan = try fixture.prepare()
            XCTAssertEqual(plan.categories.count, 7)
            XCTAssertTrue(plan.categories.allSatisfy { $0.recovered > 0 && $0.skipped == 0 && !$0.hasUnknownLoss && !$0.hasPartialLoss })
            try inspect(plan) { context in
                let messages = try context.fetch(FetchDescriptor<ChatMessage>())
                XCTAssertEqual(messages.count, 3)
                let answer = try XCTUnwrap(messages.first { !$0.isUser })
                XCTAssertEqual(answer.assistantText, "Readable answer")
                XCTAssertEqual(answer.imageAttachments.first?.data, Fixture.image)
                XCTAssertEqual(answer.toolActivityPlacements.first?.activity.title, "Readable tool")
                XCTAssertEqual(answer.parentMessage?.content, "First question")
                XCTAssertEqual(try context.fetch(FetchDescriptor<VoicePreset>()).first?.promptText, "Voice reference")
                XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceServerPreset>()).first?.serverAddress, "https://voice.example.test")
                XCTAssertEqual(try context.fetch(FetchDescriptor<ChatServerPreset>()).first?.selectedModel, "fixture-model")
                let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
                XCTAssertEqual(settings.selectedModel, "fixture-model")
                XCTAssertEqual(ChatModelCapabilityStore.restoringPreferences(from: settings).thinkingPreferences["https://chat.example.test|fixture-model"], .high)
                settings.selectedModel = "updated-after-recovery"
                let message = ChatMessage(content: "New message after recovery", isUser: true, session: answer.session)
                context.insert(message)
                try context.save()
            }
            try inspect(plan) { context in
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 4)
                XCTAssertEqual(try context.fetch(FetchDescriptor<AppSettings>()).first?.selectedModel, "updated-after-recovery")
            }
        }
    }

    func testBrokenRelationshipsAreSkippedWithoutCreatingChatsOrReparenting() throws {
        try withFixture { fixture in
            try fixture.sql("UPDATE ZCHATMESSAGE SET ZSESSION=999999 WHERE ZISUSER=1 AND ZPARENTMESSAGE IS NOT NULL")
            try fixture.sql("UPDATE ZCHATMESSAGE SET ZPARENTMESSAGE=Z_PK WHERE ZISUSER=0")
            let plan = try fixture.prepare()
            try inspect(plan) { context in
                let sessions = try context.fetch(FetchDescriptor<ChatSession>())
                XCTAssertEqual(sessions.count, 1)
                XCTAssertEqual(sessions.first?.messages.map(\.content), ["First question"])
            }
            XCTAssertEqual(try category("ChatMessage", in: plan).recovered, 1)
            XCTAssertEqual(try category("ChatMessage", in: plan).skipped, 2)
        }
    }

    func testRawExportIncludesUnreadableBytesSidecarsAndKeychain() throws {
        try withFixture { fixture in
            let source = fixture.root.appendingPathComponent("raw", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let files = ["broken.store": Data([0, 255, 1]), "broken.store-wal": Data([7, 8]), "broken.store-shm": Data([9])]
            for (name, bytes) in files { try bytes.write(to: source.appendingPathComponent(name)) }
            let keychain = try PropertyListSerialization.data(fromPropertyList: [["acct": "synthetic-key", "v_Data": Data("synthetic-secret".utf8)]], format: .xml, options: 0)
            let crashReports = source.appendingPathComponent("CrashReporter")
            try FileManager.default.createDirectory(at: crashReports, withIntermediateDirectories: true)
            try Data("unrelated report".utf8).write(to: crashReports.appendingPathComponent("report.plist"))
            let sources = StartupPersistentStore.exportSources(defaultStoreURL: source.appendingPathComponent("broken.store"))
            XCTAssertEqual(Set(sources.keys), Set([
                "Stores/broken.store", "Stores/broken.store-wal", "Stores/broken.store-shm"
            ]))
            let archive = try RawDataExport.prepare(sources: sources, keychain: keychain, temporaryDirectory: fixture.root)
            XCTAssertGreaterThan(try Data(contentsOf: archive.url).count, 0)
            #if os(macOS)
            let unpacked = fixture.root.appendingPathComponent("unpacked")
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", archive.url.path, unpacked.path]
            try unzip.run()
            unzip.waitUntilExit()
            XCTAssertEqual(unzip.terminationStatus, 0)
            let contents = unpacked.appendingPathComponent("Mallow Data")
            var expected = Dictionary(uniqueKeysWithValues: files.map { ("Stores/" + $0.key, $0.value) })
            expected["Keychain.plist"] = keychain
            for (name, bytes) in expected { XCTAssertEqual(try Data(contentsOf: contents.appendingPathComponent(name)), bytes) }
            let entries = try XCTUnwrap(FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL])
            let names = try entries.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
                .map { String($0.path.dropFirst(unpacked.path.count + 1)) }
            let expectedNames = Set(expected.keys.map { "Mallow Data/" + $0 }).union(["Mallow Data/Manifest.json"])
            XCTAssertEqual(Set(names), expectedNames)
            #endif
            let attachment = XCTAttachment(contentsOfFile: archive.url)
            attachment.name = "raw-export-validation.zip"
            attachment.lifetime = .keepAlways
            add(attachment)
            for (name, bytes) in files { XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(name)), bytes) }
            archive.discard()
            XCTAssertFalse(FileManager.default.fileExists(atPath: archive.url.deletingLastPathComponent().path))
        }
    }

    nonisolated func testRawExportReadsAllRealKeychainItems() async throws {
        let service = "ExportValidation-" + UUID().uuidString
        let credentials = ["first": "synthetic-secret-1", "second": "synthetic-secret-2"]
        defer {
            for account in credentials.keys {
                XCTAssertNoThrow(try KeychainStore.delete(service: service, account: account).get())
            }
        }
        let empty = try RawDataExport.keychainSnapshot(service: service)
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: empty, format: nil) as? [String], [])
        for (account, value) in credentials {
            try KeychainStore.saveString(value, service: service, account: account).get()
        }
        let snapshot = try RawDataExport.keychainSnapshot(service: service)
        let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: snapshot, format: nil) as? [[String: Any]])
        XCTAssertEqual(decoded.count, credentials.count)
        for item in decoded {
            XCTAssertEqual(Set(item.keys), Set([kSecAttrService as String, kSecAttrAccount as String, kSecValueData as String]))
            XCTAssertEqual(item[kSecAttrService as String] as? String, service)
            let account = try XCTUnwrap(item[kSecAttrAccount as String] as? String)
            let expected = try XCTUnwrap(credentials[account])
            XCTAssertEqual(item[kSecValueData as String] as? Data, Data(expected.utf8))
        }
    }

    func testResetRemovesStoreWithoutReadingIt() throws {
        try withFixture { fixture in
            let manager = FileManager.default
            for suffix in ["-wal", "-shm"] {
                try Data([0, 255]).write(to: URL(fileURLWithPath: fixture.source.path + suffix))
            }
            let unrelated = fixture.root.appendingPathComponent("unrelated.txt")
            try Data("keep".utf8).write(to: unrelated)

            try StartupPersistentStore.reset(defaultStoreURL: fixture.source)

            XCTAssertFalse(manager.fileExists(atPath: fixture.source.path))
            for suffix in ["-wal", "-shm"] {
                XCTAssertFalse(manager.fileExists(atPath: fixture.source.path + suffix))
            }
            XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
            let container = try StartupPersistentStore.open(at: fixture.source)
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 0)
            context.insert(ChatSession(title: "After reset"))
            try context.save()
            try container.erase()
        }
    }

    func testCancelledPreviewDoesNotModifySourceAndCanBeRepeated() throws {
        try withFixture { fixture in
            try fixture.sql("UPDATE ZCHATMESSAGE SET ZOUTPUTTOKENCOUNT='bad' WHERE ZISUSER=0")
            let original = try Data(contentsOf: fixture.source)
            for _ in 0..<3 {
                let plan = try fixture.prepare()
                XCTAssertEqual(plan.recoveredCount, 10)
                plan.discard()
                XCTAssertFalse(FileManager.default.fileExists(atPath: plan.directory.path))
                XCTAssertEqual(try Data(contentsOf: fixture.source), original)
            }
        }
    }

    func testUnreadableDatabaseDoesNotOfferEmptyRecoveryAsUsableData() throws {
        try withFixture { fixture in
            let bytes = Data(repeating: 0x41, count: 4096)
            try bytes.write(to: fixture.source)
            do {
                let plan = try fixture.prepare()
                XCTAssertEqual(plan.recoveredCount, 0)
                XCTAssertTrue(plan.categories.allSatisfy(\.hasUnknownLoss))
            } catch {
                XCTAssertEqual((error as NSError).domain, "RecoverySQLite")
            }
            XCTAssertEqual(try Data(contentsOf: fixture.source), bytes)
        }
    }

    private func category(_ id: String, in plan: DataRecoveryPlan) throws -> DataRecoveryCategory {
        try XCTUnwrap(plan.categories.first { $0.id == id })
    }

    private func inspect(_ plan: DataRecoveryPlan, body: (ModelContext) throws -> Void) throws {
        try autoreleasepool {
            let context = ModelContext(plan.container)
            context.autosaveEnabled = false
            try body(context)
        }
    }

    private func withFixture(body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Fixture(root: root)
        defer {
            for plan in fixture.plans where FileManager.default.fileExists(atPath: plan.directory.path) { plan.discard() }
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Fixture cleanup failed: \(error)") }
        }
        try fixture.populate()
        try body(fixture)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        var plans: [DataRecoveryPlan] = []
        var source: URL { root.appendingPathComponent("source.store") }
        static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!

        init(root: URL) { self.root = root }

        func prepare() throws -> DataRecoveryPlan {
            let plan = try StartupDataRecovery.prepare(sourceURL: source, temporaryDirectory: root)
            plans.append(plan)
            return plan
        }

        func populate() throws {
            let working = root.appendingPathComponent("working.store")
            let container = try StartupPersistentStore.open(at: working)
            defer {
                do { try container.erase() }
                catch { XCTFail("Fixture store cleanup failed: \(error)") }
            }
            try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let session = ChatSession(title: "Recovery validation chat")
                context.insert(session)
                let question = ChatMessage(content: "First question", isUser: true, session: session)
                context.insert(question)
                let answer = ChatMessage(
                    content: "Readable answer", assistantSegments: [ChatAssistantSegment(kind: .text, text: "Readable answer")],
                    imageAttachments: [ChatImageAttachment(mimeType: "image/png", data: Self.image)],
                    isUser: false, modelIdentifier: "fixture-model", outputTokenCount: 12, tokenCount: 12,
                    toolActivityPlacements: [ChatToolActivityPlacement(
                        activity: ChatToolActivity(id: "tool-1", toolName: "calendar", title: "Readable tool", phase: .succeeded),
                        scope: .body, offset: 0, assistantSegmentAnchor: ChatAssistantSegmentAnchor(segmentIndex: 0, characterOffset: 0)
                    )], session: session, parentMessage: question
                )
                context.insert(answer)
                let followup = ChatMessage(content: "Second question", isUser: true, session: session, parentMessage: answer)
                context.insert(followup)
                session.activeRootMessageID = question.id
                question.activeChildMessageID = answer.id
                answer.activeChildMessageID = followup.id
                let preset = SystemPromptPreset(name: "Recovery prompt", mode: "normal", normalPrompt: "Normal prompt", voicePrompt: "Voice prompt")
                context.insert(preset)
                let voicePrompt = SystemPromptPreset(name: "Voice prompt fixture", mode: "voice", voicePrompt: "Selected voice prompt")
                context.insert(voicePrompt)
                let settings = AppSettings(selectedModel: "fixture-model", selectedNormalSystemPromptPresetID: preset.id, selectedVoiceSystemPromptPresetID: voicePrompt.id)
                try ChatModelCapabilityStore(thinkingPreferences: ["https://chat.example.test|fixture-model": .high]).savePreferences(to: settings)
                context.insert(settings)
                context.insert(ChatServerPreset(name: "Chat fixture", apiURL: "https://chat.example.test", selectedModel: "fixture-model"))
                context.insert(VoiceServerPreset(name: "Voice server fixture", serverAddress: "https://voice.example.test"))
                context.insert(VoicePreset(name: "Voice fixture", promptText: "Voice reference"))
                try context.save()
            }
            // A read-only backup does not compete with Core Data's asynchronous
            // connection cleanup for the write lock required by VACUUM INTO.
            try database(at: working) { origin in
                var destination: OpaquePointer?
                guard sqlite3_open(source.path, &destination) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
                defer { sqlite3_close(destination) }
                guard let backup = sqlite3_backup_init(destination, "main", origin, "main") else { throw CocoaError(.fileReadUnknown) }
                let status = sqlite3_backup_step(backup, -1)
                let finish = sqlite3_backup_finish(backup)
                guard status == SQLITE_DONE, finish == SQLITE_OK,
                      sqlite3_exec(destination, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
                    throw CocoaError(.fileReadUnknown)
                }
            }
        }

        func sql(_ statement: String, at url: URL? = nil) throws {
            try database(at: url ?? source) { database in
                guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "FixtureSQLite", code: Int(sqlite3_errcode(database)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
                }
            }
        }

        private func database<T>(at url: URL, body: (OpaquePointer) throws -> T) throws -> T {
            var handle: OpaquePointer?
            let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
            defer { if let handle { sqlite3_close(handle) } }
            guard status == SQLITE_OK, let handle else { throw CocoaError(.fileReadUnknown) }
            return try body(handle)
        }
    }
}
