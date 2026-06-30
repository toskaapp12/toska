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
                                .font(ToskaFont.serifItalic(42))
                                .foregroundColor(.white)
                            Text(Auth.auth().currentUser != nil
                                 ? "setting up your account"
                                 : "couldn't connect")
                                .font(ToskaFont.sans(13, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                            Text(Auth.auth().currentUser != nil
                                 ? "this sometimes takes a moment after creating or restoring an account — tap retry"
                                 : "check your connection and try again")
                                .font(ToskaFont.sans(12))
                                .foregroundColor(.white.opacity(0.4))
                            Button {
                                showVerifyError = false
                                isLoading = true
                                if let uid = Auth.auth().currentUser?.uid {
                                    verifyUserDocument(uid: uid)
                                }
                            } label: {
                                Text("retry")
                                    .font(ToskaFont.sans(13, weight: .medium))
                                    .foregroundColor(Color.toskaBlue)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 10)
                                    .background(Color.white)
                                    .cornerRadius(20)
                            }
                            .padding(.top, 4)

                            // Escape hatch: a permission-denied / deterministic
                            // failure won't self-heal on Retry, so always offer a
                            // way back to the login screen instead of a dead-end.
                            Button {
                                showVerifyError = false
                                try? Auth.auth().signOut()
                                NotificationCenter.default.post(name: .userDidSignOut, object: nil)
                            } label: {
                                Text("back to login")
                                    .font(ToskaFont.sans(12))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .padding(.top, 2)
                        }
                    } else {
                        VStack(spacing: 20) {
                            Text("t")
                                .font(ToskaFont.serifItalic(42))
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
        // App-wide tap-to-dismiss-keyboard, like a normal iOS app: tapping
        // anywhere outside a text field lowers the keyboard, without blocking
        // taps on buttons, posts, or scrolling. See KeyboardDismiss.swift.
        .dismissKeyboardOnTap()
        // Subtle paper-grain texture over the whole surface (3% light / 5%
        // dark), non-interactive — the editorial "printed page" feel.
        .overlay(ToskaPaperGrain())
        // N-5 (2026-06-09 re-review): privacy screen for the app switcher.
        // When the app leaves the foreground, cover sensitive grief content
        // (posts, drafts, moods) so it isn't captured in the iOS multitasking
        // snapshot or readable by a shoulder-surfer. Only over logged-in
        // surfaces — the splash/loading screens carry nothing sensitive.
        .overlay(alignment: .center) {
            if isLoggedIn && scenePhase != .active {
                ZStack {
                    Color.toskaBlue.ignoresSafeArea()
                    Text("t")
                        .font(ToskaFont.serifItalic(42))
                        .foregroundColor(.white)
                }
                .allowsHitTesting(false)
            }
        }
        .fullScreenCover(isPresented: $showPolicyUpdate) {
            // Version-bump retro-prompt. A user declining here is signed out
            // rather than deleted — their account and content persist so they
            // can return and accept later if they change their mind.
            EdgeSwipeDismissWrapper {
            PolicyAcceptanceView(
                onAccept: {
                    // Version-bump retro-prompt records only the policy
                    // acceptance fields — confirmedAdult is intentionally
                    // not touched here (existing users were already
                    // adult-confirmed at signup; new policy versions are
                    // about ToS changes, not the age gate).
                    Task { @MainActor in
                        guard let uid = Auth.auth().currentUser?.uid else {
                            showPolicyUpdate = false
                            return
                        }
                        do {
                            try await recordPolicyAcceptance(for: uid)
                            showPolicyUpdate = false
                        } catch {
                            print("⚠️ recordPolicyAcceptance failed: \(error)")
                            Telemetry.recordError(error, context: "recordPolicyAcceptance.bump.v\(currentPolicyVersion)")
                            // Leave the modal up so the user can retry. The
                            // next-launch acceptedPolicyVersion check is a
                            // backstop if they dismiss the app instead.
                        }
                    }
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
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("UI_TESTING") {
                if Auth.auth().currentUser?.uid != nil {
                    isLoggedIn = true
                }
                isLoading = false
                return
            }
            #endif
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
            // Reset the verify-error screen + admin gate so the NEXT user who
            // signs in on this device doesn't land on the previous session's
            // stranded "couldn't connect" screen (its Retry reads a now-nil user
            // and does nothing) or inherit admin UI.
            showVerifyError = false
            AdminManager.shared.reset()
            // Clear per-user device-local state so the next user signing in
            // doesn't see the previous user's leftovers. Analytics-opt-out
            // preference stays (it's a per-device choice). Push primer
            // shown flag IS cleared so the next user gets a fresh primer
            // on their first Notifications visit instead of inheriting
            // User A's "already seen" state.
            // N-4: clear ALL on-device drafts (compose + per-post replies) from
            // the protected DraftStore so the next account on this device
            // inherits none of the previous user's in-progress words. Also scrub
            // any legacy UserDefaults copies that predate the DraftStore move.
            DraftStore.clearAll()
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.composeDraftText)
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.composeDraftTag)
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.pushPrimerShown)
        }
        .onReceive(NotificationCenter.default.publisher(for: .authSessionExpired)) { _ in
            verifyTask?.cancel()
            verifyTask = nil
            isLoggedIn = false
            isLoading = false
            showVerifyError = false
            AdminManager.shared.reset()
            // C-2 (2026-06-11): a token-expiry logout must also clear on-device
            // drafts, like the explicit sign-out path above — otherwise the prior
            // user's in-progress grief text survives on a shared device.
            DraftStore.clearAll()
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.composeDraftText)
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.composeDraftTag)
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDidSignIn)) { notification in
            guard let uid = notification.userInfo?["uid"] as? String else { return }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("UI_TESTING") {
                isLoggedIn = true
                isLoading = false
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    NotificationCenter.default.post(name: .authDidVerify, object: nil)
                }
                return
            }
            #endif
            // Show the branded loading screen (not SplashView) while the
            // post-sign-in user-doc verify round-trips. Without this, isLoading
            // is false and isLoggedIn not yet true, so the root fell through to
            // SplashView for a beat — the login screen flashed back before the
            // feed appeared. Loading → feed reads as a single clean transition.
            isLoading = true
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

    func pruneOldNotifications(uid: String) async {
        // Run inside the verifyTask so a sign-out (which calls verifyTask?.cancel())
        // also tears down a mid-flight prune. Without the cancellation hop, the
        // batch.commit kept firing post-signout and burning reads/writes against
        // the user's own subcollection.
        let db = Firestore.firestore()
        let ninetyDaysAgo = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        let snapshot: QuerySnapshot?
        do {
            snapshot = try await db.collection("users").document(uid).collection("notifications")
                .whereField("createdAt", isLessThan: Timestamp(date: ninetyDaysAgo))
                .order(by: "createdAt")
                .limit(to: 100)
                .getDocumentsAsync()
        } catch {
            print("⚠️ pruneOldNotifications failed — check composite index: \(error)")
            return
        }
        guard !Task.isCancelled else { return }
        guard let docs = snapshot?.documents, !docs.isEmpty else { return }
        let batch = db.batch()
        for doc in docs { batch.deleteDocument(doc.reference) }
        do {
            try await batch.commit()
        } catch {
            print("⚠️ pruneOldNotifications batch failed: \(error)")
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
        // Belt-and-suspenders: any early return path (cancellation, transient
        // error, etc.) should leave isLoading=false so the splash screen never
        // hangs on a spinner. The success and permanent-error branches set
        // this explicitly; defer catches anything we miss. Idempotent — if
        // isLoading is already false, this is a no-op.
        defer {
            if isLoading { isLoading = false }
        }
        for attempt in 1...8 {
            guard !isLoggedIn, !Task.isCancelled else { return }

            // Classify the error on each attempt. Retrying for 28 seconds on
            // a permission-denied / unauthenticated failure (which is deterministic,
            // not transient) wasted the user's time and left them staring at a
            // loading spinner for nothing. Transient errors (network unavailable,
            // deadline exceeded, unknown) continue to retry with the existing backoff.
            let snapshot: DocumentSnapshot?
            do {
                snapshot = try await Firestore.firestore()
                    .collection("users").document(uid).getDocumentAsync()
            } catch {
                let nsError = error as NSError
                if nsError.domain == "FIRFirestoreErrorDomain" {
                    switch nsError.code {
                    case 7,   // permission-denied
                         16:  // unauthenticated
                        print("⚠️ verifyUserDocument: permanent error, aborting retry loop: \(error)")
                        Telemetry.recordError(error, context: "ContentView.verifyUserDocumentAsync.permanent")
                        isLoading = false
                        showVerifyError = true
                        return
                    default:
                        break // transient — fall through to retry
                    }
                }
                snapshot = nil
            }

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

                // Stuck-account auto-recovery. If the user completed onboarding
                // but `confirmedAdult` is still false (the original confirmAdult
                // RPC during signup was rejected by App Check — typically when a
                // debug build's debug token isn't registered yet — and commit
                // 953eebb lets signup proceed regardless), they end up unable
                // to post or repost: every post.create rule check fails on
                // hasConfirmedAdult(). Before this, the only in-app recovery
                // was an attempted post in ComposeView surfacing the "still
                // setting up your account" error — reposts and other paths
                // gave no signal. Fire confirmAdult here on next launch so any
                // stuck account self-heals as soon as App Check works.
                let confirmedAdult = data["confirmedAdult"] as? Bool ?? false
                if hasCompletedOnboarding, !confirmedAdult {
                    confirmAdultServerSideFireAndForget(uid: uid)
                }

                showVerifyError = false
                isLoggedIn = true
                isLoading = false
                recordPresence(uid: uid)
                // Inline the deferred notification post (was previously a
                // detached Task that escaped verifyTask's cancellation).
                // Sign-out cancels verifyTask, which cancels this Task.sleep
                // and the post never fires for a stale auth state. The 300ms
                // delay still gives MainTabView and FeedView time to mount
                // and attach their .onReceive(.authDidVerify) subscribers
                // before the notification arrives — without it the feed
                // stays blank until pull-to-refresh.
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled,
                      Auth.auth().currentUser?.uid == uid else { return }
                NotificationCenter.default.post(name: .authDidVerify, object: nil)
                await pruneOldNotifications(uid: uid)
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
