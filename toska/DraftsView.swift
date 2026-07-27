import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

// Draft list — pre-publish rehearsal space stored at
// users/{uid}/drafts/{draftId}. Owner-only at the rules layer; this
// view is the only place a user can see, edit, or publish them.
//
// Designed for "still in it" stage users who can't safely post yet
// (partner could see / recognize) but need somewhere to write the
// thing they can't say. Equally useful for any user who wants to
// draft something before committing it to feed.
//
// Tap a draft → open ComposeView prefilled with its text and the
// draftId; ComposeView's post-success callback deletes the original
// draft so a "publish" turns it into one real post (not a draft +
// post pair).
struct DraftItem: Identifiable {
    let id: String
    let text: String
    let createdAt: Date
}

@MainActor
struct DraftsView: View {
    @State private var drafts: [DraftItem] = []
    @State private var listener: ListenerRegistration? = nil
    @State private var selectedDraft: DraftItem? = nil
    // H2: surface a load failure instead of showing the "nothing saved" empty
    // state when the drafts read actually errored.
    @State private var draftsLoadFailed = false
    @State private var deleteError: String = ""   // F7: user-facing delete failure

    var body: some View {
            ZStack {
                LateNightTheme.background.ignoresSafeArea()
                // F7 (2026-07-27 full-audit) anchor — see .alert below.

                if draftsLoadFailed && drafts.isEmpty {
                    VStack {
                        ToskaErrorBanner("couldn't load drafts — check your connection") {
                            draftsLoadFailed = false
                            startListening()
                        }
                        Spacer()
                    }
                } else if drafts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(LateNightTheme.tertiaryText)
                            .padding(.bottom, 4)
                        Text("nothing saved yet.")
                            .font(ToskaFont.serifItalic(16))
                            .foregroundColor(LateNightTheme.secondaryText)
                        Text("write something, tap save instead of post.\nit stays here, just for you.")
                            .font(ToskaFont.sans(11))
                            .foregroundColor(LateNightTheme.tertiaryText)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                    }
                    .padding(.horizontal, 24)
                } else {
                    List {
                        ForEach(drafts) { draft in
                            Button {
                                selectedDraft = draft
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(draft.text)
                                        .font(ToskaFont.serif(16))
                                        .foregroundColor(LateNightTheme.primaryText)
                                        .lineSpacing(3)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                    Text(ToskaFormatters.fullDate.string(from: draft.createdAt).lowercased())
                                        .font(ToskaFont.sans(11))
                                        .foregroundColor(LateNightTheme.tertiaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(LateNightTheme.cardBackground)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(draftId: draft.id)
                                } label: {
                                    Label("delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("drafts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .fullScreenCover(item: $selectedDraft) { draft in
                EdgeSwipeDismissWrapper {
                    ComposeView(
                        initialText: draft.text,
                        onPostSuccess: nil,
                        editingDraftId: draft.id
                    )
                }
            }
        .onAppear { startListening() }
        .onDisappear { stopListening() }
        .alert("couldn't delete", isPresented: .init(
            get: { !deleteError.isEmpty }, set: { if !$0 { deleteError = "" } })) {
            Button("ok") { deleteError = "" }
        } message: { Text(deleteError) }
    }

    private func startListening() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        listener?.remove()
        // Capture uid + recheck inside the callback so a sign-out/sign-in
        // race doesn't write a previous user's drafts into the new user's
        // UI. Same pattern used elsewhere (UserHandleCache, FeedViewModel).
        let capturedUid = uid
        listener = Firestore.firestore()
            .collection("users").document(uid).collection("drafts")
            .order(by: "createdAt", descending: true)
            .limit(to: 100)
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == capturedUid else { return }
                    if let error = error {
                        print("⚠️ DraftsView listener error: \(error)")
                        draftsLoadFailed = true
                        return
                    }
                    draftsLoadFailed = false
                    drafts = snapshot?.documents.compactMap { doc in
                        let data = doc.data()
                        guard let text = data["text"] as? String else { return nil }
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                        return DraftItem(id: doc.documentID, text: text, createdAt: createdAt)
                    } ?? []
                }
            }
    }

    private func stopListening() {
        listener?.remove()
        listener = nil
    }

    private func delete(draftId: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore()
            .collection("users").document(uid)
            .collection("drafts").document(draftId)
            .delete { error in
                if let error = error {
                    // F7 (2026-07-27 full-audit): the swipe-delete failure was
                    // only print-logged (a no-op in release), so a real
                    // permission/backend error left the draft silently
                    // un-deleted. Surface it + buzz so the user knows to retry.
                    print("⚠️ DraftsView delete failed: \(error)")
                    Task { @MainActor in
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        deleteError = "couldn't delete that draft — try again in a moment."
                    }
                }
            }
    }
}

extension DraftItem: Equatable {
    static func == (lhs: DraftItem, rhs: DraftItem) -> Bool { lhs.id == rhs.id }
}
