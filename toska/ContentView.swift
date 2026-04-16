import SwiftUI
import Combine
import UserNotifications
import FirebaseAuth
@preconcurrency import FirebaseFirestore

@MainActor
struct ContentView: View {
    @State private var isLoggedIn = false
    @State private var showOnboarding = false
    @State private var onboardingComplete = false
    @State private var isLoading = true
    @State private var showVerifyError = false
    @State private var verifyTask: Task<Void, Never>? = nil
    // Set when the user's stored acceptedPolicyVersion is behind
    // currentPolicyVersion. Shown as a blocking fullScreenCover — the user
    // must accept the new version before they can continue using the app.
    @State private var showPolicyUpdate = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if isLoading || showVerifyError {
                ZStack {
                    Color.toskaBlue.ignoresSafeArea()
                    if showVerifyError {
                        VStack(spacing: 16) {
                            Text("t")
                                .font(.custom("Georgia-Italic", size: 42))
                                .foregroundColor(.white)
                            Text(Auth.auth().currentUser != nil
                                 ? "setting up your account"
                                 : "couldn't connect")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                            Text(Auth.auth().currentUser != nil
                                 ? "this sometimes takes a moment after creating or restoring an account — tap retry"
                                 : "check your connection and try again")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.4))
                            Button {
                                showVerifyError = false
                                isLoading = true
                                if let uid = Auth.auth().currentUser?.uid {
                                    verifyUserDocument(uid: uid)
                                }
                            } label: {
                                Text("retry")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Color.toskaBlue)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 10)
                                    .background(Color.white)
                                    .cornerRadius(20)
                            }
                            .padding(.top, 4)
                        }
                    } else {
                        VStack(spacing: 20) {
                            Text("t")
                                .font(.custom("Georgia-Italic", size: 42))
                                .foregroundColor(.white)
                            ProgressView()
                                .tint(.white.opacity(0.4))
                        }
                    }
                }
            } else if showOnboarding && !onboardingComplete {
                OnboardingView(isComplete: $onboardingComplete)
                    .onChange(of: onboardingComplete) { _, _ in
                        showOnboarding = false
                    }
            } else if isLoggedIn {
                // Push permission is requested in context (NotificationsView's
                // primer card on first visit) rather than the moment the user
                // lands on the home tab. Asking immediately at MainTabView
                // appear used to fire the system prompt with no explanation,
                // which generally produces a permanent "Don't Allow" tap.
                MainTabView()
            } else {
                SplashView()
            }
        }
        .fullScreenCover(isPresented: $showPolicyUpdate) {
            // Version-bump retro-prompt. A user declining here is signed out
            // rather than deleted — their account and content persist so they
            // can return and accept later if they change their mind.
            PolicyAcceptanceView(
                onAccept: {
                    if let uid = Auth.auth().currentUser?.uid {
                        recordPolicyAcceptance(for: uid, confirmedAdult: false)
                    }
                    showPolicyUpdate = false
                },
                onDecline: {
                    Telemetry.policyDeclined(version: currentPolicyVersion, atSignup: false)
                    showPolicyUpdate = false
                    PushNotificationManager.shared.clearFCMToken()
                    try? Auth.auth().signOut()
                    NotificationCenter.default.post(name: .userDidSignOut, object: nil)
                }
            )
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("UI_TESTING") {
                if Auth.auth().currentUser?.uid != nil {
                    isLoggedIn = true
                }
                isLoading = false
                return
            }
            if let uid = Auth.auth().currentUser?.uid {
                verifyUserDocument(uid: uid)
            } else {
                isLoading = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            showOnboarding = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDidSignOut)) { _ in
            verifyTask?.cancel()
            verifyTask = nil
            isLoggedIn = false
            isLoading = false
            // Clear per-user device-local state so the next user signing in
            // doesn't see the previous user's leftovers (compose draft,
            // analytics-opt-out preference is per-device on purpose so it
            // isn't cleared, push primer ditto). Add new keys here as they
            // get introduced.
            UserDefaults.standard.removeObject(forKey: "toska_composeDraftText")
            UserDefaults.standard.removeObject(forKey: "toska_composeDraftTag")
        }
        .onReceive(NotificationCenter.default.publisher(for: .authSessionExpired)) { _ in
            verifyTask?.cancel()
            verifyTask = nil
            isLoggedIn = false
            isLoading = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDidSignIn)) { notification in
            guard let uid = notification.userInfo?["uid"] as? String else { return }
            if ProcessInfo.processInfo.arguments.contains("UI_TESTING") {
                isLoggedIn = true
                isLoading = false
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    NotificationCenter.default.post(name: .authDidVerify, object: nil)
                }
                return
            }
            verifyUserDocument(uid: uid)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                LateNightThemeManager.shared.refresh()
                if #available(iOS 16, *) {
                    UNUserNotificationCenter.current().setBadgeCount(0)
                } else {
                    UIApplication.shared.applicationIconBadgeNumber = 0
                }
            }
        }
        // Timer.publish workaround removed — LateNightThemeManager is now
        // injected via .environment(LateNightThemeManager.shared) at the app
        // root, so SwiftUI tracks isLateNight changes automatically in any
        // view that holds @Environment(LateNightThemeManager.self).
    }

    // MARK: - Presence & Notifications

    func pruneOldNotifications(uid: String) {
        let db = Firestore.firestore()
        let ninetyDaysAgo = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        db.collection("users").document(uid).collection("notifications")
            .whereField("createdAt", isLessThan: Timestamp(date: ninetyDaysAgo))
            .order(by: "createdAt")
            .limit(to: 100)
            .getDocuments { snapshot, error in
                if let error = error {
                    print("⚠️ pruneOldNotifications failed — check composite index: \(error)")
                    return
                }
                guard let docs = snapshot?.documents, !docs.isEmpty else { return }
                let batch = db.batch()
                for doc in docs { batch.deleteDocument(doc.reference) }
                batch.commit { error in
                    if let error = error {
                        print("⚠️ pruneOldNotifications batch failed: \(error)")
                    }
                }
            }
    }

    func recordPresence(uid: String) {
        let db = Firestore.firestore()
        let today = ToskaFormatters.dateKey.string(from: Date())
        db.collection("users").document(uid).collection("presence").document(today).setData([
            "date": today,
            "createdAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    // MARK: - User Document Verification

    func verifyUserDocument(uid: String) {
        verifyTask?.cancel()
        verifyTask = Task {
            await verifyUserDocumentAsync(uid: uid)
        }
    }

    static func postAuthSessionExpired() {
        NotificationCenter.default.post(name: .authSessionExpired, object: nil)
    }

    func verifyUserDocumentAsync(uid: String) async {
        for attempt in 1...8 {
            guard !isLoggedIn, !Task.isCancelled else { return }

            let snapshot = try? await Firestore.firestore()
                .collection("users").document(uid).getDocumentAsync()

            guard !Task.isCancelled else { return }

            if snapshot?.exists == true {
                let data = snapshot?.data() ?? [:]
                let hasCompletedOnboarding =
                    data["hasCompletedOnboarding"] as? Bool ?? false
                if !hasCompletedOnboarding {
                    showOnboarding = true
                }

                // Retro-prompt existing users when the content policy has been
                // updated. We skip this for users still in onboarding —
                // OnboardingView runs its own gate for first-time users.
                let acceptedVersion = data["acceptedPolicyVersion"] as? Int ?? 0
                if hasCompletedOnboarding, acceptedVersion < currentPolicyVersion {
                    showPolicyUpdate = true
                }

                showVerifyError = false
                isLoggedIn = true
                isLoading = false
                NotificationCenter.default.post(name: .authDidVerify, object: nil)
                recordPresence(uid: uid)
                pruneOldNotifications(uid: uid)
                return
            }

            if attempt < 8 {
                let delay = UInt64(attempt) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        isLoading = false
        showVerifyError = true
    }
}
