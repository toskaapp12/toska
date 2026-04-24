import Foundation

// MARK: - UserDefaults key constants
//
// All UserDefaults keys in one place. A typo in a key string is a silent bug —
// the write succeeds, the read returns nil, and nothing tells you why.
// Using these constants makes typos a compile error instead.

enum UserDefaultsKeys {
    // Reconciliation — keyed per user so multiple accounts on one device
    // don't share a single reconcile timestamp.
    static func lastReconcileDate(uid: String) -> String {
        "lastReconcileDate_\(uid)"
    }

    // Feed scroll position preservation
    static let savedScrollPostId = "savedScrollPostId"

    // App review prompt — tracks whether the user has been asked
    static let hasBeenAskedForReview = "hasBeenAskedForReview"

    // Offline drafts — keyed per surface so a kill mid-typing doesn't lose
    // the user's words. Compose drafts already use @AppStorage on a single
    // key (one draft); messages and replies are keyed per conversation /
    // per post so drafts in different threads don't clobber each other.
    static func messageDraft(conversationId: String) -> String {
        "toska_msgDraft_\(conversationId)"
    }
    static func replyDraft(postId: String) -> String {
        "toska_replyDraft_\(postId)"
    }
}
