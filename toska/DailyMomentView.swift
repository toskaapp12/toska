import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

@MainActor
struct DailyMomentView: View {
    @Environment(\.dismiss) var dismiss
    @State private var postText = ""
    @State private var postHandle = ""
    @State private var postTag: String? = nil
    @State private var feltCount = 0
    @State private var isVisible = false
    // FIX: added explicit loading state so the view shows a spinner instead
    // of blank/zero content while the fetch is in flight.
    @State private var isLoading = true

    var timeLabel: String {
        "\(timeOfDayLabel())'s moment"
    }

    var body: some View {
        ZStack {
            Color(hex: "0a0908")
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.white.opacity(0.3))
                            .frame(width: 32, height: 32)
                    }
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
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color.toskaBlue)
                                .tracking(1)
                        }

                        Text(formattedDate())
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.2))
                    }
                    .opacity(isVisible ? 1 : 0)
                    .animation(.easeIn(duration: 0.8).delay(0.3), value: isVisible)

                    Spacer()

                    Text(postText)
                        .font(.custom("Georgia", size: 22))
                        .foregroundColor(.white.opacity(0.95))
                        .lineSpacing(8)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                        .opacity(isVisible ? 1 : 0)
                        .offset(y: isVisible ? 0 : 20)
                        .animation(.easeOut(duration: 1.0).delay(0.6), value: isVisible)

                    Spacer()

                    VStack(spacing: 8) {
                        if let tag = postTag {
                            Text(tag)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(tagColor(for: tag).opacity(0.5))
                                .tracking(1)
                        }

                        Text("\(formatCount(feltCount)) felt this")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.toskaBlue.opacity(0.7))

                        Text(postHandle)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.15))
                    }
                    .opacity(isVisible ? 1 : 0)
                    .animation(.easeIn(duration: 0.8).delay(1.2), value: isVisible)

                    Spacer()

                    VStack(spacing: 12) {
                        HStack(spacing: 5) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 10))
                            Text("screenshot this. share it. someone needs to see it.")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.2))
                        .opacity(isVisible ? 1 : 0)
                        .animation(.easeIn(duration: 0.8).delay(1.8), value: isVisible)

                        Button {
                            shareAsImage()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 12))
                                Text("share moment")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(Color.toskaBlue)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.toskaBlue.opacity(0.1))
                            .cornerRadius(20)
                        }
                        .opacity(isVisible ? 1 : 0)
                        .animation(.easeIn(duration: 0.8).delay(2.0), value: isVisible)

                        Text("toska")
                            .font(.custom("Georgia-Italic", size: 13))
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
                        postText    = postData["text"]         as? String ?? ""
                        postHandle  = postData["authorHandle"] as? String ?? "anonymous"
                        postTag     = postData["tag"]          as? String
                        feltCount   = postData["likeCount"]    as? Int    ?? 0
                    } else {
                        // The curated post ID exists but the post was deleted.
                        setFallbackPost()
                    }
                } else {
                    // No curated moment — pick the most-liked post from the
                    // last 24 hours that isn't blocked or expired.
                    let yesterday = Date().addingTimeInterval(-24 * 60 * 60)
                    let postsSnap = try await db
                        .collection("posts")
                        .whereField("createdAt", isGreaterThan: Timestamp(date: yesterday))
                        .order(by: "createdAt", descending: false)
                        .order(by: "likeCount", descending: true)
                        .limit(to: 20)
                        .getDocumentsAsync()

                    let blockedIds = BlockedUsersCache.shared.blockedUserIds
                    guard let topDoc = postsSnap.documents.first(where: {
                        let d = $0.data()
                        let authorId = d["authorId"] as? String ?? ""
                        if blockedIds.contains(authorId) { return false }
                        if let expiresAt = d["expiresAt"] as? Timestamp,
                           expiresAt.dateValue() < Date() { return false }
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
    }

    // MARK: - Helpers

    func formattedDate() -> String {
        ToskaFormatters.longDate.string(from: Date()).lowercased()
    }

    func formattedDateKey() -> String {
        ToskaFormatters.dateKey.string(from: Date())
    }

    // MARK: - Share

    @MainActor
    func shareAsImage() {
        let cardView = ZStack {
            Color(hex: "0a0908")

            VStack(spacing: 0) {
                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.toskaBlue)
                        .frame(width: 4, height: 4)
                    Text(timeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.toskaBlue)
                        .tracking(1)
                }
                .padding(.bottom, 24)

                Text(postText)
                    .font(.custom("Georgia", size: 22))
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
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(tagColor(for: tag).opacity(0.5))
                    .padding(.bottom, 8)
                }

                Text("\(formatCount(feltCount)) felt this")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.toskaBlue.opacity(0.7))
                    .padding(.bottom, 6)

                Text(postHandle)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.15))
                    .padding(.bottom, 24)

                VStack(spacing: 4) {
                    Text("toska")
                        .font(.custom("Georgia-Italic", size: 18))
                        .foregroundColor(.white.opacity(0.15))
                    Text("for the things you cant say out loud")
                        .font(.system(size: 9))
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
