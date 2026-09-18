import Foundation
import FirebaseAuth

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
        // Who queued it (2026-09-18 tech review): the flush replays through
        // the CURRENT session's uid, so without this an entry queued by
        // account A would execute under account B after a sign-out/sign-in.
        // Optional so v1 entries (pre-field) decode — they're dropped on
        // load rather than replayed against an unknowable account.
        var uid: String?
    }

    private static let storeKey = "toska_offline_action_queue_v1"

    private(set) static var entries: [Entry] = load() {
        didSet { persist() }
    }

    /// Record the user's desired end-state for a post while offline —
    /// coalesces with any prior queued toggle for the same (kind, post).
    static func setDesired(_ kind: Kind, postId: String, authorId: String, desired: Bool) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        if let idx = entries.firstIndex(where: {
            $0.kind == kind && $0.postId == postId && $0.uid == uid
        }) {
            entries[idx].desired = desired
            entries[idx].queuedAt = Date()
        } else {
            entries.append(Entry(kind: kind, postId: postId, authorId: authorId,
                                 desired: desired, queuedAt: Date(), uid: uid))
        }
    }

    /// The queued end-state for a post, if any — lets rows render the
    /// offline-optimistic state consistently after scrolling away and back.
    static func desired(_ kind: Kind, postId: String) -> Bool? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return entries.first(where: {
            $0.kind == kind && $0.postId == postId && $0.uid == uid
        })?.desired
    }

    /// Replay the CURRENT account's queued entries through the normal
    /// interaction paths. Runs only when connected; each replay removes its
    /// entry up-front so a failure can't loop forever (the server transaction
    /// dedup makes a re-tap by the user safe). Another account's entries stay
    /// queued for whenever that account signs back in; entries with no uid
    /// (v1 format) are discarded at load.
    static func flush() {
        guard NetworkMonitor.shared.isConnected, !entries.isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return }
        let batch = entries.filter { $0.uid == uid }
        guard !batch.isEmpty else { return }
        entries.removeAll { $0.uid == uid }
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
        // Drop pre-uid (v1) entries — replaying them against whichever
        // account happens to be signed in now would be wrong.
        return decoded.filter { $0.uid != nil }
    }

    private static func persist() {
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: storeKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
