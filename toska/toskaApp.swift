import SwiftUI
import FirebaseCore
import FirebaseMessaging
import FirebaseAuth
import GoogleSignIn

class AppDelegate: NSObject, UIApplicationDelegate {

    var authStateListener: AuthStateDidChangeListenerHandle?

    func application(_ application: UIApplication,
                         didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
            print("🔥 AppDelegate — didFinishLaunching")
            FirebaseApp.configure()

            // === Analytics + Crash Reporting setup ===
            //
            // The Telemetry namespace in ToskaTheme.swift fires no-op events
            // until the Firebase Analytics + Crashlytics SDKs are added to
            // the Xcode project. To enable real reporting:
            //
            //  1. In Xcode: File → Add Package Dependencies →
            //     https://github.com/firebase/firebase-ios-sdk
            //     Pick FirebaseAnalytics and FirebaseCrashlytics from the
            //     product list, attach both to the toska target.
            //
            //  2. Run Build Phases → New Run Script Phase on the toska
            //     target with:
            //         "${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"
            //     and set Input Files to:
            //         ${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${TARGET_NAME}
            //         $(SRCROOT)/$(BUILT_PRODUCTS_DIR)/$(INFOPLIST_PATH)
            //
            //  3. In ToskaTheme.swift Telemetry.event(...) and recordError(...)
            //     uncomment the Analytics.logEvent / Crashlytics.crashlytics()
            //     lines (search for "TODO" in Telemetry).
            //
            //  4. Add `import FirebaseAnalytics` and `import FirebaseCrashlytics`
            //     to the top of ToskaTheme.swift.
            //
            // No code change is needed at the call sites — every
            // Telemetry.* call across the app starts reporting automatically.

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
