import SwiftUI
import Combine
import FirebaseAuth
import FirebaseFirestore

/// Gates the in-app moderation dashboard. An account is an admin iff a doc
/// exists at `admins/{uid}` with `role == "admin"` — the SAME gate the web
/// dashboard and firestore.rules `isAdmin()` use. This only controls whether the
/// UI entry point is shown; the real perimeter is the security rules, which
/// reject every moderation write from a non-admin regardless of the app UI.
@MainActor
final class AdminManager: ObservableObject {
    static let shared = AdminManager()
    @Published private(set) var isAdmin = false
    private var lastCheckedUid: String?

    private init() {}

    /// One lightweight read of admins/{uid}. Cheap; safe to call on appear.
    func refresh() {
        guard let uid = Auth.auth().currentUser?.uid else {
            isAdmin = false; lastCheckedUid = nil; return
        }
        // Skip a redundant re-read for the same signed-in user once known true.
        if lastCheckedUid == uid && isAdmin { return }
        Firestore.firestore().collection("admins").document(uid).getDocument { [weak self] snap, _ in
            Task { @MainActor in
                guard Auth.auth().currentUser?.uid == uid else { return }
                self?.lastCheckedUid = uid
                self?.isAdmin = (snap?.data()?["role"] as? String) == "admin"
            }
        }
    }

    func reset() { isAdmin = false; lastCheckedUid = nil }
}
