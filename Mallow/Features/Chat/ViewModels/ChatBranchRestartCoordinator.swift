//
//  ChatBranchRestartCoordinator.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import Foundation

struct ChatBranchRestartResult {
    let parentMessageID: UUID
    let didMutateBranch: Bool
}

enum ChatBranchRestartIntent: Equatable, Sendable {
    case regenerate(messageID: UUID)
    case retry(errorMessageID: UUID)

    var messageID: UUID {
        switch self {
        case .regenerate(let messageID):
            return messageID
        case .retry(let errorMessageID):
            return errorMessageID
        }
    }
}

struct ChatBranchRestartConfirmation: Equatable, Sendable {
    let intent: ChatBranchRestartIntent
    let userMessageID: UUID
    let canContinueTextOnly: Bool
}

enum ChatBranchRestartRequestResult: Equatable, Sendable {
    case started
    case requiresUnsupportedImageConfirmation(ChatBranchRestartConfirmation)
    case unavailable
}

@MainActor
final class ChatBranchRestartCoordinator {

    func prepareRestart(from parent: ChatMessage) -> ChatBranchRestartResult {
        parent.activeChildMessageID = nil
        return ChatBranchRestartResult(parentMessageID: parent.id, didMutateBranch: true)
    }

}
