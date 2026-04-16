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
