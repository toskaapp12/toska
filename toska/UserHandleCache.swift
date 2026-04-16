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
    private var listener: ListenerRegistration? = nil
    private var currentUid: String? = nil

    private init() {}

    func startListening() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard uid != currentUid else { return }
        stopListening()
        currentUid = uid

        // Capture uid so a late snapshot from the previous user can't apply
        // their handle/settings to the new user — the currentUid gate inside
        // the MainActor task is the authoritative check.
        let listenerUid = uid
        listener = Firestore.firestore()
                    .collection("users").document(uid)
                    .addSnapshotListener { [weak self] snapshot, _ in
                        Task { @MainActor [weak self] in
                            guard let self = self, self.currentUid == listenerUid else { return }
                            self.handle = snapshot?.data()?["handle"] as? String ?? "anonymous"
                            self.allowSharing = snapshot?.data()?["allowSharing"] as? Bool ?? true
                            self.gentleCheckIn = snapshot?.data()?["gentleCheckIn"] as? Bool ?? true
                        }
                    }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        handle = "anonymous"
        allowSharing = true
        gentleCheckIn = true
        currentUid = nil
    }
}
