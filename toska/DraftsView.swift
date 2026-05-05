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

    var body: some View {
            ZStack {
                LateNightTheme.background.ignoresSafeArea()

                if drafts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(LateNightTheme.tertiaryText)
                            .padding(.bottom, 4)
                        Text("nothing saved yet.")
                            .font(.custom("Georgia-Italic", size: 16))
                            .foregroundColor(LateNightTheme.secondaryText)
                        Text("write something, tap save instead of post.\nit stays here, just for you.")
                            .font(.system(size: 11))
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
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(draft.text)
                                        .font(.custom("Georgia", size: 14))
                                        .foregroundColor(LateNightTheme.primaryText)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                    Text(ToskaFormatters.fullDate.string(from: draft.createdAt).lowercased())
                                        .font(.system(size: 9))
                                        .foregroundColor(LateNightTheme.tertiaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
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
                ComposeView(
                    initialText: draft.text,
                    editingDraftId: draft.id,
                    onPostSuccess: nil
                )
            }
        .onAppear { startListening() }
        .onDisappear { stopListening() }
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
                        return
                    }
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
                    print("⚠️ DraftsView delete failed: \(error)")
                }
            }
    }
}

extension DraftItem: Equatable {
    static func == (lhs: DraftItem, rhs: DraftItem) -> Bool { lhs.id == rhs.id }
}
