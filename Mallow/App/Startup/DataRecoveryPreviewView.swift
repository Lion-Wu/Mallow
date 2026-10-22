import SwiftUI

struct DataRecoveryPreviewView: View {
    @ObservedObject var coordinator: StartupDataCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRecovery = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if coordinator.isScanningRecovery {
                        ProgressView("RECOVERY_SCANNING")
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if let plan = coordinator.recoveryPlan {
                        ForEach(plan.categories) { category in
                            categoryView(category)
                        }
                        if plan.recoveredCount == 0 {
                            Text("RECOVERY_NO_RECORDS")
                                .foregroundStyle(.orange)
                        }
                    }
                    if let error = coordinator.recoveryError {
                        Text("RECOVERY_FAILED")
                            .font(.headline)
                        Text("DATA_ORIGINAL_UNCHANGED")
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .padding(20)
            }
            .navigationTitle("DATA_RECOVERY")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("COMMON_ACTION_CANCEL") {
                        coordinator.cancelRecovery()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("RECOVERY_ACTION_RESTORE") {
                        isConfirmingRecovery = true
                    }
                    .disabled(coordinator.isScanningRecovery || (coordinator.recoveryPlan?.recoveredCount ?? 0) == 0)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 480, idealHeight: 650)
        #endif
        .alert("DATA_RESTORE_CONFIRMATION", isPresented: $isConfirmingRecovery) {
            Button("COMMON_ACTION_CANCEL", role: .cancel) {}
            Button("RECOVERY_ACTION_RESTORE", role: .destructive) { coordinator.confirmRecovery() }
        } message: {
            Text("RECOVERY_RESET_WARNING")
        }
    }

    private func categoryView(_ category: DataRecoveryCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(category.title).font(.headline)
            LabeledContent("RECOVERY_RECOVERABLE", value: category.recovered.formatted())
            LabeledContent("RECOVERY_UNRECOVERABLE", value: category.hasUnknownLoss ? String(localized: "COMMON_UNKNOWN", defaultValue: "Unknown") : category.skipped.formatted())
            if category.hasPartialLoss {
                Text("RECOVERY_CONTENT_INCOMPLETE").foregroundStyle(.orange)
            }
            if !category.names.isEmpty {
                DisclosureGroup("RECOVERY_RECOVERED_ITEMS") {
                    itemNames(category.names)
                }
            }
            if !category.skippedNames.isEmpty {
                DisclosureGroup("RECOVERY_UNRECOVERABLE_ITEMS") {
                    itemNames(category.skippedNames)
                }
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func itemNames(_ names: [String]) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(names.indices, id: \.self) { index in
                Text(names[index])
                    .font(.callout)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}
