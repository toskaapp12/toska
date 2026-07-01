import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// In-app moderation dashboard (admins only). Mirrors the web dashboard
// (docs/admin.html): same collections, queries, and writes — but reached from
// the phone you carry, over the app's App Attest App Check (which "just works",
// unlike the web reCAPTCHA path). Gated by AdminManager / firestore.rules.

// MARK: - Queue model

enum ModQueue: String, CaseIterable, Identifiable {
    case crisis, flagged, pending, reports, restricted
    var id: String { rawValue }
    var title: String {
        switch self {
        case .crisis: return "crisis"
        case .flagged: return "flagged"
        case .pending: return "pending"
        case .reports: return "reports"
        case .restricted: return "restricted"
        }
    }
}

// MARK: - Row models

struct ModPost: Identifiable {
    let id: String
    let text: String
    let handle: String
    let authorId: String
    let tag: String?
    let likes: Int
    let reposts: Int
    let replies: Int
    let createdAt: Date?
    let reason: String?     // flagReason / why it's here
}

struct ModReport: Identifiable {
    let id: String
    let type: String
    let reasonLabel: String
    let reportedHandle: String
    let reportedUserId: String?
    let postId: String?
    let text: String?
    let createdAt: Date?
}

struct ModUser: Identifiable {
    let id: String
    let handle: String
}

// MARK: - View

@MainActor
struct AdminModerationView: View {
    @State private var queue: ModQueue = .crisis
    @State private var posts: [ModPost] = []
    @State private var reports: [ModReport] = []
    @State private var users: [ModUser] = []
    @State private var counts: [ModQueue: Int] = [:]
    @State private var loading = true
    @State private var toast: String?
    @State private var confirm: ConfirmAction?
    // Bumped on each loadAll(); a loader completion only applies if its captured
    // token still matches — so a load from a tab you've since switched away from
    // can't overwrite the current tab's list.
    @State private var loadToken = 0

    private let db = Firestore.firestore()
    private var adminUid: String { Auth.auth().currentUser?.uid ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            header
            queueTabs
            Divider().background(ToskaColor.divider)
            content
        }
        .background(LateNightTheme.feedBackground.ignoresSafeArea())
        .navigationBarHidden(true)
        .overlay(alignment: .bottom) { toastView }
        .onAppear { loadAll() }
        // Reload when the queue changes — crisis/flagged/pending share `posts`, so
        // without this, switching tabs showed the previous tab's data (or blank).
        .onChange(of: queue) { _, _ in loadAll() }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if let c = confirm {
                Button(c.label, role: .destructive) { c.run() }
                Button("cancel", role: .cancel) { confirm = nil }
            }
        }
    }

    // MARK: Header

    @Environment(\.dismiss) private var dismiss
    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    .foregroundColor(ToskaColor.text)
            }
            Spacer()
            Text("moderation").toskaScreenTitle()
            Spacer()
            Button { loadAll() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .semibold))
                    .foregroundColor(ToskaColor.text2)
            }
        }
        .padding(.horizontal, ToskaSpace.md)
        .padding(.vertical, ToskaSpace.sm)
    }

    private var queueTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ToskaSpace.xs) {
                ForEach(ModQueue.allCases) { q in
                    let active = q == queue
                    Button {
                        queue = q
                        HapticManager.play(.tabSwitch)
                    } label: {
                        HStack(spacing: 6) {
                            Text(q.title).font(ToskaFont.sans(13, weight: active ? .semibold : .medium))
                            if let n = counts[q], n > 0 {
                                Text("\(n)")
                                    .font(ToskaFont.sans(11, weight: .bold))
                                    .foregroundColor(active ? .white : ToskaColor.text2)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(active ? Color.white.opacity(0.25) : ToskaColor.input, in: Capsule())
                            }
                        }
                        .foregroundColor(active ? .white : ToskaColor.text2)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(active ? ToskaColor.accent : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, ToskaSpace.md)
            .padding(.bottom, ToskaSpace.sm)
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        ScrollView {
            LazyVStack(spacing: ToskaSpace.sm) {
                if loading {
                    ProgressView().tint(ToskaColor.accent).padding(.top, 60)
                } else if isEmpty {
                    emptyState
                } else {
                    switch queue {
                    case .reports:
                        ForEach(reports) { reportCard($0) }
                    case .restricted:
                        ForEach(users) { userCard($0) }
                    default:
                        ForEach(posts) { postCard($0) }
                    }
                }
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, ToskaSpace.md)
            .padding(.top, ToskaSpace.md)
        }
        .refreshable { loadAll() }
    }

    private var isEmpty: Bool {
        switch queue {
        case .reports: return reports.isEmpty
        case .restricted: return users.isEmpty
        default: return posts.isEmpty
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: queue == .crisis ? "checkmark.circle" : "tray")
                .font(.system(size: 30, weight: .light)).foregroundColor(ToskaColor.text3)
            Text(queue == .crisis ? "nothing needs attention" : "nothing here right now")
                .font(ToskaFont.serifItalic(18)).foregroundColor(ToskaColor.text2)
        }
        .frame(maxWidth: .infinity).padding(.top, 72)
    }

    // MARK: Cards

    private func postCard(_ p: ModPost) -> some View {
        VStack(alignment: .leading, spacing: ToskaSpace.sm) {
            HStack {
                if let r = p.reason, !r.isEmpty {
                    Text(r).font(ToskaFont.sans(10, weight: .bold)).textCase(.uppercase).tracking(1)
                        .foregroundColor(Color.toskaErrorRed)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.toskaErrorRed.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
                Text(timeAgo(p.createdAt)).font(ToskaFont.meta).foregroundColor(ToskaColor.time)
            }
            // Tap to open the full thread for context.
            NavigationLink {
                PostDetailView(postId: p.id, handle: p.handle, text: p.text, tag: p.tag,
                               likes: p.likes, reposts: p.reposts, replies: p.replies,
                               time: timeAgo(p.createdAt), authorId: p.authorId)
                    .navigationBarHidden(true)
            } label: {
                Text(p.text)
                    .font(ToskaFont.serif(15)).foregroundColor(ToskaColor.text)
                    .lineSpacing(ToskaLineSpacing.body).lineLimit(8)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ToskaSpace.sm)
                    .background(ToskaColor.input, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            Text("by \(p.handle)  ·  \(p.likes) felt  ·  \(p.replies) replies")
                .font(ToskaFont.sans(11)).foregroundColor(ToskaColor.text3)
            HStack(spacing: ToskaSpace.xs) {
                if queue == .pending {
                    actionButton("approve", .green) { approvePending(p.id) }
                } else if queue == .crisis {
                    // Acknowledge a crisis post without deleting/clearing it —
                    // sets crisisReviewedAt so it drops out of the queue (and won't
                    // reappear), matching the web's mark-reviewed.
                    actionButton("reviewed", .green) { markCrisisReviewed(p.id) }
                } else {
                    actionButton("unflag", .green) { unflag(p.id) }
                }
                actionButton("delete", .red) {
                    confirm = ConfirmAction(title: "delete this post?", label: "delete") { deletePost(p.id) }
                }
                actionButton("restrict", .amber) {
                    confirm = ConfirmAction(title: "restrict \(p.handle)?", label: "restrict") { restrictUser(p.authorId, p.handle) }
                }
            }
        }
        .padding(ToskaSpace.md)
        .background(ToskaColor.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ToskaColor.divider, lineWidth: 1))
    }

    private func reportCard(_ r: ModReport) -> some View {
        VStack(alignment: .leading, spacing: ToskaSpace.sm) {
            HStack {
                Text(r.type).font(ToskaFont.sans(10, weight: .bold)).textCase(.uppercase).tracking(1)
                    .foregroundColor(ToskaColor.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(ToskaColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Spacer()
                Text(timeAgo(r.createdAt)).font(ToskaFont.meta).foregroundColor(ToskaColor.time)
            }
            Text("reason: \(r.reasonLabel)").font(ToskaFont.sans(12, weight: .medium)).foregroundColor(Color.toskaErrorRed)
            if let t = r.text, !t.isEmpty {
                Text(t).font(ToskaFont.serif(15)).foregroundColor(ToskaColor.text)
                    .lineSpacing(ToskaLineSpacing.body).lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ToskaSpace.sm).background(ToskaColor.input, in: RoundedRectangle(cornerRadius: 10))
            }
            Text("reported: \(r.reportedHandle)").font(ToskaFont.sans(11)).foregroundColor(ToskaColor.text3)
            HStack(spacing: ToskaSpace.xs) {
                actionButton("dismiss", .green) { dismissReport(r.id) }
                if let pid = r.postId, !pid.isEmpty {
                    actionButton("remove post", .red) {
                        confirm = ConfirmAction(title: "remove the reported post?", label: "remove") { removeReportedPost(r.id, pid) }
                    }
                }
                if let uid = r.reportedUserId, !uid.isEmpty {
                    actionButton("restrict", .amber) {
                        confirm = ConfirmAction(title: "restrict \(r.reportedHandle)?", label: "restrict") { restrictFromReport(r.id, uid, r.reportedHandle) }
                    }
                }
            }
        }
        .padding(ToskaSpace.md)
        .background(ToskaColor.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ToskaColor.divider, lineWidth: 1))
    }

    private func userCard(_ u: ModUser) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(u.handle).font(ToskaFont.sans(14, weight: .semibold)).foregroundColor(ToskaColor.text)
                Text("restricted").font(ToskaFont.sans(11)).foregroundColor(Color.toskaAccentTan)
            }
            Spacer()
            actionButton("un-restrict", .green) { unrestrictUser(u.id) }
        }
        .padding(ToskaSpace.md)
        .background(ToskaColor.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ToskaColor.divider, lineWidth: 1))
    }

    private enum BtnKind { case green, red, amber }
    private func actionButton(_ title: String, _ kind: BtnKind, _ action: @escaping () -> Void) -> some View {
        let color: Color = kind == .red ? Color.toskaErrorRed : kind == .amber ? Color.toskaAccentTan : Color.toskaMovingOnGreen
        return Button(action: { HapticManager.play(.tabSwitch); action() }) {
            Text(title).font(ToskaFont.sans(13, weight: .semibold)).foregroundColor(color)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(ToskaTapStyle())
    }

    @ViewBuilder private var toastView: some View {
        if let t = toast {
            Text(t).font(ToskaFont.sans(13, weight: .medium)).foregroundColor(.white)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(ToskaColor.text, in: Capsule())
                .padding(.bottom, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    struct ConfirmAction { let title: String; let label: String; let run: () -> Void }

    private func showToast(_ s: String) {
        withAnimation { toast = s }
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); withAnimation { toast = nil } }
    }
    private func timeAgo(_ d: Date?) -> String { d.map { ToskaFormatters.timeAgo(from: $0) } ?? "" }

    // MARK: - Loading

    private func loadAll() {
        loadToken += 1
        loading = true
        loadPosts()
        loadReports()
        loadUsers()
        // counts: refresh all queue badges
        refreshCount(.crisis); refreshCount(.flagged); refreshCount(.pending)
        refreshCount(.reports); refreshCount(.restricted)
    }

    private func postsQuery(_ q: ModQueue) -> Query {
        let c = db.collection("posts")
        switch q {
        case .crisis:  return c.whereField("concerningContent", isEqualTo: true)
        case .flagged: return c.whereField("flagged", isEqualTo: true)
        case .pending: return c.whereField("moderationStatus", isEqualTo: "pending_review")
        default:       return c
        }
    }

    private func loadPosts() {
        guard queue == .crisis || queue == .flagged || queue == .pending else { return }
        let token = loadToken
        let q = queue
        postsQuery(queue).limit(to: 50).getDocuments { snap, _ in
            Task { @MainActor in
                guard self.loadToken == token else { return }
                // Crisis queue hides already-reviewed posts (parity with the web).
                // Firestore can't query for an absent field, so filter client-side.
                let docs = (snap?.documents ?? []).filter { q != .crisis || $0.data()["crisisReviewedAt"] == nil }
                self.posts = docs.map { d in
                    let x = d.data()
                    return ModPost(
                        id: d.documentID,
                        text: x["text"] as? String ?? "",
                        handle: x["authorHandle"] as? String ?? "anonymous",
                        authorId: x["authorId"] as? String ?? "",
                        tag: x["tag"] as? String,
                        likes: x["likeCount"] as? Int ?? 0,
                        reposts: x["repostCount"] as? Int ?? 0,
                        replies: x["replyCount"] as? Int ?? 0,
                        createdAt: (x["createdAt"] as? Timestamp)?.dateValue(),
                        reason: x["flagReason"] as? String
                    )
                }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                self.loading = false
            }
        }
    }

    private func loadReports() {
        guard queue == .reports else { return }
        let token = loadToken
        db.collection("reports").whereField("status", isEqualTo: "pending").limit(to: 50).getDocuments { snap, _ in
            Task { @MainActor in
                guard self.loadToken == token else { return }
                self.reports = (snap?.documents ?? []).map { d in
                    let x = d.data()
                    return ModReport(
                        id: d.documentID,
                        type: x["type"] as? String ?? "report",
                        reasonLabel: x["reasonLabel"] as? String ?? x["reason"] as? String ?? "",
                        reportedHandle: x["reportedHandle"] as? String ?? "unknown",
                        reportedUserId: x["reportedUserId"] as? String,
                        postId: x["postId"] as? String,
                        text: x["text"] as? String,
                        createdAt: (x["createdAt"] as? Timestamp)?.dateValue()
                    )
                }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                self.loading = false
            }
        }
    }

    private func loadUsers() {
        guard queue == .restricted else { return }
        let token = loadToken
        db.collection("users").whereField("restricted", isEqualTo: true).limit(to: 50).getDocuments { snap, _ in
            Task { @MainActor in
                guard self.loadToken == token else { return }
                self.users = (snap?.documents ?? []).map { d in
                    ModUser(id: d.documentID, handle: d.data()["handle"] as? String ?? "anonymous")
                }
                self.loading = false
            }
        }
    }

    private func refreshCount(_ q: ModQueue) {
        // Crisis can't use a server aggregation: the list EXCLUDES already-
        // reviewed posts (crisisReviewedAt set) and Firestore can't count on an
        // absent field. Fetch + filter client-side so the badge matches the list
        // and actually clears once everything's reviewed (was permanently > 0).
        if q == .crisis {
            postsQuery(.crisis).limit(to: 200).getDocuments { snap, _ in
                let n = (snap?.documents ?? []).filter { $0.data()["crisisReviewedAt"] == nil }.count
                Task { @MainActor in counts[.crisis] = n }
            }
            return
        }
        let query: Query
        switch q {
        case .reports:    query = db.collection("reports").whereField("status", isEqualTo: "pending")
        case .restricted: query = db.collection("users").whereField("restricted", isEqualTo: true)
        default:          query = postsQuery(q)
        }
        query.count.getAggregation(source: .server) { snap, _ in
            Task { @MainActor in if let n = snap?.count { counts[q] = n.intValue } }
        }
    }

    // MARK: - Actions (match docs/admin.html writes)

    // All actions check the write error: the row is only removed + a success
    // toast shown when the write actually lands. On failure the row stays and an
    // error toast appears — otherwise a denied/offline write looked like success
    // and the moderator believed harmful content was handled when it wasn't.

    private func approvePending(_ id: String) {
        db.collection("posts").document(id).updateData([
            "moderationStatus": "live", "pendingApprovedAt": FieldValue.serverTimestamp(), "pendingApprovedBy": adminUid
        ]) { err in Task { @MainActor in
            if let err = err { showToast("couldn't approve: \(err.localizedDescription)") }
            else { removePost(id); showToast("approved") }
        } }
    }

    private func markCrisisReviewed(_ id: String) {
        db.collection("posts").document(id).updateData([
            "crisisReviewedAt": FieldValue.serverTimestamp(), "crisisReviewedBy": adminUid
        ]) { err in Task { @MainActor in
            if let err = err { showToast("error: \(err.localizedDescription)") }
            else { removePost(id); showToast("marked reviewed") }
        } }
    }

    private func unflag(_ id: String) {
        // Match the web: clear flags + flagReason, stamp the audit, AND restore a
        // held post to live so clearing the flag actually returns it to the feed.
        db.collection("posts").document(id).updateData([
            "flagged": false, "concerningContent": false, "flagReason": FieldValue.delete(),
            "moderationStatus": "live", "unflaggedBy": adminUid, "unflaggedAt": FieldValue.serverTimestamp()
        ]) { err in Task { @MainActor in
            if let err = err { showToast("couldn't clear: \(err.localizedDescription)") }
            else { removePost(id); showToast("cleared") }
        } }
    }

    private func deletePost(_ id: String) {
        let ref = db.collection("posts").document(id)
        ref.updateData(["deletedBy": adminUid, "deletedAt": FieldValue.serverTimestamp()]) { err in
            if let err = err { Task { @MainActor in self.showToast("couldn't delete: \(err.localizedDescription)") }; return }
            ref.delete { err2 in Task { @MainActor in
                if let err2 = err2 { self.showToast("couldn't delete: \(err2.localizedDescription)") }
                else { self.removePost(id); self.showToast("deleted") }
            } }
        }
    }

    private func restrictUser(_ uid: String, _ handle: String) {
        guard !uid.isEmpty else { return }
        db.collection("users").document(uid).updateData([
            "restricted": true, "restrictedAt": FieldValue.serverTimestamp(), "restrictedBy": adminUid
        ]) { err in Task { @MainActor in
            if let err = err { showToast("couldn't restrict: \(err.localizedDescription)") }
            else { refreshCount(.restricted); showToast("\(handle) restricted") }
        } }
    }

    private func dismissReport(_ id: String) {
        db.collection("reports").document(id).updateData([
            "status": "dismissed", "reviewedBy": adminUid, "reviewedAt": FieldValue.serverTimestamp(), "action": "dismissed"
        ]) { err in Task { @MainActor in
            if let err = err { showToast("error: \(err.localizedDescription)") }
            else { reports.removeAll { $0.id == id }; refreshCount(.reports); showToast("dismissed") }
        } }
    }

    private func removeReportedPost(_ reportId: String, _ postId: String) {
        let pref = db.collection("posts").document(postId)
        pref.updateData(["deletedBy": adminUid, "deletedAt": FieldValue.serverTimestamp()]) { err in
            if let err = err { Task { @MainActor in self.showToast("couldn't remove: \(err.localizedDescription)") }; return }
            pref.delete { err2 in
                if let err2 = err2 { Task { @MainActor in self.showToast("couldn't remove: \(err2.localizedDescription)") }; return }
                // Only mark the report resolved once the post is actually gone —
                // and only remove the row / claim success if THAT write lands too,
                // else the report reads as resolved locally while staying pending
                // on the server (it'd re-appear for the next moderator).
                self.db.collection("reports").document(reportId).updateData([
                    "status": "resolved", "reviewedBy": self.adminUid, "reviewedAt": FieldValue.serverTimestamp(), "action": "post_deleted"
                ]) { err3 in Task { @MainActor in
                    if let err3 = err3 { self.showToast("post removed, but couldn't resolve the report: \(err3.localizedDescription)") }
                    else { self.reports.removeAll { $0.id == reportId }; self.refreshCount(.reports); self.showToast("post removed") }
                } }
            }
        }
    }

    private func restrictFromReport(_ reportId: String, _ uid: String, _ handle: String) {
        db.collection("users").document(uid).updateData([
            "restricted": true, "restrictedAt": FieldValue.serverTimestamp(), "restrictedBy": adminUid
        ]) { err in
            // Don't mark the report resolved if the restrict write failed.
            if let err = err { Task { @MainActor in self.showToast("couldn't restrict: \(err.localizedDescription)") }; return }
            self.db.collection("reports").document(reportId).updateData([
                "status": "resolved", "reviewedBy": self.adminUid, "reviewedAt": FieldValue.serverTimestamp(), "action": "user_restricted"
            ]) { err2 in Task { @MainActor in
                // User is restricted; only clear the row if the resolve write also
                // landed, else the report stays pending on the server.
                if let err2 = err2 { self.showToast("\(handle) restricted, but couldn't resolve the report: \(err2.localizedDescription)") }
                else { self.reports.removeAll { $0.id == reportId }; self.refreshCount(.reports); self.showToast("\(handle) restricted") }
            } }
        }
    }

    private func unrestrictUser(_ uid: String) {
        db.collection("users").document(uid).updateData([
            "restricted": false, "restrictedAt": FieldValue.serverTimestamp(), "restrictedBy": adminUid
        ]) { err in Task { @MainActor in
            if let err = err { showToast("error: \(err.localizedDescription)") }
            else { users.removeAll { $0.id == uid }; refreshCount(.restricted); showToast("un-restricted") }
        } }
    }

    private func removePost(_ id: String) {
        posts.removeAll { $0.id == id }
        refreshCount(queue)
    }
}
