import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

@MainActor
class BlockedUsersCache {
    static let shared = BlockedUsersCache()

    // Protects _blockedUserIds across the @MainActor writers and the nonisolated
    // isBlocked(_:) reader, which is called from Firestore callback queues.
    private nonisolated(unsafe) let lock = NSLock()
    private nonisolated(unsafe) var _blockedUserIds: Set<String> = []

    var blockedUserIds: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return _blockedUserIds
    }

    private func setBlockedUserIds(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        _blockedUserIds = ids
    }

    private func insertLocal(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        _blockedUserIds.insert(id)
    }

    private func removeLocal(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        _blockedUserIds.remove(id)
    }

    private var listener: ListenerRegistration? = nil
    private var currentUid: String? = nil

    private init() {}

    // MARK: - Listening

    func startListening() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard uid != currentUid else { return }
        stopListening()
        currentUid = uid

        listener = Firestore.firestore()
            .collection("users").document(uid).collection("blocked")
            .addSnapshotListener { [weak self] snapshot, _ in
                let ids = Set(snapshot?.documents.map { $0.documentID } ?? [])
                Task { @MainActor [weak self] in
                    self?.setBlockedUserIds(ids)
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        setBlockedUserIds([])
        currentUid = nil
    }

    // MARK: - Querying

    nonisolated func isBlocked(_ userId: String) -> Bool {
        guard !userId.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return _blockedUserIds.contains(userId)
    }

    // MARK: - Mutating
    //
    // FIX: block() and unblock() previously only updated the in-memory set,
    // meaning the block vanished on the next app launch when the snapshot
    // listener repopulated blockedUserIds from Firestore.
    //
    // Both methods now:
    //   1. Apply the change locally immediately (optimistic update) so the UI
    //      responds instantly without waiting for a network round-trip.
    //   2. Write the change to Firestore for persistence.
    //   3. Revert the local change if the Firestore write fails, so the cache
    //      never drifts permanently out of sync with the server.

    func block(_ userId: String, handle: String? = nil) {
        guard !userId.isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return }

        // Telemetry — fired before the write so it's recorded even if the
        // network round-trip fails. The block is optimistic locally anyway,
        // so the user-perceived block has happened by this point.
        Telemetry.userBlocked()

        // 1. Optimistic local update.
        insertLocal(userId)

        // 2. Persist to Firestore. Include the handle when the caller has it
        //    so the Settings "blocked users" list can show recognizable rows
        //    without a per-user lookup.
        var data: [String: Any] = ["blockedAt": FieldValue.serverTimestamp()]
        if let handle = handle, !handle.isEmpty {
            data["handle"] = handle
        }
        Firestore.firestore()
            .collection("users").document(uid)
            .collection("blocked").document(userId)
            .setData(data) { [weak self] error in
                Task { @MainActor [weak self] in
                    if let error = error {
                        // 3. Revert if the write failed.
                        print("⚠️ BlockedUsersCache.block failed: \(error)")
                        self?.removeLocal(userId)
                    }
                }
            }
    }

    func unblock(_ userId: String) {
        guard !userId.isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return }

        // 1. Optimistic local update.
        removeLocal(userId)

        // 2. Persist to Firestore.
        Firestore.firestore()
            .collection("users").document(uid)
            .collection("blocked").document(userId)
            .delete { [weak self] error in
                Task { @MainActor [weak self] in
                    if let error = error {
                        // 3. Revert if the write failed.
                        print("⚠️ BlockedUsersCache.unblock failed: \(error)")
                        self?.insertLocal(userId)
                    }
                }
            }
    }
}
