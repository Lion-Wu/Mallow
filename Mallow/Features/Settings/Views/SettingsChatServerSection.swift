//
//  SettingsChatServerSection.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import SwiftUI

struct SettingsChatServerSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    let hideHeader: Bool
    let detectedChatAPIFormatName: String
    let requestDeletion: (SettingsDeletionTarget) -> Void

    var body: some View {
        Section {
            #if os(macOS)
            LabeledContent("PRESET_TITLE") {
                Picker("", selection: $viewModel.selectedChatServerPresetID) {
                    ForEach(viewModel.chatServerPresetList) { preset in
                        Text(preset.name).tag(Optional.some(preset.id))
                    }
                }
                .labelsHidden()
            }

            HStack {
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        viewModel.addChatServerPreset()
                    } label: {
                        Label("COMMON_ACTION_ADD", systemImage: "plus.circle.fill")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .help("PRESET_ACTION_ADD")

                    Button(role: .destructive) {
                        requestDeletion(.chatServerPreset)
                    } label: {
                        Label("COMMON_ACTION_DELETE", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .help("PRESET_ACTION_DELETE_SELECTED")
                    .disabled(viewModel.chatServerPresetList.count <= 1 || viewModel.selectedChatServerPresetID == nil)
                }
            }
            #else
            Picker("PRESET_TITLE", selection: $viewModel.selectedChatServerPresetID) {
                ForEach(viewModel.chatServerPresetList) { preset in
                    Text(preset.name).tag(Optional.some(preset.id))
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 16) {
                Button {
                    viewModel.addChatServerPreset()
                } label: {
                    Label("COMMON_ACTION_ADD", systemImage: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                Button(role: .destructive) {
                    requestDeletion(.chatServerPreset)
                } label: {
                    Label("COMMON_ACTION_DELETE", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(viewModel.chatServerPresetList.count <= 1 || viewModel.selectedChatServerPresetID == nil)
            }
            #endif

            LabeledTextField(
                label: "PRESET_NAME",
                placeholder: "PRESET_NAME_PLACEHOLDER",
                text: $viewModel.chatServerPresetName,
                onCommit: { viewModel.commitChatServerEdits() }
            )

            LabeledTextField(
                label: "SETTINGS_SERVER_URL",
                placeholder: "SETTINGS_CHAT_SERVER_URL_PLACEHOLDER",
                text: $viewModel.apiURL,
                onCommit: { viewModel.commitChatServerEdits() }
            )

            LabeledContent("SETTINGS_API_FORMAT") {
                Picker("", selection: $viewModel.selectedChatAPIFormatPreference) {
                    ForEach(ChatProviderDescriptorRegistry.apiFormatOptions) { option in
                        Text(option.displayName).tag(option.preference)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if viewModel.selectedChatAPIFormatPreference == .automatic {
                Text(
                    String(
                        format: NSLocalizedString(
                            "SETTINGS_DETECTED_API_FORMAT", value: "Detected API Format: %@",
                            comment: "Shows the auto-detected API format under the API format picker"
                        ),
                        detectedChatAPIFormatName
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            LabeledSecureField(
                label: "SETTINGS_API_KEY",
                placeholder: "SETTINGS_API_KEY_PLACEHOLDER",
                text: $viewModel.chatAPIKey,
                onCommit: { viewModel.commitChatServerEdits() }
            )
        } header: {
            header
        }
    }

    @ViewBuilder
    private var header: some View {
        if hideHeader {
            EmptyView()
        } else {
            #if os(macOS)
            Text("SETTINGS_CHAT_SERVER")
                .font(.headline)
                .textCase(.none)
            #else
            Text("SETTINGS_CHAT_SERVER")
            #endif
        }
    }
}
