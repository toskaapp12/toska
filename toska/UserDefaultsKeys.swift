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

    // Compose draft persistence — survives force-quit mid-typing.
    // One draft at a time (the active compose sheet); cleared on successful post.
    static let composeDraftText = "toska_composeDraftText"
    static let composeDraftTag  = "toska_composeDraftTag"

    // Push permission primer — shown once per install so the system prompt
    // doesn't fire cold. Cleared on sign-out so a different user signing in
    // on the same device gets their own primer.
    static let pushPrimerShown = "toska_pushPrimerShown"

    // Analytics opt-out. Default true; flipped off via Settings → Privacy.
    // Read by the Telemetry namespace (non-View context) and written by
    // SettingsView via @AppStorage — same key string must match on both sides.
    static let shareAnonymousUsage = "toska_shareAnonymousUsage"

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

    // Adult-confirmation propagation flag. CreateAccountView's age gate
    // runs confirmAdultServerSide(uid:) to set `confirmedAdult: true` on
    // the user doc, but that call is `try?`-swallowed because a network
    // blip or App Check failure (common on simulator) shouldn't block
    // signup. When the server write doesn't land before OnboardingView
    // reads the user doc, OnboardingView's checkAcceptanceStatus saw
    // confirmedAdult=false and re-prompted the gate — making the user
    // confirm twice in the same signup session. This flag bridges the
    // gap: CreateAccountView sets it the moment the user passes the
    // local age gate, OnboardingView treats a set flag as "already
    // confirmed in this session," and consumes (clears) the flag so a
    // failed server confirmAdult still triggers a re-prompt on a
    // subsequent launch — preserving the long-tail server-side gate.
    // Keyed per-uid so a force-quit mid-flow doesn't leak the flag to
    // a different account that signs in on the same device.
    static func recentlyConfirmedAdult(uid: String) -> String {
        "toska_recentlyConfirmedAdult_\(uid)"
    }
}
