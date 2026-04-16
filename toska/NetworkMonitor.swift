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
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
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
                        self.bannerDismissTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            guard !Task.isCancelled else { return }
                            self.showOfflineBanner = false
                        }
                    }
                }
            }
            monitor.start(queue: queue)
            // Initialise isConnected from the real monitor's path after it starts
            isConnected = monitor.currentPath.status == .satisfied
        }
}

@MainActor
class RateLimiter {
    static let shared = RateLimiter()

    var lastPostTime: Date? = nil
    var lastLikeTime: Date? = nil
    var lastReplyTime: Date? = nil
    var lastSaveTime: Date? = nil
    // Repost was previously unrate-limited — rapid taps could fire several
    // dedup-check round trips before the first one's optimistic UI settled.
    var lastRepostTime: Date? = nil
    // Messages, reports had no client rate limiter — a held send button or
    // repeated flag taps could burst writes before the 5-per-convo rule
    // kicked in (messages) or add duplicate reports with no feedback.
    var lastMessageTime: Date? = nil
    var lastReportTime: Date? = nil

    private init() {}
}
