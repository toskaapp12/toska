import SwiftUI
import Combine
import FirebaseAuth
@preconcurrency import FirebaseFirestore

// MARK: - Witness Post Data

struct WitnessPostData {
    let postId: String
    let handle: String
    let text: String
    let tag: String?
    let timeString: String
}

// MARK: - Anniversary Post Data

struct AnniversaryPostData {
    let postId: String
    let text: String
    let tag: String?
    let dateString: String
}

// MARK: - FeedViewModel

@MainActor
class FeedViewModel: ObservableObject {

    // MARK: - Tab & Navigation State
        @Published var selectedTab = 0
        @Published var showExplore = false
        @Published var showDailyMoment = false
        @Published var showWitnessPost = false
        @Published var showPromptCompose = false

    // MARK: - Post Data
    @Published var posts: [FeedPost] = []
        @Published var followingPosts: [FeedPost] = []
        @Published var followingFetchIncomplete = false

    // MARK: - Post Metadata (per-post flags keyed by post ID)
    @Published var repostedPostIds: Set<String> = []
    @Published var likedPostIds: Set<String> = []
    @Published var savedPostIds: Set<String> = []
    @Published var postGifUrls: [String: String] = [:]
    var midnightPostIds: Set<String> = []
    var letterPostIds: Set<String> = []
    var whisperPostIds: Set<String> = []
    var repostPostIds: Set<String> = []
    var expandedLetterIds: Set<String> = []

    // MARK: - Featured Content
    var witnessPost: WitnessPostData? = nil
    var emotionalWeather = ""
    var weatherTag = ""
    var mostUnsaidText = ""
    var mostUnsaidLikes = 0
    var mostUnsaidPostId = ""
    var anniversaryPost: AnniversaryPostData? = nil
    var hasDailyMoment = false

    // MARK: - Fetch State
    // Simple in-flight flag so fetchPosts callers coalesce instead of stacking
    // duplicate Firestore queries on rapid trigger (onAppear + notification, etc).
    var isFetchingPosts = false

    // MARK: - Error State
    @Published var fetchError: String? = nil

    // MARK: - Pagination
    var lastDocument: DocumentSnapshot? = nil
    var isLoadingMore = false
    var hasMorePosts = true
    var endedDueToBlocking = false

    // MARK: - Lifecycle
        var hasFetchedInitial = false
    @Published var hasLoadedOnce = false
        var lastForegroundFetch: Date? = nil
        @Published var isRefreshing = false
    @Published var dragOffset: CGFloat = 0
        @Published var hasAppeared: Bool = false
        var savedScrollPostId: String? = nil

    // MARK: - Personalization
    var userMood: String? = nil
    var engagedTags: [String: Int] = [:]

    // MARK: - Constants
    let tabs = ["for you", "following"]

    let samplePosts: [FeedPost] = [
            FeedPost(id: "sample_1", handle: "anonymous_291034", text: "its weird how you can just become a stranger to someone who knew what you looked like sleeping", tag: "longing", likes: 847, reposts: 34, replies: 89, time: "2h", authorId: "", isShareable: true),
            FeedPost(id: "sample_2", handle: "anonymous_583021", text: "i dont even want you back i just want the months back", tag: "anger", likes: 1204, reposts: 67, replies: 43, time: "3h", authorId: "", isShareable: true),
            FeedPost(id: "sample_3", handle: "anonymous_104782", text: "somebody will ask me about you one day and ill say \"oh yeah\" like you didnt rewire my entire brain", tag: "regret", likes: 2341, reposts: 112, replies: 156, time: "4h", authorId: "", isShareable: true),
            FeedPost(id: "sample_4", handle: "anonymous_672190", text: "the funniest thing about heartbreak is you still have to like. go to work. and buy groceries. and act normal", tag: "acceptance", likes: 1893, reposts: 89, replies: 201, time: "5h", authorId: "", isShareable: true),
            FeedPost(id: "sample_5", handle: "anonymous_385021", text: "its 3am and im not texting you but i want credit for that", tag: "longing", likes: 3102, reposts: 145, replies: 178, time: "6h", authorId: "", isShareable: true),
            FeedPost(id: "sample_6", handle: "anonymous_910283", text: "you wouldve been the first person i told about how sad i am right now and thats the part that actually kills me", tag: "still love you", likes: 4521, reposts: 203, replies: 312, time: "8h", authorId: "", isShareable: true),
            FeedPost(id: "sample_7", handle: "anonymous_447291", text: "its not that i cant live without you its that everything is just slightly worse now. permanently. like someone turned the brightness down on everything and i cant find the setting", tag: "regret", likes: 6234, reposts: 289, replies: 445, time: "10h", authorId: "", isShareable: true),
            FeedPost(id: "sample_8", handle: "anonymous_662081", text: "i still sleep on my side of the bed even though the whole thing is mine now", tag: "moving on", likes: 2876, reposts: 134, replies: 198, time: "12h", authorId: "", isShareable: true),
        ]

    // MARK: - Daily Writing Prompts

    static let dailyPrompts: [(String, String, String)] = [
            ("its 2am and you cant sleep. what are you thinking about.", "longing", "moon.stars"),
            ("whats the thing you cant tell anyone because theyd say youre crazy", "longing", "moon.stars"),
            ("type out the text you almost sent last night", "unsent", "envelope"),
            ("what do you miss that has nothing to do with them as a person. like their dog. or their car. or their kitchen.", "regret", "arrow.uturn.backward"),
            ("do you still check their social media. be honest.", "longing", "moon.stars"),
            ("whats something small that still ruins you. a song. a street. a food.", "regret", "arrow.uturn.backward"),
            ("are you actually healing or just getting quieter about it", "confusion", "questionmark.circle"),
            ("what would you say if they called right now. no thinking just say it.", "still love you", "heart"),
            ("i dont want to start over with someone new and explain all my shit again. do you feel that.", "moving on", "arrow.right.circle"),
            ("do you think they feel guilty or are you not even something to feel guilty about", "anger", "flame"),
            ("say the thing you pretend you dont feel anymore", "still love you", "heart"),
            ("what song do you skip now because it ruins you", "longing", "moon.stars"),
            ("be honest. would you take them back right now if they asked.", "still love you", "heart"),
            ("whats the thought you have every single morning before you can stop it", "longing", "moon.stars"),
            ("write the letter youll never send. start with dear you.", "unsent", "envelope"),
            ("what did they say that you still hear on repeat", "regret", "arrow.uturn.backward"),
            ("do you miss them or do you miss not being alone. its okay if you dont know.", "confusion", "questionmark.circle"),
            ("whats the most pathetic thing youve done since it ended. no judgment here.", "regret", "arrow.uturn.backward"),
            ("what are you pretending is fine right now", "acceptance", "leaf"),
            ("did you eat today. did you sleep. are you drinking water. be honest.", "acceptance", "leaf"),
            ("whats the thing you cant forgive them for", "anger", "flame"),
            ("say something you havent said out loud to anyone. not even yourself.", "unsent", "envelope"),
            ("do you think about them every day still or just most days", "longing", "moon.stars"),
            ("whats the last thing that made you cry about it. like actually cry.", "regret", "arrow.uturn.backward"),
            ("are you angry or just really really sad. or both.", "anger", "flame"),
            ("i keep thinking maybe if i was different. not even better just different. do you do that too.", "confusion", "questionmark.circle"),
            ("finish this: i just want someone to", "longing", "moon.stars"),
            ("the thing nobody understands about what happened is", "confusion", "questionmark.circle"),
            ("do you still love them. you dont have to answer that. but do you.", "still love you", "heart"),
            ("i think the worst feeling is being forgotten by someone you still remember everything about", "longing", "moon.stars"),
            ("how are you. and not the version you tell people.", "confusion", "questionmark.circle"),
        ]

    // MARK: - Computed Properties

    var currentPosts: [FeedPost] {
        switch selectedTab {
        case 1: return followingPosts.isEmpty ? [] : followingPosts
        default: return posts
        }
    }

    var todaysPrompt: (String, String, String) {
        guard !Self.dailyPrompts.isEmpty else {
            return ("how are you, really?", "confusion", "questionmark.circle")
        }
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return Self.dailyPrompts[dayOfYear % Self.dailyPrompts.count]
    }

    var promptTimeLabel: String {
        "\(timeOfDayLabel())'s prompt"
    }

    var timeGreeting: String {
            let hour = Calendar.current.component(.hour, from: Date())
            if hour >= 0 && hour < 5 { return "still up?" }
            else if hour < 9 { return "how did you sleep. honestly." }
            else if hour < 12 { return "one hour at a time." }
            else if hour < 17 { return "still here." }
            else if hour < 21 { return "made it through the day." }
            else { return "its late. were here." }
        }

    var dailyMomentLabel: String {
        "\(timeOfDayLabel())'s moment"
    }

    // MARK: - Initial Load

    
    var supplementaryTask: Task<Void, Never>? = nil

        func loadInitialData() {
            print("⚡️ loadInitialData called — hasFetchedInitial: \(hasFetchedInitial), hasAuth: \(Auth.auth().currentUser != nil)")
            guard !hasFetchedInitial else {
                print("⚡️ loadInitialData — already fetched, posts.count: \(posts.count)")
                if posts.isEmpty {
                    fetchPosts()
                }
                return
            }
            guard Auth.auth().currentUser != nil else {
                print("🛑 loadInitialData — auth is nil, should not happen after isLoggedIn=true")
                return
            }
            hasFetchedInitial = true
                                lastForegroundFetch = Date()
                                savedScrollPostId = nil
                                print("⚡️ loadInitialData — proceeding with fetch")

            supplementaryTask?.cancel()
                    supplementaryTask = Task { @MainActor in
                        self.refreshAll()
                        guard !Task.isCancelled, Auth.auth().currentUser != nil else { return }
                        self.fetchUserPreferences()
                        guard !Task.isCancelled, Auth.auth().currentUser != nil else { return }
                        self.fetchAnniversaryPost()
                    }
                }

    func cancelAllTasks() {
            supplementaryTask?.cancel()
            supplementaryTask = nil
            followingTask?.cancel()
            followingTask = nil
            userPreferencesTask?.cancel()
            userPreferencesTask = nil
            likedListener?.remove()
            likedListener = nil
            savedListener?.remove()
            savedListener = nil
            repostedListener?.remove()
            repostedListener = nil
            hasFetchedInitial = false
        hasLoadedOnce = false
        posts = []
        followingPosts = []
        likedPostIds = []
        savedPostIds = []
        repostedPostIds = []
        fetchError = nil
                savedScrollPostId = nil
                dragOffset = 0
            }

    func handleNewPostCreated() {
        fetchPosts()
        fetchMostUnsaidAndDailyMoment()
    }

    // Called from FeedView in response to .userBlocked so the blocked user's
    // posts vanish from the in-memory feed immediately, without waiting for
    // the next refresh to re-run filterBlocked.
    func handleUserBlocked(userId: String) {
        guard !userId.isEmpty else { return }
        let isBlockedAuthor: (FeedPost) -> Bool = { $0.authorId == userId }
        posts.removeAll(where: isBlockedAuthor)
        followingPosts.removeAll(where: isBlockedAuthor)
        // postGifUrls/midnightPostIds/etc. are keyed by postId, not by
        // authorId, so we can't prune by uid directly. Fall through to
        // trimPostMetadata which intersects all metadata stores with the
        // current posts array (after the removeAll above), dropping any
        // stale entries for the blocked author's posts.
        trimPostMetadata()
        // repostedPostIds / likedPostIds / savedPostIds are per-post, not
        // per-author, and self-heal via their snapshot listeners — no need
        // to prune them here.
    }

    func handleInteractionChanged(_ info: [AnyHashable: Any]) {
        guard let postId = info["postId"] as? String,
              let action = info["action"] as? String,
              let value = info["value"] as? Bool else { return }
        switch action {
        case "like":
            if value { likedPostIds.insert(postId) } else { likedPostIds.remove(postId) }
        case "save":
            if value { savedPostIds.insert(postId) } else { savedPostIds.remove(postId) }
        case "repost":
            // Mirror likes/saves — without this, a repost tapped from
            // PostDetailView or the feed's context menu doesn't flip the
            // repost state on other rendered copies of the same post, so
            // the button stays in its pre-action state until a full refresh.
            if value { repostedPostIds.insert(postId) } else { repostedPostIds.remove(postId) }
        default: break
        }
    }

    func handleForegroundReturn() {
            LateNightThemeManager.shared.refresh()
            guard hasFetchedInitial else { return }
            if let last = lastForegroundFetch, Date().timeIntervalSince(last) < 60 { return }
            lastForegroundFetch = Date()
            fetchError = nil
            fetchPosts()
            fetchFollowingPosts()
        }

    // MARK: - Refresh All

    func refreshAll() {
                fetchError = nil
                fetchRepostedPostIds()
                fetchLikedPostIds()
                fetchSavedPostIds()
                fetchPosts()
                fetchFollowingPosts()
                fetchWitnessPost()
                fetchEmotionalWeather()
                fetchMostUnsaidAndDailyMoment()
                fetchAnniversaryPost()
            }

    // MARK: - Fetch User Interaction States

    // Snapshot listeners keep likedPostIds / savedPostIds / repostedPostIds
    // continuously in sync with Firestore. Each listener fires only on the
    // delta since its last snapshot, so a like added on another device shows
    // up immediately here without a refresh, and pull-to-refresh no longer
    // re-fetches 500 docs per call (previous pattern burned ~1500 reads per
    // refresh across these three). Listeners are idempotent — subsequent
    // fetch*() calls with a listener already attached are no-ops; they are
    // torn down and reset in cancelAllTasks on sign-out.
    private var likedListener: ListenerRegistration? = nil
    private var savedListener: ListenerRegistration? = nil
    private var repostedListener: ListenerRegistration? = nil

    func fetchLikedPostIds() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard likedListener == nil else { return }
        // Capture uid so the callback can verify it's still serving the same
        // account before mutating @Published state. Without this, an in-flight
        // snapshot fired after a sign-out/sign-in for a different user can
        // write the previous user's liked set into the new user's UI.
        let capturedUid = uid
        likedListener = Firestore.firestore()
            .collection("users").document(uid).collection("liked")
            .order(by: "createdAt", descending: true)
            .limit(to: 500)
            .addSnapshotListener { [weak self] snapshot, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          Auth.auth().currentUser?.uid == capturedUid else { return }
                    self.likedPostIds = Set(snapshot?.documents.map { $0.documentID } ?? [])
                }
            }
    }

    func fetchSavedPostIds() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard savedListener == nil else { return }
        let capturedUid = uid
        savedListener = Firestore.firestore()
            .collection("users").document(uid).collection("saved")
            .order(by: "createdAt", descending: true)
            .limit(to: 500)
            .addSnapshotListener { [weak self] snapshot, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          Auth.auth().currentUser?.uid == capturedUid else { return }
                    self.savedPostIds = Set(snapshot?.documents.map { $0.documentID } ?? [])
                }
            }
    }

    func fetchRepostedPostIds() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard repostedListener == nil else { return }
        let capturedUid = uid
        repostedListener = Firestore.firestore()
            .collection("posts")
            .whereField("authorId", isEqualTo: uid)
            .whereField("isRepost", isEqualTo: true)
            .order(by: "createdAt", descending: true)
            .limit(to: 200)
            .addSnapshotListener { [weak self] snapshot, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          Auth.auth().currentUser?.uid == capturedUid else { return }
                    let ids = snapshot?.documents.compactMap { $0.data()["originalPostId"] as? String } ?? []
                    self.repostedPostIds = Set(ids)
                }
            }
    }

    // MARK: - Fetch User Preferences for For You

    // Task storage so rapid repeat calls (e.g. loadInitialData → refreshAll in
    // quick succession) cancel any prior in-flight preferences fetch before
    // starting a new one. Previously there was no cancellation guard and no
    // task storage, so two concurrent fetches each ran the TaskGroup-based
    // tag rollup and their increments were both applied to engagedTags —
    // doubling counts. The new version also assigns engagedTags rather than
    // incrementing into it, which makes repeat fetches idempotent.
    private var userPreferencesTask: Task<Void, Never>? = nil

    func fetchUserPreferences() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        userPreferencesTask?.cancel()
        userPreferencesTask = Task { @MainActor [weak self] in
            let db = Firestore.firestore()

            // Mood lives in users/{uid}/private/data going forward (owner-only)
            // so it isn't readable by other authenticated users via the public
            // users-doc rule. Older accounts may still have it on the main doc;
            // fall back there until OnboardingView/SettingsView writes the new
            // location and the legacy field gets cleared.
            async let mainSnap = try? db.collection("users").document(uid).getDocumentAsync()
            async let privateSnap = try? db.collection("users").document(uid)
                .collection("private").document("data").getDocumentAsync()
            let main = await mainSnap?.data() ?? [:]
            let priv = await privateSnap?.data() ?? [:]
            guard !Task.isCancelled, let self else { return }
            self.userMood = (priv["selectedMood"] as? String) ?? (main["selectedMood"] as? String)

            // Engaged-tag rollup: fetch the last 50 liked posts, then fetch the
            // tag of each in parallel chunks, then REPLACE engagedTags with the
            // fresh count. Never += into the existing dictionary — that
            // accumulated across refreshes and quietly skewed the for-you
            // score boost at line ~514.
            guard let likedSnap = try? await db.collection("users").document(uid).collection("liked")
                .order(by: "createdAt", descending: true)
                .limit(to: 50)
                .getDocumentsAsync() else { return }
            guard !Task.isCancelled else { return }

            let postIds = likedSnap.documents.map { $0.documentID }
            guard !postIds.isEmpty else {
                self.engagedTags = [:]
                return
            }
            let chunks = stride(from: 0, to: postIds.count, by: 30).map {
                Array(postIds[$0..<min($0 + 30, postIds.count)])
            }

            var newTags: [String: Int] = [:]
            await withTaskGroup(of: [String].self) { group in
                for chunk in chunks {
                    group.addTask {
                        guard !Task.isCancelled else { return [] }
                        guard let postSnap = try? await db.collection("posts")
                            .whereField(FieldPath.documentID(), in: chunk)
                            .getDocumentsAsync() else { return [] }
                        return postSnap.documents.compactMap { $0.data()["tag"] as? String }
                    }
                }
                for await tags in group {
                    for tag in tags {
                        newTags[tag, default: 0] += 1
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self.engagedTags = newTags
        }
    }

    // MARK: - Filter Helper

    nonisolated func filterBlocked(documents: [QueryDocumentSnapshot]) -> [QueryDocumentSnapshot] {
        return documents.filter { doc in
            let data = doc.data()
            let authorId = data["authorId"] as? String ?? ""
            if BlockedUsersCache.shared.isBlocked(authorId) { return false }
            if let originalAuthorId = data["originalAuthorId"] as? String,
               BlockedUsersCache.shared.isBlocked(originalAuthorId) { return false }
            if let expiresAt = data["expiresAt"] as? Timestamp,
               expiresAt.dateValue() < Date() { return false }
            // Hide posts flagged by server-side moderation (Cloud Functions)
            if data["flagged"] as? Bool == true { return false }
            return true
        }
    }

    // MARK: - Extract extra post metadata

    /// Soft cap to prevent unbounded growth across long sessions. Once a per-
    /// post metadata cache exceeds this size, we drop a random ~20% of entries.
    /// Random drop avoids the scan cost of LRU tracking while still bounding
    /// memory; cache misses just re-extract from the next snapshot pass.
    private static let postMetadataSoftCap = 800

    func extractPostMetadata(from doc: QueryDocumentSnapshot) {
        let docData = doc.data()
        if let gifUrl = docData["gifUrl"] as? String {
            postGifUrls[doc.documentID] = gifUrl
        }
        if docData["isMidnightPost"] as? Bool == true {
            midnightPostIds.insert(doc.documentID)
        }
        if docData["isLetter"] as? Bool == true {
            letterPostIds.insert(doc.documentID)
        }
        if docData["isRepost"] as? Bool == true {
            repostPostIds.insert(doc.documentID)
        }
        if docData["isWhisper"] as? Bool == true {
            whisperPostIds.insert(doc.documentID)
        }
        // Trim if any of the metadata stores have grown past the cap. Cheap
        // count check; the actual trim only runs occasionally.
        if postGifUrls.count > Self.postMetadataSoftCap
            || midnightPostIds.count > Self.postMetadataSoftCap
            || letterPostIds.count > Self.postMetadataSoftCap
            || repostPostIds.count > Self.postMetadataSoftCap
            || whisperPostIds.count > Self.postMetadataSoftCap {
            trimPostMetadata()
        }
    }

    private func trimPostMetadata() {
        // Keep metadata for any post that is currently visible in either the
        // For You feed or the Following feed. Using only `posts` here would
        // drop metadata for Following-tab-only posts the moment this runs.
        var keepIds = Set(posts.map { $0.id })
        keepIds.formUnion(followingPosts.map { $0.id })
        postGifUrls = postGifUrls.filter { keepIds.contains($0.key) }
        midnightPostIds = midnightPostIds.intersection(keepIds)
        letterPostIds = letterPostIds.intersection(keepIds)
        repostPostIds = repostPostIds.intersection(keepIds)
        whisperPostIds = whisperPostIds.intersection(keepIds)
    }

    // MARK: - Fetch Posts

    func fetchPosts() {
            guard Auth.auth().currentUser != nil else {
                print("⚠️ fetchPosts — skipped, currentUser is nil at call time")
                return
            }
            // Coalesce concurrent callers. Without this, every rapid onAppear /
            // notification trigger fires a fresh 60-doc Firestore query in parallel,
            // wasting reads and racing on posts assignment.
            guard !isFetchingPosts else {
                print("⚠️ fetchPosts — already in flight, skipping")
                return
            }
            isFetchingPosts = true
            // Reset the blocking-saturation flag here too, not just inside
            // loadMorePosts. Without this, a refresh that lands on a clean
            // batch never clears the stale flag set by a prior pagination
            // session, and the UI can incorrectly show end-of-feed copy.
            endedDueToBlocking = false
            let db = Firestore.firestore()
            print("🔄 fetchPosts — firing Firestore query, hasAuth: \(Auth.auth().currentUser != nil)")

            Task { @MainActor in
                defer { self.isFetchingPosts = false }
                guard let snapshot = try? await db.collection("posts")
                    .order(by: "createdAt", descending: true)
                    .limit(to: 60)
                    .getDocumentsAsync() else {
                    self.hasLoadedOnce = true
                    self.posts = []
                    return
                }
                self.fetchError = nil
                let documents = snapshot.documents
                print("✅ fetchPosts — got \(documents.count) docs from Firestore")
                let filtered = self.filterBlocked(documents: documents)

                    let scored: [(doc: QueryDocumentSnapshot, score: Double)] = filtered.map { doc in
                        let data = doc.data()
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                        let likeCount = data["likeCount"] as? Int ?? 0
                        let replyCount = data["replyCount"] as? Int ?? 0
                        let tag = data["tag"] as? String

                        var score: Double = 0

                                                let hoursAgo = Date().timeIntervalSince(createdAt) / 3600
                                                if hoursAgo < 1 { score += 50 }
                                                else if hoursAgo < 3 { score += 40 }
                                                else if hoursAgo < 6 { score += 30 }
                                                else if hoursAgo < 12 { score += 20 }
                                                else if hoursAgo < 24 { score += 10 }
                                                else { score += max(0, 5 - hoursAgo / 24) }

                                                let decayFactor = max(0.2, 1.0 - (hoursAgo / 48.0))
                                                score += Double(likeCount) * 1.5 * decayFactor
                                                score += Double(replyCount) * 2.0 * decayFactor

                        if let tag = tag, let mood = self.userMood, tag == mood {
                            score += 15
                        }

                        if let tag = tag, let tagCount = self.engagedTags[tag] {
                            score += Double(tagCount) * 5
                        }

                        if tag != nil { score += 3 }
                        if data["isLetter"] as? Bool == true { score += 5 }

                        var hasher = Hasher()
                        hasher.combine(doc.documentID)
                        hasher.combine(Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0)
                        let hash = abs(hasher.finalize())
                        score += Double(hash % 500) / 100.0

                        return (doc: doc, score: score)
                    }

                    let ranked = scored.sorted { $0.score > $1.score }
                    let topDocs = Array(ranked.prefix(20))

                    var newPosts: [FeedPost] = []
                    for item in topDocs {
                        newPosts.append(FeedView.feedPost(from: item.doc))
                        self.extractPostMetadata(from: item.doc)
                    }

                print("✅ fetchPosts — setting \(newPosts.count) posts after scoring/filtering")

                if !newPosts.isEmpty {
                                                                                                                            self.posts = newPosts
                                                                                                                            self.hasLoadedOnce = true
                                                                                                                            // Cursor must track Firestore's query order (createdAt DESC),
                                                                                                                            // not our client-side score rank. Using topDocs.last previously
                                                                                                                            // set the cursor to the lowest-scored doc in the top-20 — and
                                                                                                                            // `start(afterDocument:)` then resumed in createdAt order after
                                                                                                                            // that doc, silently skipping the chronologically-earlier posts
                                                                                                                            // that ranked below the top-20 on this page. Net effect was
                                                                                                                            // permanent holes in the feed.
                                                                                                                            self.lastDocument = documents.last
                                                                                                                            self.hasMorePosts = documents.count >= 60
                                                                                        } else if documents.count >= 60 {
                                                                                                                                                    self.hasLoadedOnce = true
                                                                                                                                                    self.posts = []
                                                                                                                                                    self.lastDocument = documents.last
                                                                                                                                                    self.hasMorePosts = true
                                                                                                                                                    self.loadMorePosts()
                                                                                                                                                } else {
                                                                                                                                                    self.hasLoadedOnce = true
                                                                                                                                                    self.posts = []
                                                                                                                                                    self.hasMorePosts = false
                                                                                                                                                }
            }
                }

                // MARK: - Load More Posts

    func loadMorePosts(depth: Int = 0) {
        guard !isLoadingMore, hasMorePosts, let last = lastDocument else { return }
        guard depth < 5 else {
            isLoadingMore = false
            hasMorePosts = false
            endedDueToBlocking = true
            return
        }
        isLoadingMore = true

        let db = Firestore.firestore()
        db.collection("posts")
                    .order(by: "createdAt", descending: true)
                    .start(afterDocument: last)
                    .limit(to: 20)
                    .getDocuments { [weak self] snapshot, error in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                    if let error = error {
                        print("⚠️ loadMorePosts error: \(error)")
                        self.isLoadingMore = false
                        self.fetchError = "couldn't load more posts — pull to retry"
                        return
                    }
                    self.fetchError = nil
                    guard let documents = snapshot?.documents else {
                        self.isLoadingMore = false
                        self.hasMorePosts = false
                        return
                    }
                    let filtered = self.filterBlocked(documents: documents)
                    let existingIds = Set(self.posts.map { $0.id })
                    for doc in filtered where !existingIds.contains(doc.documentID) {
                        self.posts.append(FeedView.feedPost(from: doc))
                        self.extractPostMetadata(from: doc)
                    }
                    self.lastDocument = documents.last
                    self.hasMorePosts = documents.count >= 20
                    self.endedDueToBlocking = false
                    if filtered.isEmpty && documents.count >= 20 {
                        self.isLoadingMore = false
                        self.loadMorePosts(depth: depth + 1)
                    } else {
                        self.isLoadingMore = false
                    }
                }
            }
    }

    // MARK: - Following Posts

    private var followingTask: Task<Void, Never>? = nil

    func fetchFollowingPosts() {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            let db = Firestore.firestore()

            followingTask?.cancel()
            followingTask = Task { @MainActor in
                let followingLimit = 200
                guard !Task.isCancelled, Auth.auth().currentUser?.uid == uid else { return }
                guard let followSnap = try? await db.collection("users").document(uid).collection("following")
                    .limit(to: followingLimit)
                    .getDocumentsAsync() else {
                    self.fetchError = "couldn't load following posts — pull to retry"
                    return
                }

                let followedIds = followSnap.documents.map { $0.documentID }
                guard !followedIds.isEmpty else {
                    followingPosts = []
                    followingFetchIncomplete = false
                    return
                }

                if followSnap.documents.count >= followingLimit {
                    followingFetchIncomplete = true
                }

                let chunks = stride(from: 0, to: followedIds.count, by: 30).map {
                    Array(followedIds[$0..<min($0 + 30, followedIds.count)])
                }

                // FIX: task group closures are non-isolated, so @MainActor methods
                // like FeedView.feedPost(from:) cannot be called inside them.
                // Instead, collect raw documents from each chunk and do all
                // @MainActor parsing after the group completes on the main actor.
                var allRawResults: [(doc: QueryDocumentSnapshot, date: Date)] = []
                var anyChunkFailed = false

                await withTaskGroup(of: [(doc: QueryDocumentSnapshot, date: Date)]?.self) { group in
                    for chunk in chunks {
                        group.addTask {
                            // This closure is non-isolated — only pure Swift and
                            // non-actor-isolated calls are allowed here.
                            let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 60 * 60)
                            guard let postSnapshot = try? await db.collection("posts")
                                .whereField("authorId", in: chunk)
                                .whereField("createdAt", isGreaterThan: Timestamp(date: threeDaysAgo))
                                .order(by: "createdAt", descending: true)
                                .limit(to: 30)
                                .getDocumentsAsync() else { return nil }

                            // filterBlocked is now nonisolated so it's safe here.
                            let filtered = self.filterBlocked(documents: postSnapshot.documents)
                            return filtered.map { doc in
                                let createdAt = (doc.data()["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                                return (doc: doc, date: createdAt)
                            }
                        }
                    }

                    for await chunkResults in group {
                        if let results = chunkResults {
                            allRawResults.append(contentsOf: results)
                        } else {
                            anyChunkFailed = true
                        }
                    }
                }

                // Back on the main actor — safe to call FeedView.feedPost(from:)
                // and extractPostMetadata here.
                guard !Task.isCancelled, Auth.auth().currentUser?.uid == uid else { return }
                let sorted = allRawResults.sorted { $0.date > $1.date }.prefix(50)
                followingPosts = sorted.map { item in
                    let post = FeedView.feedPost(from: item.doc)
                    self.extractPostMetadata(from: item.doc)
                    return post
                }
                let wasTruncated = followSnap.documents.count >= followingLimit
                followingFetchIncomplete = anyChunkFailed || wasTruncated
            }
        }

    // MARK: - Witness Post

    func fetchWitnessPost() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        db.collection("posts")
            .whereField("replyCount", isEqualTo: 0)
            .whereField("isRepost", isEqualTo: false)
            .order(by: "createdAt", descending: true)
            .limit(to: 10)
            .getDocuments { snapshot, error in
                if let error = error {
                    print("⚠️ fetchWitnessPost — check composite index (replyCount, isRepost, createdAt): \(error)")
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let documents = snapshot?.documents else { return }
                    guard let doc = documents.first(where: {
                        let data = $0.data()
                        let authorId = data["authorId"] as? String ?? ""
                        if authorId == uid || BlockedUsersCache.shared.isBlocked(authorId) { return false }
                        if let expiresAt = data["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() { return false }
                        if data["flagged"] as? Bool == true { return false }
                        return true
                    }) else { return }
                    let data = doc.data()
                    let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                    self.witnessPost = WitnessPostData(
                        postId: doc.documentID,
                        handle: data["authorHandle"] as? String ?? "anonymous",
                        text: data["text"] as? String ?? "",
                        tag: data["tag"] as? String,
                        timeString: ToskaFormatters.hourMinute.string(from: createdAt).lowercased()
                    )
                }
            }
    }

    // MARK: - Most Unsaid Today

    func fetchMostUnsaidAndDailyMoment() {
        guard Auth.auth().currentUser != nil else { return }
        let yesterday = Date().addingTimeInterval(-24 * 60 * 60)
        Firestore.firestore().collection("posts")
            .whereField("createdAt", isGreaterThan: Timestamp(date: yesterday))
            .whereField("isRepost", isEqualTo: false)
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .getDocuments { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error = error {
                        print("⚠️ fetchMostUnsaidAndDailyMoment error: \(error)")
                        return
                    }
                    guard let docs = snapshot?.documents else {
                        self.mostUnsaidText = ""
                        self.mostUnsaidLikes = 0
                        self.mostUnsaidPostId = ""
                        self.hasDailyMoment = false
                        return
                    }
                    let sorted = docs.sorted {
                        ($0.data()["likeCount"] as? Int ?? 0) > ($1.data()["likeCount"] as? Int ?? 0)
                    }

                    if let topDoc = sorted.first {
                        self.hasDailyMoment = (topDoc.data()["likeCount"] as? Int ?? 0) > 0
                    } else {
                        self.hasDailyMoment = false
                    }

                    guard let doc = sorted.first(where: {
                        let data = $0.data()
                        if BlockedUsersCache.shared.isBlocked(data["authorId"] as? String ?? "") { return false }
                        if let expiresAt = data["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() { return false }
                        if data["flagged"] as? Bool == true { return false }
                        return true
                    }) else {
                        self.mostUnsaidText = ""
                        self.mostUnsaidLikes = 0
                        self.mostUnsaidPostId = ""
                        return
                    }
                    let data = doc.data()
                    self.mostUnsaidText = data["text"] as? String ?? ""
                    self.mostUnsaidLikes = data["likeCount"] as? Int ?? 0
                    self.mostUnsaidPostId = doc.documentID
                }
            }
    }

    // MARK: - Anniversary Post

    func fetchAnniversaryPost() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        let now = Date()
        let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
        let oneYearAgoStart = oneYearAgo.addingTimeInterval(-12 * 60 * 60)
        let oneYearAgoEnd = oneYearAgo.addingTimeInterval(12 * 60 * 60)

        db.collection("posts")
            .whereField("authorId", isEqualTo: uid)
            .whereField("isRepost", isEqualTo: false)
            .whereField("createdAt", isGreaterThan: Timestamp(date: oneYearAgoStart))
            .whereField("createdAt", isLessThan: Timestamp(date: oneYearAgoEnd))
            .limit(to: 1)
            .getDocuments { snapshot, error in
                if let error = error {
                    print("⚠️ fetchAnniversaryPost — check composite index (authorId, isRepost, createdAt): \(error)")
                    return
                }
                Task { @MainActor in
                    // Captured-uid recheck. The query filter is `authorId ==
                    // uid`, so a sign-out/sign-in race during the fetch would
                    // otherwise land the previous user's anniversary post
                    // text into the new user's UI under the "your post from
                    // 1 year ago" label — a misattribution that exposes
                    // year-old authorship across accounts.
                    guard Auth.auth().currentUser?.uid == uid else { return }
                    guard let doc = snapshot?.documents.first else { return }
                    let data = doc.data()
                    // Don't surface a year-old post that was later flagged by
                    // moderation. The post is the current user's own (filter
                    // above is `authorId == uid`), so blocked-user filtering
                    // doesn't apply, but the author themselves may have had
                    // the post auto-flagged for spam/PII/etc. — silently
                    // showing it again as an anniversary defeats the
                    // moderation system. Also skip posts soft-flagged as
                    // concerning content.
                    if data["flagged"] as? Bool == true { return }
                    if data["concerningContent"] as? Bool == true { return }
                    let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                    self.anniversaryPost = AnniversaryPostData(
                        postId: doc.documentID,
                        text: data["text"] as? String ?? "",
                        tag: data["tag"] as? String,
                        dateString: ToskaFormatters.fullDate.string(from: createdAt).lowercased()
                    )
                }
            }
    }

    // MARK: - Emotional Weather

    func fetchEmotionalWeather() {
        guard Auth.auth().currentUser != nil else { return }
        let db = Firestore.firestore()
        let sixHoursAgo = Date().addingTimeInterval(-6 * 60 * 60)

        db.collection("posts")
            .whereField("createdAt", isGreaterThan: Timestamp(date: sixHoursAgo))
            .limit(to: 50)
            .getDocuments { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error = error {
                        print("⚠️ fetchEmotionalWeather error: \(error)")
                        self.setDefaultWeather()
                        return
                    }
                    guard let documents = snapshot?.documents else {
                        self.setDefaultWeather()
                        return
                    }
                    var tagCounts: [String: Int] = [:]
                    for doc in documents {
                        if let tag = doc.data()["tag"] as? String {
                            tagCounts[tag, default: 0] += 1
                        }
                    }
                    if let topTag = tagCounts.max(by: { $0.value < $1.value }) {
                        self.weatherTag = topTag.key
                        self.emotionalWeather = self.weatherPhrase(for: topTag.key)
                    } else {
                        self.setDefaultWeather()
                    }
                }
            }
    }

    // MARK: - Share Most Unsaid

    func shareMostUnsaid() {
        guard !mostUnsaidText.isEmpty else { return }

        let cardView = ZStack {
                    Color(hex: "0a0908")

                    VStack(spacing: 0) {
                        Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.toskaBlue)
                        .frame(width: 4, height: 4)
                    Text("most unsaid today")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.toskaBlue)
                        .tracking(1)
                }
                .padding(.bottom, 24)

                Text(mostUnsaidText)
                    .font(.custom("Georgia", size: 22))
                    .foregroundColor(.white.opacity(0.95))
                    .lineSpacing(8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Spacer()

                Text("\(formatCount(mostUnsaidLikes)) felt this")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "c47a8a").opacity(0.7))
                    .padding(.bottom, 24)

                VStack(spacing: 4) {
                    Text("toska")
                        .font(.custom("Georgia-Italic", size: 18))
                        .foregroundColor(.white.opacity(0.15))
                    Text("say what you never said")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.08))
                }
                .padding(.bottom, 40)
            }
        }
        .frame(width: 1080 / 3, height: 1920 / 3)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: cardView)
        renderer.scale = 3.0

        if let image = renderer.uiImage {
            presentShareSheet(with: [image])
        }
    }

    // MARK: - Weather Helpers

    func setDefaultWeather() {
        let defaults: [(String, String)] = [
                    ("longing", "a lot of people are missing someone right now"),
                    ("regret", "everyone keeps thinking about what they shouldve said"),
                    ("still love you", "a lot of people still love someone who left"),
                ]
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let pick = defaults[dayOfYear % defaults.count]
        weatherTag = pick.0
        emotionalWeather = pick.1
    }

    func weatherPhrase(for tag: String) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let timeOfDay: String
        if hour >= 21 || hour < 5 { timeOfDay = "tonight" }
        else if hour < 12 { timeOfDay = "this morning" }
        else if hour < 17 { timeOfDay = "this afternoon" }
        else { timeOfDay = "this evening" }

        switch tag {
                case "longing": return "a lot of people are missing someone \(timeOfDay)"
                case "anger": return "a lot of people are angry \(timeOfDay)"
                case "regret": return "everyone keeps replaying the same moments \(timeOfDay)"
                case "acceptance": return "people are trying to accept things \(timeOfDay)"
                case "confusion": return "nobody knows what theyre feeling \(timeOfDay)"
                case "unsent": return "a lot of things are going unsaid \(timeOfDay)"
                case "moving on": return "people are trying to move on \(timeOfDay)"
                case "still love you": return "a lot of people still love someone they shouldnt \(timeOfDay)"
                default: return "everyones going through something \(timeOfDay)"
                }
    }
}
