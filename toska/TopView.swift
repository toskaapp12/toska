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
            case .all:   return Date().addingTimeInterval(-365 * 24 * 60 * 60)
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

    @State private var rankedPosts: [RankedPost] = []
    @State private var isLoading = true
    @State private var hasFetchedInitial = false
    @State private var period: Period = .today

    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                periodSelector
                    .padding(.bottom, 4)

                if isLoading {
                    Spacer()
                    ProgressView().tint(ToskaColor.accent)
                    Spacer()
                } else if rankedPosts.isEmpty {
                    emptyState
                    Spacer()
                } else {
                    content
                }
            }
        }
        .onAppear {
            guard !hasFetchedInitial else { return }
            hasFetchedInitial = true
            fetchTopPosts()
        }
        .onChange(of: period) { _, _ in
            isLoading = true
            fetchTopPosts()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("most felt")
                .toskaEyebrow()
            Text("top")
                .toskaScreenTitle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    // MARK: - Period selector (segmented control)

    private var periodSelector: some View {
        HStack(spacing: 3) {
            ForEach(Period.allCases) { p in
                let isSel = period == p
                Button {
                    if period != p { period = p }
                } label: {
                    Text(p.rawValue)
                        .font(.system(size: 14, weight: isSel ? .semibold : .medium))
                        .foregroundColor(isSel ? ToskaColor.text : ToskaColor.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(isSel ? ToskaColor.card : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(isSel ? ToskaColor.accent.opacity(0.5) : Color.clear, lineWidth: 1)
                                )
                                .shadow(color: isSel ? Color.black.opacity(0.06) : Color.clear, radius: 3, x: 0, y: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(ToskaColor.input))
        .padding(.horizontal, 16)
    }

    // MARK: - Content

    private var content: some View {
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
                    .padding(.bottom, 18)

                // Hero — the single most-felt post.
                if let hero = rankedPosts.first {
                    heroCard(hero)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 22)
                }

                // The rest — ranked 02…N.
                if rankedPosts.count > 1 {
                    Text("the rest")
                        .toskaEyebrow()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)

                    ForEach(Array(rankedPosts.dropFirst().enumerated()), id: \.element.id) { idx, post in
                        restRow(post, rank: idx + 2)
                        Rectangle()
                            .fill(ToskaColor.divider)
                            .frame(height: 0.5)
                            .padding(.leading, 52)
                    }
                }

                Color.clear.frame(height: 100)
            }
            .refreshable {
                await withCheckedContinuation { continuation in
                    fetchTopPosts(onComplete: { continuation.resume() })
                }
            }
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
        HStack(spacing: 2) {
            ForEach(Array(rankedPosts.prefix(7).enumerated()), id: \.element.id) { _, post in
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
                    .font(ToskaFont.serif(24))
                    .foregroundColor(ToskaColor.text)
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .center) {
                    if let tag = post.tag {
                        emotionChip(tag)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Text(formatCount(post.likes))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ToskaColor.text)
                        Text("felt this")
                            .font(.system(size: 13))
                            .foregroundColor(ToskaColor.text2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
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

                    HStack(spacing: 6) {
                        if let tag = post.tag {
                            Image(systemName: ToskaEmotion.icon(tag))
                                .font(.system(size: 11))
                                .foregroundColor(tagColor(for: tag))
                            Text(tag)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(tagColor(for: tag))
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundColor(ToskaColor.text3)
                        }
                        Text("\(formatCount(post.likes)) felt this")
                            .font(.system(size: 12.5))
                            .foregroundColor(ToskaColor.text2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Emotion chip (hero)

    private func emotionChip(_ tag: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ToskaEmotion.icon(tag))
                .font(.system(size: 13, weight: .medium))
            Text(tag)
                .font(ToskaFont.chip)
        }
        .foregroundColor(tagColor(for: tag))
        .padding(.vertical, 5)
        .padding(.leading, 9)
        .padding(.trailing, 11)
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(ToskaColor.text3)
            Text("nothing yet")
                .font(.system(size: 13))
                .foregroundColor(ToskaColor.text2)
            Text("everyones being quiet right now.")
                .font(.system(size: 11))
                .foregroundColor(ToskaColor.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - Aggregation

    /// Two most-frequent tags among the ranked posts, most-felt first.
    private func topTags() -> [String] {
        var counts: [String: Int] = [:]
        for post in rankedPosts {
            if let tag = post.tag { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(2).map { $0.key }
    }

    // MARK: - Fetch

    func fetchTopPosts(onComplete: (() -> Void)? = nil) {
        let cutoff = period.cutoff
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
                        isLoading = false
                        onComplete?()
                        return
                    }
                    guard let documents = snapshot?.documents else {
                        isLoading = false
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

                    rankedPosts = engaged
                        .sorted { $0.score > $1.score }
                        .prefix(10)
                        .map { RankedPost(id: $0.id, handle: $0.handle, text: $0.text, tag: $0.tag, likes: $0.likes, authorId: $0.authorId, replies: $0.replies, reposts: $0.reposts, time: $0.time) }
                    print("📊 TopView showing \(rankedPosts.count) ranked, engaged: \(engaged.count)")
                    isLoading = false
                    onComplete?()
                }
            }
    }
}
