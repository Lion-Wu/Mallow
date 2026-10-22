import SwiftUI

struct SettingsVoicePresetSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var settingsManager: SettingsManager
    var hideHeader = false
    var requestDeletion: (SettingsDeletionTarget) -> Void

    var body: some View {
        Section {
            switch viewModel.ttsProvider {
            case .gptSoVITS:
                presetPickerRow
                presetActionButtons
                presetDetailFields
                presetApplyStatusRow
                presetApplyRow
            case .appleSpeech:
                appleSpeechSettings
            case .personalVoice:
                personalVoiceSettings
            }
        } header: {
            if hideHeader {
                EmptyView()
            } else {
                SettingsSectionHeader("SETTINGS_VOICE_MODEL")
            }
        }
    }

    @ViewBuilder
    private var appleSpeechSettings: some View {
        Picker("VOICE_PROVIDER_APPLE_SPEECH", selection: $viewModel.appleSpeechVoiceIdentifier) {
            Text("SETTINGS_SYSTEM_DEFAULT").tag(String?.none)
            if let selectedIdentifier = viewModel.appleSpeechVoiceIdentifier,
               !viewModel.availableSystemVoices.contains(where: { $0.id == selectedIdentifier }) {
                Text("VOICE_SELECTED_VOICE_NOT_INSTALLED").tag(Optional.some(selectedIdentifier))
            }
            ForEach(viewModel.availableSystemVoices) { voice in
                Text(voice.displayName).tag(Optional.some(voice.id))
            }
        }
    }

    @ViewBuilder
    private var personalVoiceSettings: some View {
        switch viewModel.personalVoiceAuthorizationStatus {
        case .notDetermined:
            if viewModel.isRequestingPersonalVoiceAuthorization {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("VOICE_PERSONAL_REQUESTING_ACCESS")
                }
                .foregroundStyle(.secondary)
            } else {
                Text("VOICE_PERSONAL_ACCESS_UNAUTHORIZED")
                    .foregroundStyle(.secondary)
            }
        case .authorized:
            if viewModel.availablePersonalVoices.isEmpty {
                Text("VOICE_PERSONAL_NO_VOICE")
                    .foregroundStyle(.secondary)
            } else {
                Picker("VOICE_PROVIDER_APPLE_PERSONAL", selection: $viewModel.personalVoiceIdentifier) {
                    ForEach(viewModel.availablePersonalVoices) { voice in
                        Text(voice.displayName).tag(Optional.some(voice.id))
                    }
                }
            }
        case .denied:
            Text("VOICE_PERSONAL_ACCESS_UNAUTHORIZED")
                .foregroundStyle(.secondary)
        case .unsupported:
            Text("VOICE_PERSONAL_UNSUPPORTED")
                .foregroundStyle(.secondary)
        @unknown default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var presetPickerRow: some View {
        #if os(macOS)
        LabeledContent("PRESET_TITLE") {
            Picker("", selection: $viewModel.selectedPresetID) {
                ForEach(viewModel.presetList) { p in
                    Text(p.name).tag(Optional.some(p.id))
                }
            }
            .labelsHidden()
        }
        #else
        Picker("PRESET_TITLE", selection: $viewModel.selectedPresetID) {
            ForEach(viewModel.presetList) { p in
                Text(p.name).tag(Optional.some(p.id))
            }
        }
        .pickerStyle(.menu)
        #endif
    }

    @ViewBuilder
    private var presetActionButtons: some View {
        #if os(macOS)
        HStack {
            Spacer()
            HStack(spacing: 8) {
                Button {
                    viewModel.addPreset()
                } label: {
                    Label("COMMON_ACTION_ADD", systemImage: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help("PRESET_ACTION_ADD")

                Button(role: .destructive) {
                    requestDeletion(.voicePreset)
                } label: {
                    Label("COMMON_ACTION_DELETE", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help("PRESET_ACTION_DELETE_SELECTED")
                .disabled(viewModel.presetList.count <= 1 || viewModel.selectedPresetID == nil)
            }
        }
        #else
        HStack(spacing: 16) {
            Button {
                viewModel.addPreset()
            } label: {
                Label("COMMON_ACTION_ADD", systemImage: "plus.circle.fill")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button(role: .destructive) {
                requestDeletion(.voicePreset)
            } label: {
                Label("COMMON_ACTION_DELETE", systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(viewModel.presetList.count <= 1 || viewModel.selectedPresetID == nil)
        }
        #endif
    }

    private var presetDetailFields: some View {
        Group {
            LabeledTextField(label: "PRESET_NAME",
                             placeholder: "PRESET_NAME_PLACEHOLDER",
                             text: $viewModel.presetName,
                             onCommit: viewModel.commitVoicePresetEdits)

            LabeledTextField(label: "PRESET_REFERENCE_AUDIO_PATH",
                             placeholder: "PRESET_REFERENCE_AUDIO_PATH_PLACEHOLDER",
                             text: $viewModel.presetRefAudioPath,
                             onCommit: viewModel.commitVoicePresetEdits)
            LabeledTextField(label: "PRESET_REFERENCE_TEXT",
                             placeholder: "PRESET_REFERENCE_TEXT_PLACEHOLDER",
                             text: $viewModel.presetPromptText,
                             onCommit: viewModel.commitVoicePresetEdits)
            LabeledTextField(label: "PRESET_REFERENCE_LANGUAGE",
                             placeholder: "VOICE_LANGUAGE_PLACEHOLDER",
                             text: $viewModel.presetPromptLang,
                             onCommit: viewModel.commitVoicePresetEdits)

            LabeledTextField(label: "PRESET_GPT_WEIGHTS_PATH",
                             placeholder: "PRESET_GPT_WEIGHTS_PATH_PLACEHOLDER",
                             text: $viewModel.presetGPTWeightsPath,
                             onCommit: viewModel.commitVoicePresetEdits)
            LabeledTextField(label: "PRESET_SOVITS_WEIGHTS_PATH",
                             placeholder: "PRESET_SOVITS_WEIGHTS_PATH_PLACEHOLDER",
                             text: $viewModel.presetSoVITSWeightsPath,
                             onCommit: viewModel.commitVoicePresetEdits)
        }
    }

    private var presetApplyRow: some View {
        HStack {
            Spacer()
            Button {
                viewModel.applySelectedPresetNow()
            } label: {
                Label("PRESET_ACTION_APPLY_NOW", systemImage: "arrow.triangle.2.circlepath.circle")
            }
            .settingsActionButtonStyle()
            #if os(macOS)
            .help("PRESET_ACCESSIBILITY_APPLY")
            #endif
            .disabled(settingsManager.isApplyingPreset || viewModel.selectedPresetID == nil)
        }
    }

    private var presetApplyStatusRow: some View {
        let shouldShowMessage = settingsManager.isApplyingPreset
            || !(settingsManager.lastApplyError?.isEmpty ?? true)
            || (settingsManager.lastPresetApplyAt != nil && settingsManager.lastPresetApplySucceeded)

        return Group {
            if settingsManager.isApplyingPreset {
                HStack(spacing: 8) {
                    ProgressView()
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                    if settingsManager.isRetryingPresetApply {
                        Text(String(format: NSLocalizedString("AUDIO_RETRY_ATTEMPT", value: "Retrying (attempt %d)...", comment: "Shown while auto retry is waiting to reconnect"), max(1, settingsManager.presetApplyRetryAttempt)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text("PRESET_APPLYING")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                #if os(macOS)
                .help(settingsManager.presetApplyRetryLastError ?? "")
                #endif
            } else if let err = settingsManager.lastApplyError, !err.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text(err)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                #if os(macOS)
                .help(err)
                #endif
            } else if settingsManager.lastPresetApplyAt != nil, settingsManager.lastPresetApplySucceeded {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("PRESET_APPLIED")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                EmptyView()
            }
        }
        .opacity(shouldShowMessage ? 1 : 0)
        .accessibilityHidden(!shouldShowMessage)
        #if !os(macOS)
        .listRowSeparator(shouldShowMessage ? .visible : .hidden)
        #endif
    }
}
