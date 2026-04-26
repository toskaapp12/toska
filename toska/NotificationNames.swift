import Foundation

extension NSNotification.Name {
    static let userDidSignIn       = NSNotification.Name("UserDidSignIn")
    static let userDidSignOut      = NSNotification.Name("UserDidSignOut")
    static let showOnboarding      = NSNotification.Name("ShowOnboarding")
    static let authSessionExpired  = NSNotification.Name("AuthSessionExpired")
    static let authDidVerify       = NSNotification.Name("AuthDidVerify")
    static let newPostCreated      = NSNotification.Name("NewPostCreated")
    static let scrollFeedToTop     = NSNotification.Name("ScrollFeedToTop")
    static let dismissAllSheets    = NSNotification.Name("DismissAllSheets")
    static let openPostFromPush        = NSNotification.Name("OpenPostFromPush")
        // Push tap on a DM notification routes through here. Emitted by
        // PushNotificationManager and handled by MainTabView to open the
        // ConversationView sheet. Raw name preserved across the migration so
        // existing production installs with in-flight notifications still route.
        static let openConversationFromPush = NSNotification.Name("OpenConversationFromPush")
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
    }
