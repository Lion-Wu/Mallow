//
//  ChatComposerTrailingButton.swift
//  Mallow
//
//  Created by Codex on 2026.06.14.
//

import SwiftUI

struct ChatComposerTrailingButton: View {
    let isLoading: Bool
    let isPriming: Bool
    let canSendDraft: Bool
    let isModelReady: Bool
    let buttonHeight: CGFloat
    let trackHeight: CGFloat
    let onQueueDraft: () -> Void
    let onCancelGeneration: () -> Void
    let onSend: () -> Void
    let onStartRealtimeVoice: () -> Void

    var body: some View {
        Group {
            if isLoading || isPriming {
                if canSendDraft && isModelReady {
                    sendButton(action: onQueueDraft)
                } else {
                    stopButton
                }
            } else if canSendDraft {
                sendButton(action: onSend)
            } else {
                realtimeVoiceButton
            }
        }
        .frame(height: trackHeight, alignment: .center)
        .offset(y: max(0, (buttonHeight - trackHeight) * 0.5))
    }

    private func sendButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isModelReady ? ChatTheme.accent : Color.secondary)
                .accessibilityLabel("Send Message")
        }
        .buttonStyle(.plain)
        .disabled(!isModelReady)
        .help(isModelReady ? "" : ChatNetworkError.modelInformationUnavailable.localizedDescription)
    }

    private var stopButton: some View {
        Button(action: onCancelGeneration) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
                .accessibilityLabel("Stop Generation")
        }
        .buttonStyle(.plain)
    }

    private var realtimeVoiceButton: some View {
        Button(action: onStartRealtimeVoice) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isModelReady ? ChatTheme.accent : Color.secondary)
                .accessibilityLabel("Start Realtime Voice Conversation")
        }
        .buttonStyle(.plain)
        .disabled(!isModelReady)
        .help(isModelReady ? "" : ChatNetworkError.modelInformationUnavailable.localizedDescription)
    }
}
