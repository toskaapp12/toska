import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

@MainActor
struct FeelingCircleView: View {
    let tag: String
    @Environment(\.dismiss) var dismiss
    @State private var messages: [CircleMessage] = []
    @State private var newMessage = ""
    @State private var isSending = false
    @State private var myMessageCount = 0
    @State private var participantCount = 0
    @State private var listener: ListenerRegistration? = nil
    @State private var hasJoined = false
    @State private var showNameWarning = false
    @State private var showGentleCheck = false
    @State private var pendingMessageText = ""
    @State private var gentleCheckLevel: CrisisLevel = .soft
    // Report path for circle messages — Agent 8 noted these were a
    // moderation blind spot (no escape hatch on user-submitted text).
    @State private var reportTarget: CircleMessage? = nil

    private let messageLimit = 5

    var circleId: String {
        let dateKey = ToskaFormatters.dateKey.string(from: Date())
        return "\(dateKey)_\(tag)"
    }

    var canSend: Bool {
        !newMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isSending
        && myMessageCount < messageLimit
    }

    var body: some View {
        ZStack {
            Color(hex: "0a0908").ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: - Header
                VStack(spacing: 6) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .light))
                                .foregroundColor(Color.toskaBlue)
                        }
                        Spacer()
                        VStack(spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: sharedTags.first(where: { $0.name == tag })?.icon ?? "tag")
                                    .font(.system(size: 11))
                                Text(tag)
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(tagColor(for: tag))

                            Text("feeling circle · \(participantCount) \(participantCount == 1 ? "person" : "people")")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        Spacer()
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13))
                            .foregroundColor(.clear)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(tagColor(for: tag))
                            .frame(width: 4, height: 4)
                        Text("expires at your local midnight")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.2))
                    }
                    .padding(.bottom, 6)
                }

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)

                // MARK: - Messages
                if messages.isEmpty && hasJoined {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(.white.opacity(0.15))
                        Text("you're the first one here. set the tone. no pressure.")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.3))
                        Text("say it. someone else is on their way.")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.15))
                    }
                    Spacer()
                } else if !hasJoined {
                    Spacer()
                    VStack(spacing: 16) {
                        VStack(spacing: 4) {
                            Image(systemName: sharedTags.first(where: { $0.name == tag })?.icon ?? "tag")
                                .font(.system(size: 28, weight: .light))
                                .foregroundColor(tagColor(for: tag))
                            Text("feeling \(tag)?")
                                .font(.custom("Georgia-Italic", size: 20))
                                .foregroundColor(.white)
                                .padding(.top, 4)
                            Text("you're not the only one tonight.")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.35))
                        }

                        VStack(spacing: 6) {
                            Text("this is a temporary circle for everyone")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.25))
                            Text("feeling \(tag) today. \(messageLimit) messages each.")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.25))
                            Text("it disappears at midnight.")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.25))
                        }

                        Button {
                            joinCircle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.2")
                                    .font(.system(size: 12))
                                Text("join the circle")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(Color(hex: "0a0908"))
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .cornerRadius(20)
                        }
                        .padding(.top, 4)

                        if participantCount > 0 {
                            Text("\(participantCount) already here")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.2))
                        }
                    }
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(messages) { msg in
                                    circleMessage(msg)
                                        .id(msg.id)
                                }
                                Color.clear.frame(height: 12).id("bottom")
                            }
                            .padding(.top, 12)
                        }
                        .onChange(of: messages.count) { _, _ in
                            withAnimation {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                }

                // MARK: - Input
                if hasJoined {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)

                    VStack(spacing: 4) {
                        if myMessageCount >= messageLimit {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 10))
                                Text("you've shared your \(messageLimit) messages in this circle")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(.white.opacity(0.25))
                            .padding(.vertical, 12)
                        } else {
                            HStack(spacing: 10) {
                                TextField("say something...", text: $newMessage)
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .tint(tagColor(for: tag))
                                    .onChange(of: newMessage) { _, newValue in
                                        if newValue.count > 500 {
                                            newMessage = String(newValue.prefix(500))
                                        }
                                    }

                                Text("\(messageLimit - myMessageCount) left")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.2))

                                Button {
                                    sendMessage()
                                } label: {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 26))
                                        .foregroundColor(canSend ? tagColor(for: tag) : Color.white.opacity(0.1))
                                }
                                .disabled(!canSend)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                    }
                    .background(Color.white.opacity(0.03))
                }
            }
        }
        .onAppear {
            checkIfJoinedAndLoadCount()
        }
        .onDisappear {
            listener?.remove()
            listener = nil
        }
        .alert("keep it anonymous", isPresented: $showNameWarning) {
            Button("edit") {}
            Button("send anyway", role: .destructive) {
                if let level = crisisCheckLevelRespectingSetting(for: pendingMessageText) {
                    gentleCheckLevel = level
                    showGentleCheck = true
                } else {
                    postMessageNow(pendingMessageText)
                }
            }
        } message: {
            Text("your message may include a name or identifying info. toska is anonymous for everyone.")
        }
        .overlay {
            if showGentleCheck {
                CrisisCheckInView(
                    isPresented: $showGentleCheck,
                    level: gentleCheckLevel,
                    onProceed: { postMessageNow(pendingMessageText) }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showGentleCheck)
        .sheet(item: $reportTarget) { msg in
            // Reuse the user-target ReportSheet — circle messages are
            // ephemeral (gone at midnight) so a user-level report is more
            // useful for the moderation queue than a per-message ID that
            // won't exist by review time.
            ReportSheet(target: .user(userId: msg.authorId, handle: msg.handle))
        }
    }

    // MARK: - Message Bubble

    func circleMessage(_ msg: CircleMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if msg.isMe { Spacer(minLength: 60) }

            if !msg.isMe {
                ZStack {
                    Circle()
                        .fill(tagColor(for: tag).opacity(0.15))
                        .frame(width: 28, height: 28)
                    Text(String(msg.handle.replacingOccurrences(of: "anonymous_", with: "").prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(tagColor(for: tag))
                }
            }

            VStack(alignment: msg.isMe ? .trailing : .leading, spacing: 3) {
                if !msg.isMe {
                    Text(msg.handle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(tagColor(for: tag).opacity(0.5))
                }

                Text(msg.text)
                    .font(.system(size: 14))
                    .foregroundColor(msg.isMe ? .white : .white.opacity(0.85))
                    .lineSpacing(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        msg.isMe
                            ? tagColor(for: tag).opacity(0.25)
                            : Color.white.opacity(0.06)
                    )
                    .cornerRadius(14)

                Text(msg.time)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.15))
            }

            if !msg.isMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contextMenu {
            if !msg.isMe {
                Button(role: .destructive) {
                    reportTarget = msg
                } label: {
                    Label("report", systemImage: "flag")
                }
                Button(role: .destructive) {
                    BlockedUsersCache.shared.block(msg.authorId, handle: msg.handle)
                } label: {
                    Label("block", systemImage: "person.slash")
                }
            }
        }
    }

    // MARK: - Data Functions

    func checkIfJoinedAndLoadCount() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("feelingCircles").document(circleId).getDocument { snapshot, _ in
            Task { @MainActor in
                let participants = snapshot?.data()?["participants"] as? [String] ?? []
                participantCount = participants.count
                if participants.contains(uid) {
                    hasJoined = true
                    startListening()
                }
            }
        }
    }

    func joinCircle() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        let circleRef = db.collection("feelingCircles").document(circleId)

        let calendar = Calendar.current
        var midnight = calendar.startOfDay(for: Date())
        midnight = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight

        circleRef.setData([
            "tag": tag,
            "date": ToskaFormatters.dateKey.string(from: Date()),
            "participants": FieldValue.arrayUnion([uid]),
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: midnight)
        ], merge: true) { _ in
            Task { @MainActor in
                hasJoined = true
                participantCount += 1
                startListening()
            }
        }
    }

    func startListening() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let listenerUid = uid
        listener?.remove()

        listener = Firestore.firestore()
            .collection("feelingCircles").document(circleId)
            .collection("messages")
            .order(by: "createdAt", descending: false)
            .limit(to: 200)
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    // Re-check auth inside the callback. If the user signed
                    // out (or expired) while the listener was attached, the
                    // outer guard's captured uid is now stale — applying
                    // those messages would attribute them to a torn-down
                    // session and the next write would fail with code 7.
                    guard Auth.auth().currentUser?.uid == listenerUid else {
                        listener?.remove()
                        listener = nil
                        return
                    }
                    if let error = error {
                        let nsError = error as NSError
                        if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                            listener?.remove()
                            listener = nil
                        }
                        return
                    }
                    guard let docs = snapshot?.documents else { return }
                    var myCount = 0
                    messages = docs.compactMap { doc in
                        let data = doc.data()
                        let authorId = data["authorId"] as? String ?? ""
                        let isMe = authorId == listenerUid
                        if isMe { myCount += 1 }
                        if !isMe && BlockedUsersCache.shared.isBlocked(authorId) { return nil }
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                        return CircleMessage(
                            id: doc.documentID,
                            authorId: authorId,
                            handle: data["authorHandle"] as? String ?? "anonymous",
                            text: data["text"] as? String ?? "",
                            time: ToskaFormatters.hourMinute.string(from: createdAt).lowercased(),
                            isMe: isMe
                        )
                    }
                    myMessageCount = myCount
                }
            }
    }

    func sendMessage() {
        let trimmed = newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard myMessageCount < messageLimit else { return }

        if containsNameOrIdentifyingInfo(trimmed) {
            pendingMessageText = trimmed
            showNameWarning = true
            return
        }
        if let level = crisisCheckLevelRespectingSetting(for: trimmed) {
            pendingMessageText = trimmed
            gentleCheckLevel = level
            showGentleCheck = true
            return
        }

        postMessageNow(trimmed)
    }

    private func postMessageNow(_ text: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard myMessageCount < messageLimit else { return }
        guard !isSending else { return }

        isSending = true
        newMessage = ""

        let handle = UserHandleCache.shared.handle
        let db = Firestore.firestore()

        db.collection("feelingCircles").document(circleId)
            .collection("messages")
            .whereField("authorId", isEqualTo: uid)
            .count
            .getAggregation(source: .server) { snapshot, error in
                Task { @MainActor in
                    if let error = error {
                        print("⚠️ FeelingCircle count check failed: \(error)")
                        self.isSending = false
                        self.newMessage = text
                        return
                    }
                    let serverCount = Int(truncating: snapshot?.count ?? 0)
                    guard serverCount < self.messageLimit else {
                        self.myMessageCount = serverCount
                        self.isSending = false
                        return
                    }

                    db.collection("feelingCircles").document(self.circleId)
                        .collection("messages")
                        .addDocument(data: [
                            "text": text,
                            "authorId": uid,
                            "authorHandle": handle,
                            "createdAt": FieldValue.serverTimestamp()
                        ]) { error in
                            Task { @MainActor in
                                self.isSending = false
                                if error != nil {
                                    self.newMessage = text
                                }
                            }
                        }
                }
            }
    }
}
