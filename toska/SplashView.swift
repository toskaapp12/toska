import SwiftUI
import AuthenticationServices
import GoogleSignIn
import FirebaseAuth
import FirebaseFirestore

@MainActor
struct SplashView: View {
    @State private var showCreateAccount = false
    @State private var showSignIn = false
    // AppleSignInHelper is an ObservableObject (class) that holds the pending
    // continuation across the Apple Authorization delegate callbacks.
    // @StateObject is the canonical storage for view-owned ObservableObjects —
    // @State works for reference types in modern SwiftUI but doesn't guarantee
    // the same singleton-per-view semantics, and an accidental re-init in the
    // middle of a sign-in would drop the pending continuation on the floor.
    @StateObject private var appleHelper = AppleSignInHelper()
    @State private var errorMessage = ""
    @State private var isSigningIn = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.toskaBlue
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 60, height: 60)
                    Text("t")
                        .font(ToskaFont.serifItalic(42))
                        .foregroundColor(.white)
                }
                .padding(.bottom, 14)

                Text("toska")
                    .font(ToskaFont.serifItalic(42))
                    .foregroundColor(.white)
                    .padding(.bottom, 6)

                Text("for the things you couldnt say to your ex")
                    .font(ToskaFont.serifItalic(12))
                    .foregroundColor(.white.opacity(0.3))

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        showCreateAccount = true
                    } label: {
                        Text("im new here")
                            .font(ToskaFont.sans(15, weight: .medium))
                            .foregroundColor(Color(hex: "1a1c22"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white)
                            .cornerRadius(14)
                    }

                    Button {
                        showSignIn = true
                    } label: {
                        Text("sign in")
                            .font(ToskaFont.sans(15, weight: .regular))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.white.opacity(0.14))
                            .cornerRadius(14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                            )
                    }

                    // Official Sign in with Apple button (HIG-compliant).
                    // Splash sits on toskaBlue (a dark/blue ground), so the
                    // .white style reads best against it.
                    SignInWithAppleButton(.signIn, onRequest: { request in
                        appleHelper.prepareRequest(request)
                    }, onCompletion: { result in
                        isSigningIn = true
                        Task {
                            do {
                                try await appleHelper.handleAuthorization(result)
                            } catch {
                                errorMessage = friendlyAuthErrorMessage(error)
                            }
                            isSigningIn = false
                        }
                    })
                    .signInWithAppleButtonStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .cornerRadius(10)
                    .disabled(isSigningIn)

                    // Google-branding-compliant button: white surface, dark-gray
                    // label, subtle border. Uses the official multicolor "G"
                    // asset ("GoogleG" in Assets.xcassets) when present; falls
                    // back to the blue placeholder glyph if the asset hasn't been
                    // added yet, so the build is never broken. A-2: drop
                    // google_g.png (@1x/@2x/@3x) from Google's branding kit into
                    // GoogleG.imageset and the official mark renders automatically.
                    Button {
                        signInWithGoogle()
                    } label: {
                        HStack(spacing: 8) {
                            if isSigningIn {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(Color(hex: "3C4043"))
                            } else {
                                if UIImage(named: "GoogleG") != nil {
                                    Image("GoogleG")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 18, height: 18)
                                } else {
                                    Text("G")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(Color(hex: "4285F4"))
                                }
                                // The native Sign in with Apple button renders its
                                // label at ~17pt; match that (19 was too big, 15 too
                                // small) so the two buttons read as the same size.
                                Text("Sign in with Google")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(Color(hex: "3C4043"))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "DADCE0"), lineWidth: 1)
                        )
                    }
                    .disabled(isSigningIn)

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(ToskaFont.sans(11))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.top, 2)
                    }

                    HStack(spacing: 0) {
                        Text("by being here you agree to our ")
                            .font(ToskaFont.sans(11))
                            .foregroundColor(.white.opacity(0.3))
                        Link("terms", destination: URL(string: "https://www.toskaapp.com/terms")!)
                            .font(ToskaFont.sans(11))
                            .foregroundColor(.white.opacity(0.5))
                        Text(" and ")
                            .font(ToskaFont.sans(11))
                            .foregroundColor(.white.opacity(0.3))
                        Link("privacy policy", destination: URL(string: "https://www.toskaapp.com/privacy")!)
                            .font(ToskaFont.sans(11))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
        .fullScreenCover(isPresented: $showCreateAccount) {
            EdgeSwipeDismissWrapper { CreateAccountView() }
        }
        .fullScreenCover(isPresented: $showSignIn) {
            EdgeSwipeDismissWrapper { SignInView() }
        }
    }

    // MARK: - Shared User Document Creation
    //
    // FIX: extracted the "create Firestore user document" logic that was
    // previously duplicated between the Google and Apple sign-in paths into
    // one shared async function. Both paths now call this instead of
    // independently nesting callbacks four levels deep.
    //
    // For a new user: generates a handle, writes the document, posts
    // ShowOnboarding and UserDidSignIn.
    // For a returning user: just posts UserDidSignIn.
    // Any Firestore error throws and is caught by the caller.

    /// Method is passed in so the telemetry event reflects which provider
    /// brought the user to this code path (currently only Google calls
    /// this — Apple has its own helper).
    func createUserDocumentIfNeeded(uid: String, email: String, method: Telemetry.SignupMethod) async throws {
        let db = Firestore.firestore()
        let snapshot = try await db.collection("users").document(uid).getDocumentAsync()

        if snapshot.exists {
            UserHandleCache.shared.startListening()
            Telemetry.signInCompleted(method: method)
            NotificationCenter.default.post(name: .userDidSignIn, object: nil, userInfo: ["uid": uid])
            return
        }

        // Bounded handle assignment — see AppleSignInHelper for the full
        // rationale. A hung Firestore would previously leave Google sign-up
        // spinning forever because the inner continuation never resumed.
        let handle: String
        do {
            handle = try await withTimeout(seconds: 5) {
                await generateUniqueHandleAsync()
            }
        } catch {
            handle = "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
        }

        try await db.collection("users").document(uid).setData([
            "handle": handle,
            "followerCount": 0,
            "followingCount": 0,
            "totalLikes": 0,
            "allowSharing": true,
            "showFollowerCount": false,
            "hasCompletedOnboarding": false,
            "createdAt": FieldValue.serverTimestamp()
        ])
        // Email lives in the owner-only private subcollection so it isn't
        // exposed by the broader users-doc reads policy.
        try? await db.collection("users").document(uid)
            .collection("private").document("data")
            .setData(["email": email], merge: true)

        UserHandleCache.shared.startListening()
        Telemetry.signupCompleted(method: method)
        NotificationCenter.default.post(name: .showOnboarding, object: nil)
        NotificationCenter.default.post(name: .userDidSignIn, object: nil, userInfo: ["uid": uid])
    }

    // MARK: - Google Sign In
    //
    // FIX: replaced the four-level callback pyramid with a single async/await
    // do/catch block. All errors now surface to the user via errorMessage
    // instead of being silently discarded. The user document creation logic
    // is handled by createUserDocumentIfNeeded() above.

    func signInWithGoogle() {
        guard !isSigningIn else { return }
        isSigningIn = true

        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let rootVC = windowScene.keyWindow?.rootViewController else {
            isSigningIn = false
            return
        }

        Task { @MainActor in
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)

                guard let idToken = result.user.idToken?.tokenString else {
                    errorMessage = "unable to get google credentials"
                    isSigningIn = false
                    return
                }

                let credential = GoogleAuthProvider.credential(
                    withIDToken: idToken,
                    accessToken: result.user.accessToken.tokenString
                )

                let authResult = try await Auth.auth().signIn(with: credential)
                let uid = authResult.user.uid
                let email = authResult.user.email ?? ""

                try await createUserDocumentIfNeeded(uid: uid, email: email, method: .google)
            } catch {
                Telemetry.recordError(error, context: "SplashView.signInWithGoogle")
                errorMessage = friendlyAuthErrorMessage(error)
                // Rollback: if Google credentialed us into Firebase Auth but
                // the user-doc write failed, delete the orphaned auth account.
                // Fall back to signOut if delete fails.
                if Auth.auth().currentUser != nil {
                    // Clear any FCM token first, for parity with the other
                    // sign-out/deletion paths (harmless here — a brand-new account
                    // that never persisted one).
                    PushNotificationManager.shared.clearFCMToken()
                    do {
                        try await Auth.auth().currentUser?.delete()
                    } catch {
                        try? Auth.auth().signOut()
                    }
                }
            }
            isSigningIn = false
        }
    }
}
