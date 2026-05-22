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
struct SavedPost: Identifiable {
    let id: String          // doc ID
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
}

struct NotificationItem: Identifiable, Equatable {
    let id: String
    let icon: String
    let displayText: String
    let type: String
    let time: String
    let isUnread: Bool
    let createdAt: Date
    let postId: String
    let fromUserId: String
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
struct SavedReply: Identifiable {
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
struct LikedReply: Identifiable {
    let id: String
    let postId: String
    let replyText: String
    let replyHandle: String
    let likedAt: Date
}
/// Used in FeelingCircleView for temporary group chat messages
struct CircleMessage: Identifiable {
    let id: String
    let handle: String
    let text: String
    let time: String
    let isMe: Bool
}

