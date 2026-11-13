import SwiftUI

struct AppOnboardingView: View {
    enum Page { case welcome, sharing }

    @ObservedObject var coordinator: AppOnboardingCoordinator
    let onAccepted: () -> Void
    @State private var showsSharing: Bool

    init(coordinator: AppOnboardingCoordinator, initialPage: Page = .welcome, onAccepted: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onAccepted = onAccepted
        _showsSharing = State(initialValue: initialPage == .sharing)
    }

    var body: some View {
        NavigationStack {
            if coordinator.hasCompletedWelcome {
                content(for: .sharing)
            } else {
                content(for: .welcome)
                    .navigationDestination(isPresented: $showsSharing) {
                        content(for: .sharing)
                    }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
        .accessibilityIdentifier("onboarding")
    }

    private func content(for page: Page) -> some View {
        ZStack {
            AppBackgroundView()
            VStack(spacing: 0) {
                pageContent(for: page)
                footer(for: page)
                    .frame(maxWidth: 480)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    #if os(macOS)
                    .padding(.bottom, 24)
                    #else
                    .padding(.bottom, 16)
                    #endif
            }
        }
        #if os(macOS)
        .toolbar(removing: .title)
        .toolbar {
            let title = ToolbarItem(placement: .principal) {
                Text(verbatim: ApplicationInformation.name)
                    .font(.headline)
            }
            if #available(macOS 26, *) {
                title.sharedBackgroundVisibility(.hidden)
            } else {
                title
            }
        }
        #else
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        #endif
    }

    private func pageContent(for page: Page) -> some View {
        ScrollView {
            VStack(spacing: 32) {
                header(for: page)
                VStack(alignment: .leading, spacing: 26) {
                    if page == .welcome {
                        feature("ONBOARDING_CHAT_TITLE", detail: "ONBOARDING_CHAT_BODY", symbol: "bubble.left.and.bubble.right.fill")
                        feature("ONBOARDING_VOICE_TITLE", detail: "ONBOARDING_VOICE_BODY", symbol: "waveform")
                        feature("ONBOARDING_TOOLS_TITLE", detail: "ONBOARDING_TOOLS_BODY", symbol: "wrench.and.screwdriver")
                        feature("ONBOARDING_SERVICES_TITLE", detail: "ONBOARDING_SERVICES_BODY", symbol: "slider.horizontal.3")
                    } else {
                        feature("ONBOARDING_RECIPIENT_TITLE", detail: "ONBOARDING_RECIPIENT_BODY", symbol: "network")
                        feature("ONBOARDING_CONTENT_TITLE", detail: "ONBOARDING_CONTENT_BODY", symbol: "text.bubble.fill")
                        feature("ONBOARDING_EXTRA_TITLE", detail: "ONBOARDING_EXTRA_BODY", symbol: "waveform.and.mic")
                        feature("ONBOARDING_POLICY_TITLE", detail: "ONBOARDING_POLICY_BODY", symbol: "hand.raised.fill")
                    }
                }
                #if os(macOS)
                .frame(maxWidth: .infinity, alignment: .leading)
                #endif
                if page == .sharing {
                    Link("ABOUT_ACTION_PRIVACY_POLICY", destination: URL(string: "https://lionwu.com/mallow/privacy")!)
                }
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
    }

    private func header(for page: Page) -> some View {
        VStack(spacing: 18) {
            Image(systemName: page == .welcome ? "sparkles" : "hand.raised.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.blue.gradient)
                .frame(width: 88, height: 88)
                .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .accessibilityHidden(true)
            Text(page == .welcome ? LocalizedStringKey("ONBOARDING_WELCOME_TITLE") : LocalizedStringKey("ONBOARDING_SHARING_TITLE"))
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            if page == .sharing {
                Text("ONBOARDING_SHARING_SUBTITLE")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func feature(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 34, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func footer(for page: Page) -> some View {
        VStack(spacing: 16) {
            if page == .sharing {
                Text("ONBOARDING_CONSENT_EXPLANATION")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = coordinator.persistenceError {
                    Text(verbatim: error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("onboarding-consent-error")
                }
                VStack(spacing: 8) {
                    Button {
                        if coordinator.recordPrivacyDecision(accepted: true) { onAccepted() }
                    } label: {
                        Text("ONBOARDING_ACCEPT").frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .appGlassButtonStyle(prominent: true)
                    .tint(.blue)
                    .accessibilityIdentifier("onboarding-accept")
                    Button { declineAndExit() } label: {
                        Text("ONBOARDING_DECLINE").frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .appGlassButtonStyle()
                    .accessibilityIdentifier("onboarding-decline")
                }
            } else {
                Button { showsSharing = true } label: {
                    Text("ONBOARDING_CONTINUE").frame(maxWidth: .infinity, minHeight: 28)
                }
                .appGlassButtonStyle(prominent: true)
                .tint(.blue)
                .accessibilityIdentifier("onboarding-continue")
            }
        }
        .controlSize(.large)
        .multilineTextAlignment(.center)
    }

    private func declineAndExit() {
        coordinator.recordPrivacyDecision(accepted: false)
        StartupDataCoordinator.exitApplication()
    }
}

#Preview("Welcome") {
    AppOnboardingView(coordinator: AppOnboardingCoordinator(stateURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), onAccepted: {})
}

#Preview("Data Sharing") {
    AppOnboardingView(coordinator: AppOnboardingCoordinator(stateURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), initialPage: .sharing, onAccepted: {})
        #if os(macOS)
        .frame(width: 600, height: 820)
        #endif
}
