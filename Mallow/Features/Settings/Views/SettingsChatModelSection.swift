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
                    Label("Refresh Model List", systemImage: "arrow.clockwise.circle")
                }
                .settingsActionButtonStyle()
                #if os(macOS)
                .help("Refresh available model list")
                #endif
                .disabled(viewModel.isLoadingModels)
            }
            .padding(.top, 6)

            if viewModel.shouldShowUnknownModelImageInputToggle {
                Toggle(
                    "Enable image input for this model",
                    isOn: Binding(
                        get: { viewModel.isSelectedUnknownModelImageInputEnabled },
                        set: { viewModel.setSelectedUnknownModelImageInputEnabled($0) }
                    )
                )

                Text("Unable to confirm whether this model supports image input. Enable it if supported.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.shouldShowUnknownModelThinkingOptions {
                LabeledContent("Supported Thinking Options") {
                    Menu {
                        ForEach(viewModel.availableManualThinkingOptions) { option in
                            Toggle(isOn: Binding(
                                get: { viewModel.selectedManualThinkingOptions.contains(option) },
                                set: { viewModel.setManualThinkingOption(option, enabled: $0) }
                            )) {
                                if option == .on && viewModel.usesAnthropicFixedBudgetThinking {
                                    Text("Fixed-budget Thinking")
                                } else {
                                    Text(option.displayName)
                                }
                            }
                        }
                    } label: {
                        Text(viewModel.selectedManualThinkingOptions.isEmpty
                             ? String(localized: "None")
                             : viewModel.selectedManualThinkingOptions.map(\.displayName).joined(separator: ", "))
                    }
                }
                Text("Unable to confirm this model's supported thinking options. Select them manually.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            header
        }
    }

    private var modelPickerRow: some View {
        LabeledContent("Model") {
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
                    Text(String(format: NSLocalizedString("Retrying (attempt %d)...", comment: "Shown while auto retry is waiting to reconnect"), max(1, viewModel.modelRetryAttempt)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("Loading model list...")
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
            Text("Chat Model")
                .font(.headline)
                .textCase(.none)
            #else
            Text("Chat Model")
            #endif
        }
    }
}
