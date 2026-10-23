import XCTest
@testable import Mallow

final class ChatAPIKeyStoreTests: XCTestCase {
    func testStoresTrimmedKeyUsingPresetScopedAccount() throws {
        let presetID = UUID()
        var saved: [(value: String, service: String, account: String)] = []
        let store = ChatAPIKeyStore(
            service: "test.service",
            loadString: { _, _ in nil },
            saveString: { value, service, account in
                saved.append((value, service, account))
                return .success(())
            },
            deleteString: { _, _ in .success(()) }
        )

        store.save("  secret-token  ", for: presetID)

        let write = try XCTUnwrap(saved.first)
        XCTAssertEqual(write.value, "secret-token")
        XCTAssertEqual(write.service, "test.service")
        XCTAssertEqual(write.account, store.account(forChatServerPresetID: presetID))
    }

    func testEmptyKeyDeletesExistingPresetAccount() throws {
        let presetID = UUID()
        var deleted: [(service: String, account: String)] = []
        let store = ChatAPIKeyStore(
            service: "test.service",
            loadString: { _, _ in "existing-token" },
            saveString: { _, _, _ in
                XCTFail("empty API keys should delete instead of save")
                return .failure(KeychainStoreError(status: -1))
            },
            deleteString: { service, account in
                deleted.append((service, account))
                return .success(())
            }
        )

        store.save("   ", for: presetID)

        let deletion = try XCTUnwrap(deleted.first)
        XCTAssertEqual(deletion.service, "test.service")
        XCTAssertEqual(deletion.account, store.account(forChatServerPresetID: presetID))
    }

    func testWriteReportsKeychainFailure() {
        let presetID = UUID()
        let store = ChatAPIKeyStore(
            service: "test.service",
            loadString: { _, _ in nil },
            saveString: { _, _, _ in .failure(KeychainStoreError(status: -50)) },
            deleteString: { _, _ in .failure(KeychainStoreError(status: -50)) }
        )

        guard case .failed(let failure) = store.write("new-token", for: presetID) else {
            return XCTFail("Expected a Keychain write failure")
        }
        XCTAssertTrue(
            failure.localizedDescription.hasPrefix(
                String(localized: "DATA_API_KEY_SAVE_FAILED", defaultValue: "The API key could not be saved.")
            )
        )
        XCTAssertEqual(
            failure.reason,
            KeychainStoreError(status: -50).localizedDescription
        )
    }
}
