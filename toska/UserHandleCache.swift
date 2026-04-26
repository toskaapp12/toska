import Foundation
import Observation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

// Converted from a plain @MainActor class to @Observable so views reading
// `handle`, `isRestricted`, `allowSharing`, `gentleCheckIn` inline (e.g.
// ComposeView's `canPost` computed property) automatically re-render when
// Firestore snapshots update the underlying values. Previously consumers
// read a fresh value on first render but weren't notified of later changes —
// so if a user's restriction kicked in mid-session, ComposeView's button
// stayed enabled until some unrelated state change forced a redraw.
//
// Mirrors the pattern already used by NetworkMonitor and LateNightThemeManager
// elsewhere in the codebase. Implementation-detail fields (listeners, the
// intermediate legacy/private gentleCheckIn sources, the bound uid) are
// marked @ObservationIgnored so changing them doesn't trigger view redraws.
@Observable
@MainActor
class UserHandleCache {
    static let shared = UserHandleCache()

    private(set) var handle: String = "anonymous"
    private(set) var allowSharing: Bool = true
    // Mirrors the user's "gentle check-in" setting. Default true so a user who
    // hasn't seen Settings yet still gets the soft-tier check-in. The explicit
    // crisis tier ignores this flag — see CrisisCheckInView / crisisLevel(for:).
    private(set) var gentleCheckIn: Bool = true
    // Backing store: what the user doc says. Consumers read `isRestricted`
    // below, which applies the restrictedUntil auto-expiry so a user whose
    // 48-hour system-restriction has elapsed is no longer gated even if the
    // server hasn't cleaned up the boolean yet.
    private var rawIsRestricted: Bool = false
    // Auto-restrict expiry timestamp set by Cloud Functions. Admin
    // restrictions leave this nil (restriction is indefinite until the admin
    // clears it). System ("repeat offender") restrictions set it to +48h.
    private(set) var restrictedUntil: Date? = nil
    var isRestricted: Bool {
        guard rawIsRestricted else { return false }
        if let until = restrictedUntil, Date() >= until { return false }
        return true
    }

    @ObservationIgnored private var listener: ListenerRegistration? = nil
    @ObservationIgnored private var privateListener: ListenerRegistration? = nil
    // Track whether the private/data doc has surfaced a gentleCheckIn value.
    // If it has, that takes precedence over the legacy field on the main doc;
    // otherwise we fall back to the main-doc value so users who haven't been
    // through SettingsView since the migration still get their setting honored.
    @ObservationIgnored private var privateGentleCheckIn: Bool? = nil
    @ObservationIgnored private var legacyGentleCheckIn: Bool = true
    @ObservationIgnored private var currentUid: String? = nil

    private init() {}

    func startListening() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard uid != currentUid else { return }
        stopListening()
        currentUid = uid

        // Capture uid at listener-creation time and re-check it inside every
        // snapshot callback. On a rapid sign-out/sign-in for a different
        // account, the old listener's in-flight snapshot can fire after the
        // new listener is attached and write a stale value (prior user's
        // handle/restricted status) into the observable cache.
        let capturedUid = uid
        listener = Firestore.firestore()
                    .collection("users").document(uid)
                    .addSnapshotListener { [weak self] snapshot, _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.currentUid == capturedUid else { return }
                            self.handle = snapshot?.data()?["handle"] as? String ?? "anonymous"
                            self.allowSharing = snapshot?.data()?["allowSharing"] as? Bool ?? true
                            self.legacyGentleCheckIn = snapshot?.data()?["gentleCheckIn"] as? Bool ?? true
                            self.rawIsRestricted = snapshot?.data()?["restricted"] as? Bool ?? false
                            self.restrictedUntil = (snapshot?.data()?["restrictedUntil"] as? Timestamp)?.dateValue()
                            self.recomputeGentleCheckIn()
                        }
                    }

        privateListener = Firestore.firestore()
                    .collection("users").document(uid)
                    .collection("private").document("data")
                    .addSnapshotListener { [weak self] snapshot, _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.currentUid == capturedUid else { return }
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
        rawIsRestricted = false
        restrictedUntil = nil
        currentUid = nil
    }
}
