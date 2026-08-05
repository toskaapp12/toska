import SwiftUI
import FirebaseAuth
import FirebaseFirestore

@MainActor
struct WeeklyRecapView: View {
    @Environment(\.dismiss) var dismiss
    @State private var postCount = 0
    @State private var totalLikesReceived = 0
    @State private var topTag: String? = nil
    @State private var topPostText = ""
    @State private var topPostLikes = 0
    @State private var communityPostCount = 0
    @State private var isLoading = true
    @State private var isVisible = false
    // (2026-08-05) every query in fetchRecapData was `try?`, so a network
    // failure silently rendered the "nothing this week" empty state — telling
    // a user their week was empty when the reads just failed. Set when any
    // required query errors; drives the shared ToskaErrorBanner + hides the
    // share button (which would otherwise share zeros).
    @State private var loadFailed = false
    
    var body: some View {
        ZStack {
            Color.toskaNearBlack.ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        // F6 (2026-07-27 full-audit): 32pt hit area was below the
                        // 44pt minimum; keep the 14pt glyph, enlarge the target.
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.white.opacity(0.3))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("close")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
                Spacer()
                
                if isLoading {
                                    ProgressView().tint(Color.toskaBlue)
                                } else if loadFailed {
                                    // Failure state (2026-08-05) — distinct from the
                                    // "nothing this week" empty state below, which a
                                    // failed fetch used to masquerade as.
                                    ToskaErrorBanner("couldn't load your recap — check your connection") {
                                        loadFailed = false
                                        isLoading = true
                                        fetchRecapData()
                                    }
                                    .padding(.horizontal, 16)
                                } else if postCount == 0 {
                                    VStack(spacing: 12) {
                                        Text("nothing this week.")
                                            .font(ToskaFont.serifItalic(20))
                                            .foregroundColor(.white.opacity(0.4))
                                        Text("say something. it keeps.")
                                            .font(ToskaFont.sans(12))
                                            .foregroundColor(.white.opacity(0.2))
                                    }
                                    .opacity(isVisible ? 1 : 0)
                                    .animation(.easeIn(duration: 0.8).delay(0.3), value: isVisible)
                                } else {
                                    VStack(spacing: 24) {                        VStack(spacing: 4) {
                            Text("your week")
                                                            .font(ToskaFont.serifItalic(22))
                                                            .foregroundColor(.white)
                            Text(weekRangeString())
                                .font(ToskaFont.sans(11))
                                .foregroundColor(.white.opacity(0.25))
                        }
                        .opacity(isVisible ? 1 : 0)
                        .animation(.easeIn(duration: 0.6).delay(0.2), value: isVisible)
                        
                        // Stats row
                        HStack(spacing: 24) {
                            recapStat(number: postCount, label: "posts")
                            recapStat(number: totalLikesReceived, label: "total likes")
                        }
                        .opacity(isVisible ? 1 : 0)
                        .animation(.easeIn(duration: 0.6).delay(0.5), value: isVisible)
                        
                        // Top post
                        if !topPostText.isEmpty {
                            VStack(spacing: 8) {
                                Text("hit the hardest this week")
                                    .font(ToskaFont.sans(11, weight: .semibold))
                                    .foregroundColor(Color.toskaBlue)
                                    .tracking(1)
                                
                                Text(topPostText)
                                    .font(ToskaFont.serif(16))
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineSpacing(5)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                                
                                Text("\(formatCount(topPostLikes)) felt this")
                                    .font(ToskaFont.sans(11))
                                    .foregroundColor(Color.toskaWhisperPink.opacity(0.7))
                            }
                            .opacity(isVisible ? 1 : 0)
                            .offset(y: isVisible ? 0 : 15)
                            .animation(.easeOut(duration: 0.8).delay(0.8), value: isVisible)
                        }
                        
                        // Top mood
                        if let tag = topTag {
                            VStack(spacing: 4) {
                                Text("you were mostly feeling")
                                                                    .font(ToskaFont.sans(11))
                                                                    .foregroundColor(.white.opacity(0.3))
                                Text(tag)
                                    .font(ToskaFont.sans(13, weight: .semibold))
                                    .foregroundColor(tagColor(for: tag))
                            }
                            .opacity(isVisible ? 1 : 0)
                            .animation(.easeIn(duration: 0.6).delay(1.1), value: isVisible)
                        }
                        
                        // Community stat
                        if communityPostCount > 0 {
                            Text("\(formatCount(communityPostCount)) people said something they couldnt say anywhere else this week")
                                .font(ToskaFont.sans(11))
                                .foregroundColor(.white.opacity(0.25))
                                .opacity(isVisible ? 1 : 0)
                                .animation(.easeIn(duration: 0.6).delay(1.4), value: isVisible)
                        }
                    }
                }
                
                Spacer()
                
                // Share button
                // Share button — hidden while loading OR after a failed load
                              // so it can't be tapped before data has arrived
                              // (would share zeros). (2026-08-05: + loadFailed)
                              if !isLoading && !loadFailed {
                                  Button {
                                      shareRecap()
                                  } label: {
                                      HStack(spacing: 6) {
                                          Image(systemName: "square.and.arrow.up")
                                              .font(.system(size: 12))
                                          Text("share recap")
                                              .font(ToskaFont.sans(12, weight: .medium))
                                      }
                                      .foregroundColor(Color.toskaBlue)
                                      .padding(.horizontal, 24)
                                      .padding(.vertical, 10)
                                      .background(Color.toskaBlue.opacity(0.1))
                                      .cornerRadius(20)
                                  }
                                  .opacity(isVisible ? 1 : 0)
                                  .animation(.easeIn(duration: 0.6).delay(1.7), value: isVisible)
                              }
                Text("toska")
                    .font(ToskaFont.serifItalic(13))
                    .foregroundColor(.white.opacity(0.12))
                    .padding(.top, 12)
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
                    fetchRecapData()
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        isVisible = true
                    }
                }
    }
    
    func recapStat(number: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(number)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(label)
                .font(ToskaFont.sans(11))
                .foregroundColor(.white.opacity(0.4))
        }
    }
    
    private static let weekRangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    func weekRangeString() -> String {
        let today = Date()
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: today) ?? today
        let fmt = Self.weekRangeFormatter
        return "\(fmt.string(from: weekAgo).lowercased()) – \(fmt.string(from: today).lowercased())"
    }
    
    func fetchRecapData() {
            guard let uid = Auth.auth().currentUser?.uid else {
                isLoading = false
                return
            }
            let db = Firestore.firestore()
            // Anchor to start-of-day in the user's calendar so the window is a
            // full 7 calendar days regardless of when the user opens the recap.
            // Using addingTimeInterval(-7*86400) would drift up to 23-25h around DST.
            let calendar = Calendar.current
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: Date())) ?? Date().addingTimeInterval(-7 * 24 * 60 * 60)
            let userWeekQuery = db.collection("posts")
                .whereField("authorId", isEqualTo: uid)
                .whereField("createdAt", isGreaterThan: Timestamp(date: weekAgo))
            
            Task { @MainActor in
                // Run all four queries concurrently, wait for all to finish.
                // (2026-08-05) the three user-scoped queries now return nil on
                // a QUERY error (vs. a real zero/empty result) so a network
                // failure can surface the retry banner instead of silently
                // rendering "nothing this week".
                async let postCountResult: Int? = {
                    // Exclude reposts so "posts this week" counts the user's own
                    // words, consistent with the top-post stat (which skips
                    // reposts) and the totalLikes sum below. Covered by the
                    // [authorId, isRepost, createdAt] composite index.
                    guard let snap = try? await userWeekQuery
                        .whereField("isRepost", isEqualTo: false)
                        .count.getAggregation(source: .server) else { return nil }
                    return Int(truncating: snap.count)
                }()
                
                async let communityCountResult: Int = {
                                    // Must pin moderationStatus == "live": without it a
                                    // pending_review post by another author COULD match, so
                                    // Firestore can't prove the cross-author query safe and
                                    // DENIES the aggregation → the community stat silently
                                    // stayed 0 and the line never rendered.
                                    let snap = try? await db.collection("posts")
                                        .whereField("moderationStatus", isEqualTo: "live")
                                        .whereField("createdAt", isGreaterThan: Timestamp(date: weekAgo))
                                        .whereField("isRepost", isEqualTo: false)
                                        .count
                                        .getAggregation(source: .server)
                                    return Int(truncating: snap?.count ?? 0)
                                }()
                
                async let topPostResult: (String, Int)? = {
                    // Fetch this week's posts ordered by createdAt (the range
                    // filter field — Firestore requires the first orderBy to
                    // match the inequality field, so we can't .order(by:
                    // "likeCount") here without an INVALID_ARGUMENT that the
                    // outer try? would silently swallow into ("", 0)). Sort
                    // by likeCount client-side, then pick the first that's
                    // not expired/flagged/concerning. Mirrors the same
                    // workaround in DailyMomentView.
                    guard let snap = try? await userWeekQuery
                        .order(by: "createdAt", descending: true)
                        .limit(to: 50)
                        .getDocuments() else { return nil }
                    let sortedByLikes = snap.documents.sorted {
                        ($0.data()["likeCount"] as? Int ?? 0)
                            > ($1.data()["likeCount"] as? Int ?? 0)
                    }
                    if !sortedByLikes.isEmpty {
                        let docs = sortedByLikes
                        let now = Date()
                        for doc in docs {
                            let data = doc.data()
                            if data["flagged"] as? Bool == true { continue }
                            if data["concerningContent"] as? Bool == true { continue }
                            // (2026-08-05) skip posts held for moderation —
                            // "hit the hardest this week" must not celebrate a
                            // post that review may remove. The author-scoped
                            // query returns their held posts (authorId == me
                            // satisfies the read rule), so without this filter
                            // a pending_review post could be the week's top
                            // post. "live" and the brief pending_validation
                            // window still qualify, matching the flagged/
                            // concerning filters above.
                            if data["moderationStatus"] as? String == "pending_review" { continue }
                            if let expiresAt = data["expiresAt"] as? Timestamp,
                               expiresAt.dateValue() < now { continue }
                            // Skip reposts. The user's "top post of the week"
                            // is meant to celebrate their original words —
                            // showing a repost (whose text is the original
                            // author's, just shared by this user) under
                            // "your top post" reads as if they wrote it.
                            // Falls through to the next candidate from the
                            // top-5 widening above.
                            if data["isRepost"] as? Bool == true { continue }
                            return (data["text"] as? String ?? "", data["likeCount"] as? Int ?? 0)
                        }
                    }
                    return ("", 0)
                }()
                
                async let tagDistResult: (Int, String?)? = {
                    guard let snap = try? await userWeekQuery
                        .order(by: "createdAt", descending: true)
                        .limit(to: 100)
                        .getDocuments() else { return nil }
                    let docs = snap.documents
                    var likes = 0
                    var tagCounts: [String: Int] = [:]
                    for doc in docs {
                        let data = doc.data()
                        // Skip reposts: their likeCount and tag belong to the
                        // original author, so counting them would attribute other
                        // people's engagement to this user's week (and disagree
                        // with the repost-excluded post count + top post).
                        if data["isRepost"] as? Bool == true { continue }
                        likes += data["likeCount"] as? Int ?? 0
                        if let tag = data["tag"] as? String {
                            tagCounts[tag, default: 0] += 1
                        }
                    }
                    return (likes, tagCounts.max(by: { $0.value < $1.value })?.key)
                }()
                
                // Await all four — none can leave isLoading stuck
                let postCountValue = await postCountResult
                let communityCount = await communityCountResult
                let topPost = await topPostResult
                let tagDist = await tagDistResult

                // (2026-08-05) any REQUIRED user-scoped query failing → show
                // the retry banner, not the "nothing this week" empty state.
                // communityCount is deliberately NOT required: it's a vanity
                // line that renders only when > 0, and treating its historically
                // fussier cross-author aggregation as fatal would brick the
                // whole recap over a cosmetic stat.
                guard let postCountValue, let topPost, let tagDist else {
                    self.loadFailed = true
                    self.isLoading = false
                    return
                }

                self.postCount = postCountValue
                self.communityPostCount = communityCount
                self.topPostText = topPost.0
                self.topPostLikes = topPost.1
                self.totalLikesReceived = tagDist.0
                self.topTag = tagDist.1
                self.loadFailed = false
                self.isLoading = false
            }
        }
    
    @MainActor
    func shareRecap() {
        let cardView = ZStack {
            Color.toskaNearBlack
            VStack(spacing: 16) {
                Spacer()
                Text("my week")
                                    .font(ToskaFont.serifItalic(20))
                                    .foregroundColor(.white)
                Text(weekRangeString())
                    .font(ToskaFont.sans(11))
                    .foregroundColor(.white.opacity(0.25))
                Spacer()
                HStack(spacing: 24) {
                    recapStat(number: postCount, label: "posts")
                    recapStat(number: totalLikesReceived, label: "total likes")
                }
                if let tag = topTag {
                    Text("mostly \(tag)")
                        .font(ToskaFont.sans(11))
                        .foregroundColor(tagColor(for: tag).opacity(0.7))
                }
                Spacer()
                Text("toska")
                    .font(ToskaFont.serifItalic(12))
                    .foregroundColor(.white.opacity(0.12))
                    .padding(.bottom, 16)
            }
        }
            .frame(width: 390, height: 690)
                    .environment(\.colorScheme, .dark)
                    
                    let renderer = ImageRenderer(content: cardView)
        renderer.scale = 3.0
        if let image = renderer.uiImage {
                            presentShareSheet(with: [image])
                        }
            }
        }
