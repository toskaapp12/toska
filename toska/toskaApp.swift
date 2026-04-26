import SwiftUI
import FirebaseCore
import FirebaseMessaging
import FirebaseAuth
import FirebaseAppCheck
import GoogleSignIn

// AppCheck provider factory for release builds. FirebaseAppCheck ships
// AppCheckDebugProviderFactory (used in the #if DEBUG branch below) but no
// built-in App Attest factory — each app provides its own so it can decide
// what to do on older OS / incompatible devices. We use App Attest directly
// since the app's deployment target (iOS 18.6) is well above App Attest's
// iOS 14 minimum. AppAttestProvider(app:) returns nil on simulators (where
// App Attest isn't supported); that's fine because release builds only run
// on real devices.
class AppAttestProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        return AppAttestProvider(app: app)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {

    var authStateListener: AuthStateDidChangeListenerHandle?

    // AppDelegate normally lives for the app's lifetime, so a manual deinit
    // isn't strictly required — the OS reclaims everything on terminate. But
    // if a future refactor ever swaps the delegate (test rig, scene
    // restructure), an unremoved auth-state listener would keep firing into
    // a deallocated handler. Defensive cleanup costs nothing.
    deinit {
        if let handle = authStateListener {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    func application(_ application: UIApplication,
                         didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
            print("🔥 AppDelegate — didFinishLaunching")
            #if DEBUG
            let providerFactory = AppCheckDebugProviderFactory()
            #else
            let providerFactory = AppAttestProviderFactory()
            #endif
            AppCheck.setAppCheckProviderFactory(providerFactory)
            FirebaseApp.configure()

            // Analytics + Crashlytics are wired through the Telemetry namespace
            // in ToskaTheme.swift. FirebaseApp.configure() above also boots
            // Analytics; Crashlytics auto-collects on next launch after a crash.

        // Bump URLCache so AsyncImage / GIF reloads don't constantly refetch.
        // The URLSession default is ~4 MB memory + ~20 MB disk, which a feed
        // full of Giphy GIFs evicts within a few minutes of scrolling. 50 MB
        // memory + 200 MB disk holds enough that returning to a screen
        // doesn't redownload the same media. Numbers are conservative —
        // iOS aggressively reclaims under memory pressure.
        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            diskPath: nil
        )

        UNUserNotificationCenter.current().delegate = PushNotificationManager.shared
        Messaging.messaging().delegate = PushNotificationManager.shared

        // Prewarm the Taptic Engine so the first user-facing haptic of the
        // session (a tab switch, a like, a send) is instant instead of
        // having ~50–100 ms cold-start latency.
        HapticManager.prepareAll()

        authStateListener = Auth.auth().addStateDidChangeListener { _, user in
            Task { @MainActor in
                if let user = user {
                    BlockedUsersCache.shared.startListening()
                    UserHandleCache.shared.startListening()
                } else {
                    BlockedUsersCache.shared.stopListening()
                    UserHandleCache.shared.stopListening()
                }
            }
        }

        return true
    }

    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Without this handler, push registration failures vanish silently.
        // Most causes are environmental (no Apple Developer entitlement on
        // the build, simulator without push capability, network issues at
        // app start) — we want to see them in Crashlytics so a regression
        // in entitlements or APNS config surfaces fast.
        print("⚠️ APNS registration failed: \(error)")
        Telemetry.recordError(error, context: "AppDelegate.didFailToRegisterForRemoteNotifications")
    }
}

@main
struct toskaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
            WindowGroup {
                ContentView()
                    .environment(LateNightThemeManager.shared)
                    // Cap Dynamic Type at .accessibility3 globally. Most of the
                    // app uses brand-tuned fixed sizes (Georgia italic at
                    // specific sizes is the visual identity), so we don't honor
                    // the full xxxLarge → accessibility5 range — those settings
                    // would break the layout. Capping here at a3 still gives
                    // a meaningful boost for users on larger Dynamic Type
                    // settings without distorting the design language.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                    // Universal links: a tap on an https://www.toskaapp.com/p/{id}
                    // link from anywhere in iOS arrives here. We translate it
                    // into the same .openPostFromPush notification that push
                    // notifications use, so MainTabView's existing handler
                    // does the actual deep-link routing — no parallel code path.
                    //
                    // Uses www.toskaapp.com rather than the apex because the
                    // apex has no A records in the current DNS zone; the
                    // GitHub Pages site (which serves the AASA file) is
                    // reachable via the www CNAME.
                    .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                        handleUniversalLink(activity)
                    }
            }
        }

    private func handleUniversalLink(_ activity: NSUserActivity) {
        guard let url = activity.webpageURL else { return }
        // Path shapes we route:
        //   /p/{postId}          → open post
        // Everything else falls through to opening the app at the feed,
        // which is the safer default than crashing or 404-ing in-app.
        //
        // The postId is validated against the Firestore doc ID character
        // set before routing. Without this, a crafted URL like
        // https://www.toskaapp.com/p/..%2F..%2Fadmin can push unexpected
        // values into the deep-link handler.
        let parts = url.path.split(separator: "/")
        if parts.count >= 2, parts[0] == "p" {
            let postId = String(parts[1])
            guard isValidFirestoreDocId(postId) else { return }
            NotificationCenter.default.post(
                name: .openPostFromPush,
                object: nil,
                userInfo: ["postId": postId]
            )
        }
    }
}
