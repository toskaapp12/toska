import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

// MARK: - Prompt Responses ("what others said…", owner 2026-09-22)
//
// Everyone's answers to a given day's prompt, newest first. Reached from the
// feed's prompt band — the prompt becomes a shared moment, not just a
// writing cue. Rows are the canonical FeedPostRow (full interactions);
// the per-row purple prompt line is omitted since the whole page IS the
// prompt's context.
@MainActor
struct PromptResponsesView: View {
    let promptText: String
    let promptDate: String
    @Environment(\.dismiss) var dismiss

    @State private var responses: [FeedPost] = []
    @State private var hasLoaded = false
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ToskaHeader(title: "", onBack: { dismiss() }) { EmptyView() }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // The prompt itself, band-styled — same voice as the feed.
                        VStack(alignment: .leading, spacing: 0) {
                            Text("today's prompt")
                                .font(ToskaFont.sans(10.5, weight: .semibold))
                                .textCase(.uppercase)
                                .tracking(0.74)
                                .foregroundColor(ToskaColor.promptEyebrow)
                            Text(promptText)
                                .font(ToskaFont.serif(16))
                                .foregroundColor(ToskaColor.promptInk)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 6)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 14, leading: 28, bottom: 14, trailing: 28))
                        .background(ToskaColor.promptBg)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(ToskaColor.promptHair).frame(height: 1)
                        }

                        if loadFailed {
                            ToskaErrorBanner("couldn't load responses — check your connection") {
                                loadFailed = false; hasLoaded = false
                                load()
                            }
                        } else if !hasLoaded {
                            SkeletonFeed(kind: .post, count: 3)
                        } else if responses.isEmpty {
                            VStack(spacing: 8) {
                                Text("no one has answered yet.")
                                    .font(ToskaFont.serifItalic(16))
                                    .foregroundColor(ToskaColor.text2)
                                Text("your words could be the first.")
                                    .font(ToskaFont.sans(12.5))
                                    .foregroundColor(ToskaColor.text2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(responses) { post in
                                    FeedPostRow(
                                        handle: post.handle,
                                        text: post.text,
                                        tag: post.tag,
                                        likes: post.likes,
                                        reposts: post.reposts,
                                        replies: post.replies,
                                        time: post.time,
                                        postId: post.id,
                                        authorId: post.authorId,
                                        isAlreadyReposted: InteractionStateStore.shared.repostedPostIds.contains(post.id),
                                        isAlreadyLiked: InteractionStateStore.shared.likedPostIds.contains(post.id),
                                        isAlreadySaved: InteractionStateStore.shared.savedPostIds.contains(post.id),
                                        isShareable: post.isShareable
                                    )
                                    .equatable()
                                    .id(post.id)
                                }
                            }
                        }
                        Color.clear.frame(height: 40)
                    }
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard !hasLoaded else { return }
        let capturedUid = Auth.auth().currentUser?.uid
        Task { @MainActor in
            do {
                let snap = try await Firestore.firestore().collection("posts")
                    .whereField("promptDate", isEqualTo: promptDate)
                    .whereField("moderationStatus", isEqualTo: "live")
                    .order(by: "createdAt", descending: true)
                    .limit(to: 100)
                    .getDocumentsAsync()
                guard Auth.auth().currentUser?.uid == capturedUid else { return }
                responses = snap.documents
                    .map { FeedView.feedPost(from: $0) }
                    .filter { !BlockedUsersCache.shared.isBlocked($0.authorId) }
                hasLoaded = true
            } catch {
                loadFailed = true
                hasLoaded = true
            }
        }
    }
}
