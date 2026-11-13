//
//  AppMenuCommands.swift
//  Mallow
//
//  Created by Lion Wu on 2023/12/25.
//

#if os(macOS)
import SwiftUI

/// App-level commands for the About window and starting a new chat.
struct AppMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var chatSessionsViewModel: ChatSessionsViewModel
    let isAppAccessAllowed: Bool

    init(_ vm: ChatSessionsViewModel, isAppAccessAllowed: Bool) {
        self._chatSessionsViewModel = ObservedObject(wrappedValue: vm)
        self.isAppAccessAllowed = isAppAccessAllowed
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(LocalizedStringResource("ABOUT_TITLE", defaultValue: "About \(ApplicationInformation.name)")) {
                openWindow(id: AboutView.windowID)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button(LocalizedStringResource("CHAT_TITLE_NEW", defaultValue: "New Chat")) {
                guard isAppAccessAllowed, chatSessionsViewModel.canStartNewSession else { return }
                chatSessionsViewModel.startNewSession()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(!isAppAccessAllowed || !chatSessionsViewModel.canStartNewSession)
        }
    }
}
#endif
