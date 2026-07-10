import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

@MainActor
class BlockedUsersCache {
    // nonisolated singleton accessor so the nonisolated isBlocked(_:)
    // reader (called from Firestore callback queues and
    // FeedViewModel.filterBlocked) can reach `shared` without a main-actor
    // hop. Safe because `shared` is set once at static init and never
    // reassigned; the underlying mutable state is guarded by the NSLock.
    // Pairs with the nonisolated init() below.
    nonisolated static let shared = BlockedUsersCache()

    // Protects _blockedUserIds across the @MainActor writers and the nonisolated
    // isBlocked(_:) reader, which is called from Firestore callback queues.
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var _blockedUserIds: Set<String> = []

    var blockedUserIds: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return _blockedUserIds
    }

    private func setBlockedUserIds(_ ids: Set<String>) {
        lock.lock()
        let added = ids.subtracting(_blockedUserIds)
        _blockedUserIds = ids
        lock.unlock()
        // F-P3-1 (2026-07-09 full-audit): a block that arrives via THIS listener
        // — a block made on another device, or the cold-start initial load
        // landing AFTER the feed already rendered — must prune the displayed
        // feed the same way an in-app block() does. Previously only block()
        // broadcast .userBlocked, so a listener-delivered block left the
        // blocked author's posts on screen until the next navigation/refresh.
        // Re-use the same broadcast; FeedViewModel.handleUserBlocked is
        // idempotent, so block()'s own notification double-firing is harmless.
        // An unblock (set shrinks) adds nothing, so it never strips rows.
        if !added.isEmpty {
            Task { @MainActor in
                for uid in added { self.postUserBlockedBroadcast(userId: uid, handle: nil) }
            }
        }
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

    private nonisolated init() {}

    // MARK: - Listening

    func startListening() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard uid != currentUid else { return }
        stopListening()
        currentUid = uid

        // Capture uid at listener-creation time and re-check it in the
        // callback. On a fast sign-out/sign-in for a different account, the
        // old listener's in-flight snapshot can fire AFTER stopListening()
        // ran but before Firestore actually tore the listener down server-
        // side — without this guard, the previous user's blocked-users set
        // would briefly land in the new user's cache. Mirrors the same
        // pattern used in UserHandleCache.
        let capturedUid = uid
        listener = Firestore.firestore()
            .collection("users").document(uid).collection("blocked")
            .addSnapshotListener { [weak self] snapshot, error in
                // On error (permission change, transient network), keep the
                // existing cache. Coercing snapshot?.documents to [] would
                // empty the cache and make every blocked user appear unblocked
                // until the listener reconnects.
                if let error = error {
                    print("⚠️ BlockedUsersCache listener error: \(error)")
                    return
                }
                guard let snapshot = snapshot else { return }
                let ids = Set(snapshot.documents.map { $0.documentID })
                Task { @MainActor [weak self] in
                    guard let self, self.currentUid == capturedUid else { return }
                    self.setBlockedUserIds(ids)
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

    // Fire-and-forget block. Fine for surfaces that show a transient undo-toast
    // (feed / reply / daily-moment / report menus) where an optimistic local
    // block is acceptable. For a surface that navigates away on a "blocked"
    // CONFIRMATION (OtherProfileView), use the async variant and gate the
    // confirmation on its Bool result — otherwise a failed write shows
    // "you won't see them anymore" and dismisses while the block didn't persist.
    func block(_ userId: String, handle: String? = nil) {
        Task { await block(userId, handle: handle) }
    }

    @discardableResult
    func block(_ userId: String, handle: String? = nil) async -> Bool {
        guard !userId.isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return false }

        // Telemetry — fired before the write so it's recorded even if the
        // network round-trip fails. The block is optimistic locally anyway,
        // so the user-perceived block has happened by this point.
        Telemetry.userBlocked()

        // 1. Optimistic local update. Capture prior membership so a failed write
        //    doesn't unblock a user whose earlier block genuinely persisted
        //    (double-tap, or blocked from another surface while this write is in
        //    flight). insertLocal hides the user immediately from every
        //    isBlocked-filtered surface, so the perceived block is instant even
        //    though the feed-strip broadcast waits for the write below.
        let wasBlocked = isBlocked(userId)
        insertLocal(userId)

        // 2. Persist to Firestore. Include the handle when the caller has it
        //    so the Settings "blocked users" list can show recognizable rows
        //    without a per-user lookup.
        // `blockedUid` duplicates the doc id (which is the blocked user's uid)
        // into a queryable field. S-2 (2026-06-16): the account-deletion cascade
        // needs a collectionGroup("blocked").where("blockedUid"==deletedUid)
        // query to clean up everyone ELSE's block entries pointing at a deleted
        // user — a doc id alone isn't collectionGroup-queryable. firestore.rules
        // pins blockedUid == the doc id so it can't point at a third party.
        var data: [String: Any] = [
            "blockedAt": FieldValue.serverTimestamp(),
            "blockedUid": userId
        ]
        if let handle = handle, !handle.isEmpty {
            data["handle"] = handle
        }
        let docRef = Firestore.firestore()
            .collection("users").document(uid)
            .collection("blocked").document(userId)

        // Offline / dead-connection handling: setData's continuation resumes
        // only on SERVER ack, which never arrives offline — but with disk
        // persistence (the iOS default; nothing in this app overrides
        // cacheSettings) the write is durably queued and syncs on reconnect,
        // even across a relaunch. Waiting for the ack therefore meant an
        // offline block closed its confirm dialog with zero feedback: no feed
        // strip, no toast, the author's posts still on screen. Queued IS
        // durable here, so broadcast immediately when offline; the timeout
        // race below catches the stale-isConnected case the same way. A real
        // failure (permission-denied) still returns promptly through the
        // error path online.
        if !NetworkMonitor.shared.isConnected {
            docRef.setData(data) { error in
                if let error = error { print("⚠️ BlockedUsersCache.block (queued offline) failed: \(error)") }
            }
            postUserBlockedBroadcast(userId: userId, handle: handle)
            return true
        }

        let writeTask = Task { try await docRef.setData(data) }
        let outcome = await withTaskGroup(of: Result<Void, Error>?.self) { group -> Result<Void, Error>? in
            group.addTask { do { try await writeTask.value; return .success(()) } catch { return .failure(error) } }
            group.addTask { try? await Task.sleep(nanoseconds: 8_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        switch outcome {
        case .success, .none:
            // .none = timed out waiting for the ack (connection flaky enough
            // that NWPathMonitor hasn't noticed). The write stays queued in
            // the persistent cache exactly like the offline branch — treat as
            // durable rather than leaving the user with no feedback.
            //
            // Broadcast AFTER the write commits (or is durably queued) — so a
            // failed block can't strip the feed / flash a "blocked · undo"
            // toast while the caller (e.g. OtherProfileView) shows a
            // "couldn't block" error. This strips already-loaded
            // FeedViewModel.posts and drives MainTabView's undo toast (the
            // fetch-time isBlocked filter doesn't touch loaded posts).
            postUserBlockedBroadcast(userId: userId, handle: handle)
            return true
        case .failure(let error):
            // 3. Revert if the write failed — but only if THIS call added the
            //    block; don't clear a block that already persisted.
            print("⚠️ BlockedUsersCache.block failed: \(error)")
            if !wasBlocked { removeLocal(userId) }
            return false
        }
    }

    private func postUserBlockedBroadcast(userId: String, handle: String?) {
        var userInfo: [String: Any] = ["userId": userId]
        if let handle = handle, !handle.isEmpty {
            userInfo["handle"] = handle
        }
        NotificationCenter.default.post(name: .userBlocked, object: nil, userInfo: userInfo)
    }

    /// Returns true on successful Firestore write, false if it failed (in
    /// which case the cache reverts its optimistic removal). Async so the
    /// caller — e.g. BlockedUsersListView — can revert its own local view
    /// state on failure instead of leaving the row removed in the UI while
    /// the cache silently reinserts behind it. Also silences the Swift 6
    /// "consider asynchronous alternative" warning that the callback-based
    /// DocumentReference.delete triggered.
    @discardableResult
    func unblock(_ userId: String) async -> Bool {
        guard !userId.isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return false }

        // 1. Optimistic local update.
        removeLocal(userId)

        // 2. Persist to Firestore. Offline: same queued-is-durable reasoning
        //    as block() above — the delete syncs on reconnect; awaiting an
        //    ack that can't arrive would hang the caller (BlockedUsersListView)
        //    forever with the row already optimistically removed.
        if !NetworkMonitor.shared.isConnected {
            Firestore.firestore()
                .collection("users").document(uid)
                .collection("blocked").document(userId)
                .delete { error in
                    if let error = error { print("⚠️ BlockedUsersCache.unblock (queued offline) failed: \(error)") }
                }
            return true
        }
        do {
            try await Firestore.firestore()
                .collection("users").document(uid)
                .collection("blocked").document(userId)
                .delete()
            return true
        } catch {
            // 3. Revert if the write failed.
            print("⚠️ BlockedUsersCache.unblock failed: \(error)")
            insertLocal(userId)
            return false
        }
    }
}
