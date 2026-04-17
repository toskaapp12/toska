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
    private static let authCodeKey = "toska_apple_auth_code"

    // MARK: - Start Sign In

    func startSignIn() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do {
                let nonce = try randomNonceString()
                currentNonce = nonce
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = [.email]
                request.nonce = sha256(nonce)
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            } catch {
                // If nonce generation fails, resume immediately so the
                // continuation is never left hanging.
                self.continuation?.resume(throwing: error)
                self.continuation = nil
            }
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
                // Wrap generateUniqueHandle in a 20s timeout so a hung Firestore
                // call can never leave Apple sign-in spinning forever. On timeout
                // we fall back to a UUID-based handle, which is always unique.
                let handle: String = await withTaskGroup(of: String.self) { group in
                    group.addTask {
                        await withCheckedContinuation { c in
                            generateUniqueHandle { c.resume(returning: $0) }
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                        return "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
                    }
                    let first = await group.next() ?? "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
                    group.cancelAll()
                    return first
                }
                isNewUser = true
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
                // Email lives in the owner-only private subcollection so
                // it isn't exposed by the broader users-doc reads policy.
                try? await db.collection("users").document(uid)
                    .collection("private").document("data")
                    .setData(["email": userEmail], merge: true)
                UserHandleCache.shared.startListening()
                Telemetry.signupCompleted(method: .apple)
                NotificationCenter.default.post(
                    name: NSNotification.Name("ShowOnboarding"),
                    object: nil
                )
            } else {
                UserHandleCache.shared.startListening()
                Telemetry.signInCompleted(method: .apple)
            }

            NotificationCenter.default.post(
                name: NSNotification.Name("UserDidSignIn"),
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
            if isNewUser {
                do {
                    try await Auth.auth().currentUser?.delete()
                } catch {
                    try? Auth.auth().signOut()
                }
            } else {
                try? Auth.auth().signOut()
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
        do {
            try await Auth.auth().revokeToken(withAuthorizationCode: authCodeString)
            deleteAuthCode()
        } catch {
            print("⚠️ Apple token revocation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Keychain helpers

    private static func saveAuthCode(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: authCodeKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadAuthCode() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
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
