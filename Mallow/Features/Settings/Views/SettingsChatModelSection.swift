//
//  SettingsChatModelSection.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import SwiftUI

struct SettingsChatModelSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    let hideHeader: Bool

    private var hasModelListError: Bool {
        !(viewModel.chatServerErrorMessage?.isEmpty ?? true)
    }

    private var showModelPicker: Bool {
        !(viewModel.isLoadingModels || hasModelListError)
    }

    var body: some View {
        Section {
            modelPickerRow

            HStack {
                Spacer()
                Button(action: viewModel.fetchAvailableModels) {
                    Label("MODEL_ACTION_REFRESH_LIST", systemImage: "arrow.clockwise.circle")
                }
                .settingsActionButtonStyle()
                #if os(macOS)
                .help("MODEL_ACCESSIBILITY_REFRESH_LIST")
                #endif
                .disabled(viewModel.isLoadingModels)
            }
            .padding(.top, 6)

            if viewModel.shouldShowUnknownModelImageInputToggle {
                Toggle(
                    "SETTINGS_IMAGE_INPUT_ENABLE_OVERRIDE",
                    isOn: Binding(
                        get: { viewModel.isSelectedUnknownModelImageInputEnabled },
                        set: { viewModel.setSelectedUnknownModelImageInputEnabled($0) }
                    )
                )

                Text("MODEL_IMAGE_SUPPORT_UNKNOWN")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.shouldShowUnknownModelThinkingOptions {
                LabeledContent("MODEL_SUPPORTED_THINKING_OPTIONS") {
                    Menu {
                        ForEach(viewModel.availableManualThinkingOptions) { option in
                            Toggle(isOn: Binding(
                                get: { viewModel.selectedManualThinkingOptions.contains(option) },
                                set: { viewModel.setManualThinkingOption(option, enabled: $0) }
                            )) {
                                if option == .on && viewModel.usesAnthropicFixedBudgetThinking {
                                    Text("THINKING_FIXED_BUDGET")
                                } else {
                                    Text(option.displayName)
                                }
                            }
                        }
                    } label: {
                        Text(viewModel.selectedManualThinkingOptions.isEmpty
                             ? String(localized: "COMMON_NONE", defaultValue: "None")
                             : viewModel.selectedManualThinkingOptions.map(\.displayName).joined(separator: ", "))
                    }
                }
                Text("MODEL_THINKING_OPTIONS_UNKNOWN")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            header
        }
    }

    private var modelPickerRow: some View {
        LabeledContent("MODEL_TITLE") {
            ZStack(alignment: .trailing) {
                HStack {
                    Spacer(minLength: 0)
                    Picker("", selection: $viewModel.selectedModel) {
                        ForEach(viewModel.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    #if !os(macOS)
                    .pickerStyle(.menu)
                    #endif
                }
                .opacity(showModelPicker ? 1 : 0)
                .allowsHitTesting(showModelPicker)
                .accessibilityHidden(!showModelPicker)

                modelListStatusView
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var modelListStatusView: some View {
        if viewModel.isLoadingModels {
            HStack(spacing: 8) {
                ProgressView()
                    #if os(macOS)
                    .controlSize(.small)
                    #endif
                if viewModel.isRetryingModels {
                    Text(String(format: NSLocalizedString("AUDIO_RETRY_ATTEMPT", value: "Retrying (attempt %d)...", comment: "Shown while auto retry is waiting to reconnect"), max(1, viewModel.modelRetryAttempt)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("MODEL_LIST_LOADING")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            #if os(macOS)
            .help(viewModel.modelRetryLastError ?? "")
            #endif
        } else if let message = viewModel.chatServerErrorMessage, !message.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            #if os(macOS)
            .help(message)
            #endif
        }
    }

    @ViewBuilder
    private var header: some View {
        if hideHeader {
            EmptyView()
        } else {
            #if os(macOS)
            Text("SETTINGS_CHAT_MODEL")
                .font(.headline)
                .textCase(.none)
            #else
            Text("SETTINGS_CHAT_MODEL")
            #endif
        }
    }
}
