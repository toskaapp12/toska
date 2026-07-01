import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

@MainActor
struct DailyMomentView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var postText = ""
    @State private var postHandle = ""
    @State private var postTag: String? = nil
    @State private var feltCount = 0
    @State private var isVisible = false
    // FIX: added explicit loading state so the view shows a spinner instead
    // of blank/zero content while the fetch is in flight.
    @State private var isLoading = true

    // B1 (App Store 1.2): the daily moment is a prominent, share-encouraged
    // surface of another user's post, so it MUST carry the same report/block
    // affordances as every other UGC surface. We retain the real postId +
    // authorId of the fetched post (curated or trending) so Report/Block can
    // act on it. Fallback posts (setFallbackPost) leave these empty, which
    // hides the moderation menu — there's no real author to act against.
    @State private var postId = ""
    @State private var authorId = ""
    @State private var showReportSheet = false
    @State private var showBlockConfirm = false

    var timeLabel: String {
        "\(timeOfDayLabel())'s moment"
    }

    /// Show the report/block menu only for real fetched posts that aren't the
    /// viewer's own. Mirrors the gating in FeedView.FeedPostRow.
    private var canModerate: Bool {
        !postId.isEmpty && !authorId.isEmpty && authorId != Auth.auth().currentUser?.uid
    }

    var body: some View {
        ZStack {
            Color.toskaNearBlack
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Spacer()
                    if canModerate {
                        Menu {
                            Button {
                                showReportSheet = true
                            } label: {
                                Label("report", systemImage: "flag")
                            }
                            Button(role: .destructive) {
                                showBlockConfirm = true
                            } label: {
                                Label("block \(postHandle)", systemImage: "person.slash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .light))
                                .foregroundColor(.white.opacity(0.3))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("More options for this moment")
                    }
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.white.opacity(0.3))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if isLoading {
                    Spacer()
                    ProgressView()
                        .tint(Color.toskaBlue)
                    Spacer()
                } else {
                    Spacer()

                    VStack(spacing: 4) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.toskaBlue)
                                .frame(width: 4, height: 4)
                            Text(timeLabel)
                                .font(ToskaFont.sans(11, weight: .semibold))
                                .foregroundColor(Color.toskaBlue)
                                .tracking(1)
                        }

                        Text(formattedDate())
                            .font(ToskaFont.sans(11))
                            .foregroundColor(.white.opacity(0.2))
                    }
                    .opacity(isVisible ? 1 : 0)
                    .animation(reduceMotion ? .none : .easeIn(duration: 0.8).delay(0.3), value: isVisible)

                    Spacer()

                    Text(postText)
                        .font(ToskaFont.serif(22))
                        .foregroundColor(.white.opacity(0.95))
                        .lineSpacing(8)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                        .opacity(isVisible ? 1 : 0)
                        .offset(y: isVisible || reduceMotion ? 0 : 20)
                        .animation(reduceMotion ? .none : .easeOut(duration: 1.0).delay(0.6), value: isVisible)

                    Spacer()

                    VStack(spacing: 8) {
                        if let tag = postTag {
                            Text(tag)
                                .font(ToskaFont.sans(11, weight: .medium))
                                .foregroundColor(tagColor(for: tag).opacity(0.5))
                                .tracking(1)
                        }

                        Text("\(formatCount(feltCount)) felt this")
                            .font(ToskaFont.sans(11, weight: .medium))
                            .foregroundColor(Color.toskaBlue.opacity(0.7))

                        // Anonymous attribution — never the third party's handle
                        // (this card is screenshot/share-encouraged; a handle here
                        // becomes a searchable pseudonym off-platform).
                        Text("— someone on toska")
                            .font(ToskaFont.sans(11))
                            .foregroundColor(.white.opacity(0.15))
                    }
                    .opacity(isVisible ? 1 : 0)
                    .animation(reduceMotion ? .none : .easeIn(duration: 0.8).delay(1.2), value: isVisible)

                    Spacer()

                    VStack(spacing: 12) {
                        HStack(spacing: 5) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 10))
                            Text("screenshot this. share it. someone needs to see it.")
                                .font(ToskaFont.sans(11, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.2))
                        .opacity(isVisible ? 1 : 0)
                        .animation(reduceMotion ? .none : .easeIn(duration: 0.8).delay(1.8), value: isVisible)

                        Button {
                            shareAsImage()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 12))
                                Text("share moment")
                                    .font(ToskaFont.sans(12, weight: .medium))
                            }
                            .foregroundColor(Color.toskaBlue)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.toskaBlue.opacity(0.1))
                            .cornerRadius(20)
                        }
                        .opacity(isVisible ? 1 : 0)
                        .animation(reduceMotion ? .none : .easeIn(duration: 0.8).delay(2.0), value: isVisible)

                        Text("toska")
                            .font(ToskaFont.serifItalic(13))
                            .foregroundColor(.white.opacity(0.12))
                            .padding(.top, 4)
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                isVisible = true
            }
            fetchDailyPost()
        }
        .fullScreenCover(isPresented: $showReportSheet) {
            EdgeSwipeDismissWrapper {
                NavigationStack {
                    ReportSheet(target: .post(
                        postId: postId,
                        authorId: authorId,
                        authorHandle: postHandle,
                        text: postText
                    ))
                    .navigationBarHidden(true)
                }
            }
        }
        .confirmationDialog(
            "block \(postHandle)?",
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            Button("block", role: .destructive) {
                BlockedUsersCache.shared.block(authorId, handle: postHandle)
                // The moment is this author's content — once blocked there's
                // nothing left to show here, so dismiss back to the feed.
                dismiss()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("you wont see their posts or replies. they wont be notified.")
        }
    }

    // MARK: - Fetch

    // FIX: replaced the six-level callback pyramid with a single async/await
    // do/catch block. The original nested every Firestore call inside the
    // completion handler of the previous one, swallowing all errors with { _ in }
    // at each level. Now:
    //   - All errors fall through to a single catch that calls setFallbackPost().
    //   - isLoading is always set to false whether the fetch succeeds or fails,
    //     so the spinner never gets stuck on screen.
    //   - The logic is flat and easy to follow: check curated doc → fetch that
    //     post → or fetch trending → populate state.
    func fetchDailyPost() {
        let db = Firestore.firestore()
        Task { @MainActor in
            defer { isLoading = false }
            do {
                let todayString = formattedDateKey()
                let dailySnap = try await db
                    .collection("dailyMoment")
                    .document(todayString)
                    .getDocumentAsync()

                if let data = dailySnap.data(), let postId = data["postId"] as? String {
                    // A curated daily moment exists — fetch that specific post.
                    let postSnap = try await db
                        .collection("posts")
                        .document(postId)
                        .getDocumentAsync()

                    if let postData = postSnap.data() {
                        // Even a curated daily-moment post can have been
                        // flagged or expired between the curator's selection
                        // and now. Re-check before rendering — the in-app
                        // moderation policy is "hide flagged content from
                        // feeds", and that explicitly includes the daily
                        // moment surface (one of the most prominent in the
                        // app). Falls through to the trending fallback if
                        // any of these tripped.
                        let isFlagged = postData["flagged"] as? Bool == true
                        let isConcerning = postData["concerningContent"] as? Bool == true
                        let isExpired: Bool = {
                            guard let ts = postData["expiresAt"] as? Timestamp else { return false }
                            return ts.dateValue() < Date()
                        }()
                        let blockedAuthor: Bool = {
                            let authorId = postData["authorId"] as? String ?? ""
                            return BlockedUsersCache.shared.isBlocked(authorId)
                        }()
                        // Honor the author's sharing consent. This surface
                        // renders the post into an exportable image card and
                        // prompts "screenshot this. share it." — redistributing
                        // a post whose author turned sharing OFF. The feed gates
                        // its share button on `isShareable`; this surface must
                        // too. Legacy posts predate the flag and default to
                        // shareable (matches FeedView/ProfileView).
                        let notShareable = (postData["isShareable"] as? Bool ?? true) == false
                        // Fall back if authorId is missing — otherwise a real UGC
                        // post renders here with report/block disabled (no authorId
                        // to act on), the exact unreportable-content gap App Store
                        // 1.2 cares about.
                        let noAuthor = (postData["authorId"] as? String ?? "").isEmpty
                        // Parity with the trending query's server-side filters:
                        // only render a curated post that is still moderationStatus
                        // == "live" (a later removal / pending_review that didn't
                        // also set `flagged` would otherwise still show here), and
                        // skip reposts (they'd credit the reposter's handle for the
                        // original's words on the shared card).
                        let notLive = (postData["moderationStatus"] as? String ?? "") != "live"
                        let isRepost = postData["isRepost"] as? Bool == true
                        if isFlagged || isConcerning || isExpired || blockedAuthor || notShareable || noAuthor || notLive || isRepost {
                            setFallbackPost()
                        } else {
                            postText      = postData["text"]         as? String ?? ""
                            postHandle    = postData["authorHandle"] as? String ?? "anonymous"
                            postTag       = postData["tag"]          as? String
                            feltCount     = postData["likeCount"]    as? Int    ?? 0
                            // `postId` (the @State) is shadowed here by the local
                            // `let postId` from the dailyMoment doc — same value
                            // (this post's id), so qualify with self to assign it.
                            self.postId   = postSnap.documentID
                            self.authorId = postData["authorId"]     as? String ?? ""
                        }
                    } else {
                        // The curated post ID exists but the post was deleted.
                        setFallbackPost()
                    }
                } else {
                    // No curated moment — pick the most-liked post from the
                    // last 24 hours that isn't blocked or expired.
                    //
                    // Firestore requires the inequality field (`createdAt`) to
                    // be the first orderBy, so we can't order by likeCount in
                    // the query itself. Instead: fetch the 100 most-recent
                    // posts from the last 24 hours, then sort by likeCount
                    // client-side and pick the top that passes block/expiry
                    // filters. Uses the existing composite index
                    // (createdAt DESC, likeCount DESC).
                    let yesterday = Date().addingTimeInterval(-24 * 60 * 60)
                    let postsSnap = try await db
                        .collection("posts")
                        // moderationStatus filter required by firestore.rules
                        // 2026-05-31 (see FeedViewModel.fetchPosts comment).
                        .whereField("moderationStatus", isEqualTo: "live")
                        .whereField("createdAt", isGreaterThan: Timestamp(date: yesterday))
                        .order(by: "createdAt", descending: true)
                        .order(by: "likeCount", descending: true)
                        .limit(to: 100)
                        .getDocumentsAsync()

                    let sortedByLikes = postsSnap.documents.sorted { a, b in
                        let la = a.data()["likeCount"] as? Int ?? 0
                        let lb = b.data()["likeCount"] as? Int ?? 0
                        return la > lb
                    }

                    let blockedIds = BlockedUsersCache.shared.blockedUserIds
                    guard let topDoc = sortedByLikes.first(where: {
                        let d = $0.data()
                        let authorId = d["authorId"] as? String ?? ""
                        // Skip authorless posts — they'd render here unreportable
                        // (canModerate requires a non-empty authorId). Parity with
                        // the curated branch's noAuthor fallback.
                        if authorId.isEmpty { return false }
                        if blockedIds.contains(authorId) { return false }
                        if let expiresAt = d["expiresAt"] as? Timestamp,
                           expiresAt.dateValue() < Date() { return false }
                        // Same moderation filter as the curated path above:
                        // flagged or concerning posts are silently skipped
                        // here too. Reposts also skip — the original is
                        // what's actually trending; surfacing the repost
                        // would credit the wrong author handle on the
                        // daily-moment card.
                        if d["flagged"] as? Bool == true { return false }
                        if d["concerningContent"] as? Bool == true { return false }
                        if d["isRepost"] as? Bool == true { return false }
                        // Skip posts the author opted out of sharing — this
                        // surface exports the chosen post as a shareable image.
                        if (d["isShareable"] as? Bool ?? true) == false { return false }
                        return true
                    }) else {
                        setFallbackPost()
                        return
                    }

                    let data   = topDoc.data()
                    postText   = data["text"]         as? String ?? ""
                    postHandle = data["authorHandle"] as? String ?? "anonymous"
                    postTag    = data["tag"]          as? String
                    feltCount  = data["likeCount"]    as? Int    ?? 0
                    postId     = topDoc.documentID
                    authorId   = data["authorId"]     as? String ?? ""
                }
            } catch {
                // Any Firestore error (network down, permission denied, etc.)
                // lands here. Show a fallback post so the screen is never blank.
                print("⚠️ fetchDailyPost failed: \(error)")
                setFallbackPost()
            }
        }
    }

    // MARK: - Fallback

    func setFallbackPost() {
        let fallbacks: [(text: String, handle: String, tag: String, likes: Int)] = [
            (
                text: "its weird how you can just become a stranger to someone who knew what you looked like sleeping",
                handle: "anonymous_104782",
                tag: "regret",
                likes: 847
            ),
            (
                text: "you wouldve been the first person i told about how sad i am right now and thats the part that actually kills me",
                handle: "anonymous_291034",
                tag: "still love you",
                likes: 4521
            ),
            (
                text: "its not that i cant live without you its that everything is just slightly worse now. permanently. like someone turned the brightness down on everything and i cant find the setting",
                handle: "anonymous_552837",
                tag: "longing",
                likes: 6234
            ),
            (
                text: "i still sleep on my side of the bed even though the whole thing is mine now",
                handle: "anonymous_662081",
                tag: "moving on",
                likes: 2876
            ),
            (
                text: "somebody will ask me about you one day and ill say oh yeah like you didnt rewire my entire brain",
                handle: "anonymous_447291",
                tag: "regret",
                likes: 2341
            ),
        ]
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let pick = fallbacks[dayOfYear % fallbacks.count]
        postText   = pick.text
        postHandle = pick.handle
        postTag    = pick.tag
        feltCount  = pick.likes
        // Fallback posts are static editorial copy, not real UGC — no author
        // to report or block, so clear the ids to hide the moderation menu.
        postId     = ""
        authorId   = ""
    }

    // MARK: - Helpers

    func formattedDate() -> String {
        ToskaFormatters.longDate.string(from: Date()).lowercased()
    }

    /// dailyMoment doc IDs are written by the curator (server-side / Admin SDK
    /// — the dailyMoment rule is `allow write: if false;` for clients) so we
    /// have to match whatever calendar they used. UTC is the only timezone
    /// where every device on the planet computes the same key for the same
    /// instant — using the device's local time would make a user in PST and
    /// a user in JST look up different documents at the same UTC second.
    /// Without this explicit pin, ToskaFormatters.dateKey defaults to the
    /// device's current timezone, which only works coincidentally if the
    /// device happens to be on UTC.
    private static let utcDateKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    func formattedDateKey() -> String {
        Self.utcDateKey.string(from: Date())
    }

    // MARK: - Share

    @MainActor
    func shareAsImage() {
        let cardView = ZStack {
            Color.toskaNearBlack

            VStack(spacing: 0) {
                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.toskaBlue)
                        .frame(width: 4, height: 4)
                    Text(timeLabel)
                        .font(ToskaFont.sans(11, weight: .semibold))
                        .foregroundColor(Color.toskaBlue)
                        .tracking(1)
                }
                .padding(.bottom, 24)

                Text(postText)
                    .font(ToskaFont.serif(22))
                    .foregroundColor(.white.opacity(0.95))
                    .lineSpacing(8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Spacer()

                if let tag = postTag {
                    HStack(spacing: 5) {
                        let tagData = sharedTags.first(where: { $0.name == tag })
                        Image(systemName: tagData?.icon ?? "tag")
                            .font(.system(size: 10))
                        Text(tag)
                            .font(ToskaFont.sans(11, weight: .medium))
                    }
                    .foregroundColor(tagColor(for: tag).opacity(0.5))
                    .padding(.bottom, 8)
                }

                Text("\(formatCount(feltCount)) felt this")
                    .font(ToskaFont.sans(13, weight: .medium))
                    .foregroundColor(Color.toskaBlue.opacity(0.7))
                    .padding(.bottom, 6)

                // Do NOT stamp the third-party author's handle into the EXPORTED
                // image — this surface tells users to "screenshot this. share
                // it." off-platform, which would turn an anonymous pseudonym
                // into a searchable identifier on public media. Attribute
                // anonymously, matching ShareCardView (own posts show no handle).
                Text("— someone on toska")
                    .font(ToskaFont.sans(11))
                    .foregroundColor(.white.opacity(0.15))
                    .padding(.bottom, 24)

                VStack(spacing: 4) {
                    Text("toska")
                        .font(ToskaFont.serifItalic(18))
                        .foregroundColor(.white.opacity(0.15))
                    Text("for the things you couldnt say to them")
                        .font(ToskaFont.sans(11))
                        .foregroundColor(.white.opacity(0.08))
                }
                .padding(.bottom, 40)
            }
        }
        .frame(width: 1080 / 3, height: 1920 / 3)

        let renderer = ImageRenderer(content: cardView)
        renderer.scale = 3.0

        if let image = renderer.uiImage {
            presentShareSheet(with: [image])
        }
    }
}
