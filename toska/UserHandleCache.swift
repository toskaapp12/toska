import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

@MainActor
class UserHandleCache {
    static let shared = UserHandleCache()

    private(set) var handle: String = "anonymous"
    private(set) var allowSharing: Bool = true
    // Mirrors the user's "gentle check-in" setting. Default true so a user who
    // hasn't seen Settings yet still gets the soft-tier check-in. The explicit
    // crisis tier ignores this flag — see CrisisCheckInView / crisisLevel(for:).
    private(set) var gentleCheckIn: Bool = true
    // Set to true by Cloud Functions when a user accumulates >= 3 flagged posts.
    // While restricted, the user cannot create new posts.
    private(set) var isRestricted: Bool = false
    private var listener: ListenerRegistration? = nil
    private var privateListener: ListenerRegistration? = nil
    // Track whether the private/data doc has surfaced a gentleCheckIn value.
    // If it has, that takes precedence over the legacy field on the main doc;
    // otherwise we fall back to the main-doc value so users who haven't been
    // through SettingsView since the migration still get their setting honored.
    private var privateGentleCheckIn: Bool? = nil
    private var legacyGentleCheckIn: Bool = true
    private var currentUid: String? = nil

    private init() {}

    func startListening() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard uid != currentUid else { return }
        stopListening()
        currentUid = uid

        listener = Firestore.firestore()
                    .collection("users").document(uid)
                    .addSnapshotListener { [weak self] snapshot, _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.handle = snapshot?.data()?["handle"] as? String ?? "anonymous"
                            self.allowSharing = snapshot?.data()?["allowSharing"] as? Bool ?? true
                            self.legacyGentleCheckIn = snapshot?.data()?["gentleCheckIn"] as? Bool ?? true
                            self.isRestricted = snapshot?.data()?["restricted"] as? Bool ?? false
                            self.recomputeGentleCheckIn()
                        }
                    }

        privateListener = Firestore.firestore()
                    .collection("users").document(uid)
                    .collection("private").document("data")
                    .addSnapshotListener { [weak self] snapshot, _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.privateGentleCheckIn = snapshot?.data()?["gentleCheckIn"] as? Bool
                            self.recomputeGentleCheckIn()
                        }
                    }
    }

    private func recomputeGentleCheckIn() {
        gentleCheckIn = privateGentleCheckIn ?? legacyGentleCheckIn
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        privateListener?.remove()
        privateListener = nil
        handle = "anonymous"
        allowSharing = true
        gentleCheckIn = true
        privateGentleCheckIn = nil
        legacyGentleCheckIn = true
        isRestricted = false
        currentUid = nil
    }
}
