import SwiftUI
import FirebaseCore
import FirebaseAnalytics
import FirebaseMessaging
import FirebaseAuth
import FirebaseAppCheck
import FirebasePerformance
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

    // T-7 (2026-06-11): window-level privacy cover for the app-switcher snapshot.
    // The SwiftUI overlay in ContentView only covers ContentView's own layer —
    // .sheet / .fullScreenCover presentations (the composer with in-progress
    // grief text, an open thread, the share card) render ABOVE it and were
    // captured in the iOS multitasking snapshot. A cover added directly to the
    // key window sits above every presentation, so nothing sensitive leaks into
    // the switcher. Added on willResignActive (before the snapshot is taken),
    // removed on didBecomeActive.
    private var privacyCover: UIView?

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

    func applicationWillResignActive(_ application: UIApplication) {
        guard privacyCover == nil else { return }
        let keyWindow = application.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard let window = keyWindow else { return }
        let cover = UIView(frame: window.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // toskaBlue (#9198a8) — matches the ContentView SwiftUI cover.
        cover.backgroundColor = UIColor(red: 0x91 / 255.0, green: 0x98 / 255.0, blue: 0xa8 / 255.0, alpha: 1.0)
        let label = UILabel()
        label.text = "t"
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 42)
        label.sizeToFit()
        label.center = CGPoint(x: cover.bounds.midX, y: cover.bounds.midY)
        label.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin, .flexibleLeftMargin, .flexibleRightMargin]
        cover.addSubview(label)
        window.addSubview(cover)
        privacyCover = cover
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        privacyCover?.removeFromSuperview()
        privacyCover = nil
    }

    func application(_ application: UIApplication,
                         didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
            print("🔥 AppDelegate — didFinishLaunching")
            // SIMULATOR APP CHECK GOTCHA — see RUNBOOK.md → Local development
            // → "Simulator App Check — first-run gotcha". On a fresh simulator
            // install, the debug token printed below must be registered in
            // Firebase Console (toskastaging) before any Firebase call
            // requiring App Check will succeed; otherwise expect cascading
            // 403s on confirmAdult / handle queries / count reconcile.
            #if DEBUG
            let providerFactory = AppCheckDebugProviderFactory()
            #else
            let providerFactory = AppAttestProviderFactory()
            #endif
            AppCheck.setAppCheckProviderFactory(providerFactory)

            // Environment switch: Debug builds talk to the `toskastaging`
            // Firebase project; Release builds talk to `toska-4ebf4` (prod).
            // Both plists are bundled with the app — Release ignores the
            // staging plist by reading `GoogleService-Info.plist` via the
            // default FirebaseApp.configure() path. Without this branch,
            // every simulator run + every TestFlight build hits production,
            // which is how prior incidents leaked test data into the live
            // feed. See RUNBOOK.md → Environments for the full workflow.
            #if DEBUG
            if let stagingPath = Bundle.main.path(forResource: "GoogleService-Info-Staging", ofType: "plist"),
               let stagingOptions = FirebaseOptions(contentsOfFile: stagingPath) {
                FirebaseApp.configure(options: stagingOptions)
                print("🔥 Firebase configured against STAGING (toskastaging)")
            } else {
                // Fail closed: a missing staging plist must NOT silently
                // configure Debug against prod — that's how prior incidents
                // leaked test data into the live feed. Crash the dev build so
                // the misconfiguration is caught immediately instead of
                // cross-talking to production.
                fatalError("GoogleService-Info-Staging.plist not found — Debug builds must not fall back to prod. Add the staging plist to the bundle.")
            }
            #else
            FirebaseApp.configure()
            #endif

            // FirebasePerformance auto-starts at dyld load time via
            // +[FPRClient load], which is why this target needs -ObjC in
            // OTHER_LDFLAGS — without it the +load is dead-stripped and
            // Performance silently never starts. This explicit reference
            // isn't what initializes the SDK (that already happened); it's
            // a link-time assertion that FirebasePerformance is present and
            // a grep target. See RUNBOOK → Monitoring.
            _ = Performance.sharedInstance()

            // Analytics + Crashlytics are wired through the Telemetry namespace
            // in ToskaTheme.swift. FirebaseApp.configure() above also boots
            // Analytics; Crashlytics auto-collects on next launch after a crash.

            // The Settings → Privacy toggle must govern Firebase Analytics'
            // AUTOMATIC collection (sessions, screen views), not just our
            // custom Telemetry events — otherwise opting out is cosmetic.
            // SettingsView re-invokes this when the toggle flips.
            Analytics.setAnalyticsCollectionEnabled(Telemetry.isOptedIn)

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

        // Distinguish the listener's INITIAL callback from a real signed-in →
        // signed-out transition. Firing the full scrub on every signed-out
        // cold launch ran sign-out side effects with nothing to sign out of —
        // including an FCM token delete/rotation per launch. The persisted
        // wasSignedInAtLastRun flag keeps the one initial-callback case that
        // DOES need the scrub: the session was invalidated while the app
        // wasn't running, and the previous account's local state (drafts,
        // admin gate, push primer, FCM token) is still on disk.
        var isInitialAuthCallback = true
        authStateListener = Auth.auth().addStateDidChangeListener { _, user in
            let isSignedIn = user != nil
            Task { @MainActor in
                let wasInitial = isInitialAuthCallback
                isInitialAuthCallback = false
                if isSignedIn {
                    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.wasSignedInAtLastRun)
                    BlockedUsersCache.shared.startListening()
                    UserHandleCache.shared.startListening()
                } else {
                    BlockedUsersCache.shared.stopListening()
                    UserHandleCache.shared.stopListening()
                    let endedSignedInLastRun = UserDefaults.standard.bool(forKey: UserDefaultsKeys.wasSignedInAtLastRun)
                    UserDefaults.standard.set(false, forKey: UserDefaultsKeys.wasSignedInAtLastRun)
                    guard !wasInitial || endedSignedInLastRun else { return }
                    // Out-of-band sign-outs (token revoked server-side, account
                    // deleted elsewhere, credential invalidated) don't go through
                    // the in-app buttons, so the per-user local scrub (drafts,
                    // admin gate, onboarding flags, FCM token) never ran. Post the
                    // expiry event so ContentView's scrub fires for EVERY sign-out.
                    // Idempotent with the button paths' .userDidSignOut (both just
                    // clear already-clear state).
                    NotificationCenter.default.post(name: .authSessionExpired, object: nil)
                    // Also post .userDidSignOut: the view-level teardowns
                    // (NotificationsView / MainTabView / ProfileView /
                    // PostDetailView listeners + delayed mark-read tasks) observe
                    // ONLY .userDidSignOut, not .authSessionExpired. Without this,
                    // an out-of-band sign-out leaves those listeners/tasks running
                    // against the previous uid. Idempotent (button paths already
                    // post it; teardowns just remove already-removable state).
                    NotificationCenter.default.post(name: .userDidSignOut, object: nil)
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
        // iOS gates universal-link delivery to domains in the entitlement's
        // associated-domains list, so in practice only those hosts reach
        // this handler. The explicit host and scheme checks below are
        // defense-in-depth: if the entitlement is ever loosened (e.g.
        // another applinks domain added for a marketing site), an
        // attacker-controlled host can't steer this routing logic just
        // because they got a URL into NSUserActivity.
        // We also reject http:// — only https:// universal links should
        // hit this code path.
        //
        // app.toskaapp.com is where share links point (Firebase Hosting
        // serves the /p/{id} pages + its own AASA); www/apex stay for
        // links minted before the app domain existed.
        let universalLinkHosts: Set<String> =
            ["www.toskaapp.com", "toskaapp.com", "app.toskaapp.com"]
        guard url.scheme == "https",
              let host = url.host, universalLinkHosts.contains(host) else { return }
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
