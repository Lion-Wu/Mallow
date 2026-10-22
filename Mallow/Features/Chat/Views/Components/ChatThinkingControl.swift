//
//  ChatThinkingControl.swift
//  Mallow
//
//  Created by Codex on 2026.06.14.
//

import SwiftUI

struct ChatThinkingControl: View {
    let capability: ModelThinkingCapability
    let currentOption: ModelThinkingOption?
    let height: CGFloat
    let onSelectOption: (ModelThinkingOption) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if capability.isConfigurable {
                Menu {
                    ForEach(capability.options) { option in
                        Button {
                            onSelectOption(option)
                        } label: {
                            if option == currentOption {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                } label: {
                    thinkingPillLabel(
                        title: thinkingControlTitle(for: currentOption),
                        isEnabled: currentOption.map { !$0.isDisabled && $0 != .serverDefault } ?? false,
                        showsDisclosure: true
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .frame(height: height, alignment: .leading)
    }

    private func thinkingControlTitle(for option: ModelThinkingOption?) -> String {
        guard let option else {
            return NSLocalizedString("Thinking", comment: "Thinking control label")
        }
        if option == .on {
            return NSLocalizedString("Thinking", comment: "Thinking control label")
        }
        return String(
            format: NSLocalizedString("Thinking %@", comment: "Thinking control label with effort"),
            option.displayName
        )
    }

    private func thinkingPillLabel(title: String, isEnabled: Bool, showsDisclosure: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.8)
            }
        }
        .foregroundStyle(isEnabled ? ChatTheme.accent : Color.secondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(isEnabled ? ChatTheme.accent.opacity(0.15) : Color.secondary.opacity(0.08))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(isEnabled ? ChatTheme.accent.opacity(0.32) : ChatTheme.subtleStroke.opacity(0.24), lineWidth: 0.75)
        )
        .contentShape(Capsule(style: .continuous))
        .accessibilityLabel(title)
    }
}
