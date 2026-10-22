//
//  VoiceMessageViewPreviews.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import SwiftUI

#Preview {
    let session = ChatSession(title: "Preview")
    let message: ChatMessage = {
        let message = ChatMessage(
            content: "<think>\nReasoning preview...\n</think>\nHello from the assistant!",
            isUser: false,
            isActive: false,
            createdAt: Date(),
            tokenCount: 1,
            session: session
        )
        session.messages.append(message)
        return message
    }()
    let audio = GlobalAudioManager()

    VoiceMessageView(
        message: message,
        showActionButtons: true,
        developerModeEnabled: true,
        contentFingerprint: ContentFingerprint.make(message.content),
        onSelectText: { _ in },
        onRegenerate: { _ in },
        onEditUserMessage: { _ in },
        onSwitchVersion: { _ in },
        onRetry: { _ in }
    )
    .environmentObject(audio)
    .environmentObject(ChatViewModel(
        chatSession: session,
        settingsManager: .shared,
        reachability: .shared,
        audioManager: audio
    ))
    .modelContainer(for: [ChatSession.self, ChatMessage.self, AppSettings.self], inMemory: true)
    .padding()
    .background(AppBackgroundView())
}
