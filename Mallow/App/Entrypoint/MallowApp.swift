//
//  MallowApp.swift
//  Mallow
//
//  Created by Lion Wu on 2023/12/25.
//

import SwiftUI
import SwiftData

@main
@MainActor
struct MallowApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appEnvironment: AppEnvironment
    @StateObject private var startupCoordinator: StartupDataCoordinator
    @StateObject private var onboardingCoordinator: AppOnboardingCoordinator

    init() {
        _ = DataStorageInspector.launchDate
        let appEnvironment = AppEnvironment()
        let onboardingCoordinator = AppOnboardingCoordinator()
        let startupCoordinator = StartupDataCoordinator { [weak appEnvironment, weak onboardingCoordinator] container in
            onboardingCoordinator?.reload()
            if onboardingCoordinator?.hasAccepted == true {
                appEnvironment?.start(with: container)
            }
        }
        appEnvironment.settingsManager.onPersistentStoreReadFailure = { [weak startupCoordinator, weak appEnvironment] error in
            appEnvironment?.quiescePersistentStore()
            startupCoordinator?.reportPersistentStoreReadFailure(error)
        }
        appEnvironment.chatSessionsViewModel.onPersistentStoreReadFailure = { [weak startupCoordinator, weak appEnvironment] error in
            appEnvironment?.quiescePersistentStore()
            startupCoordinator?.reportPersistentStoreReadFailure(error)
        }
        startupCoordinator.onWillClearAllAppData = { [weak appEnvironment, weak onboardingCoordinator] in
            onboardingCoordinator?.requireConsent()
            appEnvironment?.prepareForClearingAllAppData()
        }
        startupCoordinator.onWillResetPersistentStore = { [weak appEnvironment] in
            appEnvironment?.quiescePersistentStore()
        }
        _appEnvironment = StateObject(wrappedValue: appEnvironment)
        _startupCoordinator = StateObject(wrappedValue: startupCoordinator)
        _onboardingCoordinator = StateObject(wrappedValue: onboardingCoordinator)
    }

    var body: some Scene {
        WindowGroup {
            StartupDataGateView(
                coordinator: startupCoordinator,
                loadingContent: {
                    StartupLoadingView(title: "COMMON_LOADING")
                },
                readyContent: { container in
                    if onboardingCoordinator.hasAccepted {
                        mainContent
                            .modelContainer(container)
                    } else {
                        onboardingContent(container: container)
                    }
                }
            )
        }
        #if os(visionOS)
        .defaultSize(width: 1400, height: 900)
        .windowResizability(.contentMinSize)
        #endif
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            appEnvironment.updatePersistenceMode(for: newPhase)
            appEnvironment.updateConnectionMonitoring(for: newPhase)
        }

        #if os(macOS)
        Window(LocalizedStringResource("ABOUT_TITLE", defaultValue: "About \(ApplicationInformation.name)"), id: AboutView.windowID) {
            AboutView()
        }
        .defaultSize(width: 760, height: 820)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Settings {
            StartupDataGateView(
                coordinator: startupCoordinator,
                loadingContent: {
                    StartupLoadingView(title: "SETTINGS_LOADING")
                },
                readyContent: { container in
                    if onboardingCoordinator.hasAccepted {
                        SettingsView(settingsManager: appEnvironment.settingsManager)
                            .environmentObject(appEnvironment)
                            .environmentObject(startupCoordinator)
                            .environmentObject(appEnvironment.errorCenter)
                            .modelContainer(container)
                    } else {
                        onboardingContent(container: container)
                    }
                }
            )
        }
        .commands {
            AppMenuCommands(appEnvironment.chatSessionsViewModel, isAppAccessAllowed: onboardingCoordinator.hasAccepted)
        }
        #endif
    }

    private func onboardingContent(container: ModelContainer) -> some View {
        AppOnboardingView(coordinator: onboardingCoordinator) {
            appEnvironment.start(with: container)
        }
    }

    private var mainContent: some View {
        ContentView()
            .environmentObject(appEnvironment)
            .environmentObject(startupCoordinator)
            .environmentObject(appEnvironment.audioManager)
            .environmentObject(appEnvironment.settingsManager)
            .environmentObject(appEnvironment.chatSessionsViewModel)
            .environmentObject(appEnvironment.speechInputManager)
            .environmentObject(appEnvironment.errorCenter)
            .environmentObject(appEnvironment.voiceOverlayViewModel)
    }
}
