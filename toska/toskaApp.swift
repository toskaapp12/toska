import SwiftUI
import FirebaseCore
import FirebaseMessaging
import FirebaseAuth
import FirebaseAppCheck
import GoogleSignIn

class AppDelegate: NSObject, UIApplicationDelegate {

    var authStateListener: AuthStateDidChangeListenerHandle?

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
            }
        }
}
