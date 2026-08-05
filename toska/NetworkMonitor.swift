import Foundation
import Network
import Observation

@Observable
@MainActor
class NetworkMonitor {
    static let shared = NetworkMonitor()
    
    var isConnected = true
        var showOfflineBanner = false

        private let monitor = NWPathMonitor()
        private let queue = DispatchQueue(label: "NetworkMonitor")
        private var bannerDismissTask: Task<Void, Never>? = nil

        private init() {
            // pathUpdateHandler is a @Sendable closure invoked off the main
            // queue. The inner Task re-captures self weakly so Swift 6 strict
            // concurrency doesn't flag the cross-closure self capture as a
            // shared-mutable-state hazard.
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let wasConnected = self.isConnected
                    self.isConnected = path.status == .satisfied

                    if path.status != .satisfied {
                        self.bannerDismissTask?.cancel()
                        self.bannerDismissTask = nil
                        self.showOfflineBanner = true
                    } else if !wasConnected {
                        // Reconnected — wait 2s then hide banner, cancelling any prior task
                        self.bannerDismissTask?.cancel()
                        self.bannerDismissTask = Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            guard !Task.isCancelled, let self else { return }
                            self.showOfflineBanner = false
                        }
                    }
                }
            }
            monitor.start(queue: queue)
        }
}

@MainActor
class RateLimiter {
    static let shared = RateLimiter()

    var lastPostTime: Date? = nil
    var lastReplyTime: Date? = nil

    // Like/save/repost are per-postId so a quick double-tap on the same post
    // is throttled but interacting with a different post in the next 200ms
    // works as expected. Previously a single timestamp gated all posts, which
    // silently dropped scroll-fast like activity with no UI feedback.
    private var lastLikeByPost: [String: Date] = [:]
    private var lastSaveByPost: [String: Date] = [:]
    private var lastRepostByPost: [String: Date] = [:]

    // The per-post dictionaries would otherwise grow unbounded for the whole
    // session (one entry per post the user ever interacts with). The longest
    // rate-limit window here is 0.8s, so any entry older than this retention
    // window can never gate a new action — prune it on each record to keep
    // memory bounded while leaving recent (still-throttling) entries intact.
    private static let entryRetention: TimeInterval = 60

    private func prune(_ dict: inout [String: Date]) {
        let cutoff = Date().addingTimeInterval(-Self.entryRetention)
        dict = dict.filter { $0.value > cutoff }
    }

    func lastLikeTime(for postId: String) -> Date? { lastLikeByPost[postId] }
    func recordLike(for postId: String) {
        prune(&lastLikeByPost)
        lastLikeByPost[postId] = Date()
    }

    // In-flight like guard. The 0.8s rate-limit window is enough to debounce
    // a quick double-tap, but a slow transaction that runs longer than 0.8s
    // could let a second tap fire while the first is still committing — both
    // optimistic updates land, both rollbacks (or one rollback + one success)
    // race, and the UI flips state visibly. Tracking in-flight transactions
    // explicitly closes that gap. Caller marks at toggleLike entry, unmarks
    // in the completion handler regardless of success/failure.
    // Tracked with the start timestamp (not a bare Set) so a stuck entry can
    // self-heal: if a caller ever throws before reaching markLikeComplete, an
    // entry older than this safety window is treated as cleared rather than
    // locking that post's like for the rest of the session.
    private var inFlightLikes: [String: Date] = [:]
    private static let inFlightTimeout: TimeInterval = 10
    func isLikeInFlight(_ postId: String) -> Bool {
        guard let startedAt = inFlightLikes[postId] else { return false }
        if Date().timeIntervalSince(startedAt) > Self.inFlightTimeout {
            inFlightLikes[postId] = nil
            return false
        }
        return true
    }
    func markLikeInFlight(_ postId: String) { inFlightLikes[postId] = Date() }
    func markLikeComplete(_ postId: String) { inFlightLikes[postId] = nil }

    // Same in-flight pattern for repost/unrepost, keyed by the post (or reply) id.
    // Because repost AND unrepost both check + mark this, they serialize against
    // each other — a second tap (double-repost, double-unrepost, or a repost↔
    // unrepost thrash) is dropped until the in-flight write completes, which is
    // what otherwise drifted the visible repost count.
    private var inFlightReposts: [String: Date] = [:]
    func isRepostInFlight(_ id: String) -> Bool {
        guard let startedAt = inFlightReposts[id] else { return false }
        if Date().timeIntervalSince(startedAt) > Self.inFlightTimeout { inFlightReposts[id] = nil; return false }
        return true
    }
    func markRepostInFlight(_ id: String) { inFlightReposts[id] = Date() }
    func markRepostComplete(_ id: String) { inFlightReposts[id] = nil }

    // Same in-flight pattern for save/unsave, keyed by the post (or "reply_{id}")
    // id. The lastSaveTime rate window alone can't stop a save→unsave interleave
    // slower than the window: the second toggle reads a not-yet-committed doc,
    // no-ops, and leaves server and UI disagreeing (bookmark sticks opposite in
    // Post/Reply detail, which only check once on appear). check+mark here
    // serializes the two so they converge to the latest intent.
    private var inFlightSaves: [String: Date] = [:]
    func isSaveInFlight(_ id: String) -> Bool {
        guard let startedAt = inFlightSaves[id] else { return false }
        if Date().timeIntervalSince(startedAt) > Self.inFlightTimeout { inFlightSaves[id] = nil; return false }
        return true
    }
    func markSaveInFlight(_ id: String) { inFlightSaves[id] = Date() }
    func markSaveComplete(_ id: String) { inFlightSaves[id] = nil }

    func lastSaveTime(for postId: String) -> Date? { lastSaveByPost[postId] }
    func recordSave(for postId: String) {
        prune(&lastSaveByPost)
        lastSaveByPost[postId] = Date()
    }

    func lastRepostTime(for postId: String) -> Date? { lastRepostByPost[postId] }
    func recordRepost(for postId: String) {
        prune(&lastRepostByPost)
        lastRepostByPost[postId] = Date()
    }

    // Account-switch hygiene (2026-08-05): every cooldown here throttles ONE
    // user's intent, but the singleton outlives sign-out — user A posts, signs
    // out, user B signs in on the same device and inherits A's 30s post window
    // / 5s reply window / in-flight locks, so B's first action is silently
    // swallowed (ComposeView shows A's "one breath" banner to B). Clear it all
    // on the same .userDidSignOut notification the views already tear down on.
    // In-flight maps are cleared too: a straggling completion from the old
    // session only calls markComplete (sets nil), which is idempotent.
    func reset() {
        lastPostTime = nil
        lastReplyTime = nil
        lastLikeByPost.removeAll()
        lastSaveByPost.removeAll()
        lastRepostByPost.removeAll()
        inFlightLikes.removeAll()
        inFlightReposts.removeAll()
        inFlightSaves.removeAll()
    }

    private init() {
        // Registered lazily on first use — fine, because state only exists
        // after first use. Same @Sendable-closure + inner-@MainActor-Task shape
        // as NetworkMonitor.pathUpdateHandler so Swift 6 strict concurrency
        // doesn't flag the cross-closure self capture.
        NotificationCenter.default.addObserver(
            forName: .userDidSignOut, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reset()
            }
        }
    }
}
