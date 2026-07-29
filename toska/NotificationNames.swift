import Foundation

extension NSNotification.Name {
    static let userDidSignIn       = NSNotification.Name("UserDidSignIn")
    static let userDidSignOut      = NSNotification.Name("UserDidSignOut")
    static let showOnboarding      = NSNotification.Name("ShowOnboarding")
    static let authSessionExpired  = NSNotification.Name("AuthSessionExpired")
    static let authDidVerify       = NSNotification.Name("AuthDidVerify")
    static let newPostCreated      = NSNotification.Name("NewPostCreated")
    // Posted by PostDetailView.deletePost on successful deletion. userInfo
    // carries ["postId": String] so cached references (e.g. FeedViewModel's
    // todaysPromptResponse) can invalidate themselves instead of waiting
    // until the next pull-to-refresh.
    static let postDeleted         = NSNotification.Name("PostDeleted")
    // Cross-screen sync family (2026-07-29 owner report: "changes must show
    // up with no refresh needed"). Thread views self-heal via their reply
    // snapshot listeners; these exist for the ONE-SHOT-fetch screens
    // (profile tabs, feed, top board) that would otherwise go stale.
    // Posted on successful reply deletion. userInfo: ["replyId": String]
    static let replyDeleted        = NSNotification.Name("ReplyDeleted")
    // Posted on successful post text edit. userInfo: ["postId": String]
    static let postEdited          = NSNotification.Name("PostEdited")
    // Posted on successful reply text edit. userInfo: ["replyId": String]
    static let replyEdited         = NSNotification.Name("ReplyEdited")
    static let scrollFeedToTop     = NSNotification.Name("ScrollFeedToTop")
    static let dismissAllSheets    = NSNotification.Name("DismissAllSheets")
    static let openPostFromPush        = NSNotification.Name("OpenPostFromPush")
        // Push tap on a follow notification routes through here — opens
        // OtherProfileView. Same migration concern as above.
        static let openProfileFromPush      = NSNotification.Name("OpenProfileFromPush")
        static let postInteractionChanged  = NSNotification.Name("PostInteractionChanged")
        static let saveFeedScrollPosition  = NSNotification.Name("SaveFeedScrollPosition")
        // Posted when the empty-feed coaching state's "say something" button
        // is tapped. MainTabView listens for this and opens the compose
        // sheet, since FeedView doesn't own the showCompose state.
        static let openComposeFromEmptyFeed = NSNotification.Name("OpenComposeFromEmptyFeed")
        // Posted by BlockedUsersCache.block(_:) with userInfo["userId"] set
        // to the newly-blocked uid. FeedViewModel observes this and strips
        // the user's posts from the in-memory feed arrays so blocked content
        // vanishes immediately — without this, the feed kept rendering the
        // blocked author's posts until the next refresh.
        static let userBlocked = NSNotification.Name("UserBlocked")
        // Posted by MainTabView when the user taps the bell tab while
        // already on the notifications tab. NotificationsView listens and
        // pops any pushed destinations (selectedPost, selectedFollowUser,
        // selectedConversation) back to the root inbox list. Same pattern
        // every major iOS social app uses (Twitter, Instagram, etc.):
        // tapping the active tab returns you to its root.
        static let popNotificationsTabToRoot = NSNotification.Name("PopNotificationsTabToRoot")
        // Tap-active-tab-to-scroll-to-top notifications. Universal iOS
        // pattern (Twitter, Reddit, every social app). MainTabView posts
        // the matching name when the user taps a tab icon that's already
        // selected; each tab's view listens and snaps its ScrollView to
        // the top via a ScrollViewReader anchor.
        static let scrollTopTabToTop  = NSNotification.Name("ScrollTopTabToTop")
        static let scrollProfileToTop = NSNotification.Name("ScrollProfileToTop")
        // Posted by OtherProfileView.toggleFollow after a follow/unfollow
        // commits. FeedView observes it and re-fetches the Following feed so a
        // newly-followed user's posts appear immediately instead of only after
        // the next pull-to-refresh (an unfollow likewise drops them).
        static let userFollowingChanged = NSNotification.Name("UserFollowingChanged")
        // Posted by MainTabView when the user SWITCHES to the Top tab (not a
        // re-tap). MainTabView keeps every tab alive via the .opacity trick,
        // so TopView's onAppear fires only once per session — this is the
        // "tab became visible again" signal TopView uses to refresh a stale
        // "most felt" board (see TopView.ensureFetched's staleness window).
        static let topTabSelected     = NSNotification.Name("TopTabSelected")
        // (scrollFeedToTop already exists above — added to the same family
        // of behaviors when the feed's scroll-up affordance was wired.)
    }
