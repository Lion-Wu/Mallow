import SwiftUI
import UniformTypeIdentifiers

struct DataManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var coordinator: StartupDataCoordinator
    @StateObject private var model = DataManagementModel()
    @State private var showingImporter = false
    let commitEdits: () -> Void

    var body: some View {
        overview
        .navigationTitle("DATA_MANAGEMENT")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("COMMON_ACTION_CLOSE") { dismiss() }.disabled(model.isBusy)
            }
        }
        #endif
        .disabled(model.isBusy)
        .interactiveDismissDisabled(model.isBusy)
        .task {
            model.observeStorage(environment: environment)
            model.refreshUsage()
        }

        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): model.importBackup(url, environment: environment, commitEdits: commitEdits)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .modifier(DataExportPresentation(model: model, source: .backup))
        .sheet(item: $model.preview) { preview in
            DataImportPreviewView(preview: preview, progressMessage: model.progressMessage(for: .mergeImport), errorMessage: model.errorMessage) {
                model.preview = nil
            } confirm: {
                model.confirmImport(environment: environment, coordinator: coordinator, commitEdits: commitEdits)
            }
            .interactiveDismissDisabled(model.isBusy)
        }
        .alert("DATA_MANAGEMENT", isPresented: Binding(
            get: { model.errorMessage != nil && model.preview == nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("COMMON_ACTION_OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder
    private var overview: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    storageOverview.padding(12)
                }
                HStack(alignment: .top, spacing: 16) {
                    GroupBox("SETTINGS_CHAT_MANAGEMENT") {
                        VStack(spacing: 0) { storageLinks }
                            .padding(.top, 8)
                    }
                    GroupBox("DATA_MANAGEMENT") {
                        VStack(spacing: 0) { maintenanceLinks }
                            .padding(.top, 8)
                    }
                }
                HStack {
                    Text("DATA_BACKUP_AND_RESTORE").font(.headline)
                    Spacer()
                    transferButtons
                }
                .controlSize(.large)
            }
            .buttonStyle(.plain)
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        #else
        Form {
            Section("STORAGE_TITLE") { storageOverview }
            Section("SETTINGS_CHAT_MANAGEMENT") { storageLinks }
            Section("DATA_MANAGEMENT") { maintenanceLinks }
            Section("DATA_BACKUP_AND_RESTORE") { transferButtons }
        }
        .formStyle(.grouped)
        #endif
    }

    private var storageOverview: some View {
        DataStorageChart(usage: model.usage, isLoading: model.progress?.kind == .loadUsage)
    }

    private var storageLinks: some View {
        Group {
            NavigationLink {
                DataChatStorageList(model: model, commitEdits: commitEdits)
            } label: { navigationRow("STORAGE_GROUP_BY_CHAT", systemImage: "bubble.left.and.bubble.right") }
            NavigationLink {
                DataAttachmentMessageList(model: model, commitEdits: commitEdits)
            } label: { navigationRow("STORAGE_IMAGES_AND_ATTACHMENTS", systemImage: "photo") }
        }
    }

    private var maintenanceLinks: some View {
        Group {
            NavigationLink {
                DataModelBrowser(model: model, commitEdits: commitEdits)
            } label: { navigationRow("DATA_MODEL_DATA", systemImage: "cpu") }
            NavigationLink {
                DataCleanupView(model: model, commitEdits: commitEdits)
            } label: { navigationRow("STORAGE_CACHE_AND_CLEANUP", systemImage: "internaldrive") }
        }
    }

    private var transferButtons: some View {
        Group {
            Button { model.exportBackup(environment: environment, commitEdits: commitEdits) } label: {
                DataOperationButtonLabel(title: "DATA_ACTION_EXPORT", systemImage: "square.and.arrow.up",
                    progressMessage: model.progressMessage(for: .exportBackup))
            }
            Button { showingImporter = true } label: {
                DataOperationButtonLabel(title: "DATA_ACTION_IMPORT", systemImage: "square.and.arrow.down",
                    progressMessage: model.progressMessage(for: .readImport))
            }
        }
        #if os(macOS)
        .buttonStyle(.bordered)
        #endif
    }

    private func navigationRow(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 20)
            Text(title).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            #if os(macOS)
            Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .padding(12)
        #endif
        .contentShape(Rectangle())
    }

}

struct DataStorageChart: View {
    let usage: DataStorageUsage?
    let isLoading: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var columns: [GridItem] {
        #if os(iOS)
        Array(repeating: GridItem(.flexible(), alignment: .leading),
              count: horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        #else
        [GridItem(.adaptive(minimum: 260), alignment: .leading)]
        #endif
    }

    private struct Category: Identifiable {
        let title: LocalizedStringKey
        let bytes: Int64
        let color: Color
        let id: Int
    }

    private var categories: [Category] {
        [Category(title: "CHAT_LIST_TITLE", bytes: usage?.chats ?? 0, color: .blue, id: 0),
         Category(title: "CHAT_IMAGES", bytes: usage?.images ?? 0, color: .purple, id: 1),
         Category(title: "SETTINGS_TITLE", bytes: usage?.settings ?? 0, color: .teal, id: 2),
         Category(title: "STORAGE_DOCUMENTS", bytes: usage?.documents ?? 0, color: .indigo, id: 4),
         Category(title: "STORAGE_CACHES", bytes: usage?.caches ?? 0, color: .pink, id: 5),
         Category(title: "STORAGE_TEMPORARY_FILES", bytes: usage?.temporaryFiles ?? 0, color: .yellow, id: 6),
         Category(title: "STORAGE_DATABASE_AND_OTHER", bytes: usage?.other ?? 0, color: .gray, id: 7)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("STORAGE_USED").font(.subheadline).foregroundStyle(.secondary)
                    if isLoading {
                        ProgressView().controlSize(.small).accessibilityLabel("COMMON_LOADING_ELLIPSIS")
                    }
                }
                Text(usage.map { bytes($0.total) } ?? "—").font(.system(.title, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(categories.filter { $0.bytes > 0 }) { category in
                        category.color
                            .frame(width: geometry.size.width * CGFloat(category.bytes) / CGFloat(max(usage?.total ?? 0, 1)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: 20)
            .accessibilityHidden(true)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(categories) { category in
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                    layout {
                        HStack(spacing: 8) {
                            Circle().fill(category.color).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(category.title)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(usage == nil ? "—" : bytes(category.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

private struct DataCleanupView: View {
    @ObservedObject var model: DataManagementModel
    let commitEdits: () -> Void
    @State private var selectedCleanup: DataCleanupCategory?

    var body: some View {
        Form {
            if let usage = model.usage {
                Section {
                    LabeledContent("STORAGE_RECLAIMABLE", value: bytes(usage.reclaimable + (model.unusedFiles?.reduce(0) { $0 + $1.bytes } ?? 0)))
                        .font(.headline)
                }
                Section("STORAGE_NETWORK_CACHE") {
                    LabeledContent("STORAGE_USED", value: bytes(usage.networkCache))
                    Button { selectedCleanup = .networkCache } label: {
                        DataOperationButtonLabel(title: "STORAGE_ACTION_CLEAR_NETWORK_CACHE", progressMessage: model.progressMessage(for: .cleanNetworkCache))
                    }
                    .disabled(usage.networkCache == 0)
                }
                Section("STORAGE_TEMPORARY_FILES") {
                    LabeledContent("STORAGE_RECLAIMABLE", value: bytes(usage.reclaimableTemporaryFiles))
                    Button { selectedCleanup = .temporaryFiles } label: {
                        DataOperationButtonLabel(title: "STORAGE_ACTION_REMOVE_TEMPORARY_FILES", progressMessage: model.progressMessage(for: .cleanTemporaryFiles))
                    }
                    .disabled(usage.reclaimableTemporaryFiles == 0)
                }
            }
            Section {
                NavigationLink {
                    DataCleanupReviewView(model: model, commitEdits: commitEdits)
                } label: {
                    Label("DATA_CLEANUP", systemImage: "externaldrive.badge.exclamationmark")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("STORAGE_CACHE_AND_CLEANUP")
        .disabled(model.isBusy)
        .alert(cleanupTitle, isPresented: Binding(
            get: { selectedCleanup != nil }, set: { if !$0 { selectedCleanup = nil } }
        )) {
            Button(cleanupTitle) {
                if let selectedCleanup { model.clean(selectedCleanup) }
                selectedCleanup = nil
            }
            Button("COMMON_ACTION_CANCEL", role: .cancel) { selectedCleanup = nil }
        } message: {
            Text("COMMON_IRREVERSIBLE_WARNING")
        }
        .alert("STORAGE_CACHE_AND_CLEANUP", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("COMMON_ACTION_OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var cleanupTitle: String {
        selectedCleanup == .networkCache ? String(localized: "STORAGE_ACTION_CLEAR_NETWORK_CACHE", defaultValue: "Clear Network Cache") : String(localized: "STORAGE_ACTION_REMOVE_TEMPORARY_FILES", defaultValue: "Remove Temporary Files")
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

struct DataImportPreviewView: View {
    let preview: DataImportPreview
    let progressMessage: String?
    private var isBusy: Bool { progressMessage != nil }
    let errorMessage: String?
    let cancel: () -> Void
    let confirm: () -> Void

    private let originalMessages: [UUID: ChatMessageBackup]
    private let mergedMessages: [UUID: ChatMessageBackup]
    private let messageChanges: [DataImportChange]
    private let messageChangesBySession: [UUID: [DataImportChange]]

    init(preview: DataImportPreview, progressMessage: String?, errorMessage: String?, cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.preview = preview
        self.progressMessage = progressMessage
        self.errorMessage = errorMessage
        self.cancel = cancel
        self.confirm = confirm
        let originals = Dictionary(uniqueKeysWithValues: preview.original.snapshot.messages.map { ($0.id, $0) })
        let merged = Dictionary(uniqueKeysWithValues: preview.merged.messages.map { ($0.id, $0) })
        originalMessages = originals
        mergedMessages = merged
        let changes = preview.changes.filter { change in
            guard let id = change.messageID, change.kind != .skipped else { return false }
            guard var old = originals[id], let new = merged[id] else { return true }
            old.activeChildMessageID = new.activeChildMessageID
            return old != new
        }
        messageChanges = changes
        messageChangesBySession = Dictionary(grouping: changes.filter { $0.sessionID != nil }, by: { $0.sessionID! })
    }

    private var affectedSessions: [ChatSessionBackup] {
        let ids = Set(messageChanges.compactMap(\.sessionID))
        let originals = Dictionary(uniqueKeysWithValues: preview.original.snapshot.sessions.map { ($0.id, $0) })
        return preview.merged.sessions.filter { session in
            ids.contains(session.id) || originals[session.id].map {
                $0.title != session.title || selectedMessage(in: $0, messages: originalMessages)?.id != selectedMessage(in: session, messages: mergedMessages)?.id
            } ?? true
        }.sorted { ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt) }
    }

    private var otherChanges: [DataImportChange] {
        preview.changes.filter { $0.messageID == nil && $0.sessionID == nil && $0.kind != .skipped }
    }

    private var skippedCategories: [DataRecoveryCategory] {
        (preview.incoming.categories + preview.original.categories).filter {
            $0.skipped > 0 || $0.hasUnknownLoss || $0.hasPartialLoss
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                summary
                Section { changeLinks }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("DATA_IMPORT_PREVIEW")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("COMMON_ACTION_CANCEL", action: cancel).disabled(isBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: confirm) {
                        DataOperationButtonLabel(title: "DATA_ACTION_MERGE", progressMessage: progressMessage)
                    }
                    .disabled(isBusy || preview.count(.added) + preview.count(.updated) + preview.count(.branch) == 0)
                }
            }
            .disabled(isBusy)
        }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 680)
        #endif
    }

    private var summary: some View {
        Section {
            #if os(iOS)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    statistics.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 16) { statistics }
            }
            .padding(.vertical, 8)
            #else
            HStack(alignment: .top, spacing: 20) { statistics }
            #endif
        }
    }

    @ViewBuilder
    private var statistics: some View {
        statistic("DATA_NEW_MESSAGES", count: messageChanges.filter { $0.kind == .added || $0.kind == .branch }.count)
        statistic("DATA_UPDATED_MESSAGES", count: messageChanges.filter { $0.kind == .updated }.count)
        statistic("DATA_ISSUES_FOUND", count: skippedCategories.contains { $0.hasUnknownLoss } ? nil : skippedCategories.reduce(0) { $0 + max($1.skipped, $1.issues.count) })
    }

    @ViewBuilder
    private var changeLinks: some View {
        NavigationLink {
            List(affectedSessions, id: \.id) { session in
                NavigationLink {
                    conversation(session)
                        .navigationTitle(session.title)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).lineLimit(2)
                        Text(String(localized: "DATA_CHANGED_MESSAGES", defaultValue: "Changed Messages") + " · " + (messageChangesBySession[session.id]?.count ?? 0).formatted())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if affectedSessions.isEmpty {
                    ContentUnavailableView("DATA_EMPTY", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .navigationTitle("DATA_CHAT_CHANGES")
        } label: { previewRow("DATA_CHAT_CHANGES", count: affectedSessions.count) }
        if !otherChanges.isEmpty {
            NavigationLink {
                List(otherChanges) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(change.category == change.name ? change.name : change.category + " · " + change.name)
                        Text(change.kind == .added ? LocalizedStringKey("DATA_IMPORT_ADD_DESCRIPTION") : LocalizedStringKey("DATA_IMPORT_REPLACE_DESCRIPTION"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.navigationTitle("DATA_SETTINGS_AND_PRESETS")
            } label: { previewRow("DATA_SETTINGS_AND_PRESETS", count: otherChanges.count) }
        }
        if affectedSessions.isEmpty && otherChanges.isEmpty {
            Text("DATA_IMPORT_ALREADY_PRESENT")
        }
        if !skippedCategories.isEmpty {
            NavigationLink {
                skippedItems.navigationTitle("DATA_ISSUES_FOUND")
            } label: { previewRow("DATA_ISSUES_FOUND", count: skippedCategories.contains { $0.hasUnknownLoss } ? nil : skippedCategories.reduce(0) { $0 + max($1.skipped, $1.issues.count) }) }
        }
    }

    private func previewRow(_ title: LocalizedStringKey, count: Int?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(count?.formatted() ?? String(localized: "COMMON_UNKNOWN", defaultValue: "Unknown")).foregroundStyle(.secondary)
        }
    }

    private func statistic(_ title: LocalizedStringKey, count: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count?.formatted() ?? String(localized: "COMMON_UNKNOWN", defaultValue: "Unknown")).font(.title.bold())
            Text(title).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func conversation(_ session: ChatSessionBackup) -> some View {
        let original = preview.original.snapshot.sessions.first { $0.id == session.id }
        let messages = mergedMessages
        let changes = (messageChangesBySession[session.id] ?? []).sorted {
            ($0.messageID.flatMap { messages[$0]?.createdAt } ?? .distantPast) < ($1.messageID.flatMap { messages[$0]?.createdAt } ?? .distantPast)
        }
        return Form {
            if original == nil || original?.title != session.title {
                Section {
                    if original == nil { Text("CHAT_TITLE_NEW") }
                    if let original, original.title != session.title {
                        Text(original.title + " → " + session.title).foregroundStyle(.secondary)
                    }
                }
            }
            if !changes.isEmpty {
                Section("DATA_CHANGED_MESSAGES") {
                    ForEach(changes) { change in
                        if let id = change.messageID, let message = messages[id] {
                            NavigationLink {
                                messageChange(change, message: message)
                                    .navigationTitle(change.kind == .updated ? LocalizedStringKey("DATA_ACTION_UPDATE_MESSAGE") : LocalizedStringKey("DATA_NEW_MESSAGES"))
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    if !message.content.isEmpty {
                                        Text(message.content).lineLimit(2)
                                    } else if message.imageAttachmentsData != nil {
                                        Label("CHAT_IMAGES", systemImage: "photo")
                                    } else {
                                        Text("DATA_EMPTY").foregroundStyle(.secondary)
                                    }
                                    HStack {
                                        if let createdAt = message.createdAt { Text(createdAt, style: .date) }
                                        Text(change.kind == .updated ? LocalizedStringKey("DATA_ACTION_UPDATE_MESSAGE") : change.kind == .branch ? LocalizedStringKey("CHAT_BRANCH_NEW") : LocalizedStringKey("DATA_NEW_MESSAGES"))
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if changes.isEmpty, let original,
               let selected = selectedMessage(in: session, messages: messages),
               selected.id != selectedMessage(in: original, messages: originalMessages)?.id {
                Section {
                    DataImportMessageView(message: selected)
                } header: {
                    Text("DATA_IMPORT_BRANCH_PREVIEW")
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func messageChange(_ change: DataImportChange, message: ChatMessageBackup) -> some View {
        Form {
            if change.kind == .updated {
                Section("MESSAGE_TITLE") { DataImportMessageView(message: message) }
                if let old = originalMessages[message.id] {
                    Section {
                        Text("DATA_IMPORT_REPLACED_FIELDS")
                            .foregroundStyle(.secondary)
                        ForEach(updatedFields(from: old, to: message), id: \.self) { field in
                            Text(field)
                        }
                    } header: {
                        Text("DATA_ACTION_UPDATE_MESSAGE")
                    }
                }
            } else {
                if let parent = message.parentID.flatMap({ mergedMessages[$0] }) {
                    Section {
                        DataImportMessageView(message: parent)
                    } header: {
                        Text("DATA_IMPORT_AFTER_MESSAGE")
                    }
                } else {
                    Section { Text("DATA_IMPORT_CHAT_START").foregroundStyle(.secondary) }
                }
                if change.kind == .branch {
                    let existing = preview.original.snapshot.messages.filter {
                        $0.sessionID == message.sessionID && $0.parentID == message.parentID
                    }.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
                    if !existing.isEmpty {
                        Section("DATA_IMPORT_EXISTING_BRANCH") {
                            ForEach(existing, id: \.id) { DataImportMessageView(message: $0) }
                        }
                    }
                }
                Section {
                    DataImportMessageView(message: message)
                } header: {
                    Text(change.kind == .branch ? LocalizedStringKey("DATA_IMPORT_ADDED_BRANCH") : LocalizedStringKey("DATA_IMPORT_ADDED_MESSAGE"))
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private struct RecoverySection: Identifiable {
        let category: DataRecoveryCategory
        let isLocal: Bool
        var id: String { (isLocal ? "local:" : "incoming:") + category.id }
    }

    private var skippedItems: some View {
        let sections = preview.incoming.categories.map { RecoverySection(category: $0, isLocal: false) }
            + preview.original.categories.map { RecoverySection(category: $0, isLocal: true) }
        return Form {
            ForEach(sections.filter { $0.category.skipped > 0 || $0.category.hasUnknownLoss || $0.category.hasPartialLoss }) { section in
                skippedSection(section.category, isLocal: section.isLocal)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func selectedMessage(in session: ChatSessionBackup, messages: [UUID: ChatMessageBackup]) -> ChatMessageBackup? {
        var message = session.activeRootMessageID.flatMap { messages[$0] }
        while let next = message?.activeChildMessageID.flatMap({ messages[$0] }) {
            message = next
        }
        return message
    }

    private func skippedSection(_ category: DataRecoveryCategory, isLocal: Bool) -> some View {
        Section {
            ForEach(category.problems.indices, id: \.self) { index in
                Text(category.problems[index])
            }
            if category.hasUnknownLoss && category.problems.isEmpty {
                Text("RECOVERY_CATEGORY_UNREADABLE")
                    .foregroundStyle(.secondary)
            }
            if category.hasPartialLoss { Text("RECOVERY_CONTENT_INCOMPLETE").foregroundStyle(.secondary) }
            ForEach(category.issues) { issue in
                NavigationLink {
                    Form {
                        Section(issue.reason.title) {
                            Text(issue.explanation)
                            ForEach(issue.fields, id: \.self) { field in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(DataRecoveryIssue.fieldTitle(field)).font(.headline)
                                    if let explanation = issue.fieldProblems[field] {
                                        Text(explanation).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Section("MESSAGE_TITLE") {
                            if let date = issue.date { Text(date, format: .dateTime).font(.caption).foregroundStyle(.secondary) }
                            Text(issue.name).textSelection(.enabled)
                        }
                    }
                    .formStyle(.grouped)
                    .navigationTitle("DATA_ISSUE_DETAILS")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.name).lineLimit(2)
                        Text(issue.reason.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if category.issues.isEmpty {
                ForEach(category.skippedNames.indices, id: \.self) { index in
                    Text(category.skippedNames[index]).textSelection(.enabled)
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                Text(isLocal ? LocalizedStringKey("DATA_MERGE_INCOMPLETE") : LocalizedStringKey("DATA_IMPORT_RECORDS_UNMERGED"))
                HStack {
                    Text(category.title)
                    Spacer()
                    Text(category.hasUnknownLoss ? String(localized: "COMMON_UNKNOWN", defaultValue: "Unknown") : max(category.skipped, category.issues.count).formatted())
                }
            }
        }
    }

    private func updatedFields(from old: ChatMessageBackup, to new: ChatMessageBackup) -> [String] {
        var result: [String] = []
        func changed<T: Equatable>(_ title: String, _ before: T, _ after: T) {
            if before != after { result.append(title) }
        }
        changed(String(localized: "MODEL_TITLE", defaultValue: "Model"), old.modelIdentifier, new.modelIdentifier)
        changed(String(localized: "SETTINGS_SERVER_ADDRESS", defaultValue: "Server Address"), old.apiBaseURL, new.apiBaseURL)
        changed(String(localized: "MESSAGE_DATE", defaultValue: "Message Date"), old.createdAt, new.createdAt)
        changed(String(localized: "MESSAGE_RESPONSE_CONTENT", defaultValue: "Response Content"), old.assistantSegmentsData, new.assistantSegmentsData)
        changed(String(localized: "CHAT_CONVERSATION_CONTEXT", defaultValue: "Conversation Context"), old.openAIResponsesConversationItemsData, new.openAIResponsesConversationItemsData)
        changed(String(localized: "TOOLS_ACTIVITY", defaultValue: "Tool Activity"), old.toolActivityPlacementsData, new.toolActivityPlacementsData)
        changed(String(localized: "THINKING_SETTINGS", defaultValue: "Thinking Settings"), old.thinkingOptionRawValue, new.thinkingOptionRawValue)
        if old.requestID != new.requestID || old.providerResponseID != new.providerResponseID || old.requestContextFingerprint != new.requestContextFingerprint || old.requestUsedPreviousResponseID != new.requestUsedPreviousResponseID || old.requestPreviousResponseID != new.requestPreviousResponseID {
            result.append(String(localized: "DATA_REQUEST_RESPONSE_RECORDS", defaultValue: "Request and Response Records"))
        }
        if old.generationRounds != new.generationRounds || old.streamStartedAt != new.streamStartedAt || old.streamFirstTokenAt != new.streamFirstTokenAt || old.streamFirstTokenAtSource != new.streamFirstTokenAtSource || old.streamCompletedAt != new.streamCompletedAt || old.timeToFirstToken != new.timeToFirstToken || old.outputTokenCount != new.outputTokenCount || old.reasoningOutputTokenCount != new.reasoningOutputTokenCount || old.tokensPerSecond != new.tokensPerSecond || old.tokenCount != new.tokenCount || old.tokenCountSource != new.tokenCountSource || old.timeToFirstTokenSource != new.timeToFirstTokenSource || old.tokensPerSecondSource != new.tokensPerSecondSource || old.promptMessageCount != new.promptMessageCount || old.promptCharacterCount != new.promptCharacterCount {
            result.append(String(localized: "MESSAGE_GENERATION_STATISTICS", defaultValue: "Generation Statistics"))
        }
        if old.finishReason != new.finishReason || old.finishReasonSource != new.finishReasonSource || old.errorDescription != new.errorDescription || old.isActive != new.isActive {
            result.append(String(localized: "MESSAGE_COMPLETION_STATUS", defaultValue: "Completion Status"))
        }
        return result
    }
}

private struct DataImportMessageView: View {
    let message: ChatMessageBackup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.isUser ? LocalizedStringKey("CHAT_ROLE_YOU") : LocalizedStringKey("CHAT_ROLE_ASSISTANT")).font(.subheadline.weight(.semibold))
                Spacer()
                if let createdAt = message.createdAt {
                    Text(createdAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !message.content.isEmpty {
                RichMarkdownView(markdown: message.content)
            } else if message.imageAttachmentsData == nil {
                Text("DATA_EMPTY").foregroundStyle(.secondary)
            }
            if message.imageAttachmentsData != nil { Label("CHAT_IMAGES", systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DataOperationButtonLabel: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    let progressMessage: String?

    var body: some View {
        if let progressMessage {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(progressMessage).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(progressMessage))
        } else if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

struct DataExportPresentation: ViewModifier {
    @ObservedObject var model: DataManagementModel
    let source: DataPreparedExport.Source

    private var export: DataPreparedExport? {
        model.preparedExport?.source == source ? model.preparedExport : nil
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        content.fileExporter(
            isPresented: Binding(get: { export != nil }, set: { if !$0 { model.finishExport(source: source) } }),
            document: export?.document, contentType: .zip,
            defaultFilename: export?.archive.url.deletingPathExtension().lastPathComponent
        ) { result in
            if case .failure(let error) = result { model.finishExport(source: source, error: error) }
            else { model.finishExport(source: source) }
        }
        #else
        content.background {
            DataExportSharePresenter(url: export?.archive.url) { _, error in
                model.finishExport(source: source, error: error)
            }
            .frame(width: 1, height: 1)
        }
        #endif
    }
}
