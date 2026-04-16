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
    static let openPostFromPush    = NSNotification.Name("OpenPostFromPush")
}
