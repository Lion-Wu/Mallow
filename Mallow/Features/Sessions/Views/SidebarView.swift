//
//  SidebarView.swift
//  Mallow
//
//  Created by Lion Wu on 2024.11.04.
//

import Combine
import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var chatSessionsViewModel: ChatSessionsViewModel

    var onConversationTap: (ChatSession) -> Void
    var onOpenSettings: () -> Void

    @State private var renamingSession: ChatSession? = nil
    @State private var newTitle: String = ""
    @State private var searchText: String = ""
    // Query that produced the currently visible sidebar results; it intentionally lags searchText during debounce.
    @State private var visibleSearchKeyword: String = ""
    @State private var sidebarGroups: [SidebarSessionGroup] = []
    @State private var appliedCalendarConfiguration: SidebarCalendarConfiguration?
    @State private var isSidebarSearchLoading: Bool = false
    @State private var sidebarSearchRefreshTask: Task<Void, Never>? = nil
    @State private var sidebarSelectionID: UUID?
    @FocusState private var isRenameFieldFocused: Bool

    // Deletion confirmation
    @State private var showDeleteChatAlert: Bool = false
    @State private var pendingDeleteSessionIDs: [UUID] = []

    private static let sidebarSearchDebounceNanoseconds: UInt64 = 180_000_000
    private static let sidebarSearchBatchSize: Int = 12

    private var searchKeyword: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedRenameTitle: String {
        newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowSidebarSearchLoading: Bool {
        isSidebarSearchLoading && !searchKeyword.isEmpty
    }

    private var shouldShowInitialSessionLoading: Bool {
        SidebarSessionListLoadState.resolve(
            isPersistentStoreAttached: chatSessionsViewModel.isPersistentStoreAttached,
            hasSessions: !chatSessionsViewModel.chatSessions.isEmpty,
            hasPublishedGroups: !sidebarGroups.isEmpty,
            visibleSearchKeyword: visibleSearchKeyword
        ) == .loading
    }

    private var isSidebarSearchActive: Bool {
        !searchKeyword.isEmpty
    }

    private var appDisplayName: String {
        Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
        ?? Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
        ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
        ?? "Mallow"
    }

    @ViewBuilder
    private var sidebarSearchLoadingRow: some View {
        sidebarLoadingRow(title: "Searching...")
    }

    @ViewBuilder
    private var sidebarInitialLoadingRow: some View {
        sidebarLoadingRow(title: "Loading...")
    }

    private func sidebarLoadingRow(title: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, sidebarRowVerticalPadding)
    }

    @ViewBuilder
    private var sidebarSearchLoadingSection: some View {
        if shouldShowSidebarSearchLoading {
            Section {
                sidebarSearchLoadingRow
            }
        }
    }

    var body: some View {
        Group {
            #if os(macOS)
            macSidebar
            #elseif os(visionOS)
            visionSidebar
            #else
            iosSidebar
            #endif
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        .alert("Rename Chat",
               isPresented: renameAlertBinding) {
            TextField("New Title", text: $newTitle)
            Button("Cancel", role: .cancel) {
                dismissRenameSheet()
            }
            Button("Save") {
                commitRename()
            }
            .disabled(trimmedRenameTitle.isEmpty)
        }
        #endif
        .alert("Delete chat?",
               isPresented: $showDeleteChatAlert) {
            Button("Delete", role: .destructive) {
                let indexes = Set(pendingDeleteSessionIDs.compactMap { sessionID in
                    chatSessionsViewModel.chatSessions.firstIndex(where: { $0.id == sessionID })
                })
                if !indexes.isEmpty {
                    let offsets = IndexSet(indexes)
                    chatSessionsViewModel.deleteSession(at: offsets)
                }
                pendingDeleteSessionIDs.removeAll()
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteSessionIDs.removeAll()
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .onAppear {
            scheduleSidebarSearchRefresh(debounce: false)
        }
        .onReceive(chatSessionsViewModel.$chatSessions) { _ in
            scheduleSidebarSearchRefresh(debounce: !searchKeyword.isEmpty)
        }
        .onReceive(chatSessionsViewModel.sidebarContentDidChange) {
            scheduleSidebarSearchRefresh(debounce: !searchKeyword.isEmpty)
        }
        .onChange(of: searchText) { _, _ in
            scheduleSidebarSearchRefresh(debounce: !searchKeyword.isEmpty)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            refreshSidebarGroupsForSystemCalendarChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            refreshSidebarGroupsForSystemCalendarChange()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refreshSidebarGroupsIfCalendarConfigurationChanged()
        }
        .onDisappear {
            sidebarSearchRefreshTask?.cancel()
            sidebarSearchRefreshTask = nil
        }
    }

    private func refreshSidebarGroupsForSystemCalendarChange() {
        scheduleSidebarSearchRefresh(
            debounce: false,
            calendar: .autoupdatingCurrent
        )
    }

    private func refreshSidebarGroupsIfCalendarConfigurationChanged() {
        let calendar = Calendar.autoupdatingCurrent
        guard SidebarCalendarConfiguration.needsRefresh(
            applied: appliedCalendarConfiguration,
            calendar: calendar
        ) else {
            return
        }
        scheduleSidebarSearchRefresh(debounce: false, calendar: calendar)
    }

    private func scheduleSidebarSearchRefresh(
        debounce: Bool,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        let requestedKeyword = searchKeyword
        let requestedCalendarConfiguration = SidebarCalendarConfiguration(calendar: calendar)
        let shouldDebounce = debounce && !requestedKeyword.isEmpty
        sidebarSearchRefreshTask?.cancel()
        sidebarSearchRefreshTask = Task { @MainActor in
            if shouldDebounce {
                try? await Task.sleep(nanoseconds: Self.sidebarSearchDebounceNanoseconds)
                guard !Task.isCancelled else { return }
            }

            let normalizedQuery = chatSessionsViewModel.normalizedSidebarSearchQuery(requestedKeyword)
            if normalizedQuery.isEmpty {
                isSidebarSearchLoading = false
                publishSidebarGroups(
                    SidebarSessionGrouping.groupedSessions(
                        chatSessionsViewModel.chatSessions,
                        calendar: calendar
                    )
                )
                appliedCalendarConfiguration = requestedCalendarConfiguration
                visibleSearchKeyword = requestedKeyword
                return
            }

            let candidates = chatSessionsViewModel.chatSessions
            var matchedSessions: [ChatSession] = []
            isSidebarSearchLoading = !candidates.isEmpty

            var startIndex = 0
            while startIndex < candidates.count {
                guard !Task.isCancelled else { return }

                let endIndex = min(startIndex + Self.sidebarSearchBatchSize, candidates.count)
                let batch = Array(candidates[startIndex..<endIndex])
                let newMatches = chatSessionsViewModel.sessions(
                    in: batch,
                    matchingNormalizedSidebarQuery: normalizedQuery
                )

                if !newMatches.isEmpty {
                    matchedSessions.append(contentsOf: newMatches)
                }

                startIndex = endIndex
                isSidebarSearchLoading = startIndex < candidates.count
                await Task.yield()
            }

            guard !Task.isCancelled else { return }
            isSidebarSearchLoading = false
            publishSidebarGroups(
                SidebarSessionGrouping.groupedSessions(
                    matchedSessions,
                    calendar: calendar
                )
            )
            appliedCalendarConfiguration = requestedCalendarConfiguration
            visibleSearchKeyword = requestedKeyword
        }
    }

    private func publishSidebarGroups(_ proposed: [SidebarSessionGroup]) {
        guard !SidebarSessionGrouping.hasSameLayout(
            sidebarGroups,
            as: proposed
        ) else {
            return
        }
        sidebarGroups = proposed
    }

    // MARK: - Swipe Delete Hook

    private func handleSwipeDelete(at offsets: IndexSet, within sessions: [ChatSession]) {
        let sessionIDs = offsets.compactMap { offset -> UUID? in
            guard offset < sessions.count else { return nil }
            return sessions[offset].id
        }
        requestDelete(for: sessionIDs)
    }

    private func requestDelete(for session: ChatSession) {
        requestDelete(for: [session.id])
    }

    private func requestDelete(for sessionIDs: [UUID]) {
        var seen = Set<UUID>()
        let uniqueIDs = sessionIDs.filter { seen.insert($0).inserted }
        guard !uniqueIDs.isEmpty else { return }
        pendingDeleteSessionIDs = uniqueIDs
        showDeleteChatAlert = true
    }

    // MARK: - Rename

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renamingSession != nil },
            set: { isPresented in
                if !isPresented {
                    dismissRenameSheet()
                }
            }
        )
    }

    private func renamePopoverBinding(for session: ChatSession) -> Binding<Bool> {
        Binding(
            get: { renamingSession?.id == session.id },
            set: { isPresented in
                if !isPresented, renamingSession?.id == session.id {
                    dismissRenameSheet()
                }
            }
        )
    }

    @ViewBuilder
    private func renameSheetView() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Chat")
                .font(.headline)
            TextField("New Title", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .focused($isRenameFieldFocused)
                .onSubmit(commitRename)
            HStack {
                Button("Cancel") {
                    dismissRenameSheet()
                }
                Spacer()
                Button("Save") {
                    commitRename()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedRenameTitle.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            isRenameFieldFocused = true
        }
    }

    private func renameSession(_ session: ChatSession) {
        renamingSession = session
        newTitle = session.title
    }

    private func dismissRenameSheet() {
        renamingSession = nil
        newTitle = ""
        isRenameFieldFocused = false
    }

    private func commitRename() {
        guard let session = renamingSession else {
            dismissRenameSheet()
            return
        }

        let title = trimmedRenameTitle
        guard !title.isEmpty else { return }

        chatSessionsViewModel.renameSession(session, to: title, reason: .immediate)
        dismissRenameSheet()
    }

    private func selectDraftSession() {
        guard chatSessionsViewModel.canStartNewSession else { return }
        let draft = chatSessionsViewModel.draftSession
        chatSessionsViewModel.selectedSession = draft
        onConversationTap(draft)
    }

    private func selectSessionFromSidebar(_ session: ChatSession) {
        chatSessionsViewModel.selectSession(session, matchingSidebarQuery: visibleSearchKeyword)
        onConversationTap(session)
    }

    private func selectMacSession(with sessionID: UUID?) {
        // A single-selection sidebar always has a valid app-level selection.
        // AppKit may transiently write nil while List rows are being reconciled;
        // accepting it would make the detail column fall back to the empty draft.
        guard let sessionID else { return }
        if sessionID == chatSessionsViewModel.draftSession.id {
            chatSessionsViewModel.selectedSession = chatSessionsViewModel.draftSession
            return
        }
        guard let session = chatSessionsViewModel.chatSessions.first(where: { $0.id == sessionID }) else {
            return
        }
        chatSessionsViewModel.selectSession(session, matchingSidebarQuery: visibleSearchKeyword)
    }

    private func synchronizeSidebarSelection(with sessionID: UUID?) {
        guard sidebarSelectionID != sessionID else { return }
        sidebarSelectionID = sessionID
    }

    private func sidebarPreview(for session: ChatSession) -> SidebarSessionPreview {
        chatSessionsViewModel.sidebarPreview(for: session, matchingSearchQuery: visibleSearchKeyword)
    }

    private func sidebarPreviewText(for preview: SidebarSessionPreview) -> Text {
        guard !preview.emphasizedRanges.isEmpty else {
            return Text(verbatim: preview.text)
        }

        var result = Text("")
        var cursor = preview.text.startIndex
        for nsRange in preview.emphasizedRanges {
            guard let range = Range(nsRange, in: preview.text),
                  range.lowerBound >= cursor else {
                continue
            }
            if cursor < range.lowerBound {
                result = result + Text(verbatim: String(preview.text[cursor..<range.lowerBound]))
            }
            result = result + Text(verbatim: String(preview.text[range])).bold()
            cursor = range.upperBound
        }
        if cursor < preview.text.endIndex {
            result = result + Text(verbatim: String(preview.text[cursor..<preview.text.endIndex]))
        }
        return result
    }

    #if os(macOS)
    private var macSidebar: some View {
        let rows = measuredSidebarRows
        return GeometryReader { geometry in
            NativeSidebarList(
                rows: rows,
                selection: $sidebarSelectionID,
                contentInsets: geometry.safeAreaInsets
            ) { sessionID in
                requestDelete(for: [sessionID])
            }
            .ignoresSafeArea()
        }
        .onChange(of: sidebarSelectionID) { _, sessionID in
            selectMacSession(with: sessionID)
        }
        .onChange(of: chatSessionsViewModel.selectedSessionID, initial: true) { _, sessionID in
            synchronizeSidebarSelection(with: sessionID)
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: Text("Search Chats"))
        .safeAreaInset(edge: .bottom) {
            SidebarSettingsFooter(style: .mac, onOpenSettings: onOpenSettings)
        }
    }

    private var measuredSidebarRows: [NativeSidebarRow] {
        let draft = chatSessionsViewModel.draftSession
        var rows = [NativeSidebarRow(id: draft.id, selectionID: draft.id, isGroup: false,
            key: .init(title: "draft"), content: AnyView(macDraftRow))]
        if shouldShowInitialSessionLoading || sidebarGroups.isEmpty {
            rows.append(NativeSidebarRow(id: "chats-header", selectionID: nil, isGroup: true,
                key: .init(title: "chats"), content: AnyView(Text("Chats").font(.caption).foregroundStyle(.secondary))))
            let content: AnyView
            let key: String
            if shouldShowInitialSessionLoading {
                content = AnyView(sidebarInitialLoadingRow); key = "loading"
            } else if visibleSearchKeyword.isEmpty {
                content = AnyView(Text("No chats yet").foregroundStyle(.secondary)); key = "empty"
            } else if shouldShowSidebarSearchLoading {
                content = AnyView(sidebarSearchLoadingRow); key = "searching"
            } else {
                content = AnyView(Text(String(format: NSLocalizedString("No chats match \"%@\"", comment: ""), visibleSearchKeyword))); key = visibleSearchKeyword
            }
            rows.append(NativeSidebarRow(id: "status", selectionID: nil, isGroup: false,
                key: .init(title: key), content: content))
        } else {
            for group in sidebarGroups {
                rows.append(NativeSidebarRow(id: group.id, selectionID: nil, isGroup: true,
                    key: .init(title: String(describing: group.id), calendarDay: Calendar.autoupdatingCurrent.startOfDay(for: Date())), content: AnyView(group.section.title.font(.caption).foregroundStyle(.secondary))))
                for session in group.sessions {
                    rows.append(NativeSidebarRow(id: session.id, selectionID: session.id, isGroup: false,
                        key: .init(title: session.title, preview: sidebarPreview(for: session), isRenaming: renamingSession?.id == session.id),
                        content: AnyView(macSessionRow(session).contextMenu {
                            Button("Rename") { renameSession(session) }
                            Button("Delete", role: .destructive) { requestDelete(for: session) }
                        }), measurementContent: AnyView(macSessionRowContent(session)), canDelete: true))
                }
            }
            if shouldShowSidebarSearchLoading {
                rows.append(NativeSidebarRow(id: "status", selectionID: nil, isGroup: false,
                    key: .init(title: "searching"), content: AnyView(sidebarSearchLoadingRow)))
            }
        }
        return rows
    }
    #endif

    @ViewBuilder
    private var iosSidebarList: some View {
        List {
            if !isSidebarSearchActive {
                Section {
                    NavigationLink(value: ChatSessionNavigationRoute(
                        sessionID: chatSessionsViewModel.draftSession.id
                    )) {
                        iosDraftRowContent
                    }
                    .disabled(!chatSessionsViewModel.canStartNewSession)
                }
            }
            if shouldShowInitialSessionLoading || sidebarGroups.isEmpty {
                Section(LocalizedStringKey("Chats")) {
                    if shouldShowInitialSessionLoading {
                        sidebarInitialLoadingRow
                            .listRowBackground(Color.clear)
                    } else if visibleSearchKeyword.isEmpty {
                        ContentUnavailableView(
                            LocalizedStringKey("No chats yet"),
                            systemImage: "text.bubble",
                            description: Text("Start a new conversation to begin talking.")
                        )
                        .listRowBackground(Color.clear)
                    } else if shouldShowSidebarSearchLoading {
                        sidebarSearchLoadingRow
                            .listRowBackground(Color.clear)
                    } else {
                        ContentUnavailableView(
                            LocalizedStringKey("No Results"),
                            systemImage: "magnifyingglass",
                            description: Text("Try a different search.")
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            } else {
                ForEach(sidebarGroups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            NavigationLink(value: ChatSessionNavigationRoute(
                                sessionID: session.id,
                                searchQuery: visibleSearchKeyword
                            )) {
                                iosSessionRow(session)
                            }
                            .contextMenu {
                                Button("Rename") { renameSession(session) }
                                Button("Delete", role: .destructive) {
                                    requestDelete(for: session)
                                }
                            }
                        }
                        .onDelete { offsets in
                            handleSwipeDelete(at: offsets, within: group.sessions)
                        }
                    } header: {
                        group.section.title
                    }
                }
                sidebarSearchLoadingSection
            }
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    @ViewBuilder
    private var iosSidebar: some View {
        #if os(iOS) || os(tvOS)
        #if os(iOS)
        iosSidebarList
            .listStyle(.insetGrouped)
            .navigationTitle(appDisplayName)
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: Text("Search Chats"))
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .bottomBar) {
                        Button(action: onOpenSettings) {
                            Label("Settings", systemImage: "gear")
                        }
                    }

                    ToolbarSpacer(placement: .bottomBar)

                    DefaultToolbarItem(kind: .search, placement: .bottomBar)

                    ToolbarSpacer(placement: .bottomBar)

                    ToolbarItem(placement: .bottomBar) {
                        Button(action: selectDraftSession) {
                            Label("New Chat", systemImage: "square.and.pencil")
                        }
                        .disabled(!chatSessionsViewModel.canStartNewSession)
                    }
                } else {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(action: onOpenSettings) {
                            Label("Settings", systemImage: "gear")
                        }

                        Spacer()

                        Button(action: selectDraftSession) {
                            Label("New Chat", systemImage: "square.and.pencil")
                        }
                        .disabled(!chatSessionsViewModel.canStartNewSession)
                    }
                }
            }
        #else
        iosSidebarList
            .listStyle(.insetGrouped)
        #endif
        #else
        iosSidebarList
            .listStyle(.plain)
        #endif
    }

    private var visionSidebar: some View {
        List(selection: $sidebarSelectionID) {
            Section {
                iosDraftRow
                    .tag(chatSessionsViewModel.draftSession.id)
            }

            if shouldShowInitialSessionLoading || sidebarGroups.isEmpty {
                Section(LocalizedStringKey("Chats")) {
                    if shouldShowInitialSessionLoading {
                        sidebarInitialLoadingRow
                    } else if visibleSearchKeyword.isEmpty {
                        ContentUnavailableView(
                            LocalizedStringKey("No chats yet"),
                            systemImage: "text.bubble",
                            description: Text("Start a new conversation to begin talking.")
                        )
                    } else if shouldShowSidebarSearchLoading {
                        sidebarSearchLoadingRow
                    } else {
                        ContentUnavailableView(
                            LocalizedStringKey("No Results"),
                            systemImage: "magnifyingglass",
                            description: Text("Try a different search.")
                        )
                    }
                }
            } else {
                ForEach(sidebarGroups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            iosSessionRow(session)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectSessionFromSidebar(session)
                                }
                                .contextMenu {
                                    Button("Rename") { renameSession(session) }
                                    Button("Delete", role: .destructive) {
                                        requestDelete(for: session)
                                    }
                                }
                                .tag(session.id)
                        }
                        .onDelete { offsets in
                            handleSwipeDelete(at: offsets, within: group.sessions)
                        }
                    } header: {
                        group.section.title
                    }
                }
                sidebarSearchLoadingSection
            }
        }
        .onChange(of: sidebarSelectionID) { _, sessionID in
            selectMacSession(with: sessionID)
        }
        .onChange(of: chatSessionsViewModel.selectedSessionID, initial: true) { _, sessionID in
            synchronizeSidebarSelection(with: sessionID)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 10) {
            SidebarSearchHeader(style: .vision, searchText: $searchText)
        }
        .safeAreaInset(edge: .bottom) {
            SidebarSettingsFooter(style: .vision, onOpenSettings: onOpenSettings)
        }
    }

    private func sessionInitials(_ session: ChatSession) -> String {
        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return "VC" }
        let components = trimmedTitle.split(separator: " ")
        if components.count >= 2 {
            return components.prefix(2)
                .compactMap { $0.first }
                .map { String($0) }
                .joined()
                .uppercased()
        }
        return trimmedTitle.prefix(2).uppercased()
    }

    private var macDraftRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.secondary)
            Text("New Chat")
                .font(.headline)
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func macSessionRow(_ session: ChatSession) -> some View {
        macSessionRowContent(session)
            .popover(isPresented: renamePopoverBinding(for: session), arrowEdge: .trailing) {
                renameSheetView()
            }
    }

    private func macSessionRowContent(_ session: ChatSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                sidebarPreviewText(for: sidebarPreview(for: session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var iosDraftRow: some View {
        iosDraftRowContent
            .contentShape(Rectangle())
            .onTapGesture { selectDraftSession() }
    }

    private var iosDraftRowContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.secondary)
            Text("New Chat")
                .font(.body.weight(.semibold))
            Spacer()
        }
        .padding(.vertical, sidebarRowVerticalPadding)
    }

    private func iosSessionRow(_ session: ChatSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                sidebarPreviewText(for: sidebarPreview(for: session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, sidebarRowVerticalPadding)
    }

    private var sidebarRowVerticalPadding: CGFloat {
        #if os(visionOS)
        return 10
        #else
        return 6
        #endif
    }

}

#Preview {
    let settingsManager = SettingsManager.shared
    let chatSessions = ChatSessionsViewModel(
        settingsManager: settingsManager,
        reachability: ServerReachabilityMonitor.shared,
        audioManager: GlobalAudioManager.shared
    )
    let container = try! ModelContainer(
        for: Schema([
            ChatSession.self,
            ChatMessage.self,
            ChatRequestContextMetadata.self,
            AppSettings.self
        ]),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
    _ = chatSessions.attach(context: container.mainContext)

    return SidebarView(
        onConversationTap: { _ in },
        onOpenSettings: {}
    )
    .modelContainer(container)
    .environmentObject(chatSessions)
}
#if os(macOS)
import AppKit

private struct NativeSidebarRow {
    struct Key: Equatable {
        let title: String
        var preview: SidebarSessionPreview? = nil
        var isRenaming = false
        var calendarDay: Date? = nil
    }
    let id: AnyHashable
    let selectionID: UUID?
    let isGroup: Bool
    let key: Key
    let content: AnyView
    var measurementContent: AnyView? = nil
    var canDelete = false
}

private struct NativeSidebarList: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    let rows: [NativeSidebarRow]
    @Binding var selection: UUID?
    let contentInsets: EdgeInsets
    let onDelete: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeSidebarScrollView, context: Context) -> CGSize? {
        // The parent owns the viewport size; the table's document height must
        // not feed back into the scroll view's fitting size during layout.
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    func makeNSView(context: Context) -> NativeSidebarScrollView {
        let scroll = NativeSidebarScrollView()
        let table = NativeSidebarTableView()
        table.onDelete = { [weak coordinator = context.coordinator] in
            coordinator?.deleteSelection()
        }
        table.headerView = nil
        table.style = .sourceList
        table.floatsGroupRows = false
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.minWidth = 0
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.autoresizingMask = [.width]
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        context.coordinator.table = table
        scroll.onWidthChange = { [weak coordinator = context.coordinator] width in
            coordinator?.apply(width: width)
        }
        return scroll
    }

    func updateNSView(_ scroll: NativeSidebarScrollView, context: Context) {
        // SwiftUI owns the search, toolbar, and footer safe area. The native
        // scroll view fills that area and receives its insets exactly once.
        scroll.contentInsets = NSEdgeInsets(
            top: contentInsets.top,
            left: layoutDirection == .leftToRight ? contentInsets.leading : contentInsets.trailing,
            bottom: contentInsets.bottom,
            right: layoutDirection == .leftToRight ? contentInsets.trailing : contentInsets.leading
        )
        let coordinator = context.coordinator
        coordinator.selection = $selection
        coordinator.onDelete = onDelete
        coordinator.pendingRows = rows
        coordinator.environment = RowEnvironment(
            colorScheme: colorScheme, locale: locale,
            dynamicTypeSize: dynamicTypeSize, layoutDirection: layoutDirection
        )
        coordinator.apply(width: scroll.contentSize.width)
    }

    static func dismantleNSView(_ scroll: NativeSidebarScrollView, coordinator: Coordinator) {
        scroll.onWidthChange = nil
        coordinator.table?.delegate = nil
        coordinator.table?.dataSource = nil
    }

    struct RowEnvironment: Equatable {
        var colorScheme = ColorScheme.light
        var locale = Locale.current
        var dynamicTypeSize = DynamicTypeSize.large
        var layoutDirection = LayoutDirection.leftToRight
        var groupInset: CGFloat = 0

        func content(for row: NativeSidebarRow, measuring: Bool = false) -> AnyView {
            AnyView((measuring ? row.measurementContent ?? row.content : row.content)
                .padding(.horizontal, row.isGroup ? groupInset : 0)
                .padding(.vertical, row.isGroup ? 2 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.colorScheme, colorScheme)
                .environment(\.locale, locale)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .environment(\.layoutDirection, layoutDirection))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct LayoutRow {
            let row: NativeSidebarRow
            let height: CGFloat
        }
        struct Measurement {
            let key: NativeSidebarRow.Key
            let width: CGFloat
            let environment: RowEnvironment
            let height: CGFloat
        }
        var selection: Binding<UUID?>
        var onDelete: ((UUID) -> Void)?
        weak var table: NSTableView?
        var pendingRows: [NativeSidebarRow] = []
        var environment = RowEnvironment()
        private var appliedEnvironment = RowEnvironment()
        private var displayed: [LayoutRow] = []
        private var measurements: [AnyHashable: Measurement] = [:]
        private var width: CGFloat = 0
        private var isApplying = false
        private var lastSelectionID: UUID?
        private let measurer = NSHostingController(rootView: AnyView(EmptyView()))

        init(selection: Binding<UUID?>) {
            self.selection = selection
            super.init()
            measurer.sizingOptions = []
        }

        func apply(width proposedWidth: CGFloat) {
            guard let table, proposedWidth > 0, !isApplying else { return }
            isApplying = true
            defer { isApplying = false }
            // AppKit owns the source-list margins. A column is narrower than
            // the clip view; assigning the clip width makes the table overflow.
            table.sizeLastColumnToFit()
            let nextWidth = table.tableColumns[0].width
            environment.groupInset = table.rect(ofColumn: 0).minX
            let environmentChanged = appliedEnvironment != environment
            let widthChanged = width != nextWidth
            let idsChanged = displayed.map { $0.row.id } != pendingRows.map(\.id)
            if !environmentChanged, !widthChanged, !idsChanged,
               zip(displayed, pendingRows).allSatisfy({ $0.row.key == $1.key }) {
                synchronizeSelection()
                return
            }
            // Retain a row identity and its viewport position across actual
            // height/order changes; estimates never own this table's geometry.
            let scroll = table.enclosingScrollView
            let visibleTop = (scroll?.contentView.bounds.minY ?? 0) + (scroll?.contentInsets.top ?? 0)
            let visibleRow = table.row(at: NSPoint(x: table.bounds.midX, y: visibleTop))
            let wasEmpty = displayed.isEmpty
            let anchor: (id: AnyHashable, offset: CGFloat)? = displayed.indices.contains(visibleRow)
                ? (displayed[visibleRow].row.id, visibleTop - table.rect(ofRow: visibleRow).minY)
                : nil
            var changed = IndexSet()
            var changedHeights = IndexSet()
            let previous = Dictionary(uniqueKeysWithValues: displayed.map { ($0.row.id, $0) })
            let next = pendingRows.enumerated().map { index, row -> LayoutRow in
                let height: CGFloat
                if let measured = measurements[row.id], measured.key == row.key,
                   measured.width == nextWidth, measured.environment == environment {
                    height = measured.height
                } else {
                    measurer.rootView = environment.content(for: row, measuring: true)
                    height = ceil(measurer.sizeThatFits(in: CGSize(width: nextWidth, height: .greatestFiniteMagnitude)).height)
                    measurements[row.id] = Measurement(key: row.key, width: nextWidth, environment: environment, height: height)
                }
                if previous[row.id]?.height != height { changedHeights.insert(index) }
                if environmentChanged || widthChanged || previous[row.id]?.row.key != row.key {
                    changed.insert(index)
                }
                return LayoutRow(row: row, height: height)
            }
            displayed = next
            let retainedIDs = Set(pendingRows.map(\.id))
            measurements = measurements.filter { retainedIDs.contains($0.key) }
            width = nextWidth
            appliedEnvironment = environment
            if idsChanged {
                table.reloadData()
            } else if !changed.isEmpty {
                if !changedHeights.isEmpty {
                    table.noteHeightOfRows(withIndexesChanged: changedHeights)
                }
                for index in changed {
                    if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NativeSidebarCell {
                        cell.host.rootView = environment.content(for: displayed[index].row)
                    }
                }
            }
            if idsChanged || !changedHeights.isEmpty,
               let anchor, let index = displayed.firstIndex(where: { $0.row.id == anchor.id }),
               let scroll = table.enclosingScrollView {
                table.layoutSubtreeIfNeeded()
                let desiredY = table.rect(ofRow: index).minY + anchor.offset - scroll.contentInsets.top
                let minY = -scroll.contentInsets.top
                let maxY = max(minY, table.bounds.height - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
                let point = NSPoint(x: scroll.contentView.bounds.minX, y: min(max(minY, desiredY), maxY))
                scroll.contentView.scroll(to: point)
                scroll.reflectScrolledClipView(scroll.contentView)
            } else if wasEmpty, let scroll {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            synchronizeSelection()
        }

        private func synchronizeSelection() {
            guard let table else { return }
            let selectionChanged = lastSelectionID != selection.wrappedValue
            lastSelectionID = selection.wrappedValue
            let selectedRow = displayed.firstIndex { $0.row.selectionID == selection.wrappedValue && $0.row.selectionID != nil }
            if let selectedRow, table.selectedRow != selectedRow {
                table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
                if selectionChanged { table.scrollRowToVisible(selectedRow) }
            }
        }

        func deleteSelection() {
            guard let table else { return }
            deleteRow(table.selectedRow)
        }

        private func deleteRow(_ index: Int) {
            guard displayed.indices.contains(index), displayed[index].row.canDelete,
                  let id = displayed[index].row.selectionID else { return }
            onDelete?(id)
        }

        func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
            guard edge == .trailing, displayed[row].row.canDelete else { return [] }
            return [NSTableViewRowAction(style: .destructive, title: NSLocalizedString("Delete", comment: "")) { [weak self] _, index in
                self?.deleteRow(index)
            }]
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            displayed[row].row.selectionID == nil ? nil : displayed[row].row.key.title
        }

        func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { displayed[row].height }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { displayed[row].row.isGroup }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { displayed[row].row.selectionID != nil }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table, displayed.indices.contains(table.selectedRow) else { return }
            lastSelectionID = displayed[table.selectedRow].row.selectionID
            selection.wrappedValue = lastSelectionID
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("sidebar-row")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NativeSidebarCell ?? NativeSidebarCell()
            cell.identifier = identifier
            cell.host.rootView = environment.content(for: displayed[row].row)
            return cell
        }
    }
}

private final class NativeSidebarTableView: NSTableView {
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class NativeSidebarScrollView: NSScrollView {
    var onWidthChange: ((CGFloat) -> Void)?
    override func layout() {
        super.layout()
        onWidthChange?(contentSize.width)
    }
}

private final class NativeSidebarCell: NSTableCellView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHost()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureHost()
    }
    private func configureHost() {
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
#endif
