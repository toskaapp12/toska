import Foundation
import UIKit
import FirebaseAuth
@preconcurrency import FirebaseFirestore

/// Shared service for post interactions (like, save, repost, notify).
/// Used by both FeedPostRow and PostDetailView to eliminate duplicated logic.
@MainActor
class PostInteractionManager {

    // MARK: - Like

    struct LikeResult {
        let isLiked: Bool
        let newCount: Int
    }

    @MainActor
    static func toggleLike(
        postId: String,
        authorId: String,
        currentlyLiked: Bool,
        currentCount: Int,
        onUpdate: @escaping (LikeResult) -> Void
    ) {
        // FIX #2: Guard auth BEFORE optimistic update — session expiry means
        // we can't roll back, so don't show the update at all if auth is gone.
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else {
                    if Auth.auth().currentUser == nil {
                        ContentView.postAuthSessionExpired()
                    }
                    onUpdate(LikeResult(isLiked: currentlyLiked, newCount: currentCount))
                    return
                }
        // F-P2-1: no self-like — rules deny the create (mirrors the repost
        // own_post guard). Unlike direction stays allowed so a legacy
        // self-like can still be removed.
        if !currentlyLiked, !authorId.isEmpty, authorId == uid { return }
        if let last = RateLimiter.shared.lastLikeTime(for: postId), Date().timeIntervalSince(last) < 0.8 { return }
               // In-flight guard: rejects re-entry while a previous toggle's
               // transaction is still running. The 0.8s rate limit catches
               // fast double-taps, but a slow transaction (network latency,
               // contended write) can run longer than 0.8s and let a second
               // tap fire while the first is mid-commit — both optimistic
               // updates land, both rollbacks race, the UI thrashes. The
               // server is still consistent (transactions dedupe via the
               // existing-like-doc check), but the user sees the heart
               // toggle twice. Marking in-flight here and clearing in the
               // completion handler closes the window cleanly.
               guard !RateLimiter.shared.isLikeInFlight(postId) else { return }
               guard NetworkMonitor.shared.isConnected else {
                   print("⚠️ toggleLike — offline, skipping")
                   return
               }
               // Record the rate-limit timestamp on attempt rather than on
               // success. Previously this was set inside the transaction's
               // success branch, which left a window where a second tap
               // within 0.8s of the first could pass the gate (because
               // lastLikeTime was still nil/stale). The transaction's
               // own dedup check still prevents double-likes server-side,
               // but the local UI was firing two optimistic updates and
               // two rollbacks per double-tap. Setting the timestamp now
               // bounds the rate to 1 attempt per 0.8s per post regardless
               // of outcome — cleaner UI, same server guarantee.
               RateLimiter.shared.recordLike(for: postId)
               RateLimiter.shared.markLikeInFlight(postId)
               UIImpactFeedbackGenerator(style: .light).impactOccurred()
               Telemetry.likeTapped()

        let db = Firestore.firestore()
        let likeRef = db.collection("posts").document(postId).collection("likes").document(uid)
        let userLikedRef = db.collection("users").document(uid).collection("liked").document(postId)
            let newLiked = !currentlyLiked
        let newCount = max(0, currentCount + (newLiked ? 1 : -1))

        // Optimistic update
        onUpdate(LikeResult(isLiked: newLiked, newCount: newCount))

        NotificationCenter.default.post(
                  name: .postInteractionChanged,
                  object: nil,
                  userInfo: ["postId": postId, "action": "like", "value": newLiked]
              )

        db.runTransaction({ transaction, errorPointer in
            // Read the like doc inside the transaction to prevent duplicate
            // likes from two devices.
            let existingLike: DocumentSnapshot
            do { existingLike = try transaction.getDocument(likeRef) }
            catch let e as NSError { errorPointer?.pointee = e; return nil }

            if newLiked {
                // Already liked (e.g. from another device) — no-op. Return a
                // marker (mirrors repostReply) so the completion skips the
                // notification: re-sending overwrites the deterministic
                // notification doc with isRead:false, flipping the author's
                // already-read notification back to unread.
                if existingLike.exists { return true }

                transaction.setData(["createdAt": FieldValue.serverTimestamp()], forDocument: likeRef)
                transaction.setData(["createdAt": FieldValue.serverTimestamp()], forDocument: userLikedRef)
                // Counter update handled by Cloud Function on like doc create.
            } else {
                // Always clean up the user-facing liked record.
                transaction.deleteDocument(userLikedRef)

                if existingLike.exists {
                    // Like doc exists — delete it. Cloud Function handles counter.
                    transaction.deleteDocument(likeRef)
                }
            }

            return nil
        }, completion: { object, error in
            Task { @MainActor in
                // Always clear the in-flight marker, regardless of success
                // or failure, so a later legitimate tap can re-enter.
                RateLimiter.shared.markLikeComplete(postId)
                if let error = error {
                    // Roll back optimistic update.
                    onUpdate(LikeResult(isLiked: currentlyLiked, newCount: currentCount))
                    NotificationCenter.default.post(
                                         name: .postInteractionChanged,
                                         object: nil,
                                         userInfo: ["postId": postId, "action": "like", "value": currentlyLiked]
                                     )
                    print("⚠️ toggleLike transaction failed: \(error)")
                } else {
                    // Rate-limit timestamp is now set on attempt (above), not
                    // here on success — keeps double-tap behaviour consistent
                    // whether the transaction succeeds, fails, or hits a
                    // dedup no-op.

                    // totalLikes counter update handled by Cloud Function.
                    // Skip the notification when the transaction no-opped on an
                    // already-existing like (see the marker above).
                    let wasNoOp = (object as? Bool) == true
                    if !wasNoOp, !authorId.isEmpty, authorId != uid {
                        if newLiked {
                            sendNotification(postId: postId, toUserId: authorId, type: "like", message: "")
                        }
                    }
                }
            }
        })
    }

    // MARK: - Save

    @MainActor
    static func toggleSave(
        postId: String,
        authorId: String,
        currentlySaved: Bool,
        onUpdate: @escaping (Bool) -> Void
    ) {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else {
                    if Auth.auth().currentUser == nil {
                        ContentView.postAuthSessionExpired()
                    }
                    return
                }
        if let last = RateLimiter.shared.lastSaveTime(for: postId), Date().timeIntervalSince(last) < 1 { return }
                guard NetworkMonitor.shared.isConnected else {
                    print("⚠️ toggleSave — offline, skipping")
                    return
                }
                // In-flight guard (parity with toggleLike): the 1s rate window
                // can't stop a save→unsave interleave slower than the window —
                // the second toggle reads the not-yet-committed doc and no-ops,
                // leaving server and UI disagreeing. Serialize on the post id.
                guard !RateLimiter.shared.isSaveInFlight(postId) else { return }
                // Record on attempt, not success — same rationale as
                // toggleLike. With a 1-second gate, this also serializes
                // the save↔unsave order: a rapid save→unsave→save sequence
                // can't reach the third tap until the first two have at
                // least started, which keeps Firestore writes from
                // arriving out of order and leaving the user in the
                // opposite state from what they intended.
                RateLimiter.shared.recordSave(for: postId)
                RateLimiter.shared.markSaveInFlight(postId)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let db = Firestore.firestore()
        let saveRef = db.collection("users").document(uid).collection("saved").document(postId)
        let newSaved = !currentlySaved

        // Optimistic update
        onUpdate(newSaved)

        NotificationCenter.default.post(
                    name: .postInteractionChanged,
                    object: nil,
                    userInfo: ["postId": postId, "action": "save", "value": newSaved]
                )
        // Transactional toggle. The previous shape used independent delete or
        // setData calls — Firestore doesn't guarantee write order across
        // independent operations, so a fast save→unsave→save sequence
        // (each tap separated by < the rate-limit gate's window resolution)
        // could land out of order and end with the post in the opposite
        // state from what the user intended. Wrapping in a transaction
        // reads the live state inside the transaction and applies the
        // toggle relative to that, so concurrent retries always converge
        // to the user's most recent intent.
        db.runTransaction({ transaction, errorPointer in
            let existing: DocumentSnapshot
            do { existing = try transaction.getDocument(saveRef) }
            catch let e as NSError {
                errorPointer?.pointee = e
                return nil
            }
            if newSaved {
                if !existing.exists {
                    transaction.setData(
                        ["createdAt": FieldValue.serverTimestamp()],
                        forDocument: saveRef
                    )
                }
            } else {
                if existing.exists {
                    transaction.deleteDocument(saveRef)
                }
            }
            return nil
        }, completion: { _, error in
            Task { @MainActor in
                RateLimiter.shared.markSaveComplete(postId)
                if let error = error {
                    print("⚠️ toggleSave transaction failed: \(error)")
                    // Roll back optimistic update.
                    onUpdate(currentlySaved)
                    NotificationCenter.default.post(
                        name: .postInteractionChanged,
                        object: nil,
                        userInfo: ["postId": postId, "action": "save", "value": currentlySaved]
                    )
                    return
                }
                if newSaved, !authorId.isEmpty, authorId != uid {
                    sendNotification(postId: postId, toUserId: authorId, type: "save", message: "")
                }
            }
        })
    }

    // MARK: - Repost

    struct RepostResult {
        let isReposted: Bool
        let newCount: Int
    }

    @MainActor
    static func repost(
        postId: String,
        postText: String,
        postTag: String?,
        authorId: String,
        originalHandle: String,
        currentCount: Int,
        onUpdate: @escaping (RepostResult) -> Void
    ) {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else {
                    if Auth.auth().currentUser == nil {
                        ContentView.postAuthSessionExpired()
                    }
                    return
                }
        if let last = RateLimiter.shared.lastRepostTime(for: postId), Date().timeIntervalSince(last) < 2 { return }
        guard uid != authorId else { return }
               guard NetworkMonitor.shared.isConnected else {
                   print("⚠️ repost — offline, skipping")
                   return
               }
               // Record on attempt — same rationale as toggleLike/toggleSave.
               // 2-second gate is enough to let the dedup-check round-trip
               // settle before a second tap can land, so we don't fire two
               // optimistic increments per rapid double-tap on the same post.
               RateLimiter.shared.recordRepost(for: postId)
               // In-flight guard: the optimistic +1 only fires after two network
               // round-trips (dedup query + post fetch), so a second tap arriving
               // slower than the 2s rate window would otherwise re-enter and stack
               // a second +1. Serialize on the shared repost key (same one unrepost
               // uses) and clear it on EVERY exit below.
               guard !RateLimiter.shared.isRepostInFlight(postId) else { return }
               RateLimiter.shared.markRepostInFlight(postId)

               let db = Firestore.firestore()

               db.collection("posts")
            .whereField("authorId", isEqualTo: uid)
            .whereField("isRepost", isEqualTo: true)
            .whereField("originalPostId", isEqualTo: postId)
            .limit(to: 1)
            .getDocuments { existingSnap, error in
                Task { @MainActor in
                    // FIX #5: The original condition was `error != nil && existingSnap == nil`.
                    // When offline, Firestore can return a non-nil stale snapshot AND a
                    // non-nil error simultaneously — the old condition lets the duplicate
                    // check pass with stale cached data. Correct check: any error → fail safe.
                    if let error = error {
                        print("⚠️ repost dedup check failed: \(error)")
                        RateLimiter.shared.markRepostComplete(postId)
                        onUpdate(RepostResult(isReposted: false, newCount: currentCount))
                        return
                    }
                    if let docs = existingSnap?.documents, !docs.isEmpty {
                        // Already reposted — reflect that in the UI.
                        RateLimiter.shared.markRepostComplete(postId)
                        onUpdate(RepostResult(isReposted: true, newCount: currentCount))
                        return
                    }

                    // FIX #6: Original code discarded the error on this getDocument call.
                    // If this fails (post deleted, network error), snapshot?.data() is nil
                    // and the function returned silently — but the optimistic update at line
                    // below had already been issued. Now the optimistic update only fires
                    // AFTER we confirm the post exists and is not itself a repost.
                    Task { @MainActor in
                        let snapshot: DocumentSnapshot?
                        do {
                            snapshot = try await db.collection("posts").document(postId).getDocumentAsync()
                        } catch {
                            print("⚠️ repost post fetch failed: \(error)")
                            RateLimiter.shared.markRepostComplete(postId)
                            onUpdate(RepostResult(isReposted: false, newCount: currentCount))
                            return
                        }
                            guard let data = snapshot?.data() else {
                                // Post was deleted.
                                RateLimiter.shared.markRepostComplete(postId)
                                onUpdate(RepostResult(isReposted: false, newCount: currentCount))
                                return
                            }
                            if data["isRepost"] as? Bool == true {
                                // Cannot repost a repost — no change.
                                RateLimiter.shared.markRepostComplete(postId)
                                onUpdate(RepostResult(isReposted: false, newCount: currentCount))
                                return
                            }
                            if data["isWhisper"] as? Bool == true || data["isMidnightPost"] as? Bool == true {
                                // Ephemeral originals can't be reposted: the repost
                                // doc carries neither the whisper/midnight flags nor
                                // expiresAt, so it would outlive the original as a
                                // permanent, unbadged copy of content its author was
                                // promised disappears. Rules + validatePost enforce
                                // this server-side; bailing here keeps the button
                                // from flashing a doomed optimistic state.
                                RateLimiter.shared.markRepostComplete(postId)
                                onUpdate(RepostResult(isReposted: false, newCount: currentCount))
                                return
                            }

                            // Optimistic update — only issued after post existence confirmed.
                            onUpdate(RepostResult(isReposted: true, newCount: currentCount + 1))
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

                            // Broadcast to other surfaces rendering the same post so
                            // their repost button state flips without waiting for a
                            // refresh. Mirrors the like/save pattern above.
                            NotificationCenter.default.post(
                                name: .postInteractionChanged,
                                object: nil,
                                userInfo: ["postId": postId, "action": "repost", "value": true]
                            )

                            // Resolve handle — fall back to Firestore if the cache
                            // hasn't loaded yet. Otherwise a repost sends
                            // authorHandle: "anonymous" and the rules' authorHandle
                            // pin (firestore.rules) rejects the write, so reposts
                            // silently fail while normal posts (ComposeView, which
                            // already does this fallback) succeed.
                            var repostHandle = UserHandleCache.shared.handle
                            if repostHandle == "anonymous" {
                                let handleSnap = try? await db.collection("users").document(uid).getDocumentAsync()
                                repostHandle = handleSnap?.data()?["handle"] as? String ?? "anonymous"
                            }
                            // Mirror the original post's isShareable flag so the repost
                            // inherits the author's sharing setting. If the original
                            // author chose "don't allow sharing", the repost carries
                            // that forward — the share-card button stays hidden on
                            // the repost too. Previously reposts hardcoded
                            // `isShareable: true`, overriding the original author's
                            // intent in an anonymous/privacy-first app.
                            let originalIsShareable = data["isShareable"] as? Bool ?? true

                            // Build the repost from the FRESHLY-FETCHED original post
                            // (not the feed's cached params) so the create rule's repost
                            // pins always match by construction:
                            //   • text == original.text   (a stale/edited feed value would
                            //     fail the pin and roll the optimistic "reposted" state back)
                            //   • originalAuthorId == original.authorId
                            // 2026-06 repost fix — this was the green-then-grey failure.
                            let freshText = data["text"] as? String ?? postText
                            let freshAuthorId = data["authorId"] as? String ?? authorId

                            // originalHandle is byline-only and OPTIONAL in the rule
                            // (firestore.rules): when present it MUST equal the original
                            // AUTHOR's current user-doc handle. The post's stored
                            // authorHandle / the feed's param can be stale (author changed
                            // handle) or the author's user doc can be missing (e.g. seeded
                            // posts whose user docs weren't created) — either fails the
                            // get(users/…).handle pin and denies the whole write. Resolve
                            // the author's LIVE handle; if unavailable, OMIT the field so
                            // the repost still lands (just without an "originally by"
                            // byline) instead of being rejected.
                            var resolvedOriginalHandle: String? = nil
                            if !freshAuthorId.isEmpty,
                               let authorSnap = try? await db.collection("users").document(freshAuthorId).getDocumentAsync(),
                               let liveHandle = authorSnap.data()?["handle"] as? String,
                               !liveHandle.isEmpty {
                                resolvedOriginalHandle = liveHandle
                            }

                            var repostData: [String: Any] = [
                                "authorId": uid,
                                "authorHandle": repostHandle,
                                "text": freshText,
                                "likeCount": 0,
                                "repostCount": 0,
                                "replyCount": 0,
                                "isShareable": originalIsShareable,
                                "isRepost": true,
                                "originalPostId": postId,
                                "originalAuthorId": freshAuthorId,
                                "createdAt": FieldValue.serverTimestamp(),
                                // Start hidden until validatePost verifies the
                                // repost and promotes it to "live" (2026-06-01
                                // audit) — same as ComposeView.postNow.
                                "moderationStatus": "pending_validation"
                            ]
                            if let h = resolvedOriginalHandle { repostData["originalHandle"] = h }
                            if let tag = postTag { repostData["tag"] = tag }

                            // FIX #7 + #8: The original code used addDocument() followed
                            // by a separate runTransaction() for repostCount. A crash or
                            // network drop between them left the repost doc written but
                            // the original post's repostCount un-incremented (permanent
                            // drift). Worse, the transaction used try? on getDocument,
                            // meaning a read failure silently zeroed current → repostCount
                            // was set to 1 regardless of actual value.
                            //
                            // Fix: Use a single transaction that atomically writes the
                            // repost doc AND increments repostCount. The new repost doc
                            // gets a deterministic ID (uid_postId) so the transaction is
                            // safe to retry — duplicate retries are idempotent because
                            // setData on the same docId is a no-op if data is identical.
                            let newRepostRef = db.collection("posts")
                                .document("\(uid)_repost_\(postId)")

                            let postRef = db.collection("posts").document(postId)

                            db.runTransaction({ transaction, errorPointer in
                                let postSnap: DocumentSnapshot
                                do { postSnap = try transaction.getDocument(postRef) }
                                catch let e as NSError {
                                    errorPointer?.pointee = e
                                    return nil
                                }

                                guard postSnap.exists else {
                                    errorPointer?.pointee = NSError(
                                        domain: "PostInteractionManager",
                                        code: 404,
                                        userInfo: [NSLocalizedDescriptionKey: "Post no longer exists"]
                                    )
                                    return nil
                                }

                                // Check for existing repost doc inside the transaction
                                // (dedup safety net on top of the pre-check above).
                                let existingRepost: DocumentSnapshot
                                do { existingRepost = try transaction.getDocument(newRepostRef) }
                                catch let e as NSError {
                                    errorPointer?.pointee = e
                                    return nil
                                }
                                if existingRepost.exists {
                                    // Already reposted — idempotent, no-op.
                                    return nil
                                }

                                // Write the repost doc. Counter update handled by Cloud Function
                                // on post create (isRepost == true triggers repostCount increment).
                                transaction.setData(repostData, forDocument: newRepostRef)
                                return nil

                            }, completion: { _, txError in
                                Task { @MainActor in
                                    RateLimiter.shared.markRepostComplete(postId)
                                    if let txError = txError {
                                        print("⚠️ repost transaction failed: \(txError)")
                                        // Roll back the optimistic update (locally and
                                        // across other surfaces that mirrored it).
                                        onUpdate(RepostResult(isReposted: false, newCount: currentCount))
                                        NotificationCenter.default.post(
                                            name: .postInteractionChanged,
                                            object: nil,
                                            userInfo: ["postId": postId, "action": "repost", "value": false]
                                        )
                                        return
                                    }
                                    // Atomic write succeeded. Rate-limit timestamp
                                    // is set on attempt (above), not here.
                                    if !authorId.isEmpty, authorId != uid {
                                        sendNotification(
                                            postId: postId,
                                            toUserId: authorId,
                                            type: "repost",
                                            message: ""
                                        )
                                    }
                                    // Refresh the feed so the repost shows up in real time —
                                    // but flagged isRepost:true so FeedView updates IN PLACE and
                                    // does NOT scroll to the top (that scroll is only for a
                                    // freshly composed post).
                                    NotificationCenter.default.post(
                                        name: .newPostCreated,
                                        object: nil,
                                        userInfo: ["isRepost": true]
                                    )
                                }
                            })
                    }
                }
            }
    }

    // MARK: - Un-repost (undo a repost)

    /// Deletes the caller's repost of `postId`. The repost doc has a deterministic
    /// id (`{uid}_repost_{postId}`) set by repost(); deleting it both removes it
    /// from the feed and fires onRepostDeletedUpdateCount server-side, which
    /// decrements the original post's repostCount. Optimistic: flips the UI to
    /// not-reposted + decrements immediately, rolls back on failure.
    @MainActor
    static func unrepost(
        postId: String,
        currentCount: Int,
        onUpdate: @escaping (RepostResult) -> Void
    ) {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else {
            if Auth.auth().currentUser == nil { ContentView.postAuthSessionExpired() }
            return
        }
        guard NetworkMonitor.shared.isConnected else {
            print("⚠️ unrepost — offline, skipping")
            return
        }
        // Serialize against a concurrent repost/unrepost on the same post so a
        // double-tap can't fire two optimistic decrements (count drift).
        guard !RateLimiter.shared.isRepostInFlight(postId) else { return }
        RateLimiter.shared.markRepostInFlight(postId)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // Optimistic: flip off + decrement, and broadcast so other surfaces match.
        onUpdate(RepostResult(isReposted: false, newCount: max(0, currentCount - 1)))
        NotificationCenter.default.post(
            name: .postInteractionChanged,
            object: nil,
            userInfo: ["postId": postId, "action": "repost", "value": false]
        )

        let db = Firestore.firestore()

        func rollback(_ error: Error?) {
            Task { @MainActor in
                RateLimiter.shared.markRepostComplete(postId)
                print("⚠️ unrepost failed: \(String(describing: error))")
                onUpdate(RepostResult(isReposted: true, newCount: currentCount))
                NotificationCenter.default.post(
                    name: .postInteractionChanged, object: nil,
                    userInfo: ["postId": postId, "action": "repost", "value": true]
                )
            }
        }

        // Find the caller's actual repost doc by query rather than assuming the
        // deterministic id — LEGACY reposts were created with random addDocument()
        // ids, so deleting "{uid}_repost_{postId}" would no-op (Firestore returns
        // success on a missing doc), leaving the repost in place + the count drifted
        // and the row un-undoable. Query authorId+isRepost+originalPostId, delete
        // whatever matches; fall back to the deterministic id only if none found.
        db.collection("posts")
            .whereField("authorId", isEqualTo: uid)
            .whereField("isRepost", isEqualTo: true)
            .whereField("originalPostId", isEqualTo: postId)
            .getDocuments { snap, qErr in
                if let qErr = qErr { rollback(qErr); return }
                let docs = snap?.documents ?? []
                let refs = docs.isEmpty
                    ? [db.collection("posts").document("\(uid)_repost_\(postId)")]
                    : docs.map { $0.reference }
                let group = DispatchGroup()
                var firstErr: Error?
                for ref in refs {
                    group.enter()
                    ref.delete { e in if firstErr == nil { firstErr = e }; group.leave() }
                }
                group.notify(queue: .main) {
                    RateLimiter.shared.markRepostComplete(postId)
                    if let e = firstErr { rollback(e); return }
                    // Success. Server repostCount decrement handled by
                    // onRepostDeletedUpdateCount — but it fires once PER deleted
                    // doc. We optimistically decremented by exactly 1, so if more
                    // than one repost doc matched (legacy random-id + the
                    // deterministic id), the server drops by N while the UI dropped
                    // by 1. Show the best estimate immediately, then reconcile to
                    // the AUTHORITATIVE server state once the counter CF settles —
                    // that read is the source of truth, so it corrects any drift
                    // (including from a stale base) for any number of matched docs.
                    if refs.count > 1 {
                        onUpdate(RepostResult(isReposted: false, newCount: max(0, currentCount - refs.count)))
                        Self.reconcileRepostState(postId: postId, uid: uid, afterSeconds: 3, onUpdate: onUpdate)
                    }
                }
            }
    }

    /// After the delete-triggered counter Cloud Function settles, read the
    /// AUTHORITATIVE repostCount for the post AND whether the caller's repost doc
    /// still exists, then push both truths to the UI. Used to converge the count
    /// after a multi-doc (legacy-dupe) unrepost without guessing from a possibly-
    /// stale base — and it re-derives isReposted from actual doc existence, so it
    /// stays correct even if the user re-reposted in the interim.
    private static func reconcileRepostState(
        postId: String, uid: String, afterSeconds: Double,
        onUpdate: @escaping (RepostResult) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + afterSeconds) {
            // Bail if the account switched during the delay — otherwise this
            // pushes account A's reconciled repost state into account B's UI.
            guard Auth.auth().currentUser?.uid == uid else { return }
            let db = Firestore.firestore()
            db.collection("posts").document(postId).getDocument { snap, _ in
                guard let count = snap?.data()?["repostCount"] as? Int else { return }
                db.collection("posts")
                    .whereField("authorId", isEqualTo: uid)
                    .whereField("isRepost", isEqualTo: true)
                    .whereField("originalPostId", isEqualTo: postId)
                    .limit(to: 1)
                    .getDocuments { rsnap, _ in
                        let stillReposted = !(rsnap?.documents.isEmpty ?? true)
                        Task { @MainActor in
                            // Re-check again after the async reads.
                            guard Auth.auth().currentUser?.uid == uid else { return }
                            onUpdate(RepostResult(isReposted: stillReposted, newCount: max(0, count)))
                        }
                    }
            }
        }
    }

    // MARK: - Notification

    @MainActor
    static func sendNotification(postId: String, toUserId: String, type: String, message: String) {
        guard !toUserId.isEmpty else { return }
        guard let uid = Auth.auth().currentUser?.uid, uid != toUserId else { return }
        let notifHandle = UserHandleCache.shared.handle
        let docId: String
        if postId.isEmpty {
            let minuteBucket = Int(Date().timeIntervalSince1970 / 60)
            docId = "\(type)_\(uid)_\(minuteBucket)"
        } else {
            docId = "\(type)_\(postId)_\(uid)"
        }

        // `message` is intentionally NOT written here. The notification create
        // rule no longer accepts the field — the previous shape let any
        // authenticated user plant arbitrary 200-char text into a victim's
        // NotificationsView (the rule allows reply-type notifications without
        // requiring a real reply doc to exist), bypassing validateReply
        // moderation. The Cloud Function `enrichReplyNotification` now
        // backfills `message` via Admin SDK after looking up the actual reply
        // doc, or deletes the notification if no real reply exists.
        // NotificationsView's empty-message branch ("\(handle) replied to your
        // post") is what renders in the brief window before the backfill
        // listener-snapshot lands. The `message` parameter is kept on this
        // helper for callsite stability but ignored. Remove on next signature
        // bump if it's still unused.
        _ = message

        Firestore.firestore().collection("users").document(toUserId)
            .collection("notifications").document(docId).setData([
                "type": type, "fromHandle": notifHandle, "fromUserId": uid,
                "postId": postId, "isRead": false,
                "createdAt": FieldValue.serverTimestamp()
            ], merge: false) { error in
                // Without this completion handler the previous shape silently
                // dropped permission-denied / quota / rules-rejection errors.
                // The recipient never got the notification, the actor saw no
                // feedback, and there was no log trail to diagnose later.
                // Telemetry routes to Crashlytics so persistent failures
                // (e.g. a rules regression that denies notification creates)
                // surface in production instead of vanishing.
                if let error = error {
                    print("⚠️ sendNotification(\(type)) failed: \(error.localizedDescription)")
                    Telemetry.recordError(error, context: "PostInteractionManager.sendNotification.\(type)")
                }
            }
    }

    // MARK: - Reply Like
    //
    // Full parity with toggleLike but targets a reply. Writes the like
    // doc at posts/{postId}/replies/{replyId}/likes/{uid} (counter handled
    // by onReplyLikeCreatedUpdateCount Cloud Function) AND a reverse-
    // index entry at users/{uid}/likedReplies/{replyId} so the iOS side
    // can bulk-check "did I like these replies?" without N per-reply
    // gets. Transactional so a rapid like→unlike→like sequence converges
    // to the latest intent. No notification on reply-like for v1.0 — the
    // reply author sees the count update next time they revisit the post.
    @MainActor
    static func toggleReplyLike(
        postId: String,
        replyId: String,
        replyText: String,
        replyHandle: String,
        replyAuthorId: String,
        currentlyLiked: Bool,
        currentCount: Int,
        onUpdate: @escaping (LikeResult) -> Void
    ) {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty, !replyId.isEmpty else {
            if Auth.auth().currentUser == nil { ContentView.postAuthSessionExpired() }
            onUpdate(LikeResult(isLiked: currentlyLiked, newCount: currentCount))
            return
        }
        guard NetworkMonitor.shared.isConnected else {
            print("⚠️ toggleReplyLike — offline, skipping")
            return
        }
        // F-P2-1: no self-like on your own reply — mirrors toggleLike; the
        // rules guard targets the REPLY author. Unlike stays allowed.
        if !currentlyLiked, !replyAuthorId.isEmpty, replyAuthorId == uid { return }
        // Rate-limit + in-flight guard, mirroring toggleLike: without it, rapid
        // taps on a reply heart fire N transactions and N CF counter updates and
        // thrash the optimistic count. Keyed per-reply with a "reply_" prefix so
        // it can't collide with the post-like keyspace.
        let rlKey = "reply_\(replyId)"
        if let last = RateLimiter.shared.lastLikeTime(for: rlKey), Date().timeIntervalSince(last) < 0.8 { return }
        guard !RateLimiter.shared.isLikeInFlight(rlKey) else { return }
        RateLimiter.shared.recordLike(for: rlKey)
        RateLimiter.shared.markLikeInFlight(rlKey)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let db = Firestore.firestore()
        let likeRef = db.collection("posts").document(postId)
            .collection("replies").document(replyId)
            .collection("likes").document(uid)
        let userLikedReplyRef = db.collection("users").document(uid)
            .collection("likedReplies").document(replyId)
        let newLiked = !currentlyLiked
        let newCount = max(0, currentCount + (newLiked ? 1 : -1))

        // Save-time snapshot of the reply's text + handle so ProfileView's
        // "liked" tab can render the row without re-fetching the reply doc.
        // Same trade-off as toggleReplySave — stale on reply edit, acceptable
        // for v1.0. The tap path fetches fresh parent-post data so the
        // thread view always reflects current state.
        var likedReplyPayload: [String: Any] = [
            "postId": postId,
            "replyText": replyText,
            "replyHandle": replyHandle,
            "createdAt": FieldValue.serverTimestamp()
        ]
        // MED-P3-1: snapshot the reply author's uid so the "liked" tab can drop
        // this row once the owner blocks that author (the block promise covers
        // replies too). Owner-only doc; rules allow the optional field.
        if !replyAuthorId.isEmpty { likedReplyPayload["authorId"] = replyAuthorId }

        // Optimistic update
        onUpdate(LikeResult(isLiked: newLiked, newCount: newCount))

        db.runTransaction({ transaction, errorPointer in
            let existing: DocumentSnapshot
            do { existing = try transaction.getDocument(likeRef) }
            catch let e as NSError { errorPointer?.pointee = e; return nil }

            if newLiked {
                if existing.exists { return nil }
                transaction.setData(
                    ["createdAt": FieldValue.serverTimestamp()],
                    forDocument: likeRef
                )
                transaction.setData(likedReplyPayload, forDocument: userLikedReplyRef)
            } else {
                transaction.deleteDocument(userLikedReplyRef)
                if existing.exists {
                    transaction.deleteDocument(likeRef)
                }
            }
            return nil
        }, completion: { _, error in
            Task { @MainActor in
                RateLimiter.shared.markLikeComplete(rlKey)
                if let error = error {
                    onUpdate(LikeResult(isLiked: currentlyLiked, newCount: currentCount))
                    print("⚠️ toggleReplyLike transaction failed: \(error)")
                }
            }
        })
        // Notification of reply author on like: intentionally deferred to
        // v1.1. Mirroring toggleLike's notification surface here would
        // require a new push-payload type ("reply_like") and a deep-link
        // through PostDetailView; out of scope for the v1.0 submit batch.
        _ = replyAuthorId
    }

    // MARK: - Reply Save
    //
    // Mirrors toggleSave for replies. Saved entries live at
    // users/{uid}/savedReplies/{replyId} with a `postId` field so the
    // ProfileView "saved" tab can navigate back to the parent post
    // when the user taps a saved-reply row. No server-side counter
    // (saves are per-user, not aggregated). Transactional so concurrent
    // save↔unsave on the same reply converges.
    @MainActor
    static func toggleReplySave(
        postId: String,
        replyId: String,
        replyText: String,
        replyHandle: String,
        replyAuthorId: String = "",
        currentlySaved: Bool,
        onUpdate: @escaping (Bool) -> Void
    ) {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty, !replyId.isEmpty else {
            if Auth.auth().currentUser == nil { ContentView.postAuthSessionExpired() }
            return
        }
        guard NetworkMonitor.shared.isConnected else {
            print("⚠️ toggleReplySave — offline, skipping")
            return
        }
        // Rate-limit + in-flight guard (previously toggleReplySave had NEITHER,
        // so rapid taps fired N unthrottled transactions and a save→unsave
        // interleave could leave the bookmark opposite the server). Keyed
        // "reply_{id}" so it never collides with post-save state.
        let rlKey = "reply_\(replyId)"
        if let last = RateLimiter.shared.lastSaveTime(for: rlKey), Date().timeIntervalSince(last) < 1 { return }
        guard !RateLimiter.shared.isSaveInFlight(rlKey) else { return }
        RateLimiter.shared.recordSave(for: rlKey)
        RateLimiter.shared.markSaveInFlight(rlKey)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let db = Firestore.firestore()
        let saveRef = db.collection("users").document(uid)
            .collection("savedReplies").document(replyId)
        let newSaved = !currentlySaved

        // Optimistic update
        onUpdate(newSaved)

        // Save-time snapshot of the reply's text + handle so the saved
        // tab in ProfileView can render the row without re-fetching the
        // reply doc. Stale-on-edit is an accepted trade-off for v1.0 —
        // the alternative (fetch the reply on every saved-tab load) is
        // ~N extra reads per visit and reply text edits are rare.
        var savePayload: [String: Any] = [
            "postId": postId,
            "replyText": replyText,
            "replyHandle": replyHandle,
            "createdAt": FieldValue.serverTimestamp()
        ]
        // MED-P3-1: snapshot the reply author's uid so the "saved" tab can drop
        // this row once the owner blocks that author. Owner-only; optional.
        if !replyAuthorId.isEmpty { savePayload["authorId"] = replyAuthorId }

        db.runTransaction({ transaction, errorPointer in
            let existing: DocumentSnapshot
            do { existing = try transaction.getDocument(saveRef) }
            catch let e as NSError { errorPointer?.pointee = e; return nil }

            if newSaved {
                if !existing.exists {
                    transaction.setData(savePayload, forDocument: saveRef)
                }
            } else {
                if existing.exists {
                    transaction.deleteDocument(saveRef)
                }
            }
            return nil
        }, completion: { _, error in
            Task { @MainActor in
                RateLimiter.shared.markSaveComplete(rlKey)
                if let error = error {
                    print("⚠️ toggleReplySave transaction failed: \(error)")
                    onUpdate(currentlySaved)
                }
            }
        })
    }

    // MARK: - Reply Repost
    //
    // Repost a reply by creating a new top-level POST with isRepost: true
    // and originalReplyId: <replyId>. The new post inherits the reply's
    // text + attribution; validatePost (Cloud Function) verifies the
    // reply still exists and text matches, and onReplyRepostCreatedUpdateCount
    // bumps the reply's repostCount. The new post's deterministic doc id
    // (uid_replyrepost_replyId) makes the transaction retry-safe — duplicate
    // retries are idempotent because setData on the same docId with the
    // same data is a no-op. No reposting your own reply.
    @MainActor
    static func repostReply(
        postId: String,
        replyId: String,
        replyText: String,
        replyAuthorId: String,
        replyAuthorHandle: String,
        currentCount: Int,
        onUpdate: @escaping (RepostResult) -> Void
    ) {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty, !replyId.isEmpty else {
            if Auth.auth().currentUser == nil { ContentView.postAuthSessionExpired() }
            return
        }
        guard uid != replyAuthorId else { return }
        guard NetworkMonitor.shared.isConnected else {
            print("⚠️ repostReply — offline, skipping")
            return
        }
        // Rate-limit on the reply id (mirrors repost()). Without this gate,
        // repostReply fired an optimistic +1 on every tap, so a rapid double-tap
        // stacked two increments while the server wrote once — inflating the
        // reply's repost count by one until refresh.
        if let last = RateLimiter.shared.lastRepostTime(for: replyId), Date().timeIntervalSince(last) < 2 { return }
        // In-flight guard (shared key with unrepostReply) so a write slower than
        // the 2s rate window can't let a second optimistic +1 land while the first
        // transaction is still open.
        let flightKey = "reply_\(replyId)"
        guard !RateLimiter.shared.isRepostInFlight(flightKey) else { return }
        RateLimiter.shared.markRepostInFlight(flightKey)
        RateLimiter.shared.recordRepost(for: replyId)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let db = Firestore.firestore()
        Task { @MainActor in
            // Resolve handle — fall back to Firestore if the cache hasn't loaded
            // yet, else the repost sends authorHandle: "anonymous" and the rules'
            // authorHandle pin rejects the write (mirrors ComposeView / repost).
            var repostHandle = UserHandleCache.shared.handle
            if repostHandle == "anonymous" {
                let handleSnap = try? await db.collection("users").document(uid).getDocumentAsync()
                repostHandle = handleSnap?.data()?["handle"] as? String ?? "anonymous"
            }
            // Rebuild from the FRESH original reply so the rule's reply-repost
            // pins (text == reply.text, originalAuthorId == reply.authorId) match
            // by construction, and resolve the reply author's LIVE handle for the
            // optional originalHandle byline pin — omit it if the author's user
            // doc is missing/handle-less so the repost still lands instead of
            // being denied. Same 2026-06 fix as post reposts.
            let replyRef = db.collection("posts").document(postId)
                .collection("replies").document(replyId)
            let replySnap = try? await replyRef.getDocumentAsync()
            let freshReplyText = replySnap?.data()?["text"] as? String ?? replyText
            let freshReplyAuthorId = replySnap?.data()?["authorId"] as? String ?? replyAuthorId
            var resolvedReplyHandle: String? = nil
            if !freshReplyAuthorId.isEmpty,
               let authorSnap = try? await db.collection("users").document(freshReplyAuthorId).getDocumentAsync(),
               let liveHandle = authorSnap.data()?["handle"] as? String,
               !liveHandle.isEmpty {
                resolvedReplyHandle = liveHandle
            }

            let newRepostRef = db.collection("posts")
                .document("\(uid)_replyrepost_\(replyId)")

            var repostData: [String: Any] = [
                "authorId": uid,
                "authorHandle": repostHandle,
                "text": freshReplyText,
                "likeCount": 0,
                "repostCount": 0,
                "replyCount": 0,
                "isShareable": true,
                "isRepost": true,
                "originalPostId": postId,
                "originalReplyId": replyId,
                "originalAuthorId": freshReplyAuthorId,
                "createdAt": FieldValue.serverTimestamp()
            ]
            if let h = resolvedReplyHandle { repostData["originalHandle"] = h }

            // Optimistic update
            onUpdate(RepostResult(isReposted: true, newCount: currentCount + 1))

            db.runTransaction({ transaction, errorPointer in
                let existing: DocumentSnapshot
                do { existing = try transaction.getDocument(newRepostRef) }
                catch let e as NSError { errorPointer?.pointee = e; return nil }

                // Return whether this was an idempotent no-op (the repost already
                // existed) so the completion can undo the optimistic +1 — the
                // count already includes this repost, so leaving +1 drifts it up.
                if existing.exists { return true }
                transaction.setData(repostData, forDocument: newRepostRef)
                return false
            }, completion: { object, error in
                Task { @MainActor in
                    RateLimiter.shared.markRepostComplete(flightKey)
                    if let error = error {
                        print("⚠️ repostReply transaction failed: \(error)")
                        onUpdate(RepostResult(isReposted: false, newCount: currentCount))
                        return
                    }
                    // Already reposted (stamping missed it): keep it reposted but
                    // correct the count back to currentCount (mirrors repost()).
                    if let wasNoOp = object as? Bool, wasNoOp {
                        onUpdate(RepostResult(isReposted: true, newCount: currentCount))
                    }
                    // Counter increment + reply-author notification handled by
                    // Cloud Function (onReplyRepostCreatedUpdateCount). The
                    // notification surface for "your reply was reposted" is
                    // out-of-scope for v1.0 — falls through to the in-app
                    // count update on the parent post detail view next visit.
                    // Refresh the feed in real time, flagged isRepost so it updates
                    // in place without scrolling to the top (see repost()).
                    NotificationCenter.default.post(
                        name: .newPostCreated,
                        object: nil,
                        userInfo: ["isRepost": true]
                    )
                }
            })
        }
    }

    /// Undo a reply-repost. Deletes the deterministic doc
    /// (`{uid}_replyrepost_{replyId}`) set by repostReply(); the delete fires
    /// onReplyRepostDeletedUpdateCount server-side, which decrements the reply
    /// doc's repostCount. Optimistic flip + rollback on failure.
    @MainActor
    static func unrepostReply(
        replyId: String,
        currentCount: Int,
        onUpdate: @escaping (RepostResult) -> Void
    ) {
        guard let uid = Auth.auth().currentUser?.uid, !replyId.isEmpty else {
            if Auth.auth().currentUser == nil { ContentView.postAuthSessionExpired() }
            return
        }
        guard NetworkMonitor.shared.isConnected else {
            print("⚠️ unrepostReply — offline, skipping")
            return
        }
        // Serialize against a concurrent repost/unrepost on the same reply so a
        // double-tap can't fire two optimistic decrements (count drift). Keyed
        // "reply_<id>" so it shares the guard with repostReply below and can't
        // collide with the post-repost keyspace.
        let flightKey = "reply_\(replyId)"
        guard !RateLimiter.shared.isRepostInFlight(flightKey) else { return }
        RateLimiter.shared.markRepostInFlight(flightKey)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onUpdate(RepostResult(isReposted: false, newCount: max(0, currentCount - 1)))

        let db = Firestore.firestore()
        db.collection("posts").document("\(uid)_replyrepost_\(replyId)").delete { error in
            Task { @MainActor in
                RateLimiter.shared.markRepostComplete(flightKey)
                if let error = error {
                    print("⚠️ unrepostReply failed: \(error)")
                    onUpdate(RepostResult(isReposted: true, newCount: currentCount))
                }
            }
        }
    }
}
