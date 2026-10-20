import CryptoKit
import SwiftUI
import ImageIO
#if os(macOS)
import AppKit
#endif

private struct DataBrowserSearch: ViewModifier {
    @Binding var text: String

    func body(content: Content) -> some View {
        #if os(macOS)
        // A sheet's window toolbar is separate from its NavigationStack header.
        // Keep list search inside the destination so both share the same bounds.
        content.safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                DataBrowserSearchField(text: $text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
            }
            .background(.bar)
        }
        #else
        content.searchable(text: $text)
        #endif
    }
}

#if os(macOS)
private struct DataBrowserSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Search")
        field.setAccessibilityLabel(String(localized: "Search"))
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        @objc func searchChanged(_ field: NSSearchField) {
            text.wrappedValue = field.stringValue
        }
    }
}
#endif

private func storageSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private struct DataMaintenanceRequest: Identifiable {
    let id = UUID()
    let mutation: DataManagementMutation
    let revision: SHA256.Digest
    let title: String
    let detail: String

    var isDeletion: Bool {
        switch mutation {
        case .deleteChats, .deleteAttachments, .deleteAllAttachments, .deletePreference, .deleteModelData, .clearContext, .deleteIssues:
            true
        case .recoverUnowned:
            false
        }
    }
}

private struct DataMaintenanceControls: ViewModifier {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DataManagementModel
    @Binding var request: DataMaintenanceRequest?
    let commitEdits: () -> Void
    var dismissOnCompletion = false
    var onCompletion: () -> Void = {}

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .disabled(model.isBusy)
            .onChange(of: model.catalog?.revision) { _, _ in request = nil }
            .onChange(of: model.cleanupReport?.revision) { _, _ in request = nil }
            .overlay {
                if model.progress?.kind == .loadCatalog, model.catalog == nil {
                    ProgressView().accessibilityLabel("Loading…")
                }
            }
            .confirmationDialog(request?.title ?? "", isPresented: confirmationBinding(forDeletion: false), titleVisibility: .visible) {
                if let request {
                    Button("Apply Changes", role: .destructive) {
                        apply(request)
                    }
                }
                Button("Cancel", role: .cancel) { request = nil }
            } message: {
                Text(confirmationMessage)
            }
            .alert("Confirm deletion?", isPresented: confirmationBinding(forDeletion: true)) {
                if let request {
                    Button("Delete", role: .destructive) { apply(request) }
                }
                Button("Cancel", role: .cancel) { request = nil }
            } message: {
                if case .deleteChats(let ids) = request?.mutation {
                    if ids.count == 1 {
                        Text("This will permanently delete this chat. This action cannot be undone.")
                    } else {
                        Text("This will permanently delete the selected chats. This action cannot be undone.")
                    }
                } else {
                    Text(confirmationMessage + "\n\n" + String(localized: "This action cannot be undone."))
                }
            }
            .alert("Data Management", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }

    private var confirmationMessage: String {
        request?.detail ?? ""
    }

    private func confirmationBinding(forDeletion isDeletion: Bool) -> Binding<Bool> {
        Binding(
            get: { request?.isDeletion == isDeletion },
            set: { if !$0, request?.isDeletion == isDeletion { request = nil } }
        )
    }

    private func apply(_ request: DataMaintenanceRequest) {
        model.apply(request.mutation, revision: request.revision, environment: environment,
            commitEdits: commitEdits) {
                onCompletion()
                if dismissOnCompletion { dismiss() }
            }
        self.request = nil
    }
}

private enum DataStorageSort: String, CaseIterable {
    case size, date, name
    var title: LocalizedStringKey {
        switch self {
        case .size: "Largest First"
        case .date: "Newest First"
        case .name: "Name"
        }
    }
}

struct DataChatStorageList: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: DataManagementModel
    let commitEdits: () -> Void
    @State private var search = ""
    @State private var sort = DataStorageSort.size
    @State private var selected: Set<UUID> = []
    @State private var selecting = false
    @State private var request: DataMaintenanceRequest?

    private var chats: [DataStorageChat] {
        (model.catalog?.chats ?? []).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }.sorted {
            switch sort {
            case .size: $0.bytes > $1.bytes
            case .date: $0.date > $1.date
            case .name: $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        List {
            Picker("Sort By", selection: $sort) { ForEach(DataStorageSort.allCases, id: \.self) { Text($0.title).tag($0) } }
            if model.catalog != nil, chats.isEmpty {
                Text(search.isEmpty ? LocalizedStringKey("No Data") : LocalizedStringKey("No Results"))
                    .foregroundStyle(.secondary)
            }
            ForEach(chats) { chat in
                if selecting {
                    DataSelectionRow(isSelected: selected.contains(chat.id)) {
                        if !selected.insert(chat.id).inserted { selected.remove(chat.id) }
                    } content: { chatLabel(chat) }
                } else {
                    NavigationLink {
                        DataChatStorageDetail(chat: chat, model: model, commitEdits: commitEdits)
                    } label: { chatLabel(chat) }
                }
            }
            if let catalog = model.catalog, search.isEmpty {
                Section {
                    LabeledContent("Shared Request Metadata", value: storageSize(catalog.sharedMetadataBytes))
                    if catalog.unassignedMessageBytes > 0 {
                        LabeledContent("Unassigned Messages", value: storageSize(catalog.unassignedMessageBytes))
                    }
                }
            }
        }
        .navigationTitle("By Chat").modifier(DataBrowserSearch(text: $search))
        .task { if model.catalog == nil { model.loadCatalog(environment: environment, commitEdits: commitEdits) } }
        .modifier(DataSelectionControls(isSelecting: $selecting, selection: $selected, ids: Set(chats.map(\.id))) {
            DataDestructiveButton("Delete Selected", progressMessage: model.progressMessage(for: .deleteChats)) {
                guard let catalog = model.catalog else { return }
                request = DataMaintenanceRequest(mutation: .deleteChats(selected), revision: catalog.revision,
                    title: String(localized: "Delete Chats"), detail: String(localized: "Selected chats and all their branches and attachments will be removed."))
            }.disabled(selected.isEmpty)
        })
        .modifier(DataMaintenanceControls(model: model, request: $request, commitEdits: commitEdits, onCompletion: { selected.removeAll() }))
    }

    private func chatLabel(_ chat: DataStorageChat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chat.title).lineLimit(2)
            Text(storageSize(chat.bytes) + " · " + String(localized: "Messages") + " " + chat.messageCount.formatted())
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DataChatStorageDetail: View {
    @Environment(\.dismiss) private var dismiss
    let chat: DataStorageChat
    @ObservedObject var model: DataManagementModel
    let commitEdits: () -> Void
    @State private var request: DataMaintenanceRequest?

    private var currentChat: DataStorageChat {
        model.catalog?.chats.first { $0.id == chat.id } ?? chat
    }

    var body: some View {
        Form {
            Section {
                Text(chat.title).textSelection(.enabled)
                LabeledContent("Stored Content", value: storageSize(currentChat.bytes))
                LabeledContent("Messages and Other Chat Data", value: storageSize(currentChat.bytes - currentChat.imageBytes - currentChat.contextBytes))
                LabeledContent("Images", value: storageSize(currentChat.imageBytes))
                LabeledContent("Request Snapshots and Continuation Data", value: storageSize(currentChat.contextBytes))
                LabeledContent("Messages", value: currentChat.messageCount.formatted())
                NavigationLink("Preview Chat") {
                    DataChatPreviewView(chat: chat, revision: model.catalog?.revision)
                }
            }
            Section("Messages") {
                let messages = (model.catalog?.messages ?? []).filter { $0.sessionID == chat.id }.sorted { $0.date < $1.date }
                if model.catalog != nil, messages.isEmpty {
                    Text("No Messages").foregroundStyle(.secondary)
                }
                ForEach(messages) { message in
                    NavigationLink {
                        DataStoredMessageView(message: message, model: model, commitEdits: commitEdits)
                    } label: {
                        HStack { Text(message.title).lineLimit(2); Spacer(); Text(storageSize(message.bytes)).foregroundStyle(.secondary) }
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle("Chat Storage")
        .modifier(DataActionControls {
            DataDestructiveButton("Delete Chat", progressMessage: model.progressMessage(for: .deleteChats)) {
                guard let revision = model.catalog?.revision else { return }
                request = DataMaintenanceRequest(mutation: .deleteChats([chat.id]), revision: revision,
                    title: String(localized: "Delete Chat"), detail: String(localized: "Selected chats and all their branches and attachments will be removed."))
            }
        })
        .modifier(DataMaintenanceControls(model: model, request: $request, commitEdits: commitEdits))
        .onChange(of: model.catalog?.revision) { _, _ in
            if model.catalog?.chats.contains(where: { $0.id == chat.id }) == false { dismiss() }
        }
    }
}

struct DataAttachmentMessageList: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: DataManagementModel
    let commitEdits: () -> Void
    @State private var search = ""
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var request: DataMaintenanceRequest?

    private var messages: [DataStorageMessage] {
        (model.catalog?.messages ?? []).filter {
            $0.imageBytes > 0 && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        }.sorted { $0.imageBytes > $1.imageBytes }
    }

    var body: some View {
        List(messages) { message in
            if selecting {
                DataSelectionRow(isSelected: selected.contains(message.id)) {
                    if !selected.insert(message.id).inserted { selected.remove(message.id) }
                } content: { messageLabel(message).allowsHitTesting(false) }
            } else {
                NavigationLink {
                    DataStoredMessageView(message: message, model: model, commitEdits: commitEdits)
                } label: { messageLabel(message) }
            }
        }
        .overlay {
            if model.catalog != nil, messages.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("No Data", systemImage: "photo")
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .navigationTitle("Images and Attachments").modifier(DataBrowserSearch(text: $search))
        .task {
            if model.attachmentThumbnails == nil {
                model.loadCatalog(environment: environment, commitEdits: commitEdits, includeAttachmentThumbnails: true)
            }
        }
        .modifier(DataSelectionControls(isSelecting: $selecting, selection: $selected, ids: Set(messages.map(\.id))) {
            DataDestructiveButton("Delete Selected", progressMessage: model.progressMessage(for: .deleteAttachments)) {
                guard let revision = model.catalog?.revision else { return }
                request = DataMaintenanceRequest(mutation: .deleteAllAttachments(selected), revision: revision,
                    title: String(localized: "Delete Selected Attachments"),
                    detail: String(localized: "All attachments in the selected messages will be deleted. Message text will be kept."))
            }.disabled(selected.isEmpty)
        })
        .modifier(DataMaintenanceControls(model: model, request: $request, commitEdits: commitEdits, onCompletion: { selected.removeAll() }))
    }

    private func messageLabel(_ message: DataStorageMessage) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(message.title.isEmpty ? String(localized: "Images") : message.title)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(storageSize(message.imageBytes)).font(.caption).foregroundStyle(.secondary)
                if let title = model.catalog?.chats.first(where: { $0.id == message.sessionID })?.title {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            thumbnails(for: message.id)
        }.frame(minHeight: 60)
    }

    private var thumbnailColumns: Int {
        #if os(iOS)
        horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize ? 1 : 3
        #else
        3
        #endif
    }

    @ViewBuilder
    private func thumbnails(for id: UUID) -> some View {
        if let thumbnails = model.attachmentThumbnails?[id], !thumbnails.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(thumbnails) { thumbnail in
                        Group {
                            if let image = thumbnail.image {
                                Image(decorative: image, scale: 1).resizable().scaledToFill()
                            } else { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
                        }.frame(width: 52, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(width: CGFloat(min(thumbnails.count, thumbnailColumns)) * 58 - 6, height: 60)
            #if os(iOS)
            .overlay(alignment: .bottomTrailing) {
                if thumbnails.count > thumbnailColumns {
                    Text(thumbnails.count.formatted())
                        .font(.caption2.bold()).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .allowsHitTesting(false)
                }
            }
            #endif
            .accessibilityLabel("Images and Attachments")
            .accessibilityValue(thumbnails.count.formatted())
        } else if model.progress?.kind == .loadCatalog {
            ProgressView().frame(width: 52, height: 52).accessibilityLabel("Loading…")
        } else {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary).frame(width: 52, height: 52)
        }
    }
}

private struct DataStoredMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    let message: DataStorageMessage

    private var currentMessage: DataStorageMessage {
        model.catalog?.messages.first { $0.id == message.id } ?? message
    }
    @ObservedObject var model: DataManagementModel
    let commitEdits: () -> Void
    @State private var details: DataMessageDetails?
    @State private var error: String?
    @State private var selected: Set<UUID> = []
    @State private var request: DataMaintenanceRequest?

    var body: some View {
        Form {
            Section("Storage Used") {
                LabeledContent("Stored Content", value: storageSize(currentMessage.bytes))
                LabeledContent("Messages and Other Chat Data", value: storageSize(currentMessage.bytes - currentMessage.imageBytes - currentMessage.contextBytes))
                LabeledContent("Images", value: storageSize(currentMessage.imageBytes))
                LabeledContent("Request Snapshots and Continuation Data", value: storageSize(currentMessage.contextBytes))
            }
            Section("Message") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message.date, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                    if let name = message.model { Text(name).font(.caption).foregroundStyle(.secondary) }
                    RichMarkdownView(markdown: details?.content ?? message.title)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Images and Attachments") {
                if let details {
                    if let problem = details.attachmentIssue {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else if details.attachments.isEmpty {
                        Text("No Data").foregroundStyle(.secondary)
                    }
                    ForEach(details.attachments.sorted { $0.data.count > $1.data.count }) { attachment in
                        DataSelectionRow(isSelected: selected.contains(attachment.id)) {
                            if !selected.insert(attachment.id).inserted { selected.remove(attachment.id) }
                        } content: {
                            DataAttachmentPreview(attachment: attachment)
                        }.padding(.vertical, 6)
                    }

                } else if let error { Text(error).foregroundStyle(.red) }
                else { ProgressView() }
            }
            if currentMessage.contextBytes > 0 {
                Section("Request Snapshots and Continuation Data") {
                    Text(storageSize(currentMessage.contextBytes))
                    DataDestructiveButton("Delete Request Snapshots and Continuation Data", progressMessage: model.progressMessage(for: .clearContext)) {
                        guard let revision = model.catalog?.revision else { return }
                        request = DataMaintenanceRequest(mutation: .clearContext([message.id]), revision: revision,
                            title: String(localized: "Delete Request Snapshots and Continuation Data"), detail: String(localized: "This will delete the selected request snapshots and continuation data."))
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle("Message Details")
        .modifier(DataActionControls(isVisible: details?.attachments.isEmpty == false) {
            if let details, !details.attachments.isEmpty {
                DataSelectAllButton(ids: Set(details.attachments.map(\.id)), selection: $selected)
                DataDestructiveButton("Delete Selected", progressMessage: model.progressMessage(for: .deleteAttachments)) {
                    guard let revision = model.catalog?.revision else { return }
                    request = DataMaintenanceRequest(mutation: .deleteAttachments(messageID: message.id, attachmentIDs: selected), revision: revision,
                        title: String(localized: "Delete Selected Attachments"), detail: String(localized: "Selected image attachments will be removed from this message."))
                }.disabled(selected.isEmpty)
            }
        })
        .modifier(DataMaintenanceControls(model: model, request: $request, commitEdits: commitEdits))
        .task(id: model.catalog?.revision) {
            guard model.catalog?.messages.contains(where: { $0.id == message.id }) != false else {
                dismiss()
                return
            }
            details = nil
            error = nil
            selected.removeAll()
            do {
                let staged = try environment.stageDataManagementRead()
                defer { staged.discard() }
                let id = message.id
                let expected = model.catalog?.revision
                details = try await DataManagementModel.background {
                    let source = staged.directory.appendingPathComponent(staged.contentsName).appendingPathComponent("default.store")
                    guard try AppDataBackup.sourceRevision(at: source) == expected else { throw DataBackupError.dataChanged }
                    return try DataManagementStore.messageDetails(at: source, id: id)
                }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct DataAttachmentPreview: View {
    let attachment: ChatImageAttachment
    @State private var image: CGImage?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxHeight: 300)
            } else if loaded {
                Label("Unable to Preview", systemImage: "photo.badge.exclamationmark")
            } else { ProgressView().frame(height: 120) }
            Text(attachment.mimeType + " · " + storageSize(Int64(attachment.data.count))).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task(id: attachment.id) {
            let data = attachment.data
            image = try? await DataManagementModel.background {
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return Optional<CGImage>.none }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1200
                ] as CFDictionary)
            }
            loaded = true
        }
    }
}

struct DataModelBrowser: View {
    private enum Selection: Hashable {
        case preference(String)
        case context(String)
    }

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: DataManagementModel
    let commitEdits: () -> Void
    @State private var search = ""
    @State private var selecting = false
    @State private var selected: Set<Selection> = []
    @State private var request: DataMaintenanceRequest?
    @State private var batchRequest: DataMaintenanceRequest?

    private var preferences: [DataModelPreference] {
        (model.catalog?.preferences ?? []).filter { search.isEmpty || $0.key.localizedCaseInsensitiveContains(search) }
    }

    private var contextGroups: [String: [DataStorageMessage]] {
        Dictionary(grouping: model.catalog?.messages.filter { $0.contextBytes > 0 } ?? [],
            by: { $0.model ?? String(localized: "Unknown") })
            .filter { search.isEmpty || $0.key.localizedCaseInsensitiveContains(search) }
    }

    private var selectableIDs: Set<Selection> {
        Set(preferences.map { Selection.preference($0.id) })
            .union(contextGroups.keys.map { Selection.context($0) })
    }

    var body: some View {
        List {
            ForEach(DataModelPreference.Kind.allCases, id: \.self) { kind in
                let items = preferences.filter { $0.kind == kind }
                Section {
                    if model.catalog != nil, items.isEmpty {
                        Text(search.isEmpty ? LocalizedStringKey("No Data") : LocalizedStringKey("No Results"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        if selecting {
                            DataSelectionRow(isSelected: selected.contains(.preference(item.id))) {
                                toggleSelection(.preference(item.id))
                            } content: { preferenceLabel(item) }
                        } else {
                            NavigationLink {
                                Form {
                                    Text(item.key).textSelection(.enabled)
                                    if item.kind == .endpoint { LabeledContent("Source", value: item.source) }
                                    Text(item.displayValue).textSelection(.enabled)
                                    DataDestructiveButton("Delete Setting", progressMessage: model.progressMessage(for: .deletePreference)) {
                                        guard let revision = model.catalog?.revision else { return }
                                        request = DataMaintenanceRequest(mutation: .deletePreference(item), revision: revision,
                                            title: String(localized: "Delete Setting"), detail: String(localized: "This will delete the selected setting."))
                                    }
                                }.formStyle(.grouped).navigationTitle(item.kind.title)
                                .modifier(DataMaintenanceControls(model: model, request: $request, commitEdits: commitEdits, dismissOnCompletion: true))
                            } label: { preferenceLabel(item) }
                        }
                    }
                } header: {
                    selectionHeader(kind.title, ids: Set(items.map { Selection.preference($0.id) }))
                }
            }
            Section {
                let groups = contextGroups
                let names = groups.keys.sorted()
                if model.catalog != nil, names.isEmpty {
                    Text(search.isEmpty ? LocalizedStringKey("No Data") : LocalizedStringKey("No Results"))
                        .foregroundStyle(.secondary)
                }
                ForEach(names, id: \.self) { name in
                    let items = groups[name] ?? []
                    if selecting {
                        DataSelectionRow(isSelected: selected.contains(.context(name))) {
                            toggleSelection(.context(name))
                        } content: { contextLabel(name, messages: items) }
                    } else {
                        NavigationLink {
                            Form {
                                Text(name)
                                Text(storageSize(items.reduce(0) { $0 + $1.contextBytes }))
                                DataDestructiveButton("Delete Request Snapshots and Continuation Data", progressMessage: model.progressMessage(for: .clearContext)) {
                                    guard let revision = model.catalog?.revision else { return }
                                    request = DataMaintenanceRequest(mutation: .clearContext(Set(items.map(\.id))), revision: revision,
                                        title: String(localized: "Delete Request Snapshots and Continuation Data"), detail: String(localized: "This will delete the selected request snapshots and continuation data.") + "\n" + String(localized: "Applies to this model across all servers."))
                                }
                            }.formStyle(.grouped).navigationTitle("Request Snapshots and Continuation Data")
                            .modifier(DataMaintenanceControls(model: model, request: $request, commitEdits: commitEdits, dismissOnCompletion: true))
                        } label: { contextLabel(name, messages: items) }
                    }
                }
            } header: {
                selectionHeader(String(localized: "Request Snapshots and Continuation Data"),
                    ids: Set(contextGroups.keys.map { Selection.context($0) }))
            }
        }.navigationTitle("Model Data").modifier(DataBrowserSearch(text: $search))
        .task { if model.catalog == nil { model.loadCatalog(environment: environment, commitEdits: commitEdits) } }
        .modifier(DataSelectionControls(isSelecting: $selecting, selection: $selected, ids: selectableIDs) {
            DataDestructiveButton("Delete Selected", progressMessage: model.progressMessage(for: .deleteModelData)) {
                guard let revision = model.catalog?.revision else { return }
                let selectedPreferences = preferences.filter { selected.contains(.preference($0.id)) }
                let messageIDs = Set(contextGroups.filter { selected.contains(.context($0.key)) }.values.flatMap { $0.map(\.id) })
                var descriptions: [String] = []
                if !selectedPreferences.isEmpty { descriptions.append(String(localized: "The selected model settings will be deleted.")) }
                if !messageIDs.isEmpty { descriptions.append(String(localized: "Request snapshots and continuation data will be deleted for the selected models across all servers.")) }
                guard !descriptions.isEmpty else { return }
                batchRequest = DataMaintenanceRequest(mutation: .deleteModelData(preferences: selectedPreferences, contextMessageIDs: messageIDs),
                    revision: revision, title: String(localized: "Delete Selected"), detail: descriptions.joined(separator: "\n"))
            }.disabled(selected.isEmpty)
        })
        .modifier(DataMaintenanceControls(model: model, request: $batchRequest, commitEdits: commitEdits, onCompletion: { selected.removeAll() }))
    }

    private func toggleSelection(_ id: Selection) {
        if !selected.insert(id).inserted { selected.remove(id) }
    }

    private func selectionHeader(_ title: String, ids: Set<Selection>) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selecting {
                DataSelectAllButton(ids: ids, selection: $selected)
                    .buttonStyle(.borderless)
            }
        }
        .textCase(nil)
    }

    private func preferenceLabel(_ item: DataModelPreference) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.key).lineLimit(2)
            Text(item.kind == .endpoint ? item.source + " · " + item.displayValue : item.displayValue)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func contextLabel(_ name: String, messages: [DataStorageMessage]) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(storageSize(messages.reduce(0) { $0 + $1.contextBytes })).foregroundStyle(.secondary)
        }
    }
}

struct DataCleanupReviewView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: DataManagementModel
    let commitEdits: () -> Void

    var body: some View {
        Form {
            Section {
                Text("Check database records and unused files in the app’s database folder.").foregroundStyle(.secondary)
                Button { model.scanData(environment: environment, commitEdits: commitEdits) } label: {
                    DataOperationButtonLabel(title: "Check Data", progressMessage: model.progressMessage(for: .scanData))
                }
            }
            if let files = model.unusedFiles {
                Section("Unused Files") {
                    if files.isEmpty {
                        Label("No Unused Files Found", systemImage: "checkmark.circle")
                    } else {
                        NavigationLink {
                            DataUnusedFilesView(model: model)
                        } label: {
                            HStack {
                                Text("Review Unused Files")
                                Spacer()
                                Text(files.count.formatted() + " · " + storageSize(files.reduce(0) { $0 + $1.bytes }))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let report = model.cleanupReport {
                Section("Database Issues") {
                    if report.issues.isEmpty {
                        if report.unreadableCategories.isEmpty {
                            Label("No Database Issues Found", systemImage: "checkmark.circle")
                        } else {
                            Label("Incomplete Check", systemImage: "exclamationmark.triangle")
                        }
                    } else {
                        Label("Records to Review", systemImage: "text.bubble")
                    }
                    ForEach(Array(Set(report.issues.map(\.reason))).sorted { $0.rawValue < $1.rawValue }, id: \.self) { reason in
                        let issues = report.issues.filter { $0.reason == reason }
                        NavigationLink {
                            DataCleanupIssueList(initialIssues: issues, initialRevision: report.revision, model: model, commitEdits: commitEdits)
                        } label: { HStack { Text(reason.title); Spacer(); Text(issues.count.formatted()).foregroundStyle(.secondary) } }
                    }
                    ForEach(report.unreadableCategories, id: \.self) { name in
                        LabeledContent("Incomplete Check", value: name)
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle("Data Cleanup")
        .modifier(DataMaintenanceControls(model: model, request: .constant(nil), commitEdits: commitEdits))
    }
}

private struct DataUnusedFilesView: View {
    @ObservedObject var model: DataManagementModel
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var pendingDeletion: [DataUnusedFile] = []
    private var files: [DataUnusedFile] { model.unusedFiles ?? [] }

    var body: some View {
        List {
            Section {
                Text("These files are not used by the current app.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if files.isEmpty, model.unusedFiles != nil {
                    Label("No Unused Files Found", systemImage: "checkmark.circle")
                }
                ForEach(files) { file in
                    if selecting {
                        DataSelectionRow(isSelected: selected.contains(file.id)) {
                            if !selected.insert(file.id).inserted { selected.remove(file.id) }
                        } content: { fileLabel(file) }
                    } else {
                        fileLabel(file)
                    }
                }
            }
        }
        .navigationTitle("Unused Files")
        .modifier(DataSelectionControls(isSelecting: $selecting, selection: $selected, ids: Set(files.map(\.id))) {
            Button {
                model.exportUnusedFiles(files.filter { selected.contains($0.id) })
            } label: {
                DataOperationButtonLabel(title: "Export Selected", systemImage: "square.and.arrow.up",
                    progressMessage: model.progressMessage(for: .exportUnusedFiles))
            }.disabled(selected.isEmpty)
            DataDestructiveButton("Delete Selected", progressMessage: model.progressMessage(for: .deleteUnusedFiles)) {
                pendingDeletion = files.filter { selected.contains($0.id) }
            }.disabled(selected.isEmpty)
        })
        .modifier(DataExportPresentation(model: model, source: .unusedFiles))
        .disabled(model.isBusy)
        .alert("Confirm deletion?", isPresented: Binding(
            get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }
        )) {
            Button("Delete", role: .destructive) {
                model.deleteUnusedFiles(pendingDeletion)
                pendingDeletion = []
                selected.removeAll()
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text("The selected files and folder contents will be permanently deleted. This cannot be undone.")
        }
        .alert("Data Management", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onChange(of: files.map(\.id)) { _, ids in selected.formIntersection(Set(ids)) }
    }

    private func fileLabel(_ file: DataUnusedFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.id)
                Text("Application Support/" + file.id).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(storageSize(file.bytes)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DataDestructiveButton: View {
    let title: LocalizedStringKey
    let progressMessage: String?
    let action: () -> Void

    init(_ title: LocalizedStringKey, progressMessage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.progressMessage = progressMessage
        self.action = action
    }

    var body: some View {
        #if os(iOS)
        Button(role: .destructive, action: action) {
            DataOperationButtonLabel(title: title, systemImage: "trash", progressMessage: progressMessage)
        }
        .tint(.red)
        #else
        Button(role: .destructive, action: action) {
            DataOperationButtonLabel(title: title, progressMessage: progressMessage)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        #endif
    }
}

private struct DataSelectAllButton<ID: Hashable>: View {
    let ids: Set<ID>
    @Binding var selection: Set<ID>

    private var allSelected: Bool {
        !ids.isEmpty && ids.isSubset(of: selection)
    }

    var body: some View {
        Button(allSelected ? LocalizedStringKey("Deselect All") : LocalizedStringKey("Select All")) {
            if allSelected {
                selection.subtract(ids)
            } else {
                selection.formUnion(ids)
            }
        }
        .disabled(ids.isEmpty)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

private struct DataSelectionRow<Content: View>: View {
    @ScaledMetric(relativeTo: .title3) private var indicatorSize = 28
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: indicatorSize, height: indicatorSize)
                    .accessibilityHidden(true)
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
            .frame(minHeight: 44)
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DataSelectionControls<ID: Hashable, Actions: View>: ViewModifier {
    @Binding var isSelecting: Bool
    @Binding var selection: Set<ID>
    let ids: Set<ID>
    @ViewBuilder let actions: () -> Actions

    private var selectionButton: some View {
        Button(isSelecting ? LocalizedStringKey("Done") : LocalizedStringKey("Select")) {
            isSelecting.toggle()
            selection.removeAll()
        }
        .disabled(ids.isEmpty && !isSelecting)
    }

    func body(content: Content) -> some View {
        selectionContent(content)
            .onChange(of: ids) { _, ids in selection.formIntersection(ids) }
    }

    @ViewBuilder
    private func selectionContent(_ content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) { selectionButton }
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting { DataSelectAllButton(ids: ids, selection: $selection) }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if isSelecting {
                    Text("\(selection.count) Selected")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    actions().labelStyle(.iconOnly)
                }
            }
        }
        #else
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            DataBrowserActionBar {
                if isSelecting {
                    DataSelectAllButton(ids: ids, selection: $selection)
                    actions()
                }
                selectionButton
            }
        }
        #endif
    }
}

private struct DataActionControls<Actions: View>: ViewModifier {
    var isVisible = true
    @ViewBuilder let actions: () -> Actions

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if isVisible { actions() }
            }
        }
        #else
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if isVisible { DataBrowserActionBar { actions() } }
        }
        #endif
    }
}

private struct DataBrowserActionBar<Actions: View>: View {
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actions() }
            VStack(alignment: .trailing, spacing: 12) { actions() }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding()
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct DataChatPreviewView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let chat: DataStorageChat
    let revision: SHA256.Digest?
    @State private var preview: DataChatPreview?
    @State private var selectedBranch: UUID?
    @State private var error: String?

    var body: some View {
        Group {
            if let preview {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if preview.branches.count > 1 {
                            Picker("Branch", selection: $selectedBranch) {
                                ForEach(Array(preview.branches.enumerated()), id: \.element.id) { index, branch in
                                    Text("\(index + 1) · \(branch.title)").tag(Optional(branch.id))
                                }
                            }.pickerStyle(.menu)
                        }
                        let branch = preview.branches.first { $0.id == selectedBranch }
                        let messages = branch?.messageIDs.compactMap { preview.messages[$0] } ?? []
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(message.isUser ? LocalizedStringKey("You") : LocalizedStringKey("Assistant")).font(.headline)
                                    Spacer()
                                    Text(message.date, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                                }
                                if let reasoning = message.reasoning {
                                    DisclosureGroup("Thinking") { RichMarkdownView(markdown: reasoning) }
                                        .foregroundStyle(.secondary)
                                }
                                RichMarkdownView(markdown: message.content)
                                ForEach(message.problems, id: \.self) { problem in
                                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(message.attachments) { DataAttachmentPreview(attachment: $0) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                        if messages.isEmpty { ContentUnavailableView("No Messages", systemImage: "bubble.left") }
                    }.padding(20)
                }
            } else if let error { ContentUnavailableView("Unable to Preview", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.navigationTitle(chat.title)
        .task(id: revision) {
            error = nil
            do {
                let staged = try environment.stageDataManagementRead()
                defer { staged.discard() }
                let id = chat.id
                let expected = revision
                let result = try await DataManagementModel.background {
                    let source = staged.directory.appendingPathComponent(staged.contentsName).appendingPathComponent("default.store")
                    guard try AppDataBackup.sourceRevision(at: source) == expected else { throw DataBackupError.dataChanged }
                    return try DataManagementStore.chatPreview(at: source, id: id)
                }
                preview = result
                if !result.branches.contains(where: { $0.id == selectedBranch }) {
                    selectedBranch = result.branches.first(where: { $0.id == result.activeLeafID })?.id ?? result.branches.first?.id
                }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct DataCleanupIssueList: View {
    let initialIssues: [DataRecoveryIssue]
    let initialRevision: SHA256.Digest

    private var issues: [DataRecoveryIssue] {
        model.cleanupReport?.issues.filter { $0.reason == initialIssues.first?.reason } ?? initialIssues
    }
    private var revision: SHA256.Digest { model.cleanupReport?.revision ?? initialRevision }
    @ObservedObject var model: DataManagementModel
    let commitEdits: () -> Void
    @State private var selected: Set<String> = []
    @State private var selecting = false
    @State private var request: DataMaintenanceRequest?

    private var selection: [DataRecoveryIssue] { issues.filter { selected.contains($0.id) } }

    var body: some View {
        List {
            if let issue = issues.first { Section { Text(issue.explanation).foregroundStyle(.secondary) } }
            Section {
                if issues.isEmpty {
                    Label("No Database Issues Found", systemImage: "checkmark.circle")
                }
                ForEach(issues) { issue in
                    if selecting {
                        DataSelectionRow(isSelected: selected.contains(issue.id)) {
                            if !selected.insert(issue.id).inserted { selected.remove(issue.id) }
                        } content: { issueLabel(issue) }
                        .disabled(!issue.canDelete)
                    } else {
                        NavigationLink {
                            DataCleanupIssueView(issue: issue, revision: revision, model: model, commitEdits: commitEdits)
                        } label: { issueLabel(issue) }
                    }
                }
            }
        }.navigationTitle(issues.first?.reason.title ?? String(localized: "Issues Found"))
        .modifier(DataSelectionControls(isSelecting: $selecting, selection: $selected, ids: Set(issues.filter(\.canDelete).map(\.id))) {
            if issues.first?.reason == .ownership {
                Button {
                    request = DataMaintenanceRequest(mutation: .recoverUnowned(Set(selection.compactMap(\.recordID))), revision: revision,
                        title: String(localized: "Recover Selected Messages"), detail: String(localized: "The selected messages and their related history will be restored as separate chats."))
                } label: {
                    DataOperationButtonLabel(title: "Recover Selected Messages", systemImage: "arrow.uturn.backward",
                        progressMessage: model.progressMessage(for: .recoverMessages))
                }.disabled(selection.isEmpty || selection.contains { $0.entity != "ChatMessage" })
            }
            DataDestructiveButton("Delete Selected", progressMessage: model.progressMessage(for: .deleteIssues)) {
                request = DataMaintenanceRequest(mutation: .deleteIssues(selection), revision: revision,
                    title: String(localized: "Delete Selected Records"), detail: String(localized: "Selected records will be deleted. Deleting a chat includes all its messages; deleting a message includes its later replies in every branch."))
            }.disabled(selection.isEmpty)
        })
        .modifier(DataMaintenanceControls(model: model, request: $request, commitEdits: commitEdits, onCompletion: { selected.removeAll() }))
    }

    private func issueLabel(_ issue: DataRecoveryIssue) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(issue.name).lineLimit(2)
            ForEach(issue.fields, id: \.self) { field in
                Text(DataRecoveryIssue.fieldTitle(field) + ": " + (issue.fieldProblems[field] ?? issue.explanation))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let date = issue.date { Text(date, format: .dateTime).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct DataCleanupIssueView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let initialIssue: DataRecoveryIssue
    let initialRevision: SHA256.Digest
    @ObservedObject var model: DataManagementModel
    let commitEdits: () -> Void
    @State private var content: String?
    @State private var error: String?
    @State private var request: DataMaintenanceRequest?

    init(issue: DataRecoveryIssue, revision: SHA256.Digest, model: DataManagementModel, commitEdits: @escaping () -> Void) {
        initialIssue = issue
        initialRevision = revision
        self.model = model
        self.commitEdits = commitEdits
    }

    private var issue: DataRecoveryIssue {
        model.cleanupReport?.issues.first { $0.id == initialIssue.id } ?? initialIssue
    }
    private var revision: SHA256.Digest { model.cleanupReport?.revision ?? initialRevision }

    var body: some View {
        Form {
            Section(issue.reason.title) {
                Text(issue.explanation)
                ForEach(issue.fields, id: \.self) { field in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(DataRecoveryIssue.fieldTitle(field)).font(.headline)
                        if let explanation = issue.fieldProblems[field] { Text(explanation).foregroundStyle(.secondary) }
                        Text(field).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Section("Message") {
                if let date = issue.date { Text(date, format: .dateTime).font(.caption).foregroundStyle(.secondary) }
                Text(content ?? issue.name).textSelection(.enabled)
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section {
                if issue.reason == .ownership, let id = issue.recordID, issue.entity == "ChatMessage" {
                    Button {
                        request = DataMaintenanceRequest(mutation: .recoverUnowned([id]), revision: revision,
                            title: String(localized: "Recover as a Separate Chat"), detail: String(localized: "The selected messages and their related history will be restored as separate chats."))
                    } label: {
                        DataOperationButtonLabel(title: "Recover as a Separate Chat", progressMessage: model.progressMessage(for: .recoverMessages))
                    }
                }
                if issue.canDelete {
                    DataDestructiveButton("Delete Record", progressMessage: model.progressMessage(for: .deleteIssues)) {
                        request = DataMaintenanceRequest(mutation: .deleteIssues([issue]), revision: revision,
                            title: String(localized: "Delete Record"), detail: String(localized: "Selected records will be deleted. Deleting a chat includes all its messages; deleting a message includes its later replies in every branch."))
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle("Issue Details")
        .modifier(DataMaintenanceControls(model: model, request: $request, commitEdits: commitEdits))
        .task(id: revision) {
            guard model.cleanupReport?.issues.contains(where: { $0.id == initialIssue.id }) != false else {
                dismiss()
                return
            }
            error = nil
            do {
                let staged = try environment.stageDataManagementRead()
                defer { staged.discard() }
                let issue = issue
                let expected = revision
                content = try await DataManagementModel.background {
                    let source = staged.directory.appendingPathComponent(staged.contentsName).appendingPathComponent("default.store")
                    guard try AppDataBackup.sourceRevision(at: source) == expected else { throw DataBackupError.dataChanged }
                    return try DataManagementStore.issueContent(at: source, issue: issue)
                }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
