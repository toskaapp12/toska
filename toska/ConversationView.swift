import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

// FIX: replaced the Bool return from checkIfBlocked with a typed enum so that
// a network failure is distinguishable from an actual block. Previously both
// conditions returned true, causing the view to silently dismiss when offline.
enum BlockCheckResult {
    case notBlocked
    case blocked
    case error(Error)
}

@MainActor
struct ConversationView: View {
    let conversationId: String
    let otherHandle: String
    let otherUserId: String

    @Environment(\.dismiss) var dismiss
    @FocusState private var inputFocused: Bool
    @State private var messageText = ""
    @State private var messages: [ChatMessage] = []
    @State private var myMessageCount = 0
    @State private var theirMessageCount = 0
    @State private var listener: ListenerRegistration? = nil
    @State private var metadataListener: ListenerRegistration? = nil
    @State private var isLoading = true
    @State private var showBlockAlert = false
    // Safety-check state for outgoing messages — mirrors the pattern used
    // in ComposeView, PostDetailView reply, FeelingCircleView. Previously
    // sendMessage went straight to Firestore with zero name/identifying-info
    // or crisis-content validation; conversations were the only text input
    // surface lacking the safety chain.
    @State private var showMessageNameWarning = false
    @State private var showMessageContentWarning = false
    @State private var messageContentWarningMessage = ""
    @State private var showMessageGentleCheck = false
    @State private var pendingMessageText = ""
    @State private var messageGentleCheckLevel: CrisisLevel = .soft
    @State private var showReportAlert = false
    @State private var isBlockedEitherDirection = false
    @State private var otherIsTyping = false
    @State private var typingTimer: Task<Void, Never>? = nil
    @State private var isCurrentlyTyping = false
    @State private var typingDotPhase = 0
    @State private var typingDotTask: Task<Void, Never>? = nil
    @State private var appearTask: Task<Void, Never>? = nil
    @State private var lastReadByOther: Date? = nil
    @State private var isCountsLoaded = false
    @State private var isSending = false
    // FIX: added to surface network errors from checkIfBlocked to the user
    // instead of silently dismissing the view.
    @State private var blockCheckError: String? = nil

    private let messageLimit = ToskaConstants.messageLimit

    var isSealed: Bool {
        guard isCountsLoaded else { return false }
        return myMessageCount >= messageLimit && theirMessageCount >= messageLimit
    }

    var messagesRemaining: Int {
        max(0, messageLimit - myMessageCount)
    }

    var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && myMessageCount < messageLimit
            && !isSending
    }

    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(Color.toskaBlue)
                    }
                    Spacer()
                    VStack(spacing: 1) {
                        Text(otherHandle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color.toskaTextDark)
                        if isSealed {
                            Text("conversation sealed")
                                .font(.system(size: 9))
                                .foregroundColor(Color.toskaTimestamp)
                        } else {
                            Text("\(messagesRemaining) messages left")
                                .font(.system(size: 9))
                                .foregroundColor(Color.toskaBlue)
                        }
                    }
                    Spacer()
                    Button { showBlockAlert = true } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(Color.toskaTimestamp)
                    }
                    .accessibilityLabel("Report or block")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Rectangle().fill(Color(hex: "dfe1e5")).frame(height: 0.5)

                // FIX: show a retry state when checkIfBlocked fails due to a
                // network error instead of leaving the user on a blank screen.
                if let errorMessage = blockCheckError {
                    Spacer()
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundColor(Color.toskaTextLight)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            blockCheckError = nil
                            isLoading = true
                            appearTask?.cancel()
                            appearTask = Task {
                                let result = await checkIfBlocked()
                                handleBlockCheckResult(result)
                            }
                        } label: {
                            Text("retry")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color.toskaBlue)
                        }
                    }
                    Spacer()
                } else if isLoading {
                    Spacer()
                    ProgressView().tint(Color.toskaBlue)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                VStack(spacing: 8) {
                                    Image(systemName: "bubble.left.and.bubble.right")
                                        .font(.system(size: 20, weight: .light))
                                        .foregroundColor(Color.toskaDivider)
                                    Text("anonymous conversation")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color.toskaTextLight)
                                    Text("you each get 5 messages.\nsay what matters.")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "cccccc"))
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)

                                let lastMyMessageIndex = messages.indices.last(where: { messages[$0].isMe })

                                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                    let isLastFromMe = message.isMe && index == lastMyMessageIndex
                                    let otherHasRead: Bool = {
                                        guard isLastFromMe else { return false }
                                        guard let lastReadTimestamp = lastReadByOther else { return false }
                                        return message.createdAt <= lastReadTimestamp
                                    }()

                                    MessageBubble(
                                        text: message.text,
                                        time: message.timeAgo,
                                        isMe: message.isMe,
                                        senderHandle: message.isMe ? nil : otherHandle,
                                        isSeen: otherHasRead
                                    )
                                    .id(message.id)
                                }

                                if otherIsTyping && !isSealed {
                                    HStack(spacing: 0) {
                                        Rectangle()
                                            .fill(Color.toskaBlue.opacity(0.3))
                                            .frame(width: 2, height: 14)
                                            .cornerRadius(1)

                                        HStack(spacing: 3) {
                                            ForEach(0..<3, id: \.self) { i in
                                                Circle()
                                                    .fill(Color.toskaBlue.opacity(
                                                        typingDotPhase == i ? 0.8 : 0.3
                                                    ))
                                                    .frame(width: 4, height: 4)
                                                    .offset(y: typingDotPhase == i ? -2 : 0)
                                                    .animation(
                                                        .easeInOut(duration: 0.3).delay(Double(i) * 0.15),
                                                        value: typingDotPhase
                                                    )
                                            }
                                        }
                                        .padding(.leading, 10)
                                        // FIX: cancel the previous typingDotTask before starting a
                                        // new one on every onAppear. Previously the old task kept
                                        // running after otherIsTyping flipped to false because the
                                        // conditional view's onAppear only fires when the view is
                                        // inserted, not when otherIsTyping changes. Cancelling first
                                        // ensures at most one animation loop is alive at a time.
                                        .onAppear {
                                            typingDotTask?.cancel()
                                            typingDotTask = Task { @MainActor in
                                                while !Task.isCancelled && otherIsTyping {
                                                    try? await Task.sleep(nanoseconds: 500_000_000)
                                                    guard !Task.isCancelled else { return }
                                                    typingDotPhase = (typingDotPhase + 1) % 3
                                                }
                                            }
                                        }
                                        .onDisappear {
                                            // FIX: cancel the task as soon as the typing indicator
                                            // leaves the screen so the animation loop doesn't
                                            // silently continue in the background.
                                            typingDotTask?.cancel()
                                            typingDotTask = nil
                                        }

                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                    .transition(.opacity)
                                }

                                if isSealed {
                                    VStack(spacing: 6) {
                                        Rectangle()
                                            .fill(Color(hex: "dfe1e5"))
                                            .frame(width: 40, height: 0.5)
                                        Text("this conversation is sealed")
                                            .font(.system(size: 10))
                                            .foregroundColor(Color(hex: "cccccc"))
                                        Text("some things only need to be said once")
                                            .font(.system(size: 9))
                                            .foregroundColor(Color(hex: "d8d8d8"))
                                            .italic()
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 20)
                                }

                                Color.clear.frame(height: 20).id("bottom")
                            }
                        }
                        .onChange(of: messages.count) { _, _ in
                            withAnimation {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: isLoading) { _, newValue in
                            if !newValue && !messages.isEmpty {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        // MARK: - Input bar via safeAreaInset
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isCountsLoaded {
                EmptyView()
            } else if !isSealed {
                VStack(spacing: 0) {
                    Rectangle().fill(Color(hex: "dfe1e5")).frame(height: 0.5)

                    if myMessageCount >= messageLimit {
                        HStack {
                            Spacer()
                            Text("youve said what you needed to say")
                                .font(.system(size: 11))
                                .foregroundColor(Color.toskaTextLight)
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .background(Color.white)
                    } else {
                        HStack(spacing: 4) {
                            Text("\(messagesRemaining)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(
                                    messagesRemaining <= 2
                                        ? Color(hex: "c49a6c")
                                        : Color.toskaTimestamp
                                )
                                .frame(width: 20)

                            TextField("say what you mean...", text: $messageText)
                                .font(.system(size: 13))
                                .focused($inputFocused)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Color(hex: "e8eaed"))
                                .cornerRadius(20)
                                .onChange(of: messageText) { _, newValue in
                                    if newValue.count > 500 {
                                        messageText = String(newValue.prefix(500))
                                    }
                                    let isTyping = !newValue
                                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    if isTyping && !isCurrentlyTyping {
                                        isCurrentlyTyping = true
                                        updateTypingStatus(true)
                                    } else if !isTyping && isCurrentlyTyping {
                                        isCurrentlyTyping = false
                                        updateTypingStatus(false)
                                    }
                                    typingTimer?.cancel()
                                    typingTimer = Task { @MainActor in
                                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                                        guard !Task.isCancelled else { return }
                                        isCurrentlyTyping = false
                                        updateTypingStatus(false)
                                    }
                                }

                            Button { sendMessage() } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(canSend
                                        ? Color.toskaBlue
                                        : Color.toskaDivider)
                            }
                            .disabled(!canSend)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white)
                    }
                }
                .background(Color.white.ignoresSafeArea(edges: .bottom))
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
        .onAppear {
            appearTask?.cancel()
            appearTask = Task {
                let result = await checkIfBlocked()
                handleBlockCheckResult(result)
            }
        }
        .onDisappear {
            appearTask?.cancel()
            appearTask = nil
            listener?.remove()
            listener = nil
            metadataListener?.remove()
            metadataListener = nil
            if !isBlockedEitherDirection {
                updateTypingStatus(false)
            }
            typingTimer?.cancel()
            typingDotTask?.cancel()
            typingDotTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Defensive re-attach. Firestore's snapshot listeners normally
            // recover on their own when the network comes back, but on long
            // backgrounds the connection can stay broken until something
            // pokes it. startListening() removes the prior listeners at the
            // top before reattaching, so this is safe to call repeatedly.
            guard !isBlockedEitherDirection else { return }
            startListening()
        }
        .confirmationDialog("", isPresented: $showBlockAlert) {
            Button("report conversation") {
                reportConversation()
                showReportAlert = true
            }
            Button("block user", role: .destructive) { blockAndDismiss() }
            Button("cancel", role: .cancel) {}
        }
        .alert("reported", isPresented: $showReportAlert) {
            Button("ok") {}
        } message: {
            Text("we hear you. well look into it.")
        }
        .alert("hold on", isPresented: $showMessageContentWarning) {
            Button("edit") {}
        } message: { Text(messageContentWarningMessage) }
        .alert("keep it anonymous", isPresented: $showMessageNameWarning) {
            Button("edit") {}
            Button("send anyway", role: .destructive) {
                if let level = crisisCheckLevelRespectingSetting(for: pendingMessageText) {
                    messageGentleCheckLevel = level
                    showMessageGentleCheck = true
                } else {
                    performSendChecked(pendingMessageText)
                }
            }
        } message: {
            Text("your message may include a name or identifying info. toska is anonymous for everyone.")
        }
        .overlay {
            if showMessageGentleCheck {
                CrisisCheckInView(
                    isPresented: $showMessageGentleCheck,
                    level: messageGentleCheckLevel,
                    onProceed: { performSendChecked(pendingMessageText) }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showMessageGentleCheck)
    }

    // MARK: - Block Check

    // FIX: returns BlockCheckResult instead of Bool so callers can distinguish
    // between "actually blocked" and "network failed". The old Bool return
    // treated both cases as true, silently dismissing the view when offline.
    func checkIfBlocked() async -> BlockCheckResult {
        guard let uid = Auth.auth().currentUser?.uid, !otherUserId.isEmpty else {
            isLoading = false
            return .error(URLError(.badServerResponse))
        }
        let db = Firestore.firestore()
        do {
            let iBlockedSnap = try await db.collection("users").document(uid)
                .collection("blocked").document(otherUserId).getDocumentAsync()
            if iBlockedSnap.exists {
                isBlockedEitherDirection = true
                dismiss()
                return .blocked
            }

            let theyBlockedSnap = try await db.collection("users").document(otherUserId)
                .collection("blocked").document(uid).getDocumentAsync()
            if theyBlockedSnap.exists {
                isBlockedEitherDirection = true
                dismiss()
                return .blocked
            }

            return .notBlocked
        } catch {
            isLoading = false
            return .error(error)
        }
    }

    // FIX: extracted the result-handling logic out of onAppear so it can also
    // be called from the retry button without duplicating the switch statement.
    private func handleBlockCheckResult(_ result: BlockCheckResult) {
        switch result {
        case .notBlocked:
            blockCheckError = nil
            startListening()
        case .blocked:
            // dismiss() is already called inside checkIfBlocked for this case.
            break
        case .error:
            isLoading = false
            blockCheckError = "couldn't check connection status. check your network and try again."
        }
    }

    // MARK: - Listeners

    func startListening() {
        guard !conversationId.isEmpty else { isLoading = false; return }
        guard let uid = Auth.auth().currentUser?.uid else { isLoading = false; return }
        guard !otherUserId.isEmpty else { isLoading = false; return }

        // Defensive: if startListening runs twice, remove prior listeners
        // before registering new ones to avoid duplicate callbacks.
        listener?.remove()
        listener = nil
        metadataListener?.remove()
        metadataListener = nil

        let capturedUid = uid
        let capturedOtherUid = otherUserId
        let db = Firestore.firestore()

        db.collection("conversations").document(conversationId).getDocument { snap, _ in
            Task { @MainActor in
                if let counts = snap?.data()?["messageCount"] as? [String: Int] {
                    self.myMessageCount = counts[capturedUid] ?? 0
                    self.theirMessageCount = counts[capturedOtherUid] ?? 0
                }
                self.isCountsLoaded = true
            }
        }

        metadataListener = db.collection("conversations").document(conversationId)
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == capturedUid else {
                        self.dismiss()
                        return
                    }
                    if let error = error {
                        let nsError = error as NSError
                        if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                            self.dismiss()
                        }
                        return
                    }
                    if snapshot?.exists == false {
                        self.listener?.remove()
                        self.listener = nil
                        self.metadataListener?.remove()
                        self.metadataListener = nil
                        self.dismiss()
                        return
                    }
                    guard let data = snapshot?.data() else { return }

                    let counts = data["messageCount"] as? [String: Int] ?? [:]
                    self.myMessageCount = counts[capturedUid] ?? 0
                    self.theirMessageCount = counts[capturedOtherUid] ?? 0

                    let typing = data["typing"] as? [String: Bool] ?? [:]
                    let typingAt = data["typingAt"] as? [String: Timestamp] ?? [:]
                    let otherTyping = typing[capturedOtherUid] ?? false
                    let otherTypingFresh: Bool = {
                        guard otherTyping, let ts = typingAt[capturedOtherUid] else { return false }
                        return Date().timeIntervalSince(ts.dateValue()) < 10
                    }()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.otherIsTyping = otherTypingFresh
                    }
                    if !otherTypingFresh {
                        self.typingDotTask?.cancel()
                        self.typingDotTask = nil
                    }

                    let lastRead = data["lastRead"] as? [String: Timestamp] ?? [:]
                    self.lastReadByOther = lastRead[capturedOtherUid]?.dateValue()
                }
            }

        listener = db.collection("conversations").document(conversationId)
            .collection("messages")
            .order(by: "createdAt", descending: false)
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == capturedUid else {
                        self.dismiss()
                        return
                    }
                    if let error = error {
                        let nsError = error as NSError
                        if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                            self.dismiss()
                        }
                        self.isLoading = false
                        return
                    }
                    guard let documents = snapshot?.documents else {
                        self.isLoading = false
                        return
                    }
                    self.messages = documents.compactMap { doc in
                        let data = doc.data()
                        guard let senderId = data["senderId"] as? String,
                              !senderId.isEmpty else { return nil }
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                        return ChatMessage(
                            id: doc.documentID,
                            senderId: senderId,
                            text: data["text"] as? String ?? "",
                            createdAt: createdAt,
                            timeAgo: FeedView.timeAgoString(from: createdAt),
                            isMe: senderId == capturedUid
                        )
                    }
                    self.isLoading = false
                }
            }

        markAsRead()
    }

    // MARK: - Send Message

    func sendMessage() {
        guard !isSending else { return }
        if UserHandleCache.shared.isRestricted { return }
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, myMessageCount < messageLimit else { return }
        guard Auth.auth().currentUser?.uid != nil else { return }
        guard !isBlockedEitherDirection else { dismiss(); return }

        // Safety chain: content violation first (hard block), then name-check
        // (least disruptive), then crisis-check (more disruptive).
        if let violation = contentViolation(in: trimmed) {
            messageContentWarningMessage = contentViolationMessage(for: violation)
            showMessageContentWarning = true
            return
        }
        if containsNameOrIdentifyingInfo(trimmed) {
            pendingMessageText = trimmed
            showMessageNameWarning = true
            return
        }
        if let level = crisisCheckLevelRespectingSetting(for: trimmed) {
            pendingMessageText = trimmed
            messageGentleCheckLevel = level
            showMessageGentleCheck = true
            return
        }
        performSendChecked(trimmed)
    }

    /// Called after both safety checks pass (or after the user explicitly
    /// confirms in the warning dialogs). Captures uid here so the original
    /// guard chain can be skipped on the post-confirmation path.
    private func performSendChecked(_ trimmed: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isSending = true
        performSend(trimmed: trimmed, uid: uid)
    }

    private func performSend(trimmed: String, uid: String) {
        HapticManager.play(.send)

        let previousText = messageText
        messageText = ""
        myMessageCount += 1
        isCurrentlyTyping = false
        updateTypingStatus(false)

        let db = Firestore.firestore()
        let convoRef = db.collection("conversations").document(conversationId)
        let messageRef = convoRef.collection("messages").document()

        let batch = db.batch()
        batch.setData([
            "senderId": uid,
            "text": trimmed,
            "createdAt": FieldValue.serverTimestamp()
        ], forDocument: messageRef)
        batch.setData([
            "lastMessage": trimmed,
            "lastMessageAt": FieldValue.serverTimestamp(),
            "messageCount": [uid: FieldValue.increment(Int64(1))]
        ], forDocument: convoRef, merge: true)

        batch.commit { error in
            Task { @MainActor in
                self.isSending = false
                if error != nil {
                    self.messageText = previousText
                    self.myMessageCount = max(0, self.myMessageCount - 1)
                    return
                }
                guard !self.isBlockedEitherDirection else { return }
                let minuteBucket = Int(Date().timeIntervalSince1970 / 60)
                let docId = "message_\(self.conversationId)_\(uid)_\(minuteBucket)"
                db.collection("users").document(self.otherUserId)
                    .collection("notifications").document(docId).setData([
                        "type": "message",
                        "fromHandle": UserHandleCache.shared.handle,
                        "fromUserId": uid,
                        "message": "sent you a message",
                        "postId": "",
                        "conversationId": self.conversationId,
                        "isRead": false,
                        "createdAt": FieldValue.serverTimestamp()
                    ], merge: false)
            }
        }
    }

    // MARK: - Typing Indicator

    func updateTypingStatus(_ isTyping: Bool) {
        guard let uid = Auth.auth().currentUser?.uid, !conversationId.isEmpty else { return }
        guard listener != nil else { return }
        Firestore.firestore().collection("conversations").document(conversationId)
            .setData([
                "typing": [uid: isTyping],
                "typingAt": [uid: isTyping ? FieldValue.serverTimestamp() : FieldValue.delete()]
            ], merge: true)
    }

    // MARK: - Read Receipts

    func markAsRead() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("conversations").document(conversationId)
            .setData(["lastRead": [uid: FieldValue.serverTimestamp()]], merge: true) { error in
                if let error = error {
                    print("⚠️ markAsRead failed: \(error)")
                }
            }
    }

    // MARK: - Report

    func reportConversation() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // Match the hardened firestore.rules schema for the reports
        // collection: required type / status / createdAt and a bounded
        // reason. Without these the rule rejects the write silently.
        Firestore.firestore().collection("reports").addDocument(data: [
            "type": "conversation",
            "status": "pending",
            "reportedBy": uid,
            "reason": "other",
            "reasonLabel": "reported by user",
            "createdAt": FieldValue.serverTimestamp(),
            "conversationId": conversationId,
            "reportedUserId": otherUserId,
            "reportedHandle": otherHandle,
        ])
        Telemetry.reportSubmitted(target: .conversation, reasonCode: "other")
    }

    // MARK: - Block

    func blockAndDismiss() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        // BlockedUsersCache.block() now owns the Firestore write itself (fixed
        // in BlockedUsersCache.swift), so the manual setData call that was here
        // has been removed to avoid writing the document twice.
        BlockedUsersCache.shared.block(otherUserId, handle: otherHandle)
        db.collection("users").document(uid).collection("notifications")
            .whereField("fromUserId", isEqualTo: otherUserId)
            .getDocuments { snapshot, _ in
                for doc in snapshot?.documents ?? [] { doc.reference.delete() }
            }
        dismiss()
    }
}

// MARK: - ChatMessage

struct ChatMessage: Identifiable {
    let id: String
    let senderId: String
    let text: String
    let createdAt: Date
    let timeAgo: String
    let isMe: Bool
}
