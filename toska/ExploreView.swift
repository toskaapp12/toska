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
    @State private var showLastSaid = false
    @State private var tagPosts: [ExplorePost] = []
    @State private var trendingPosts: [ExplorePost] = []
    @State private var searchResults: [ExplorePost] = []
    @State private var allPosts: [ExplorePost] = []
    @State private var isLoadingTag = false
    @State private var isLoadingTrending = true
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var tagCounts: [String: Int] = [:]
    @State private var hasFetchedInitial = false
    @State private var feelingPeople: [FeelingPerson] = []
    @State private var activeConversation: ConversationSelection? = nil
    @State private var isStartingConversation = false
    @State private var hasFinalPosts = false
        @State private var searchTask: Task<Void, Never>? = nil
        // Per-tag results cache (30s TTL). Re-tapping the same tag chip
        // shouldn't re-hit Firestore — the user is usually toggling between
        // pills to compare. The cache is dropped on view dismiss.
        @State private var tagCache: [String: (posts: [ExplorePost], fetchedAt: Date)] = [:]
        private static let tagCacheTTL: TimeInterval = 30
        @State private var lastForegroundFetch: Date? = nil

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
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color.toskaTextDark)
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
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(hex: "e8eaed"))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                                
                                // Tag pills
                                if !hasSearched && selectedTag == nil {
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
                                                            .font(.system(size: 11, weight: .medium))
                                                        if let count = tagCounts[tag.name], count > 0 {
                                                            Text("·")
                                                                .font(.system(size: 8))
                                                                .foregroundColor(Color(hex: tag.colorHex).opacity(0.4))
                                                            Text("\(count)")
                                                                .font(.system(size: 10))
                                                        }
                                                    }
                                                    .foregroundColor(Color(hex: tag.colorHex))
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 6)
                                                    .background(Color(hex: tag.colorHex).opacity(0.06))
                                                    .cornerRadius(16)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                    .padding(.bottom, 8)
                                }
                                
                                Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)

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
                                    Text("explore").font(.system(size: 11))
                                }.foregroundColor(Color.toskaBlue)
                            }
                            Spacer()
                            Text("results for \"\(searchText)\"")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color.toskaTextLight)
                            Spacer()
                            Text("explore").font(.system(size: 11)).foregroundColor(.clear)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        
                        Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)
                        
                        if isSearching {
                            Spacer()
                            ProgressView().tint(Color.toskaBlue)
                            Spacer()
                        } else if searchResults.isEmpty {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").font(.system(size: 24, weight: .light)).foregroundColor(Color.toskaDivider)
                                Text("nothing found").font(.system(size: 13)).foregroundColor(Color.toskaTextLight)
                                                                                                Text("nobody said it here yet. maybe you should.").font(.system(size: 11)).foregroundColor(Color.toskaGrayLight)
                            }
                            Spacer()
                        } else {
                            ScrollView(showsIndicators: false) {
                                LazyVStack(spacing: 0) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("searching recent posts")
                                            .font(.system(size: 9, weight: .medium)).foregroundColor(Color.toskaTextLight)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 8)
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
                                    Text("explore").font(.system(size: 11))
                                }.foregroundColor(Color.toskaBlue)
                            }
                            Spacer()
                            HStack(spacing: 5) {
                                let tagData = tags.first(where: { $0.name == selected })
                                Image(systemName: tagData?.icon ?? "tag").font(.system(size: 11)).foregroundColor(tagColor(for: selected))
                                Text(selected).font(.system(size: 13, weight: .semibold)).foregroundColor(tagColor(for: selected))
                            }
                            Spacer()
                            Text("explore").font(.system(size: 11)).foregroundColor(.clear)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        
                        Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)
                        
                        if isLoadingTag {
                            Spacer()
                            ProgressView().tint(Color.toskaBlue)
                            Spacer()
                        } else {
                            ScrollView(showsIndicators: false) {
                                LazyVStack(spacing: 0) {
                                    if !feelingPeople.isEmpty {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text("people feeling this too")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(Color.toskaTextLight)
                                                .tracking(0.3)
                                            
                                            ForEach(feelingPeople) { person in
                                                HStack(spacing: 10) {
                                                                                                    Text(person.handle)
                                                        .font(.system(size: 12, weight: .medium))
                                                        .foregroundColor(Color.toskaTextDark)
                                                    
                                                    Spacer()
                                                    
                                                    Button {
                                                                                                            startConversation(with: person)
                                                                                                        } label: {
                                                                                                            HStack(spacing: 4) {
                                                                                                                if isStartingConversation {
                                                                                                                    ProgressView().scaleEffect(0.6).tint(Color.toskaBlue)
                                                                                                                } else {
                                                                                                                    Image(systemName: "envelope").font(.system(size: 10))
                                                                                                                }
                                                                                                                Text("reach out").font(.system(size: 10, weight: .medium))
                                                                                                            }
                                                                                                            .foregroundColor(Color.toskaBlue)
                                                                                                            .padding(.horizontal, 10)
                                                                                                            .padding(.vertical, 5)
                                                                                                            .background(Color.toskaBlue.opacity(0.08))
                                                                                                            .cornerRadius(12)
                                                                                                        }
                                                                                                        .disabled(isStartingConversation)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                        .background(Color.white)
                                        
                                        Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)
                                                                            }
                                                                            
                                                                            
                                                                            
                                                                            if tagPosts.isEmpty {
                                        VStack(spacing: 8) {
                                            Image(systemName: "pencil.line").font(.system(size: 20, weight: .light)).foregroundColor(Color.toskaDivider)
                                            Text("nobody's said it yet").font(.system(size: 12)).foregroundColor(Color.toskaTextLight)
                                                                                                                                    Text("be the first.").font(.system(size: 10)).foregroundColor(Color.toskaGrayLight)
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
                                HStack { Spacer(); ProgressView().tint(Color.toskaBlue); Spacer() }.padding(.vertical, 30)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(trendingPosts.enumerated()), id: \.element.id) { index, post in
                                        FeedPostRow(handle: post.handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, postId: post.id, authorId: post.authorId)
                                    }
                                    if trendingPosts.isEmpty {
                                                                            VStack(spacing: 10) {
                                                                                Text("\"everyone's being\nquiet right now.\"")
                                                                                    .font(.custom("Georgia-Italic", size: 18))
                                                                                    .foregroundColor(Color.toskaTimestamp)
                                                                                    .multilineTextAlignment(.center)
                                                                                    .lineSpacing(4)
                                                                            }
                                                                            .frame(maxWidth: .infinity)
                                                                            .padding(.vertical, 60)
                                                                        }
                                                                    }
                                                                }
                                                                
                                                                if hasFinalPosts {
                                                                    Button { showLastSaid = true } label: {
                                                                        HStack(spacing: 8) {
                                                                            Image(systemName: "leaf")
                                                                                .font(.system(size: 12, weight: .light))
                                                                                .foregroundColor(Color.toskaBlue)
                                                                            Text("the last thing they said")
                                                                                .font(.system(size: 12, weight: .medium))
                                                                                .foregroundColor(Color.toskaTextDark)
                                                                            Spacer()
                                                                            Image(systemName: "chevron.right")
                                                                                .font(.system(size: 10, weight: .light))
                                                                                .foregroundColor(Color.toskaDivider)
                                                                        }
                                                                        .padding(.horizontal, 16)
                                                                        .padding(.vertical, 14)
                                                                    }
                                                                    .buttonStyle(.plain)
                                                                    
                                                                    Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)
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
                    checkForFinalPosts()
                }
                .onDisappear {
                    searchTask?.cancel()
                    searchTask = nil
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    guard hasFetchedInitial else { return }
                    if let last = lastForegroundFetch, Date().timeIntervalSince(last) < 60 { return }
                    lastForegroundFetch = Date()
                    tagCache.removeAll()
                    fetchTrendingPosts()
                    fetchTagCounts()
                    if let tag = selectedTag { fetchPostsForTag(tag) }
                }
        .fullScreenCover(isPresented: $showLastSaid) {
            LastThingSaidView()
        }
        
            
        .sheet(item: $activeConversation) { convo in
                    ConversationView(
                        conversationId: convo.id,
                        otherHandle: convo.handle,
                        otherUserId: convo.userId
                    )
                }
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
    
    // MARK: - Start Conversation from Explore
    
    func startConversation(with person: FeelingPerson) {
                    guard let uid = Auth.auth().currentUser?.uid, uid != person.id else { return }
                    guard !isStartingConversation else { return }
                    guard !BlockedUsersCache.shared.isBlocked(person.id) else { return }
                    isStartingConversation = true
                    let db = Firestore.firestore()
                    
                    Task {
                        defer { isStartingConversation = false }
                        
                        let blockedSnap = try? await db.collection("users").document(person.id).collection("blocked").document(uid).getDocumentAsync()
                        if blockedSnap?.exists == true { return }
                    
                    let convoId = [uid, person.id].sorted().joined(separator: "_")
                    let convoRef = db.collection("conversations").document(convoId)
                    
                    let convoSnap = try? await convoRef.getDocumentAsync()
                    if convoSnap?.exists == true {
                        activeConversation = ConversationSelection(id: convoId, handle: person.handle, userId: person.id)
                        return
                    }
                    
                    let userSnap = try? await db.collection("users").document(uid).getDocumentAsync()
                    let myHandle = userSnap?.data()?["handle"] as? String ?? "anonymous"
                    
                    do {
                                            try await convoRef.setData([
                                                "participants": [uid, person.id],
                                                "participantHandles": [uid: myHandle, person.id: person.handle],
                                                "lastMessage": "",
                                                "lastMessageAt": FieldValue.serverTimestamp(),
                                                "messageCount": [uid: 0, person.id: 0],
                                                "createdAt": FieldValue.serverTimestamp()
                                            ])
                                            activeConversation = ConversationSelection(id: convoId, handle: person.handle, userId: person.id)
                                        } catch {
                                            print("⚠️ startConversation setData failed: \(error)")
                                        }
                }
            }
    
    // MARK: - Data fetching
    
    func preloadPosts() {
            // Deferred to performSearch — no need to read 200 docs if user never searches
        }
    
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
            // Serve from cache if the entry is still warm — avoids a 30-doc
            // re-fetch every time the user toggles back to a recently-viewed tag.
            if let cached = tagCache[tag],
               Date().timeIntervalSince(cached.fetchedAt) < Self.tagCacheTTL {
                tagPosts = cached.posts
                isLoadingTag = false
                return
            }
            isLoadingTag = true; tagPosts = []
            Firestore.firestore().collection("posts")
                .whereField("tag", isEqualTo: tag)
                .whereField("isRepost", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: 30)
                .getDocuments { snapshot, _ in
                    Task { @MainActor in
                        guard let documents = snapshot?.documents else { isLoadingTag = false; return }
                        let nonExpired = documents.filter { doc in
                            if let expiresAt = doc.data()["expiresAt"] as? Timestamp {
                                return expiresAt.dateValue() >= Date()
                            }
                            return true
                        }
                        let parsed = parsePosts(from: nonExpired)
                        tagPosts = parsed
                        tagCache[tag] = (posts: parsed, fetchedAt: Date())
                        isLoadingTag = false
                    }
                }
        }
    
    func fetchTrendingPosts() {
            let yesterday = Date().addingTimeInterval(-24 * 60 * 60)
            Firestore.firestore().collection("posts")
                .whereField("createdAt", isGreaterThan: Timestamp(date: yesterday))
                .whereField("isRepost", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .order(by: "likeCount", descending: true)
                .limit(to: 10)
                .getDocuments { snapshot, _ in
                    Task { @MainActor in
                        guard let documents = snapshot?.documents else { isLoadingTrending = false; return }
                        let filtered = documents.filter { doc in
                            if let expiresAt = doc.data()["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() { return false }
                            return true
                        }
                        trendingPosts = Array(parsePosts(from: filtered).prefix(5))
                        isLoadingTrending = false
                    }
                }
        }
    
    func checkForFinalPosts() {
            Firestore.firestore().collection("finalPosts").limit(to: 1)
                .getDocuments { snapshot, _ in
                    Task { @MainActor in
                        hasFinalPosts = !(snapshot?.documents.isEmpty ?? true)
                    }
                }
        }
        
    // FIX: replaced a 200-document fan-out query with a single document read.
        // A Cloud Function (onPostCreatedUpdateTagCounts / onPostDeletedUpdateTagCounts)
        // now maintains meta/tagCounts, incrementing and decrementing each tag key
        // as posts are created and deleted. The client reads one document instead
        // of 200, saving ~199 Firestore reads every time ExploreView appears.
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
