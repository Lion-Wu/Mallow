import Foundation
import Combine

@MainActor
final class AppOnboardingCoordinator: ObservableObject {
    nonisolated static let fileName = "OnboardingState.json"
    // Increment when the privacy disclosure changes and requires a new decision.
    private static let privacyContentVersion = 1

    private struct PrivacyConsent: Codable {
        let accepted: Bool
        let acceptedAt: Date?
        let contentVersion: Int
    }

    private struct OnboardingState: Codable {
        var welcomeCompletedInAppVersion: String?
        var privacyConsent: PrivacyConsent?
    }

    @Published private var state = OnboardingState()
    @Published private(set) var persistenceError: String?
    private let stateURL: URL

    var hasAccepted: Bool {
        guard let consent = state.privacyConsent else { return false }
        return consent.accepted && consent.acceptedAt != nil && consent.contentVersion == Self.privacyContentVersion
    }

    var hasCompletedWelcome: Bool { state.welcomeCompletedInAppVersion != nil }

    init(stateURL: URL = StartupPersistentStore.defaultURL.deletingLastPathComponent()
        .appendingPathComponent(AppOnboardingCoordinator.fileName)) {
        self.stateURL = stateURL
        reload()
    }

    func reload() {
        requireConsent()
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            state = try decoder.decode(OnboardingState.self, from: Data(contentsOf: stateURL))
        } catch CocoaError.fileReadNoSuchFile {
            // First launch has no onboarding record.
        } catch {
            persistenceError = String(localized: "ONBOARDING_CONSENT_READ_ERROR")
        }
    }

    @discardableResult
    func recordPrivacyDecision(accepted: Bool) -> Bool {
        var updated = state
        if accepted && updated.welcomeCompletedInAppVersion == nil {
            updated.welcomeCompletedInAppVersion = ApplicationInformation.version
        }
        updated.privacyConsent = PrivacyConsent(
            accepted: accepted, acceptedAt: accepted ? Date() : nil, contentVersion: Self.privacyContentVersion
        )
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(updated).write(to: stateURL, options: .atomic)
            state = updated
            persistenceError = nil
            return true
        } catch {
            persistenceError = String(localized: "ONBOARDING_CONSENT_SAVE_ERROR")
            return false
        }
    }

    func requireConsent() {
        state = OnboardingState()
        persistenceError = nil
    }
}
