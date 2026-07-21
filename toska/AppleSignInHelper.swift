import Foundation
import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import Combine

@MainActor
class AppleSignInHelper: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    private var currentNonce: String?
    private var continuation: CheckedContinuation<Void, Error>?

    // MARK: - Keychain key
    //
    // `authCodeKey` is the kSecAttrAccount value; `keychainService` is the
    // kSecAttrService value. The combination of (service, account) uniquely
    // identifies this app's Apple auth-code keychain entry. Previously the
    // queries set only kSecAttrAccount, which meant a SecItemDelete with no
    // service filter could match unrelated kSecClassGenericPassword items
    // sharing the keychain access group — third-party SDKs that store
    // tokens with the same account string would have been wiped. The
    // service scope is the standard fix.
    private static let authCodeKey = "toska_apple_auth_code"
    private static let keychainService = "com.toskaapp.toska.appleAuth"

    // MARK: - Request preparation (SignInWithAppleButton onRequest hook)
    //
    // Generates the nonce, stores it in currentNonce, and configures the
    // request. Pulled out of startSignIn so the official SwiftUI
    // SignInWithAppleButton can drive the request while reusing the exact
    // same nonce + scope setup. If nonce generation fails we leave
    // currentNonce nil and the request unsigned — handleAuthorization will
    // then reject the credential (currentNonce guard) rather than crashing.
    func prepareRequest(_ request: ASAuthorizationAppleIDRequest) {
        do {
            let nonce = try randomNonceString()
            currentNonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = sha256(nonce)
        } catch {
            currentNonce = nil
            Telemetry.recordError(error, context: "AppleSignIn.prepareRequest.nonce")
        }
    }

    // MARK: - Authorization handling (SignInWithAppleButton onCompletion hook)
    //
    // On success, runs the exact same credential-exchange + Firebase sign-in +
    // rollback logic as the delegate path (shared via authorizationControllerMain).
    // On failure, throws the underlying error so the caller surfaces it.
    func handleAuthorization(_ result: Result<ASAuthorization, Error>) async throws {
        switch result {
        case .success(let authorization):
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                Task { @MainActor in
                    await authorizationControllerMain(authorization: authorization)
                }
            }
        case .failure(let error):
            throw error
        }
    }

    // MARK: - Start Sign In (legacy programmatic path)
    //
    // Retained for any non-SwiftUI caller. The SplashView SignInWithAppleButton
    // now routes through prepareRequest/handleAuthorization instead. Reuses the
    // same nonce setup via prepareRequest.

    func startSignIn() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            prepareRequest(request)
            guard currentNonce != nil else {
                // Nonce generation failed inside prepareRequest; resume
                // immediately so the continuation is never left hanging.
                self.continuation?.resume(throwing: NSError(
                    domain: "AppleSignIn",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "secure random number generation failed"]
                ))
                self.continuation = nil
                return
            }
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            await authorizationControllerMain(authorization: authorization)
        }
    }

    // FIX: Replaced the five-level callback pyramid with a single async/await
    // do/catch block. Every early-exit path now calls continuation?.resume so
    // the continuation can never hang. Previously, a silent Firestore error in
    // setData would leave the continuation unresolved forever.
    @MainActor
    private func authorizationControllerMain(authorization: ASAuthorization) async {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let nonce = currentNonce,
              let appleIDToken = appleIDCredential.identityToken,
              let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
            continuation?.resume(throwing: NSError(
                domain: "AppleSignIn",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "unable to get apple credentials"]
            ))
            continuation = nil
            return
        }

        if let authCodeData = appleIDCredential.authorizationCode {
            AppleSignInHelper.saveAuthCode(authCodeData)
        }

        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: appleIDCredential.fullName
        )

        var isNewUser = false
        do {
            let result = try await Auth.auth().signIn(with: credential)
            let uid = result.user.uid
            let db = Firestore.firestore()
            let snapshot = try await db.collection("users").document(uid).getDocumentAsync()

            if !snapshot.exists {
                let userEmail = result.user.email ?? ""
                // Bounded handle assignment. The previous shape wrapped the
                // callback-based generateUniqueHandle in a withCheckedContinuation
                // and raced it against a 20s sleep via TaskGroup — that worked
                // for the timeout but the inner continuation Task could leak
                // forever if Firestore never fired the callback. Native async
                // generateUniqueHandleAsync participates in cancellation, so
                // withTimeout actually aborts the in-flight Firestore call on
                // timeout instead of orphaning it. 5s is plenty for a single
                // candidate-existence check; on timeout we fall back to a UUID
                // handle (statistically unique, no further round-trip).
                let handle: String
                do {
                    handle = try await withTimeout(seconds: 5) {
                        await generateUniqueHandleAsync()
                    }
                } catch {
                    handle = "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
                }
                isNewUser = true
                // Batched with the handle-registry claim (firestore.rules
                // requires the pair; see commitUserDocClaimingHandle).
                _ = try await commitUserDocClaimingHandle(uid: uid, initialHandle: handle, baseData: [
                    "followerCount": 0,
                    "followingCount": 0,
                    "totalLikes": 0,
                    "allowSharing": true,
                    "showFollowerCount": false,
                    "hasCompletedOnboarding": false,
                    "createdAt": FieldValue.serverTimestamp()
                ])
                // Email-minimization (2026-07-21 privacy hardening): the email is
                // NOT copied into Firestore. It lives only in Firebase Auth (the
                // login identity, a system separate from Firestore with no join to
                // posts), so a Firestore breach can't link an email to a uid's
                // posts. Settings display + data export read it from
                // Auth.currentUser.email; nothing reads a Firestore copy.
                _ = userEmail
                UserHandleCache.shared.startListening()
                Telemetry.signupCompleted(method: .apple)
                NotificationCenter.default.post(
                    name: .showOnboarding,
                    object: nil
                )
            } else {
                UserHandleCache.shared.startListening()
                Telemetry.signInCompleted(method: .apple)
            }

            NotificationCenter.default.post(
                name: .userDidSignIn,
                object: nil,
                userInfo: ["uid": uid]
            )
            continuation?.resume()
        } catch {
            // If anything in the do block throws — Firebase sign-in, Firestore
            // read, setData — we land here and always resume the continuation.
            //
            // Rollback: if Apple credentialed us into Firebase Auth but the
            // user-doc write failed, we'd otherwise leave an orphaned auth
            // account. Try to delete it (we just signed in so there's no
            // requires-recent-login risk). Fall back to signOut if delete
            // fails for any reason — at minimum the device session is cleared.
            // Clear any FCM token first for parity with the other sign-out/
            // deletion paths (harmless on a brand-new account that never
            // persisted one).
            PushNotificationManager.shared.clearFCMToken()
            if isNewUser {
                do {
                    try await Auth.auth().currentUser?.delete()
                } catch {
                    try? Auth.auth().signOut()
                }
            } else {
                try? Auth.auth().signOut()
            }
            // If both delete() and signOut() failed for any reason, we'd leave
            // the user authenticated locally with no Firestore user doc.
            // Downstream screens assume the doc exists and wedge. Force a
            // hard sign-out notification so observers can tear their state
            // down, and record a critical error so this surfaces in
            // Crashlytics instead of failing silently.
            if Auth.auth().currentUser != nil {
                Telemetry.recordError(
                    error,
                    context: "AppleSignIn.rollbackFailed.stillAuthenticated"
                )
                NotificationCenter.default.post(name: .userDidSignOut, object: nil)
            }
            Telemetry.recordError(error, context: "AppleSignIn.userDocCreate")
            continuation?.resume(throwing: error)
        }

        continuation = nil
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.keyWindow else {
            // Falling back to a detached UIWindow means the ASAuthorizationController
            // has no real anchor to present over — sign-in will visibly fail. Log so
            // this shows up in the console rather than silently failing.
            print("⚠️ AppleSignIn: no foreground window for presentation anchor; sign-in may fail")
            return UIWindow()
        }
        return window
    }

    // MARK: - Token Revocation

    static func revokeTokenIfNeeded() async {
        guard let authCodeData = loadAuthCode(),
              let authCodeString = String(data: authCodeData, encoding: .utf8) else {
            return
        }
        // Retry with exponential backoff. The previous implementation was a
        // single attempt — if a network blip dropped the request, the token
        // stayed valid forever and a stolen device could keep using it. Four
        // attempts with 2s/4s/8s waits between them covers transient network
        // failures without hammering Apple's revocation endpoint.
        let delays: [UInt64] = [2_000_000_000, 4_000_000_000, 8_000_000_000]
        let totalAttempts = delays.count + 1
        var lastError: Error? = nil
        for attempt in 0..<totalAttempts {
            do {
                try await Auth.auth().revokeToken(withAuthorizationCode: authCodeString)
                deleteAuthCode()
                return
            } catch {
                lastError = error
                print("⚠️ Apple token revocation attempt \(attempt + 1) failed: \(error.localizedDescription)")
                if attempt < delays.count {
                    try? await Task.sleep(nanoseconds: delays[attempt])
                }
            }
        }
        // All attempts failed. Surface to Crashlytics so the failure is
        // visible in production — the local auth code stays in keychain so
        // the next sign-in attempt can retry from a known state.
        if let error = lastError {
            Telemetry.recordError(error, context: "AppleSignInHelper.revokeToken.allRetriesFailed")
        }
    }

    // MARK: - Keychain helpers

    private static func saveAuthCode(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: authCodeKey,
            kSecValueData as String: data,
            // ThisDeviceOnly (2026-07-19 security pass): the Apple auth code is a
            // device-local credential — it must never ride an encrypted backup or
            // migrate to another device. ...ThisDeviceOnly keeps background access
            // (still available after first unlock) while excluding the item from
            // backups/restore, closing a cross-device credential-exfil path.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadAuthCode() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: authCodeKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    private static func deleteAuthCode() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: authCodeKey
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Crypto helpers

    // FIX 1: Replaced fatalError with a thrown error so a SecRandom failure
    // surfaces gracefully instead of crashing the app in production.
    //
    // FIX 2: Replaced the modulo-bias approach (byte % charset.count) with
    // Apple's recommended rejection-sampling algorithm. The old charset had 65
    // characters — 256 is not evenly divisible by 65, so characters with lower
    // ASCII values appeared slightly more often. The new approach only accepts
    // bytes whose value falls within a clean multiple of charset.count,
    // discarding the rest, producing a uniform distribution.
    private func randomNonceString(length: Int = 32) throws -> String {
        precondition(length > 0)
        let charset: [Character] = Array(
            "0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._"
        )
        var result = [Character]()
        result.reserveCapacity(length)
        var remainingLength = length

        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let errorCode = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            guard errorCode == errSecSuccess else {
                throw NSError(
                    domain: "AppleSignIn",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "secure random number generation failed"]
                )
            }
            for random in randoms {
                if remainingLength == 0 { break }
                // Only accept values that fall within a clean multiple of
                // charset.count — this eliminates modulo bias entirely.
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return String(result)
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.compactMap { String(format: "%02x", $0) }.joined()
    }
}
