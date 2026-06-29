import SwiftUI
import FirebaseAuth
import FirebaseFirestore

@MainActor
struct TopView: View {
    enum Period: String, CaseIterable, Identifiable {
        case today = "today"
        case week = "this week"
        case all = "all time"
        var id: String { rawValue }

        /// Lower bound for the createdAt query window.
        var cutoff: Date {
            switch self {
            case .today: return Date().addingTimeInterval(-24 * 60 * 60)
            case .week:  return Date().addingTimeInterval(-7 * 24 * 60 * 60)
            case .all:   return Date(timeIntervalSince1970: 0)
            }
        }

        /// Eyebrow suffix on the hero card ("MOST FELT TODAY", etc.).
        var heroSuffix: String {
            switch self {
            case .today: return "today"
            case .week:  return "this week"
            case .all:   return "of all time"
            }
        }
    }

    // Per-period caches so all three pages of the swipeable pager hold their own
    // content simultaneously (a single shared rankedPosts would blank the
    // adjacent pages mid-swipe). Each period fetches once on first appearance;
    // pull-to-refresh refetches the active one.
    @State private var cache: [Period: [RankedPost]] = [:]
    @State private var loadingPeriods: Set<Period> = []
    @State private var fetchedPeriods: Set<Period> = []
    @State private var period: Period = .today

    var body: some View {
        ZStack {
            LateNightTheme.feedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                periodSelector
                    .padding(.bottom, 4)

                // Swipeable three-tab pager (today / this week / all time). The
                // period selector above and this TabView both bind to `period`,
                // so tapping a tab and swiping stay in sync — same pattern as the
                // main feed's for-you/following pager.
                SwipePager(selection: $period, ids: Period.allCases) { p in
                    periodPage(p)
                }
            }
        }
        .onAppear {
            ensureFetched(.today)
        }
        .onChange(of: period) { _, newPeriod in
            ensureFetched(newPeriod)
        }
    }

    // One page of the pager for a given period.
    @ViewBuilder
    private func periodPage(_ p: Period) -> some View {
        let posts = cache[p] ?? []
        if loadingPeriods.contains(p) && posts.isEmpty {
            VStack {
                Spacer()
                ProgressView().tint(ToskaColor.accent)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if posts.isEmpty {
            // Empty state must STILL be pull-to-refreshable — a quiet day on
            // "today" shouldn't trap the user with no way to recheck. A
            // ScrollView (even with little content) gives .refreshable a
            // scrollable surface; the tall min-height keeps the pull gesture
            // available across the whole page.
            GeometryReader { geo in
                ScrollView {
                    VStack {
                        emptyState
                    }
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .refreshable {
                    await withCheckedContinuation { continuation in
                        fetchTopPosts(for: p, force: true, onComplete: { continuation.resume() })
                    }
                }
            }
        } else {
            TopPeriodColumn(posts: posts, period: p) {
                await withCheckedContinuation { continuation in
                    fetchTopPosts(for: p, force: true, onComplete: { continuation.resume() })
                }
            }
        }
    }

    /// Fetch a period's data once (unless already fetched). force=true refetches.
    private func ensureFetched(_ p: Period) {
        guard !fetchedPeriods.contains(p) else { return }
        fetchTopPosts(for: p)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ToskaColor.accent)
                Text("most felt")
                    .toskaEyebrow()
            }
            Text("top")
                .toskaScreenTitle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    // MARK: - Period selector (segmented control)

    // Underline tab style — matches the main feed's "for you / following" tabs
    // (feedTabs in FeedView) so the period selector reads as the same control
    // vocabulary across the app instead of a separate boxed segmented control.
    private var periodSelector: some View {
        HStack(spacing: 0) {
            ForEach(Period.allCases) { p in
                let isSel = period == p
                Button {
                    if period != p {
                        withAnimation(.easeInOut(duration: 0.18)) { period = p }
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(p.rawValue)
                            .font(ToskaFont.sans(13, weight: isSel ? .semibold : .regular))
                            .foregroundColor(isSel ? ToskaColor.text : ToskaColor.text3)
                        Capsule()
                            .fill(isSel ? ToskaColor.accent : Color.clear)
                            .frame(width: 22, height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Content


    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(ToskaColor.text3)
            Text("nothing yet")
                .font(ToskaFont.sans(13))
                .foregroundColor(ToskaColor.text2)
            Text("everyones being quiet right now.")
                .font(ToskaFont.sans(11))
                .foregroundColor(ToskaColor.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - Aggregation

    /// Two most-frequent tags among the ranked posts, most-felt first.

    // MARK: - Fetch

    func fetchTopPosts(for fetchPeriod: Period, force: Bool = false, onComplete: (() -> Void)? = nil) {
        if !force && fetchedPeriods.contains(fetchPeriod) { onComplete?(); return }
        loadingPeriods.insert(fetchPeriod)
        let cutoff = fetchPeriod.cutoff
        Firestore.firestore().collection("posts")
            // moderationStatus filter required by firestore.rules
            // 2026-05-31 (see FeedViewModel.fetchPosts comment).
            .whereField("moderationStatus", isEqualTo: "live")
            .whereField("createdAt", isGreaterThan: Timestamp(date: cutoff))
            .order(by: "createdAt", descending: true)
            .limit(to: 100)
            .getDocuments { snapshot, error in
                Task { @MainActor in
                    if let error = error {
                        print("❌ TopView query error: \(error)")
                        loadingPeriods.remove(fetchPeriod)
                        fetchedPeriods.insert(fetchPeriod)
                        onComplete?()
                        return
                    }
                    guard let documents = snapshot?.documents else {
                        loadingPeriods.remove(fetchPeriod)
                        fetchedPeriods.insert(fetchPeriod)
                        onComplete?()
                        return
                    }
                    print("📊 TopView got \(documents.count) docs")
                    var engaged: [(handle: String, text: String, tag: String?, likes: Int, replies: Int, reposts: Int, time: String, id: String, authorId: String, score: Double)] = []

                    for doc in documents {
                        let data = doc.data()
                        let authorId = data["authorId"] as? String ?? ""
                        if BlockedUsersCache.shared.isBlocked(authorId) { continue }
                        if let expiresAt = data["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() { continue }
                        // Don't surface auto-flagged or admin-flagged posts on the
                        // trending screen (mirrors FeedViewModel.filterBlocked).
                        if data["flagged"] as? Bool == true { continue }
                        if data["concerningContent"] as? Bool == true { continue }
                        // Reposts shouldn't trend — original posts only.
                        if data["isRepost"] as? Bool == true { continue }

                        let likeCount = data["likeCount"] as? Int ?? 0
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()

                        // Rank by like count, createdAt as a tiebreaker so newer
                        // posts bubble up among ties. "felt this" == likes.
                        let score = Double(likeCount) + createdAt.timeIntervalSince1970 / 1_000_000_000_000
                        let entry = (
                            handle: data["authorHandle"] as? String ?? "anonymous",
                            text: data["text"] as? String ?? "",
                            tag: data["tag"] as? String,
                            likes: likeCount,
                            replies: data["replyCount"] as? Int ?? 0,
                            reposts: data["repostCount"] as? Int ?? 0,
                            time: FeedView.timeAgoString(from: createdAt),
                            id: doc.documentID,
                            authorId: authorId,
                            score: score
                        )
                        engaged.append(entry)
                    }

                    let ranked = engaged
                        .sorted { $0.score > $1.score }
                        .prefix(10)
                        .map { RankedPost(id: $0.id, handle: $0.handle, text: $0.text, tag: $0.tag, likes: $0.likes, authorId: $0.authorId, replies: $0.replies, reposts: $0.reposts, time: $0.time) }
                    print("📊 TopView showing \(ranked.count) ranked, engaged: \(engaged.count)")
                    cache[fetchPeriod] = ranked
                    loadingPeriods.remove(fetchPeriod)
                    fetchedPeriods.insert(fetchPeriod)
                    onComplete?()
                }
            }
    }
}

// MARK: - TopPeriodColumn
//
// One page of the swipeable Top/"most felt" pager — renders a single period's
// ranked posts (summary, distribution bar, hero, the rest). Extracted from
// TopView so all three periods (today / this week / all time) can live in a
// paging TabView at once, each holding its own data. `period` is passed in for
// the period-specific copy; `onRefresh` re-fetches this page on pull-to-refresh.
@MainActor
struct TopPeriodColumn: View {
    let posts: [RankedPost]
    let period: TopView.Period
    let onRefresh: () async -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                Color.clear.frame(height: 0).id("top")

                // Summary line — serif italic with the two most-felt emotions
                // tinted in their colors.
                summaryLine
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                // Distribution bar — one segment per top post, colored by tag.
                distributionBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                // Hero — the single most-felt post.
                if let hero = posts.first {
                    heroCard(hero)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }

                // The rest — ranked 02…N.
                if posts.count > 1 {
                    Text("the rest")
                        .toskaEyebrow()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)

                    ForEach(Array(posts.dropFirst().enumerated()), id: \.element.id) { idx, post in
                        restRow(post, rank: idx + 2)
                        Rectangle()
                            .fill(ToskaColor.divider)
                            .frame(height: 0.5)
                            .padding(.leading, 52)
                    }
                }

                Color.clear.frame(height: 130)
            }
            .refreshable { await onRefresh() }
            .onReceive(NotificationCenter.default.publisher(for: .scrollTopTabToTop)) { _ in
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo("top", anchor: .top)
                }
            }
        }
    }

    // MARK: - Summary line

    private var summaryLine: some View {
        let top = topTags()
        let lead: String = {
            switch period {
            case .today: return "today, the app most felt "
            case .week:  return "this week the app is mostly feeling "
            case .all:   return "of all time, the app most felt "
            }
        }()

        var line = Text(lead)
            .font(ToskaFont.serifItalic(17))
            .foregroundColor(ToskaColor.text)

        if let first = top.first {
            line = line + Text(first)
                .font(ToskaFont.serifItalic(17))
                .foregroundColor(tagColor(for: first))
        }
        if top.count > 1 {
            line = line + Text(" & ")
                .font(ToskaFont.serifItalic(17))
                .foregroundColor(ToskaColor.text)
            line = line + Text(top[1])
                .font(ToskaFont.serifItalic(17))
                .foregroundColor(tagColor(for: top[1]))
        }
        line = line + Text(".")
            .font(ToskaFont.serifItalic(17))
            .foregroundColor(ToskaColor.text)

        return line
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }

    private var distributionBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(posts.prefix(7).enumerated()), id: \.element.id) { _, post in
                Rectangle()
                    .fill(post.tag.map { tagColor(for: $0) } ?? ToskaColor.text3)
                    .frame(maxWidth: .infinity)
                    .frame(height: 5)
            }
        }
        .clipShape(Capsule())
    }

    // MARK: - Hero card

    private func heroCard(_ post: RankedPost) -> some View {
        NavigationLink {
            detail(for: post)
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                Text("most felt \(period.heroSuffix)")
                    .font(ToskaFont.eyebrow)
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundColor(ToskaColor.accent)

                Text(post.text)
                    .font(ToskaFont.serif(20))
                    .foregroundColor(ToskaColor.text)
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .center) {
                    if let tag = post.tag {
                        emotionChip(tag)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Text(formatCount(post.likes))
                            .font(ToskaFont.sans(13, weight: .semibold))
                            .foregroundColor(ToskaColor.text)
                        Text("felt this")
                            .font(ToskaFont.sans(13))
                            .foregroundColor(ToskaColor.text2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ToskaSpace.lg)
            .toskaCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rest row

    private func restRow(_ post: RankedPost, rank: Int) -> some View {
        NavigationLink {
            detail(for: post)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(String(format: "%02d", rank))
                    .font(ToskaFont.serifItalic(15))
                    .foregroundColor(ToskaColor.text3)
                    .frame(width: 24, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text(post.text)
                        .font(ToskaFont.serif(16))
                        .foregroundColor(ToskaColor.text)
                        .lineSpacing(3)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        if let tag = post.tag {
                            Image(systemName: ToskaEmotion.icon(tag))
                                .font(.system(size: 11))
                                .foregroundColor(tagColor(for: tag))
                            Text(tag)
                                .font(ToskaFont.sans(13, weight: .medium))
                                .foregroundColor(tagColor(for: tag))
                            Text("·")
                                .font(ToskaFont.sans(12))
                                .foregroundColor(ToskaColor.text3)
                        }
                        Text("\(formatCount(post.likes)) felt this")
                            .font(ToskaFont.sans(12))
                            .foregroundColor(ToskaColor.text2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Emotion chip (hero)

    private func emotionChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ToskaEmotion.icon(tag))
                .font(.system(size: 13, weight: .medium))
            Text(tag)
                .font(ToskaFont.chip)
        }
        .foregroundColor(tagColor(for: tag))
        .padding(.vertical, 4)
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .background(tagColor(for: tag).opacity(0.13))
        .clipShape(Capsule())
    }

    private func detail(for post: RankedPost) -> some View {
        PostDetailView(
            postId: post.id,
            handle: post.handle,
            text: post.text,
            tag: post.tag,
            likes: post.likes,
            reposts: post.reposts,
            replies: post.replies,
            time: post.time,
            authorId: post.authorId
        )
        .navigationBarHidden(true)
    }

    private func topTags() -> [String] {
        var counts: [String: Int] = [:]
        for post in posts {
            if let tag = post.tag { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(2).map { $0.key }
    }
}
