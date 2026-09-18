import Foundation

// MARK: - Offline Action Queue
//
// Queues LIKE and SAVE toggles made while offline and replays them when
// connectivity returns. Deliberately narrow: a 2026-07 audit rejected
// Firestore's silent offline queue because queued POSTS produced duplicates
// and ghost states — so posting/reposting stays online-only with visible
// feedback. Likes and saves are safe to queue because entries COALESCE to a
// single desired end-state per (kind, post): tapping like → unlike → like
// offline stores one "liked = true", and the flush replays exactly that.
//
// Storage is UserDefaults (tiny payload, survives relaunch); the flush runs
// whenever NetworkMonitor sees a reconnect and once on first launch-with-
// network, then replays through PostInteractionManager so every server
// guard (auth, self-like, rate limits, transaction dedup) still applies.
@MainActor
enum OfflineActionQueue {
    enum Kind: String, Codable { case like, save }

    struct Entry: Codable {
        let kind: Kind
        let postId: String
        let authorId: String
        var desired: Bool          // the end-state the user wants
        var queuedAt: Date
    }

    private static let storeKey = "toska_offline_action_queue_v1"

    private(set) static var entries: [Entry] = load() {
        didSet { persist() }
    }

    /// Record the user's desired end-state for a post while offline —
    /// coalesces with any prior queued toggle for the same (kind, post).
    static func setDesired(_ kind: Kind, postId: String, authorId: String, desired: Bool) {
        if let idx = entries.firstIndex(where: { $0.kind == kind && $0.postId == postId }) {
            entries[idx].desired = desired
            entries[idx].queuedAt = Date()
        } else {
            entries.append(Entry(kind: kind, postId: postId, authorId: authorId,
                                 desired: desired, queuedAt: Date()))
        }
    }

    /// The queued end-state for a post, if any — lets rows render the
    /// offline-optimistic state consistently after scrolling away and back.
    static func desired(_ kind: Kind, postId: String) -> Bool? {
        entries.first(where: { $0.kind == kind && $0.postId == postId })?.desired
    }

    /// Replay every queued entry through the normal interaction paths.
    /// Runs only when connected; each replay removes its entry up-front so a
    /// failure can't loop forever (the server transaction dedup makes a
    /// re-tap by the user safe).
    static func flush() {
        guard NetworkMonitor.shared.isConnected, !entries.isEmpty else { return }
        let batch = entries
        entries = []
        for e in batch {
            switch e.kind {
            case .like:
                // currentlyLiked = !desired makes the toggle land ON desired.
                PostInteractionManager.toggleLike(
                    postId: e.postId, authorId: e.authorId,
                    currentlyLiked: !e.desired, currentCount: 0
                ) { _ in }
            case .save:
                PostInteractionManager.toggleSave(
                    postId: e.postId, authorId: e.authorId,
                    currentlySaved: !e.desired
                ) { _ in }
            }
        }
    }

    // MARK: - Persistence

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return decoded
    }

    private static func persist() {
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: storeKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
