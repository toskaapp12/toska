import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

// MARK: - Post model for ExploreView

struct ExplorePost {
    let id: String
    let handle: String
    let text: String
    let tag: String?
    let likes: Int
    let reposts: Int
    let replies: Int
    let time: String
    let authorId: String
    let createdAt: Date

    init(doc: QueryDocumentSnapshot, blockedUserIds: Set<String>) throws {
            let data = doc.data()
            let authorId = data["authorId"] as? String ?? ""
            if blockedUserIds.contains(authorId) { throw ExplorePostError.blocked }
            if let originalAuthorId = data["originalAuthorId"] as? String,
               blockedUserIds.contains(originalAuthorId) { throw ExplorePostError.blocked }
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        self.id = doc.documentID
        self.handle = data["authorHandle"] as? String ?? "anonymous"
        self.text = data["text"] as? String ?? ""
        self.tag = data["tag"] as? String
        self.likes = data["likeCount"] as? Int ?? 0
        self.reposts = data["repostCount"] as? Int ?? 0
        self.replies = data["replyCount"] as? Int ?? 0
        self.time = FeedView.timeAgoString(from: createdAt)
        self.authorId = authorId
        self.createdAt = createdAt
    }
    
    enum ExplorePostError: Error {
        case blocked
    }
}

// MARK: - People feeling this model

struct FeelingPerson: Identifiable {
    let id: String // userId
    let handle: String
}

@MainActor
struct ExploreView: View {
    @State private var searchText = ""
    @State private var selectedTag: String? = nil
    @State private var tagPosts: [ExplorePost] = []
    @State private var trendingPosts: [ExplorePost] = []
    @State private var searchResults: [ExplorePost] = []
    @State private var allPosts: [ExplorePost] = []
    @State private var isLoadingTag = false
    @State private var isLoadingTrending = true
    // H2: surface a load failure on the discovery surfaces instead of showing
    // the "nobody's said it yet" empty state when the read actually errored.
    @State private var tagLoadFailed = false
    @State private var trendingLoadFailed = false
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var tagCounts: [String: Int] = [:]
    // Cohort counts by breakup stage (meta/breakupStageCounts) — shown
    // as a soft-chip row above the mood tags. The breakup-specific
    // signal that anchors the explore tab in the wedge: a visitor
    // browsing the surface immediately sees "people in 'a year or more'
    // (230)" / "people in 'they left' (47)" rather than just feeling
    // tags any anonymous app could surface.
    @State private var breakupStageCounts: [String: Int] = [:]
    @State private var hasFetchedInitial = false
    @State private var feelingPeople: [FeelingPerson] = []
        @State private var searchTask: Task<Void, Never>? = nil

        let tags = sharedTags
        
    var exploreSubtitle: String {
                let tod = timeOfDayLabel()
        if tod == "tonight" { return "who else is up right now" }
                        return "what everyone else is feeling \(tod)"
            }
        
    var body: some View {
            ZStack {
                LateNightTheme.background.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    HStack {
                        Text("explore")
                            .toskaScreenTitle()
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(Color.toskaTimestamp)
                    
                    TextField("search for a feeling...", text: $searchText)
                        .font(.system(size: 12))
                        .onSubmit { performSearch() }
                    
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            hasSearched = false
                            searchResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(Color.toskaTimestamp)
                        }
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(hex: "e8eaed"))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                                
                                // Stage chips — breakup-cohort signal above the
                                // mood tags. Display order mirrors OnboardingView.
                                // breakupStages and we hide stages with zero count
                                // so an empty cohort doesn't get its own chip.
                                // Hidden during search and when a tag is selected
                                // (focus mode for tag-filtered feed).
                                if !hasSearched && selectedTag == nil && !breakupStageCounts.isEmpty {
                                    let stageOrder = [
                                        "it just happened",
                                        "a few weeks in",
                                        "months in",
                                        "a year or more",
                                        "still in it",
                                        "they left",
                                        "i left",
                                    ]
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(stageOrder, id: \.self) { stage in
                                                if let count = breakupStageCounts[stage], count > 0 {
                                                    HStack(spacing: 4) {
                                                        Text(stage)
                                                            .font(ToskaFont.sans(11, weight: .medium))
                                                        Text("·")
                                                            .font(ToskaFont.sans(8))
                                                            .foregroundColor(Color.toskaBlue.opacity(0.4))
                                                        Text("\(count)")
                                                            .font(ToskaFont.sans(11))
                                                    }
                                                    .foregroundColor(Color.toskaBlue)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 8)
                                                    .background(Color.toskaBlue.opacity(0.06))
                                                    .cornerRadius(16)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                    .padding(.bottom, 8)
                                }

                                // Tag pills
                                if !hasSearched && selectedTag == nil {
                                    // ScrollViewReader + .scrollTo on appear so the
                                    // rail always opens anchored to the first tag
                                    // ("longing"), matching ComposeView's tag picker
                                    // which renders fresh each time. Without this,
                                    // a previous mid-scroll position can persist
                                    // and make the rail look like it's showing a
                                    // different tag list than compose.
                                    ScrollViewReader { proxy in
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 8) {
                                                ForEach(tags, id: \.name) { tag in
                                                    Button {
                                                        selectedTag = tag.name
                                                        fetchPostsForTag(tag.name)
                                                        fetchPeopleFeelingThis(tag: tag.name)
                                                    } label: {
                                                        HStack(spacing: 4) {
                                                            Image(systemName: tag.icon)
                                                                .font(.system(size: 10))
                                                            Text(tag.name)
                                                                .font(ToskaFont.sans(11, weight: .medium))
                                                            if let count = tagCounts[tag.name], count > 0 {
                                                                Text("·")
                                                                    .font(ToskaFont.sans(8))
                                                                    .foregroundColor(Color(hex: tag.colorHex).opacity(0.4))
                                                                Text("\(count)")
                                                                    .font(ToskaFont.sans(11))
                                                            }
                                                        }
                                                        .foregroundColor(Color(hex: tag.colorHex))
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 8)
                                                        .background(Color(hex: tag.colorHex).opacity(0.06))
                                                        .cornerRadius(16)
                                                    }
                                                    .id(tag.name)
                                                }
                                            }
                                            .padding(.horizontal, 16)
                                        }
                                        .onAppear {
                                            if let first = tags.first {
                                                proxy.scrollTo(first.name, anchor: .leading)
                                            }
                                        }
                                    }
                                    .padding(.bottom, 8)
                                }
                                
                                Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)

                if hasSearched {
                    // MARK: - Search Results
                    VStack(spacing: 0) {
                        HStack {
                            Button {
                                hasSearched = false
                                searchText = ""
                                searchResults = []
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left").font(.system(size: 11))
                                    Text("explore").font(ToskaFont.sans(11))
                                }.foregroundColor(Color.toskaBlue)
                            }
                            Spacer()
                            Text("results for \"\(searchText)\"")
                                .font(ToskaFont.sans(11, weight: .medium))
                                .foregroundColor(Color.toskaTextLight)
                            Spacer()
                            Text("explore").font(ToskaFont.sans(11)).foregroundColor(.clear)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        
                        Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)
                        
                        if isSearching {
                            Spacer()
                            ProgressView().tint(Color.toskaBlue)
                            Spacer()
                        } else if searchResults.isEmpty {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").font(.system(size: 24, weight: .light)).foregroundColor(Color.toskaDivider)
                                Text("nothing found").font(ToskaFont.sans(13)).foregroundColor(Color.toskaTextLight)
                                                                                                Text("nobody said it here yet. maybe you should.").font(ToskaFont.sans(11)).foregroundColor(Color.toskaPlaceholderGray)
                            }
                            Spacer()
                        } else {
                            ScrollView(showsIndicators: false) {
                                VStack(spacing: 0) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("searching recent posts")
                                            .font(ToskaFont.sans(11, weight: .medium)).foregroundColor(Color.toskaTextLight)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
                                    ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, post in
                                        FeedPostRow(handle: post.handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, postId: post.id, authorId: post.authorId)
                                    }
                                }
                            }
                        }
                    }
                } else if let selected = selectedTag {
                    // MARK: - Tag Detail View
                    VStack(spacing: 0) {
                        HStack {
                            Button {
                                selectedTag = nil
                                tagPosts = []
                                feelingPeople = []
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left").font(.system(size: 11))
                                    Text("explore").font(ToskaFont.sans(11))
                                }.foregroundColor(Color.toskaBlue)
                            }
                            Spacer()
                            HStack(spacing: 4) {
                                let tagData = tags.first(where: { $0.name == selected })
                                Image(systemName: tagData?.icon ?? "tag").font(.system(size: 11)).foregroundColor(tagColor(for: selected))
                                Text(selected).font(ToskaFont.sans(13, weight: .semibold)).foregroundColor(tagColor(for: selected))
                            }
                            Spacer()
                            Text("explore").font(ToskaFont.sans(11)).foregroundColor(.clear)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        
                        Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)
                        
                        if isLoadingTag {
                            Spacer()
                            ProgressView().tint(Color.toskaBlue)
                            Spacer()
                        } else {
                            ScrollView(showsIndicators: false) {
                                VStack(spacing: 0) {
                                    if !feelingPeople.isEmpty {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("people feeling this too")
                                                .font(ToskaFont.sans(11, weight: .semibold))
                                                .foregroundColor(Color.toskaTextLight)
                                                .tracking(0.3)
                                            
                                            // "Reach out" DM button removed when DMs were cut.
                                            // The list still shows people feeling the tag as a
                                            // soft "you're not alone" surface, just without a
                                            // direct-message affordance.
                                            ForEach(feelingPeople) { person in
                                                HStack(spacing: 8) {
                                                    Text(person.handle)
                                                        .font(ToskaFont.sans(12, weight: .medium))
                                                        .foregroundColor(Color.toskaInkOnLight)
                                                    Spacer()
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 16)
                                        .background(Color.white)
                                        
                                        Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)
                                                                            }
                                                                            
                                                                            
                                                                            
                                                                            if tagLoadFailed && tagPosts.isEmpty {
                                        ToskaErrorBanner("couldn't load posts — check your connection") {
                                            if let tag = selectedTag { fetchPostsForTag(tag) }
                                        }
                                    } else if tagPosts.isEmpty {
                                        VStack(spacing: 16) {
                                            Image(systemName: "pencil.line")
                                                .font(.system(size: 28, weight: .ultraLight))
                                                .foregroundColor(Color.toskaBlue.opacity(0.4))
                                                .padding(.bottom, 4)
                                            Text("nobody's said it yet")
                                                .font(ToskaFont.serifItalic(18))
                                                .foregroundColor(Color.toskaTextLight)
                                            Text("be the first.")
                                                .font(ToskaFont.sans(11))
                                                .foregroundColor(Color.toskaDivider)
                                        }.frame(maxWidth: .infinity).padding(.vertical, 60)
                                    } else {
                                        ForEach(Array(tagPosts.enumerated()), id: \.element.id) { index, post in
                                            FeedPostRow(handle: post.handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, postId: post.id, authorId: post.authorId)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                                    // MARK: - Main Explore
                                    ScrollView(showsIndicators: false) {
                                        VStack(alignment: .leading, spacing: 0) {
                            
                            if isLoadingTrending {
                                SkeletonFeed(kind: .post, count: 4)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(Array(trendingPosts.enumerated()), id: \.element.id) { index, post in
                                        FeedPostRow(handle: post.handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, postId: post.id, authorId: post.authorId)
                                    }
                                    if trendingLoadFailed && trendingPosts.isEmpty {
                                                                            ToskaErrorBanner("couldn't load trending — check your connection") {
                                                                                isLoadingTrending = true
                                                                                fetchTrendingPosts()
                                                                            }
                                                                            .padding(.vertical, 40)
                                                                        } else if trendingPosts.isEmpty {
                                                                            VStack(spacing: 8) {
                                                                                Text("\"everyone's being\nquiet right now.\"")
                                                                                    .font(ToskaFont.serifItalic(18))
                                                                                    .foregroundColor(Color.toskaTimestamp)
                                                                                    .multilineTextAlignment(.center)
                                                                                    .lineSpacing(4)
                                                                            }
                                                                            .frame(maxWidth: .infinity)
                                                                            .padding(.vertical, 60)
                                                                        }
                                                                    }
                                                                }
                                                                
                                                                Color.clear.frame(height: 40)
                        }
                    }
                }
            }
        }
        .onAppear {
                    guard !hasFetchedInitial else { return }
                    hasFetchedInitial = true
                    if !allPosts.isEmpty {
                        allPosts.removeAll { BlockedUsersCache.shared.isBlocked($0.authorId) }
                    }
                    fetchTrendingPosts()
                    fetchTagCounts()
                    fetchBreakupStageCounts()
                }
                .onDisappear {
                    searchTask?.cancel()
                    searchTask = nil
                }
        .hidesAppTabBar()
    }

    // MARK: - Parse helper
    
    func parsePosts(from documents: [QueryDocumentSnapshot]) -> [ExplorePost] {
        documents.compactMap { try? ExplorePost(doc: $0, blockedUserIds: BlockedUsersCache.shared.blockedUserIds) }
    }
    
    // MARK: - People Feeling This
    
    func fetchPeopleFeelingThis(tag: String) {
          guard let uid = Auth.auth().currentUser?.uid else { return }
          feelingPeople = []
          let yesterday = Date().addingTimeInterval(-24 * 60 * 60)
          Task { @MainActor in
              let snapshot = try? await Firestore.firestore().collection("posts")
                  // moderationStatus filter required by firestore.rules
                  // 2026-05-31 (see FeedViewModel.fetchPosts comment).
                  .whereField("moderationStatus", isEqualTo: "live")
                  .whereField("tag", isEqualTo: tag)
                  .whereField("createdAt", isGreaterThan: Timestamp(date: yesterday))
                  .order(by: "createdAt", descending: true)
                  .limit(to: 50)
                  .getDocumentsAsync()
              guard let documents = snapshot?.documents else { return }
              var seen: Set<String> = []
              var people: [FeelingPerson] = []
              for doc in documents {
                  let data = doc.data()
                  let authorId = data["authorId"] as? String ?? ""
                  let authorHandle = data["authorHandle"] as? String ?? "anonymous"
                  if authorId == uid { continue }
                  if BlockedUsersCache.shared.isBlocked(authorId) { continue }
                  if seen.contains(authorId) { continue }
                  seen.insert(authorId)
                  people.append(FeelingPerson(id: authorId, handle: authorHandle))
                  if people.count >= 5 { break }
              }
              feelingPeople = people
          }
      }
    
    // startConversation removed when DMs were cut. The feeling-people list
    // still surfaces as a "you're not alone" signal in the empty-tag state,
    // but there's no longer a "reach out" affordance to message them.


    // MARK: - Data fetching

    func performSearch() {
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !query.isEmpty else { return }
                isSearching = true; hasSearched = true
                
                let db = Firestore.firestore()
                
                // Step 1: Check if search matches a tag exactly — if so, query Firestore directly
        let matchingTag = sharedTags.first(where: { $0.name.lowercased().contains(query) })?.name
                
                // Step 2: Client-side search on preloaded posts
                //
                // Filter into a local copy — never mutate allPosts here.
                // Mutating the cache on each search would permanently shrink it,
                // and would also silently hide posts from a user even after
                // they're unblocked until the cache is reloaded.
                let localResults: [ExplorePost]
        if !allPosts.isEmpty {
                            localResults = allPosts
                                                    .filter { post in
                                                        !BlockedUsersCache.shared.isBlocked(post.authorId) &&
                                                        (post.text.lowercased().contains(query) ||
                                                         (post.tag?.lowercased().contains(query) ?? false) ||
                                                         post.handle.lowercased().contains(query))
                                                    }
                } else {
                    localResults = []
                }
                
                // Step 3: If we have enough local results and no tag match, use them
                if localResults.count >= 5 && matchingTag == nil {
                    searchResults = localResults
                    isSearching = false
                    return
                }
                
        // Step 4: Fetch from Firestore to supplement using async/await
                        searchTask?.cancel()
                        searchTask = Task {
                            var tagResults: [ExplorePost] = []
                            var recentResults: [ExplorePost] = []
                    
                    await withTaskGroup(of: Void.self) { group in
                        // If query matches a tag, fetch posts with that tag
                        if let tag = matchingTag {
                                                    group.addTask { @MainActor in
                                                        guard let snapshot = try? await db.collection("posts")
                                                                                                                    // moderationStatus filter required by firestore.rules
                                                                                                                    // 2026-05-31 (see FeedViewModel.fetchPosts comment).
                                                                                                                    .whereField("moderationStatus", isEqualTo: "live")
                                                                                                                    .whereField("tag", isEqualTo: tag)
                                                                                                                    .whereField("isRepost", isEqualTo: false)
                                                                                                                    .order(by: "createdAt", descending: true)
                                                                                                                    .limit(to: 30)
                                                                                                                    .getDocumentsAsync() else { return }
                                                        let nonExpired = snapshot.documents.filter { doc in
                                                            if let expiresAt = doc.data()["expiresAt"] as? Timestamp {
                                                                return expiresAt.dateValue() >= Date()
                                                            }
                                                            return true
                                                        }
                                                        tagResults = self.parsePosts(from: nonExpired)
                                                    }
                                                }
                        
                        // Fetch recent posts if local pool is empty (lazy preload on first search)
                        if allPosts.isEmpty {
                                                                            group.addTask { @MainActor in
                                                                                guard let snapshot = try? await db.collection("posts")
                                                                                                                                            // moderationStatus filter required by firestore.rules
                                                                                                                                            // 2026-05-31 (see FeedViewModel.fetchPosts comment).
                                                                                                                                            .whereField("moderationStatus", isEqualTo: "live")
                                                                                                                                            .order(by: "createdAt", descending: true)
                                                                                                                                            .limit(to: 100)
                                                                                                                                            .getDocumentsAsync() else { return }
                                                                                let nonExpired = snapshot.documents.filter { doc in
                                                                                    if let expiresAt = doc.data()["expiresAt"] as? Timestamp {
                                                                                        return expiresAt.dateValue() >= Date()
                                                                                    }
                                                                                    return true
                                                                                }
                                                                                self.allPosts = self.parsePosts(from: nonExpired)
                                                        recentResults = self.allPosts
                                                            .filter { $0.text.lowercased().contains(query) || ($0.tag?.lowercased().contains(query) ?? false) || $0.handle.lowercased().contains(query) }
                                                    }
                                                }
                    }
                    
                    // Merge and deduplicate results
                    var seen: Set<String> = []
                    var merged: [ExplorePost] = []
                    
                    for post in localResults + tagResults + recentResults {
                        if !seen.contains(post.id) {
                            seen.insert(post.id)
                            merged.append(post)
                        }
                    }
                    
                            guard !Task.isCancelled else { return }
                                                searchResults = merged
                                                isSearching = false
                                            }
                                        }
    
    func fetchPostsForTag(_ tag: String) {
            isLoadingTag = true; tagPosts = []
            Firestore.firestore().collection("posts")
                // moderationStatus filter required by firestore.rules
                // 2026-05-31 (see FeedViewModel.fetchPosts comment).
                .whereField("moderationStatus", isEqualTo: "live")
                .whereField("tag", isEqualTo: tag)
                .whereField("isRepost", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: 30)
                .getDocuments { snapshot, error in
                    Task { @MainActor in
                        guard let documents = snapshot?.documents else {
                            isLoadingTag = false
                            if error != nil { tagLoadFailed = true }
                            return
                        }
                        tagLoadFailed = false
                        let nonExpired = documents.filter { doc in
                            if let expiresAt = doc.data()["expiresAt"] as? Timestamp {
                                return expiresAt.dateValue() >= Date()
                            }
                            return true
                        }
                        tagPosts = parsePosts(from: nonExpired)
                        isLoadingTag = false
                    }
                }
        }
    
    func fetchTrendingPosts() {
            let yesterday = Date().addingTimeInterval(-24 * 60 * 60)
            Firestore.firestore().collection("posts")
                // moderationStatus filter required by firestore.rules
                // 2026-05-31 (see FeedViewModel.fetchPosts comment).
                .whereField("moderationStatus", isEqualTo: "live")
                .whereField("createdAt", isGreaterThan: Timestamp(date: yesterday))
                .whereField("isRepost", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .order(by: "likeCount", descending: true)
                .limit(to: 30)
                .getDocuments { snapshot, error in
                    Task { @MainActor in
                        guard let documents = snapshot?.documents else {
                            isLoadingTrending = false
                            if error != nil { trendingLoadFailed = true }
                            return
                        }
                        trendingLoadFailed = false
                        let filtered = documents.filter { doc in
                            if let expiresAt = doc.data()["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() { return false }
                            return true
                        }
                        // The server query only orders by recency (then likeCount as a
                        // weak tiebreaker), so "trending" was effectively just the newest
                        // posts. Re-rank the fetched window client-side with a
                        // Hacker-News-style recency-decayed engagement score so genuinely
                        // engaged posts surface. No new index required — we keep the same
                        // query and only re-sort what we already fetched.
                        let now = Date()
                        let ranked = parsePosts(from: filtered).sorted { a, b in
                            func score(_ p: ExplorePost) -> Double {
                                let engagement = Double(p.likes + p.replies * 2 + p.reposts * 3)
                                let hours = max(0, now.timeIntervalSince(p.createdAt) / 3600)
                                return engagement / pow(hours + 2, 1.5)
                            }
                            return score(a) > score(b)
                        }
                        trendingPosts = Array(ranked.prefix(5))
                        isLoadingTrending = false
                    }
                }
        }
    
    // FIX: replaced a 200-document fan-out query with a single document read.
        // A Cloud Function (onPostCreatedUpdateTagCounts / onPostDeletedUpdateTagCounts)
        // now maintains meta/tagCounts, incrementing and decrementing each tag key
        // as posts are created and deleted. The client reads one document instead
        // of 200, saving ~199 Firestore reads every time ExploreView appears.
        // Reads the per-stage user count maintained by the
        // onBreakupStageChanged Cloud Function (functions/index.js).
        // Same shape as fetchTagCounts: one document read, no fan-out.
        // Failure is silent — the chip row just hides itself rather
        // than splash a load error across the explore surface.
        func fetchBreakupStageCounts() {
            Firestore.firestore().collection("meta").document("breakupStageCounts")
                .getDocument { snapshot, error in
                    Task { @MainActor in
                        if let error = error {
                            print("⚠️ fetchBreakupStageCounts failed: \(error)")
                            return
                        }
                        guard let data = snapshot?.data() else { return }
                        var counts: [String: Int] = [:]
                        for (key, value) in data {
                            if key == "updatedAt" { continue }
                            if let n = value as? Int { counts[key] = n }
                            else if let n = value as? Int64 { counts[key] = Int(n) }
                            else if let n = value as? NSNumber { counts[key] = n.intValue }
                        }
                        breakupStageCounts = counts
                    }
                }
        }

        func fetchTagCounts() {
            Firestore.firestore().collection("meta").document("tagCounts")
                .getDocument { snapshot, error in
                    Task { @MainActor in
                        if let error = error {
                            print("⚠️ fetchTagCounts failed: \(error)")
                            return
                        }
                        guard let data = snapshot?.data() else { return }
                        var counts: [String: Int] = [:]
                        for (key, value) in data {
                            if key == "updatedAt" { continue }
                            if let count = value as? Int { counts[key] = count }
                        }
                        tagCounts = counts
                    }
                }
        }
}
