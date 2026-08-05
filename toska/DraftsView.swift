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
    // (2026-08-05 draft-loss fix) A draft is the tag, the letter mode and the
    // GIF as well as the words — saving used to persist `text` only, so
    // reopening a saved draft quietly handed back a plain post. All three are
    // OPTIONAL with today's defaults so a draft doc written before the fields
    // existed decodes to exactly the behavior it has always had (no tag, not
    // a letter, no GIF) instead of failing to decode or coming back wrong.
    var tag: String? = nil
    var isLetter: Bool = false
    var gifUrl: String? = nil
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
                                    // (2026-08-05) Metadata line. Now that a
                                    // draft actually keeps its tag / letter
                                    // mode / GIF, the list says so — otherwise
                                    // two drafts that reopen differently look
                                    // identical here. Every element is
                                    // conditional on a field that defaults to
                                    // absent, so a pre-2026-08-05 draft simply
                                    // renders the date exactly as before.
                                    HStack(spacing: 8) {
                                        Text(ToskaFormatters.fullDate.string(from: draft.createdAt).lowercased())
                                            .font(ToskaFont.sans(11))
                                            .foregroundColor(LateNightTheme.tertiaryText)
                                        if draft.isLetter {
                                            HStack(spacing: 3) {
                                                Image(systemName: "envelope")
                                                    .font(.system(size: 9))
                                                Text("letter")
                                                    .font(ToskaFont.sans(11))
                                            }
                                            .foregroundColor(Color.toskaAccentGold)
                                            .accessibilityElement(children: .combine)
                                            .accessibilityLabel("letter draft")
                                        }
                                        if let tag = draft.tag, !tag.isEmpty {
                                            // Unknown tag (older build, hand-
                                            // edited doc) falls back to the
                                            // neutral chip color instead of
                                            // crashing on a nil lookup — same
                                            // fallback the composer uses.
                                            let tagData = sharedTags.first(where: { $0.name == tag })
                                            HStack(spacing: 3) {
                                                Image(systemName: tagData?.icon ?? "tag")
                                                    .font(.system(size: 9))
                                                Text(tag)
                                                    .font(ToskaFont.sans(11))
                                            }
                                            .foregroundColor(Color(hex: tagData?.colorHex ?? "9198a8"))
                                            .accessibilityElement(children: .combine)
                                            .accessibilityLabel("tagged \(tag)")
                                        }
                                        if draft.gifUrl != nil {
                                            // Icon only: the URL is never
                                            // fetched here (a list of drafts
                                            // shouldn't kick off N downloads),
                                            // just noted so the user knows the
                                            // GIF survived.
                                            Image(systemName: "photo")
                                                .font(.system(size: 9))
                                                .foregroundColor(LateNightTheme.tertiaryText)
                                                .accessibilityLabel("has a gif")
                                        }
                                    }
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
                    // (2026-08-05) Carry the whole draft back into the
                    // composer. initialIsLetter matters most: without it a
                    // saved letter of <=500 chars reopened as a NORMAL post
                    // (ComposeView could only infer letter mode from a body
                    // over the 500 cap), and the next keystroke would then
                    // hold the user to 500 characters.
                    ComposeView(
                        initialText: draft.text,
                        initialTag: draft.tag,
                        initialIsLetter: draft.isLetter,
                        initialGifUrl: draft.gifUrl,
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
                        // (2026-08-05) Conditional casts, not force/`as!`:
                        // every one of these fields is absent on drafts saved
                        // before today (and `tag`/`gifUrl` are absent on new
                        // drafts that simply don't have one — the writer omits
                        // the key rather than storing ""). A missing or
                        // wrong-typed value falls back to the pre-existing
                        // default; nothing here can throw the row away.
                        return DraftItem(
                            id: doc.documentID,
                            text: text,
                            createdAt: createdAt,
                            tag: data["tag"] as? String,
                            isLetter: data["isLetter"] as? Bool ?? false,
                            gifUrl: data["gifUrl"] as? String
                        )
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
