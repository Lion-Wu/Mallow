//
//  SettingsAdvancedAPISections.swift
//  Mallow
//
//  Created by Codex on 2026/6/14.
//

import SwiftUI

struct SettingsAdvancedAPICurrentBackendSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var settingsManager: SettingsManager

    private var context: SettingsAdvancedAPIContext {
        SettingsAdvancedAPIContext(
            viewModel: viewModel,
            settingsManager: settingsManager
        )
    }

    var body: some View {
        Section {
            SettingsAdvancedAPIParameterControls(
                viewModel: viewModel,
                profile: .init(current: context)
            )
        } header: {
            SettingsAdvancedAPISectionHeader(title: "SETTINGS_CURRENT_BACKEND_PARAMETERS")
        } footer: {
            Text("SETTINGS_SAMPLING_DESCRIPTION")
        }
    }
}

struct SettingsAdvancedAPIBackendOverridesSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section {
            ForEach(AdvancedAPIBackendOverrideID.allCases) { backend in
                DisclosureGroup(backend.title) {
                    SettingsAdvancedAPIParameterControls(
                        viewModel: viewModel,
                        profile: .init(override: backend)
                    )
                }
            }
        } header: {
            SettingsAdvancedAPISectionHeader(title: "SETTINGS_BACKEND_OVERRIDES")
        }
    }
}

struct SettingsAdvancedAPIDefaultsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Binding var showingResetConfirmation: Bool

    var body: some View {
        Section {
            HStack {
                Spacer()
                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    Label("SETTINGS_ACTION_RESTORE_DEFAULTS", systemImage: "arrow.counterclockwise")
                }
                .settingsActionButtonStyle()
                .tint(.red)
            }
            .confirmationDialog(
                "SETTINGS_RESTORE_DEFAULTS_CONFIRMATION",
                isPresented: $showingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("SETTINGS_ACTION_RESTORE_DEFAULTS", role: .destructive) {
                    viewModel.resetAPIAdvancedSettingsToDefaults()
                }
                Button("COMMON_ACTION_CANCEL", role: .cancel) {}
            } message: {
                Text("SETTINGS_RESET_DEFAULTS_DESCRIPTION")
            }
        } header: {
            SettingsAdvancedAPISectionHeader(title: "SETTINGS_DEFAULTS")
        }
    }
}

struct SettingsDeveloperDefaultsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Binding var showingResetConfirmation: Bool

    var body: some View {
        Section {
            Button(role: .destructive) {
                showingResetConfirmation = true
            } label: {
                Label("SETTINGS_ACTION_RESTORE_DEVELOPER_DEFAULTS", systemImage: "arrow.counterclockwise")
            }
            .confirmationDialog(
                "SETTINGS_RESTORE_DEVELOPER_DEFAULTS_CONFIRMATION",
                isPresented: $showingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("SETTINGS_ACTION_RESTORE_DEVELOPER_DEFAULTS", role: .destructive) {
                    viewModel.resetDeveloperSettingsToDefaults()
                }
                Button("COMMON_ACTION_CANCEL", role: .cancel) {}
            } message: {
                Text("SETTINGS_RESET_DEVELOPER_DEFAULTS_DESCRIPTION")
            }
        } header: {
            SettingsAdvancedAPISectionHeader(title: "SETTINGS_DEVELOPER_DEFAULTS")
        }
    }
}
