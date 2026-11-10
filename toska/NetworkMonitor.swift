import Foundation
import Network
import Observation
import FirebaseCore
import FirebaseFirestore

@Observable
@MainActor
class NetworkMonitor {
    static let shared = NetworkMonitor()
    
    var isConnected = true
        var showOfflineBanner = false

        private let monitor = NWPathMonitor()
        private let queue = DispatchQueue(label: "NetworkMonitor")
        private var bannerDismissTask: Task<Void, Never>? = nil

        /// DEBUG-only offline preview hook (mirrors TOSKA_FORCE_NIGHT):
        /// `SIMCTL_CHILD_TOSKA_FORCE_OFFLINE=1 simctl launch …` pins the
        /// monitor offline so offline UX + the action queue are testable
        /// deterministically. Compiled out of Release.
        static var forcedOffline: Bool {
            #if DEBUG
            return ProcessInfo.processInfo.environment["TOSKA_FORCE_OFFLINE"] == "1"
            #else
            return false
            #endif
        }

        private init() {
            if Self.forcedOffline {
                isConnected = false
                showOfflineBanner = true
                return   // ignore real path updates — stay offline all launch
            }
            // pathUpdateHandler is a @Sendable closure invoked off the main
            // queue. The inner Task re-captures self weakly so Swift 6 strict
            // concurrency doesn't flag the cross-closure self capture as a
            // shared-mutable-state hazard.
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let wasConnected = self.isConnected
                    self.isConnected = path.status == .satisfied

                    if self.isConnected {
                        // Fresh connectivity (first sample or a reconnect) —
                        // sync anything the user did while offline.
                        OfflineActionQueue.flush()
                    }
                    if self.isConnected && !wasConnected {
                        // (owner 2026-11-02) Firestore reconnects its own stream with exponential backoff
                        // after an outage (seconds to a minute); cycling its network resets that so the
                        // next read reaches the server. Safe: queued writes stay queued and flush on
                        // enable; listeners only receive cache-flagged snapshots meanwhile (the post
                        // detail ignores cache-based absence); the offline banner is driven by NWPath,
                        // not by Firestore, so it does not blip.
                        if FirebaseApp.app() != nil {
                            let db = Firestore.firestore()
                            db.disableNetwork { _ in db.enableNetwork { _ in } }
                        }
                        NotificationCenter.default.post(name: .networkDidReconnect, object: nil)
                    }

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
    // Build 123 (owner 2026-11-05/09): a tap that lands while the same action is still
    // in flight is QUEUED, never dropped — the old `guard !isXInFlight else { return }`
    // swallowed the first undo tap on a real network (the repost pipeline is four
    // round trips; on cellular that is 1–3 s). Polls every 100 ms up to `maxWait`,
    // then runs anyway (the in-flight timeout below clears stale flags).
    /// Build 124: on the re-invocation of a queued action the optimistic callback already ran at
    /// tap time — swallow the first onUpdate so counts don't move twice; later results pass through.
    static func skipFirst<T>(_ f: @escaping (T) -> Void) -> (T) -> Void {
        var skipped = false
        return { value in
            if !skipped { skipped = true; return }
            f(value)
        }
    }

    func whenClear(_ isBusy: @escaping () -> Bool, maxWait: TimeInterval = 8, then action: @escaping () -> Void) {
        guard isBusy() else { action(); return }
        #if DEBUG
        // Test-only "before" switch: TOSKA_SIM_LEGACY_DROP=1 restores the pre-123 behaviour
        // (a tap inside the in-flight window is dropped) so the UI tests can show before/after.
        if ProcessInfo.processInfo.environment["TOSKA_SIM_LEGACY_DROP"] == "1" { return }
        #endif
        let deadline = Date().addingTimeInterval(maxWait)
        Task { @MainActor in
            while isBusy() && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            action()
        }
    }

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
    func markLikeComplete(_ postId: String) { Self.afterDebugLatency { self.inFlightLikes[postId] = nil } }

    // DEBUG-only slow-network stand-in (build 123): TOSKA_SIM_LATENCY_MS in the launch
    // environment keeps every in-flight flag set that much longer after the real write
    // completes — the same window a 3G/Edge connection opens — so the UI tests can prove
    // that a tap landing inside it is queued, not dropped. Compiled out of Release.
    static func afterDebugLatency(_ clear: @escaping @MainActor () -> Void) {
        #if DEBUG
        if let ms = ProcessInfo.processInfo.environment["TOSKA_SIM_LATENCY_MS"].flatMap(Double.init), ms > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
                clear()
            }
            return
        }
        #endif
        clear()
    }

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
    func markRepostComplete(_ id: String) { Self.afterDebugLatency { self.inFlightReposts[id] = nil } }

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
    func markSaveComplete(_ id: String) { Self.afterDebugLatency { self.inFlightSaves[id] = nil } }

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
