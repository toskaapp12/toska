import Foundation

// MARK: - Post Data Models

/// Used in FeedView (for you, following, recent tabs) and sample posts
struct FeedPost: Identifiable, Equatable {
    let id: String          // doc ID
    let handle: String
    let text: String
    let tag: String?
    let likes: Int
    let reposts: Int
    let replies: Int
    let time: String
    let authorId: String
    let isShareable: Bool
    // Original author's handle when this post is a repost (isRepost: true
    // on the Firestore doc). Populated from data["originalHandle"] in
    // FeedView.feedPost(from:). FeedPostRow uses it to render a
    // "@reposter reposted" provenance line above the post body so the
    // reader can tell at a glance that the visible handle is the
    // reposter, not the original author. nil for non-repost posts.
    var originalHandle: String? = nil
    // Original author's uid when this post is a repost. Carried so the feed's
    // .userBlocked live-strip can also drop reposts OF a just-blocked author —
    // their words otherwise persist via other people's reposts until the next
    // refresh, right after the block confirmation. nil for non-reposts.
    var originalAuthorId: String? = nil
    // Set (yyyy-MM-dd) when this post was written as a response to that day's
    // daily prompt. The feed renders such posts with the prompt shown in plum
    // above the person's reply, so prompt answers read as "prompt → reply".
    var promptDate: String? = nil
}

/// Used in ProfileView for selectedPostData, NotificationsView, TopView
/// (the "open post" shape passed to PostDetailView)
struct PostDetailData {
    let handle: String
    let text: String
    let tag: String?
    let likes: Int
    let reposts: Int
    let replies: Int
    let time: String
    let authorId: String
    var isShareable: Bool = true
}

/// Used in ProfileView for saved/liked posts (has Date for sorting, handle for display)
struct SavedPost: Identifiable, Equatable {
    let id: String          // doc ID
    let authorId: String
    let handle: String
    let text: String
    let tag: String?
    let likes: Int
    let reposts: Int
    let replies: Int
    let time: String
    let createdAt: Date
}

/// Used in ProfileView for myPosts (has handle in last position)
struct MyPost: Identifiable {
    let id: String          // doc ID
    let text: String
    let tag: String?
    let likes: Int
    let reposts: Int
    let replies: Int
    let time: String
    let handle: String
    let isRepost: Bool
    let originalHandle: String?
    // 2026-05-31: true when moderationStatus == "pending_review" on the
    // Firestore doc. ProfileView renders an "under review" banner above
    // these so the author knows the post is hidden from other users
    // pending admin approval — otherwise they'd think it published
    // normally and might repost / give up. Defaults false so legacy doc
    // shapes (pre-backfill) and live posts render normally.
    var pendingReview: Bool = false
    // Reason chip text — derived from pendingReason on the doc. Shown
    // inside the banner so the author understands which detection rule
    // tripped (e.g. "names or contact info detected"). Nil for non-pending.
    var pendingReasonLabel: String? = nil
    // N-14 (2026-06-10 re-review): true when the post was held for crisis/
    // concerning content (pendingReason == "crisis"). The held-post banner uses
    // it to surface crisis support resources to the author — "resources on
    // detection" — so a held safety post never leaves them without help, even
    // if they'd turned off the compose-time gentle check-in. Server hold
    // behavior is unchanged (every concerning post still reviewed).
    var pendingReasonIsCrisis: Bool = false
}

/// Used in OtherProfileView posts (no handle, no authorId — those are known)
struct OtherProfilePost: Identifiable {
    let id: String          // doc ID
    let text: String
    let tag: String?
    let likes: Int
    let reposts: Int
    let replies: Int
    let time: String
}

/// Used in TopView for ranked posts
struct RankedPost: Identifiable {
    let id: String          // doc ID
    let handle: String
    let text: String
    let tag: String?
    let likes: Int
    let authorId: String
    var replies: Int = 0
    var reposts: Int = 0
    var time: String = ""
}

struct NotificationItem: Identifiable, Equatable {
    let id: String
    let icon: String
    let displayText: String
    let type: String
    let time: String
    var isUnread: Bool   // var: a folded like-group is unread if ANY member is
    let createdAt: Date
    let postId: String
    let fromUserId: String
    // Rich-row fields (2026 notifications redesign): the bold actor + the action
    // phrase are shown separately; quote is the referenced post text (filled in
    // after a batch fetch); replyText is the reply body shown in its own bubble;
    // othersCount drives "X and N others felt this" grouping for likes.
    var fromHandle: String = ""
    var actionText: String = ""
    var othersCount: Int = 0
    var quote: String? = nil
    var replyText: String? = nil
}

/// Used in ProfileView and OtherProfileView for reply tabs
struct MyReply: Identifiable {
    let id: String
    let replyText: String
    let replyTime: String
    let parentText: String
    let parentHandle: String
    let parentPostId: String
    let createdAt: Date
}

/// Used in ProfileView's saved tab for saved replies. Bookmark target is
/// the reply itself; tap navigates to the parent post (where the reply
/// renders inline). Text + handle snapshotted at save time — see
/// PostInteractionManager.toggleReplySave for the stale-on-edit trade-off.
struct SavedReply: Identifiable, Equatable {
    let id: String          // reply doc id
    let postId: String      // parent post id (for navigation on tap)
    let replyText: String
    let replyHandle: String
    let savedAt: Date
}

/// Mirror of SavedReply for the "liked" tab in ProfileView. Same shape
/// because both reverse indices (users/{uid}/likedReplies +
/// users/{uid}/savedReplies) snapshot the same fields at write time. Kept
/// as a separate type for semantic clarity at call sites — same row UI
/// (ReplyEngagementRow) renders both.
struct LikedReply: Identifiable, Equatable {
    let id: String
    let postId: String
    let replyText: String
    let replyHandle: String
    let likedAt: Date
}

