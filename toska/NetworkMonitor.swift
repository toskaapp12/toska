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

    func lastLikeTime(for postId: String) -> Date? { lastLikeByPost[postId] }
    func recordLike(for postId: String) { lastLikeByPost[postId] = Date() }

    func lastSaveTime(for postId: String) -> Date? { lastSaveByPost[postId] }
    func recordSave(for postId: String) { lastSaveByPost[postId] = Date() }

    func lastRepostTime(for postId: String) -> Date? { lastRepostByPost[postId] }
    func recordRepost(for postId: String) { lastRepostByPost[postId] = Date() }

    private init() {}
}
