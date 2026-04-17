import SwiftUI
import GoogleSignIn
import FirebaseAuth
import FirebaseFirestore

@MainActor
struct SplashView: View {
    @State private var showCreateAccount = false
    @State private var showSignIn = false
    @State private var appleHelper = AppleSignInHelper()
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
                        .font(.custom("Georgia-Italic", size: 42))
                        .foregroundColor(.white)
                }
                .padding(.bottom, 14)

                Text("toska")
                    .font(.custom("Georgia-Italic", size: 42))
                    .foregroundColor(.white)
                    .padding(.bottom, 6)

                Text("say what you never said")
                    .font(.custom("Georgia-Italic", size: 12))
                    .foregroundColor(.white.opacity(0.3))

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        showCreateAccount = true
                    } label: {
                        Text("im new here")
                            .font(.system(size: 15, weight: .medium))
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
                            .font(.system(size: 15, weight: .regular))
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

                    HStack(spacing: 10) {
                        Button {
                            signInWithGoogle()
                        } label: {
                            Text(isSigningIn ? "..." : "Google")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                )
                        }
                        .disabled(isSigningIn)

                        Button {
                            guard !isSigningIn else { return }
                            isSigningIn = true
                            Task {
                                do {
                                    try await appleHelper.startSignIn()
                                } catch {
                                    errorMessage = friendlyAuthErrorMessage(error)
                                }
                                isSigningIn = false
                            }
                        } label: {
                            Text(isSigningIn ? "..." : "Apple")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                )
                        }
                        .disabled(isSigningIn)
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.top, 2)
                    }

                    HStack(spacing: 0) {
                        Text("by being here you agree to our ")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.3))
                        Link("terms", destination: URL(string: "https://toskaapp.com/terms")!)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                        Text(" and ")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.3))
                        Link("privacy policy", destination: URL(string: "https://toskaapp.com/privacy")!)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
        .fullScreenCover(isPresented: $showCreateAccount) {
            CreateAccountView()
        }
        .fullScreenCover(isPresented: $showSignIn) {
            SignInView()
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

        let handle: String = await withCheckedContinuation { c in
            generateUniqueHandle { c.resume(returning: $0) }
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
