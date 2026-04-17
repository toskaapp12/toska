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
        if let last = RateLimiter.shared.lastLikeTime, Date().timeIntervalSince(last) < 0.8 { return }
               guard NetworkMonitor.shared.isConnected else {
                   print("⚠️ toggleLike — offline, skipping")
                   return
               }
               UIImpactFeedbackGenerator(style: .light).impactOccurred()
               Telemetry.likeTapped()

        let db = Firestore.firestore()
        let likeRef = db.collection("posts").document(postId).collection("likes").document(uid)
        let userLikedRef = db.collection("users").document(uid).collection("liked").document(postId)
        let postRef = db.collection("posts").document(postId)

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
            let postSnap: DocumentSnapshot
            do {
                postSnap = try transaction.getDocument(postRef)
            } catch let error as NSError {
                errorPointer?.pointee = error
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

            let currentServerCount = postSnap.data()?["likeCount"] as? Int ?? 0

            if newLiked {
                // FIX #3 (like branch): Read likeRef inside transaction to prevent
                // duplicate likes from two devices both in the "like" state.
                let existingLike: DocumentSnapshot
                do { existingLike = try transaction.getDocument(likeRef) }
                catch let e as NSError { errorPointer?.pointee = e; return nil }

                // Already liked (e.g. from another device) — no-op, don't double-count.
                if existingLike.exists { return nil }

                transaction.setData(["createdAt": FieldValue.serverTimestamp()], forDocument: likeRef)
                transaction.setData(["createdAt": FieldValue.serverTimestamp()], forDocument: userLikedRef)
                transaction.updateData(["likeCount": currentServerCount + 1], forDocument: postRef)
            } else {
                // FIX #3 (unlike branch): Read likeRef inside transaction before
                // decrementing — if the like doc was already deleted (other device,
                // admin, cleanup), skip the decrement so count never goes negative.
                let existingLike: DocumentSnapshot
                do { existingLike = try transaction.getDocument(likeRef) }
                catch let e as NSError { errorPointer?.pointee = e; return nil }

                // Always clean up the user-facing liked record.
                transaction.deleteDocument(userLikedRef)

                if existingLike.exists {
                    // Like doc exists — safe to delete and decrement.
                    transaction.deleteDocument(likeRef)
                    if currentServerCount > 0 {
                        transaction.updateData(["likeCount": currentServerCount - 1], forDocument: postRef)
                    }
                }
                // If like doc is already gone: userLikedRef is cleaned up above,
                // count is untouched — no negative drift.
            }

            return nil
        }, completion: { _, error in
            Task { @MainActor in
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
                    // FIX #1: Set rate limiter only on confirmed success — not before
                    // the transaction. This allows immediate retry after a failure.
                    RateLimiter.shared.lastLikeTime = Date()

                    // Main transaction succeeded — update author totalLikes (best-effort).
                    if !authorId.isEmpty, authorId != uid {
                        let authorRef = db.collection("users").document(authorId)

                        // FIX #4: The totalLikes transaction previously used try? which
                        // silently zeroed current on error, setting totalLikes to 1.
                        // Now uses a proper do/catch so a read failure aborts the
                        // transaction instead of writing a corrupted value.
                        db.runTransaction({ transaction, errorPointer in
                            let snap: DocumentSnapshot
                            do {
                                snap = try transaction.getDocument(authorRef)
                            } catch let e as NSError {
                                errorPointer?.pointee = e
                                return nil  // Abort — do not write a zeroed count.
                            }
                            guard snap.exists else { return nil }
                            let current = snap.data()?["totalLikes"] as? Int ?? 0
                            if newLiked {
                                transaction.updateData(["totalLikes": current + 1], forDocument: authorRef)
                            } else if current > 0 {
                                transaction.updateData(["totalLikes": current - 1], forDocument: authorRef)
                            }
                            return nil
                        }, completion: { _, txError in
                            // FIX #4: Log the error; swallowing it silently was hiding
                            // legitimate failures (e.g. deleted author accounts).
                            if let txError = txError {
                                let nsErr = txError as NSError
                                // Code 5 = NOT_FOUND (author deleted account) — expected, skip.
                                if !(nsErr.domain == "FIRFirestoreErrorDomain" && nsErr.code == 5) {
                                    print("⚠️ totalLikes update failed: \(txError)")
                                }
                            }
                        })

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
        if let last = RateLimiter.shared.lastSaveTime, Date().timeIntervalSince(last) < 1 { return }
                guard NetworkMonitor.shared.isConnected else {
                    print("⚠️ toggleSave — offline, skipping")
                    return
                }
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
        if currentlySaved {
            saveRef.delete { error in
                Task { @MainActor in
                    if error != nil {
                        onUpdate(true)
                        NotificationCenter.default.post(
                            name: .postInteractionChanged,
                            object: nil,
                            userInfo: ["postId": postId, "action": "save", "value": true]
                        )
                    } else {
                        RateLimiter.shared.lastSaveTime = Date()
                    }
                }
            }
        } else {
            saveRef.setData(["createdAt": FieldValue.serverTimestamp()]) { error in
                Task { @MainActor in
                    if error != nil {
                        onUpdate(false)
                        NotificationCenter.default.post(
                            name: .postInteractionChanged,
                            object: nil,
                            userInfo: ["postId": postId, "action": "save", "value": false]
                        )
                    } else {
                        RateLimiter.shared.lastSaveTime = Date()
                        if !authorId.isEmpty, authorId != uid {
                            sendNotification(postId: postId, toUserId: authorId, type: "save", message: "")
                        }
                    }
                }
            }
        }
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
        if let last = RateLimiter.shared.lastRepostTime, Date().timeIntervalSince(last) < 2 { return }
        guard uid != authorId else { return }
               guard NetworkMonitor.shared.isConnected else {
                   print("⚠️ repost — offline, skipping")
                   return
               }

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
                        onUpdate(RepostResult(isReposted: false, newCount: currentCount))
                        return
                    }
                    if let docs = existingSnap?.documents, !docs.isEmpty {
                        // Already reposted — reflect that in the UI.
                        onUpdate(RepostResult(isReposted: true, newCount: currentCount))
                        return
                    }

                    // FIX #6: Original code discarded the error on this getDocument call.
                    // If this fails (post deleted, network error), snapshot?.data() is nil
                    // and the function returned silently — but the optimistic update at line
                    // below had already been issued. Now the optimistic update only fires
                    // AFTER we confirm the post exists and is not itself a repost.
                    db.collection("posts").document(postId).getDocument { snapshot, fetchError in
                        Task { @MainActor in
                            if let fetchError = fetchError {
                                print("⚠️ repost post fetch failed: \(fetchError)")
                                onUpdate(RepostResult(isReposted: false, newCount: currentCount))
                                return
                            }
                            guard let data = snapshot?.data() else {
                                // Post was deleted.
                                onUpdate(RepostResult(isReposted: false, newCount: currentCount))
                                return
                            }
                            if data["isRepost"] as? Bool == true {
                                // Cannot repost a repost — no change.
                                onUpdate(RepostResult(isReposted: false, newCount: currentCount))
                                return
                            }

                            // Optimistic update — only issued after post existence confirmed.
                            onUpdate(RepostResult(isReposted: true, newCount: currentCount + 1))
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

                            let repostHandle = UserHandleCache.shared.handle

                            var repostData: [String: Any] = [
                                "authorId": uid,
                                "authorHandle": repostHandle,
                                "text": postText,
                                "likeCount": 0,
                                "repostCount": 0,
                                "replyCount": 0,
                                "isShareable": true,
                                "isRepost": true,
                                "originalPostId": postId,
                                "originalHandle": originalHandle,
                                "originalAuthorId": authorId,
                                "createdAt": FieldValue.serverTimestamp()
                            ]
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
                                // FIX #8: Proper do/catch — read failure aborts cleanly
                                // instead of zeroing the count.
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

                                let current = postSnap.data()?["repostCount"] as? Int ?? 0

                                // Write both atomically — either both succeed or neither does.
                                transaction.setData(repostData, forDocument: newRepostRef)
                                transaction.updateData(["repostCount": current + 1], forDocument: postRef)
                                return nil

                            }, completion: { _, txError in
                                Task { @MainActor in
                                    if let txError = txError {
                                        print("⚠️ repost transaction failed: \(txError)")
                                        // Roll back the optimistic update.
                                        onUpdate(RepostResult(isReposted: false, newCount: currentCount))
                                        return
                                    }
                                    // Atomic write succeeded.
                                    if !authorId.isEmpty, authorId != uid {
                                        sendNotification(
                                            postId: postId,
                                            toUserId: authorId,
                                            type: "repost",
                                            message: ""
                                        )
                                    }
                                    NotificationCenter.default.post(
                                                                            name: .newPostCreated,
                                                                            object: nil
                                                                        )
                                }
                            })
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

        // FIX #9: The "reply" case previously hardcoded "replied to your post",
        // discarding the actual reply text passed via `message`. NotificationsView
        // reads this field to build the preview shown in the notification row
        // ("\(handle) replied: \"...\""). Passing the actual text through makes
        // notifications useful. The 200-char truncation prevents oversized documents.
        let safeMessage: String
        switch type {
        case "reply":
            let truncated = String(message.prefix(200))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            safeMessage = truncated.isEmpty ? "replied to your post" : truncated
        case "message":
            safeMessage = "sent you a message"
        default:
            safeMessage = message
        }

        Firestore.firestore().collection("users").document(toUserId)
            .collection("notifications").document(docId).setData([
                "type": type, "fromHandle": notifHandle, "fromUserId": uid,
                "message": safeMessage, "postId": postId, "isRead": false,
                "createdAt": FieldValue.serverTimestamp()
            ], merge: false)
    }
}
