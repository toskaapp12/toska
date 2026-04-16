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
        static let postInteractionChanged  = NSNotification.Name("PostInteractionChanged")
        static let saveFeedScrollPosition  = NSNotification.Name("SaveFeedScrollPosition")
        static let restoreFeedScroll       = NSNotification.Name("RestoreFeedScroll")
        // Posted when the empty-feed coaching state's "say something" button
        // is tapped. MainTabView listens for this and opens the compose
        // sheet, since FeedView doesn't own the showCompose state.
        static let openComposeFromEmptyFeed = NSNotification.Name("OpenComposeFromEmptyFeed")
    }
