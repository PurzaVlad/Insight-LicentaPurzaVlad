import SwiftUI
import Foundation
import UIKit
import OSLog

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: String // "user" or "assistant"
    let text: String
    let date: Date

    init(id: UUID = UUID(), role: String, text: String, date: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}

struct NativeChatView: View {
    struct SessionState {
        var lastReferencedDocumentId: UUID?
        var lastOriginalQuestion: String?
        var lastAssistantResponse: String?
    }

    struct ChatLLMResult {
        let reply: String
        let primaryDocument: Document?
        let rewrittenQuery: String?
    }

    struct DocumentSelectionResult {
        let documents: [Document]
        let primaryDocument: Document?
        let topScoreByDocumentId: [UUID: Double]
        let retrievalQueryUsed: String?
        let selectedHits: [ChunkHit]
        let allRankedHits: [ChunkHit]
    }

    private enum QueryIntent: String, Codable {
        case askDocFact = "ask_doc_fact"
        case followupClarification = "followup_clarification"
        case challengeDispute = "challenge_dispute"
        case smalltalk = "smalltalk"
        case newTopic = "new_topic"
    }

    private enum ExpectedAnswerType: String, Codable {
        case number = "number"
        case date = "date"
        case entity = "entity"
        case paragraph = "paragraph"
        case yesno = "yesno"
    }

    struct QueryAnalysis: Codable {
        let intent: String
        let rewrittenQuery: String
        let focusTerms: [String]
        let softExpansions: [String]
        let language: String
        let needsPreviousDocBias: Bool
        let expectedAnswerType: String
        let mustNotAnswer: Bool

        enum CodingKeys: String, CodingKey {
            case intent
            case rewrittenQuery = "rewritten_query"
            case focusTerms = "focus_terms"
            case softExpansions = "soft_expansions"
            case language
            case needsPreviousDocBias = "needs_previous_doc_bias"
            case expectedAnswerType = "expected_answer_type"
            case mustNotAnswer = "must_not_answer"
        }
    }

    @State private var input: String = ""
    @State var messages: [ChatMessage] = []
    @State private var isGenerating: Bool = false
    @State private var isThinkingPulseOn: Bool = false
    @State private var activeChatGenerationId: UUID? = nil
    @State var sessionState = SessionState()
    @State private var conversationState = ConversationState()
    @EnvironmentObject var documentManager: DocumentManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false
    @State private var showingScopePicker = false
    @State var scopedDocumentIds: Set<UUID> = []

    // Conversation history
    @State private var conversations: [PersistedConversation] = []
    @State private var currentConversationId: UUID? = nil
    @State private var showingHistory: Bool = false
    @State private var isTitlePending: Bool = false

    private let inputLineHeight: CGFloat = 22
    private let inputMinLines = 1
    private let inputMaxLines = 2
    private let inputBarMinHeight: CGFloat = 44
    @State private var inputHeight: CGFloat = 22
    private let inputMaxCornerRadius: CGFloat = 25
    private let inputMinCornerRadius: CGFloat = 12

    // Preprompt (computed so it can be scope-aware)
    var chatPreprompt: String {
        if isScopeActive, scopedDocuments.count == 1, let doc = scopedDocuments.first {
            return "You are helping the user understand \"\(doc.title)\". Read the passages and answer the question. Quote or paraphrase what the passages say — give a real answer even if partial."
        }
        if !isScopeActive {
            return "Read the passages from multiple documents and answer the question. Synthesize across sources and cite which document each piece of information comes from. If the user is continuing a conversation, keep prior context in mind."
        }
        return "Read the passages and answer the question. Give a direct, complete answer even if partial — and if you're following up on something mentioned earlier, refer to that context naturally."
    }
    let historyLimit = 4
    var selectionMaxDocs: Int { isScopeActive ? 2 : 5 }
    var activeContextCharBudget: Int { isScopeActive ? 2200 : 3200 }
    private let folderContextCharBudget = 500
    let minContextReserveChars = 450
    let maxSummaryCharsPerDoc = 420
    let maxSnippetChars = 420
    let maxSnippetsPerDoc = 2
    let maxOCRSnippetsPerDoc = 3
    let useNoHistoryForChat = true
    let defaultOCRDocCount = 3
    let lowExtractedTextThreshold = 700

    // Simplified chunk ranking weights (3 core features)
    private let bm25Weight: Double = 0.70          // Lexical matching via BM25
    private let exactMatchWeight: Double = 0.25    // Exact tokens + phrases + numeric matches
    let recencyWeight: Double = 0.05       // Recent document boost

    let evidenceAbsoluteFloor: Double = 0.12
    let evidenceMedianMargin: Double = 0.08
    let evidenceGapThreshold: Double = 0.10
    let passBTopEvidenceLimit = 3
    private let passBGatingKeywordMatchMin = 2
    let expandedEvidenceLimit = 5

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 36, weight: .light))
                                    .foregroundStyle(Color("Primary").opacity(0.7))
                                Text("Ask Anything")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("Select a document and start a conversation, or ask a general question.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                        }

                        ForEach(messages) { msg in
                            MessageRow(msg: msg)
                                .id(msg.id)
                        }

                        if isGenerating {
                            ThinkingRow(isPulseOn: $isThinkingPulseOn)
                                .id("thinking")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 80)
                }
                .hideScrollBackground()
                .scrollDismissesKeyboardIfAvailable()
                .onChange(of: messages) { newValue in
                    if let last = newValue.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            flushCurrentConversationToDisk()
                            resetConversation()
                        } label: {
                            Label("New Conversation", systemImage: "square.and.pencil")
                        }
                        Button {
                            showingHistory = true
                        } label: {
                            Label("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        }
                        Divider()
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Preferences", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.primary)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .modifier(SharedSettingsSheetBackgroundModifier())
            }
            .sheet(isPresented: $showingScopePicker) {
                ScopePickerSheet(selectedIds: $scopedDocumentIds)
                    .environmentObject(documentManager)
            }
            .sheet(isPresented: $showingHistory) {
                ConversationHistorySheet(
                    conversations: conversations,
                    onSelect: { conversation in
                        loadConversation(conversation)
                        showingHistory = false
                    },
                    onDelete: { id in
                        deleteConversation(id: id)
                    }
                )
            }
            .onAppear {
                loadConversationsFromDisk()
            }
            .onDisappear {
                flushCurrentConversationToDisk()
            }
            .onChange(of: showingHistory) { showing in
                if showing { loadConversationsFromDisk() }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if !isScopeActive && !documentManager.documents.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                            Text("Asking all \(documentManager.documents.count) documents")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    }
                    inputBar
                }
            }
        }
    }

    var scopedDocuments: [Document] {
        scopedDocumentsForSelection()
    }

    var isScopeActive: Bool {
        !scopedDocumentIds.isEmpty
    }

    private var inputCornerRadius: CGFloat {
        let lines = max(inputMinLines, min(inputMaxLines, Int(round(inputHeight / inputLineHeight))))
        let t = CGFloat(lines - 1) / CGFloat(max(inputMaxLines - 1, 1))
        return inputMaxCornerRadius - (inputMaxCornerRadius - inputMinCornerRadius) * t
    }

    @ViewBuilder
    private var scopeButton: some View {
        if isScopeActive {
            Button { showingScopePicker = true } label: {
                Image(systemName: "scope")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .background(Color.accentColor, in: Circle())
                    .ifAvailableiOS26GlassCircle(isActive: false)
            }
            .buttonStyle(.plain)
        } else {
            Button { showingScopePicker = true } label: {
                Image(systemName: "scope")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .ifAvailableiOS26GlassCircle(isActive: false)
            }
            .buttonStyle(.plain)
        }
    }

    private var inputBar: some View {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                scopeButton

                HStack(alignment: .center, spacing: 6) {
                    TextField("Ask anything", text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .lineLimit(1...6)
                        .frame(minHeight: 24)
                        .disabled(isGenerating)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                        .padding(.trailing, 6)

                    Button {
                        send()
                    } label: {
                        Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .disabled(!hasText && !isGenerating)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .ifAvailableiOS17CircleBorder()
                    .tint(Color("Primary"))
                    .frame(width: 32, height: 32)
                }
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .ifAvailableiOS26GlassBackground(cornerRadius: inputCornerRadius)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Text("AI can make mistakes. Verify important information.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 8)
        }
    }

    private func send() {
        if isGenerating {
            stopGeneration()
            return
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMsg = ChatMessage(role: "user", text: trimmed, date: Date())
        messages.append(userMsg)
        input = ""
        isGenerating = true

        // Start or update the persisted conversation
        if currentConversationId == nil {
            initializeConversation(firstMessage: userMsg)
        } else {
            updateConversationMessages()
        }

        startGeneration(question: trimmed)
    }

    private func resetConversation() {
        input = ""
        messages = []
        isGenerating = false
        activeChatGenerationId = nil
        conversationState.reset()
        currentConversationId = nil
        isTitlePending = false
    }

    private func stopGeneration() {
        guard isGenerating else { return }
        isGenerating = false
        activeChatGenerationId = nil
        EdgeAI.shared?.cancelCurrentGeneration()
    }

    private func startGeneration(question: String) {
        let generationId = UUID()
        activeChatGenerationId = generationId
        runLLMAnswer(question: question, generationId: generationId)
    }

    // MARK: - Conversation History

    private func loadConversationsFromDisk() {
        do {
            let all = try PersistenceService.shared.loadConversations()
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            let recent = all.filter { $0.updatedAt >= cutoff }
            conversations = recent
            if recent.count < all.count {
                try? PersistenceService.shared.saveConversations(recent)
            }
        } catch {
            AppLogger.ui.error("Failed to load conversations: \(error.localizedDescription)")
        }
    }

    private func flushCurrentConversationToDisk() {
        guard !messages.isEmpty else { return }
        updateConversationMessages(updateTimestamp: false)
    }

    /// Returns true if the message is a greeting or filler with no real content.
    /// Title generation is deferred until the first non-small-talk turn.
    private func isSmallTalk(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ']", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if normalized.count > 50 { return false }
        let phrases: Set<String> = [
            "hi", "hello", "hey", "yo", "sup", "what's up", "whats up", "wassup",
            "good morning", "good afternoon", "good evening", "good night",
            "how are you", "how are you doing", "how's it going", "hows it going", "how do you do",
            "i'm good", "im good", "i'm fine", "im fine", "i'm great", "im great",
            "i'm okay", "im okay", "i'm ok", "im ok",
            "fine", "great", "not bad", "pretty good", "doing good", "doing well",
            "thanks", "thank you", "thank you so much", "thanks a lot", "ty", "thx",
            "ok", "okay", "got it", "sure", "alright", "sounds good",
            "yes", "no", "yeah", "nope", "yep", "nah",
            "lol", "haha", "hehe", "wow", "nice", "cool", "awesome", "neat",
            "bye", "goodbye", "see you", "see ya", "cya", "later", "ttyl",
            "you there", "are you there", "hello there", "hey there",
        ]
        return phrases.contains(normalized)
    }

    private func initializeConversation(firstMessage: ChatMessage) {
        let tempTitle = "New Chat"
        let now = Date()
        let conversation = PersistedConversation(
            id: UUID(),
            title: tempTitle,
            messages: [PersistedMessage(id: firstMessage.id, role: firstMessage.role, text: firstMessage.text, date: firstMessage.date)],
            createdAt: now,
            updatedAt: now
        )
        conversations.append(conversation)
        currentConversationId = conversation.id
        isTitlePending = true
        do {
            try PersistenceService.shared.saveConversations(conversations)
        } catch {
            AppLogger.ui.error("Failed to save new conversation: \(error.localizedDescription)")
        }
    }

    private func updateConversationMessages(updateTimestamp: Bool = true) {
        guard let convId = currentConversationId,
              let idx = conversations.firstIndex(where: { $0.id == convId }) else { return }
        let persisted = messages.map { PersistedMessage(id: $0.id, role: $0.role, text: $0.text, date: $0.date) }
        conversations[idx].messages = persisted
        if updateTimestamp {
            conversations[idx].updatedAt = Date()
        }
        do {
            try PersistenceService.shared.saveConversations(conversations)
        } catch {
            AppLogger.ui.error("Failed to update conversation: \(error.localizedDescription)")
        }
    }

    private func loadConversation(_ conversation: PersistedConversation) {
        flushCurrentConversationToDisk()
        messages = conversation.messages.map {
            ChatMessage(id: $0.id, role: $0.role, text: $0.text, date: $0.date)
        }
        currentConversationId = conversation.id
        isTitlePending = false
        conversationState.reset()
    }

    private func deleteConversation(id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentConversationId == id {
            currentConversationId = nil
            isTitlePending = false
        }
        do {
            try PersistenceService.shared.saveConversations(conversations)
        } catch {
            AppLogger.ui.error("Failed to delete conversation: \(error.localizedDescription)")
        }
    }

    private func generateConversationTitle(userMessage: String, assistantResponse: String) {
        guard let convId = currentConversationId,
              let edgeAI = EdgeAI.shared else { return }
        let prompt = AIService.shared.buildTitlePrompt(
            userMessage: userMessage,
            assistantExcerpt: assistantResponse
        )
        edgeAI.generate(prompt, resolver: { [self] result in
            DispatchQueue.main.async {
                let raw = (result as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let title = String(raw.components(separatedBy: "\n").first ?? raw).prefix(80)
                guard !title.isEmpty else { return }
                if let idx = self.conversations.firstIndex(where: { $0.id == convId }) {
                    self.conversations[idx].title = String(title)
                    do {
                        try PersistenceService.shared.saveConversations(self.conversations)
                    } catch {
                        AppLogger.ui.error("Failed to save conversation title: \(error.localizedDescription)")
                    }
                }
            }
        }, rejecter: { _, _, _ in })
    }

    private func runLLMAnswer(question: String, generationId: UUID) {
        isGenerating = true

        Task {
            do {
                guard let edgeAI = EdgeAI.shared else {
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        self.messages.append(ChatMessage(role: "assistant", text: "Error: EdgeAI not initialized", date: Date()))
                    }
                    return
                }

                if self.activeChatGenerationId != generationId { return }

                // Query rewriting is now handled inside callChatLLM via analyzeQueryIntent
                let result = try await callChatLLM(edgeAI: edgeAI, question: question)
                DispatchQueue.main.async {
                    if self.activeChatGenerationId != generationId { return }
                    self.isGenerating = false
                    let text = result.reply.isEmpty ? "(No response)" : result.reply
                    self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                    self.updateSessionState(from: result.primaryDocument)

                    // Update conversation state with result
                    self.conversationState.update(
                        documentId: result.primaryDocument?.id,
                        documentTitle: result.primaryDocument?.title,
                        assistantResponse: text
                    )
                    self.conversationState.lastRewrittenQuery = result.rewrittenQuery

                    // Save conversation and optionally generate a title.
                    // Only lock in a title once the user asks something substantive;
                    // pure small talk keeps the placeholder across multiple turns.
                    self.updateConversationMessages()
                    if self.isTitlePending && !self.isSmallTalk(question) {
                        self.isTitlePending = false
                        self.generateConversationTitle(userMessage: question, assistantResponse: text)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if self.activeChatGenerationId != generationId { return }
                    self.isGenerating = false
                    if error.localizedDescription != "CANCELLED" {
                        self.messages.append(ChatMessage(role: "assistant", text: "Error: \(error.localizedDescription)", date: Date()))
                    }
                }
            }
        }
    }


    private struct ScopePickerSheet: View {
        @EnvironmentObject private var documentManager: DocumentManager
        @Binding var selectedIds: Set<UUID>
        @Environment(\.dismiss) private var dismiss
        @State private var editMode: EditMode = .active
        @State private var searchText = ""
        @AppStorage("documentsSortMode") private var documentsSortModeRaw = DocumentsSortMode.dateNewest.rawValue

        private enum DocumentsSortMode: String, CaseIterable {
            case dateNewest = "newest"
            case dateOldest = "oldest"
            case nameAsc = "alphabetically"
            case nameDesc = "alphabetically_desc"
            case accessNewest = "access_newest"
            case accessOldest = "access_oldest"
        }

        private enum ScopeItemKind {
            case folder(DocumentFolder)
            case document(Document)
        }

        private struct ScopeItem: Identifiable {
            let id: UUID
            let kind: ScopeItemKind
            let name: String
            let dateCreated: Date
        }

        private var documentsSortMode: DocumentsSortMode {
            DocumentsSortMode(rawValue: documentsSortModeRaw) ?? .dateNewest
        }

        private var scopeSortMode: DocumentsSortMode {
            switch documentsSortMode {
            case .accessNewest, .accessOldest:
                return documentsSortMode
            default:
                return .accessNewest
            }
        }

        private var scopeItems: [ScopeItem] {
            let folderItems = documentManager.folders.map { folder in
                ScopeItem(id: folder.id, kind: .folder(folder), name: folder.name, dateCreated: folder.dateCreated)
            }
            let documentItems = documentManager.documents.map { doc in
                ScopeItem(
                    id: doc.id,
                    kind: .document(doc),
                    name: splitDisplayTitle(doc.title).base,
                    dateCreated: doc.dateCreated
                )
            }
            return sortItems(folderItems + documentItems)
        }

        private var filteredItems: [ScopeItem] {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return scopeItems }
            let needle = trimmed.lowercased()
            return scopeItems.filter { item in
                item.name.lowercased().contains(needle)
            }
        }

        var body: some View {
            NavigationStack {
                List(selection: $selectedIds) {
                    if filteredItems.isEmpty {
                        Text("No documents or folders available.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredItems) { item in
                            switch item.kind {
                            case .folder(let folder):
                                FolderRowView(
                                    folder: folder,
                                    docCount: documentManager.itemCount(in: folder.id),
                                    isSelected: selectedIds.contains(folder.id),
                                    isSelectionMode: true,
                                    usesNativeSelection: true,
                                    onSelectToggle: {},
                                    onOpen: {},
                                    onRename: {},
                                    onMove: {},
                                    onDelete: {},
                                    isDropTargeted: false
                                )
                                .tag(folder.id)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                            case .document(let document):
                                DocumentRowView(
                                    document: document,
                                    isSelected: selectedIds.contains(document.id),
                                    isSelectionMode: true,
                                    usesNativeSelection: true,
                                    onSelectToggle: {},
                                    onOpen: {},
                                    onRename: {},
                                    onMoveToFolder: {},
                                    onDelete: {},
                                    onShare: {}
                                )
                                .tag(document.id)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .hideScrollBackground()
                .scrollDismissesKeyboardIfAvailable()
                .environment(\.editMode, $editMode)
                .navigationTitle("Scope")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search documents")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Clear") {
                            selectedIds.removeAll()
                        }
                        .foregroundColor(.primary)
                        .disabled(selectedIds.isEmpty)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundColor(.primary)
                            .buttonStyle(.borderedProminent)
                            .tint(Color("Primary"))
                            .disabled(selectedIds.isEmpty)
                    }
                }
            }
        }

        private func sortItems(_ items: [ScopeItem]) -> [ScopeItem] {
            switch scopeSortMode {
            case .dateNewest:
                return items.sorted {
                    if $0.dateCreated != $1.dateCreated { return $0.dateCreated > $1.dateCreated }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            case .dateOldest:
                return items.sorted {
                    if $0.dateCreated != $1.dateCreated { return $0.dateCreated < $1.dateCreated }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            case .nameAsc:
                return items.sorted {
                    let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                    return $0.dateCreated > $1.dateCreated
                }
            case .nameDesc:
                return items.sorted {
                    let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                    if nameOrder != .orderedSame { return nameOrder == .orderedDescending }
                    return $0.dateCreated > $1.dateCreated
                }
            case .accessNewest:
                return items.sorted {
                    let a = documentManager.lastAccessedDate(for: $0.id, fallback: $0.dateCreated)
                    let b = documentManager.lastAccessedDate(for: $1.id, fallback: $1.dateCreated)
                    if a != b { return a > b }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            case .accessOldest:
                return items.sorted {
                    let a = documentManager.lastAccessedDate(for: $0.id, fallback: $0.dateCreated)
                    let b = documentManager.lastAccessedDate(for: $1.id, fallback: $1.dateCreated)
                    if a != b { return a < b }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
        }
    }

    private struct AutoGrowingTextView: UIViewRepresentable {
        @Binding var text: String
        @Binding var height: CGFloat
        let minHeight: CGFloat
        let maxHeight: CGFloat
        let font: UIFont
        let isEditable: Bool

        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView()
            textView.isScrollEnabled = false
            textView.backgroundColor = .clear
            textView.font = font
            textView.textAlignment = .natural
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainer.lineBreakMode = .byWordWrapping
            textView.textContainer.widthTracksTextView = true
            textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textView.delegate = context.coordinator
            return textView
        }

        func updateUIView(_ uiView: UITextView, context: Context) {
            if uiView.text != text {
                uiView.text = text
            }
            uiView.font = font
            uiView.isEditable = isEditable
            uiView.isScrollEnabled = false
            uiView.textAlignment = .natural
            recalcHeight(view: uiView)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        private func recalcHeight(view: UITextView) {
            let size = view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude))
            let clamped = min(maxHeight, max(minHeight, size.height))
            if height != clamped {
                DispatchQueue.main.async {
                    height = clamped
                    view.isScrollEnabled = size.height > maxHeight
                }
            }
        }

        class Coordinator: NSObject, UITextViewDelegate {
            let parent: AutoGrowingTextView

            init(parent: AutoGrowingTextView) {
                self.parent = parent
            }

            func textViewDidChange(_ textView: UITextView) {
                parent.text = textView.text
                parent.recalcHeight(view: textView)
            }
        }
    }


    private struct ThinkingRow: View {
        @Binding var isPulseOn: Bool

        var body: some View {
            HStack(spacing: 8) {
                Text("Thinking…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .opacity(isPulseOn ? 0.78 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    isPulseOn = true
                }
            }
            .onDisappear {
                isPulseOn = false
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func ifAvailableiOS17CircleBorder() -> some View {
        self
            .buttonBorderShape(.circle)
    }

    @ViewBuilder
    func ifAvailableiOS26GlassButton(isActive: Bool) -> some View {
        if #available(iOS 26.0, *) {
            if isActive {
                self
                    .buttonStyle(.borderedProminent)
            } else {
                self
                    .buttonStyle(.glass)
            }
        } else {
            if isActive {
                self
                    .buttonStyle(.borderedProminent)
            } else {
                self
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    func ifAvailableiOS26GlassBackground(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func ifAvailableiOS26GlassCircle(isActive: Bool) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: Circle())
        } else {
            if isActive {
                self
                    .background(Color("Primary").opacity(0.15), in: Circle())
                    .overlay(Circle().stroke(Color("Primary").opacity(0.4), lineWidth: 1))
            } else {
                self
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
            }
        }
    }
}

private struct MessageRow: View {
    let msg: ChatMessage

    var body: some View {
        HStack {
            if msg.role == "assistant" {
                bubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble
            }
        }
    }

    private var bubble: some View {
        let blocks = parseMessageBlocks(msg.text)
        let hasQuotedBlocks = blocks.contains(where: \.isQuoted)

        return Group {
            if hasQuotedBlocks {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        if block.isQuoted {
                            Text(renderMarkdownLines(block.text))
                                .foregroundStyle(Color.primary)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                Text(renderMarkdownLines(trimmed))
                                    .foregroundStyle(Color.primary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(.systemGray4).opacity(0.35), lineWidth: 1)
                )
            } else {
                Text(formatMarkdownText(msg.text))
                    .foregroundStyle(msg.role == "user" ? Color.white : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(msg.role == "user" ? Color("Primary") : Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(msg.role == "user" ? Color.clear : Color(.systemGray4).opacity(0.35), lineWidth: 1)
                    )
            }
        }
    }
}
