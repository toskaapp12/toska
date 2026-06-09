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
    private var inFlightLikes: Set<String> = []
    func isLikeInFlight(_ postId: String) -> Bool { inFlightLikes.contains(postId) }
    func markLikeInFlight(_ postId: String) { inFlightLikes.insert(postId) }
    func markLikeComplete(_ postId: String) { inFlightLikes.remove(postId) }

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

    private init() {}
}
