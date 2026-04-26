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
        if let last = RateLimiter.shared.lastLikeTime(for: postId), Date().timeIntervalSince(last) < 0.8 { return }
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
                // Already liked (e.g. from another device) — no-op.
                if existingLike.exists { return nil }

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
                    // Rate-limit timestamp is now set on attempt (above), not
                    // here on success — keeps double-tap behaviour consistent
                    // whether the transaction succeeds, fails, or hits a
                    // dedup no-op.

                    // totalLikes counter update handled by Cloud Function.
                    if !authorId.isEmpty, authorId != uid {
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
                // Record on attempt, not success — same rationale as
                // toggleLike. With a 1-second gate, this also serializes
                // the save↔unsave order: a rapid save→unsave→save sequence
                // can't reach the third tap until the first two have at
                // least started, which keeps Firestore writes from
                // arriving out of order and leaving the user in the
                // opposite state from what they intended.
                RateLimiter.shared.recordSave(for: postId)
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
                    Task { @MainActor in
                        let snapshot: DocumentSnapshot?
                        do {
                            snapshot = try await db.collection("posts").document(postId).getDocumentAsync()
                        } catch {
                            print("⚠️ repost post fetch failed: \(error)")
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

                            // Broadcast to other surfaces rendering the same post so
                            // their repost button state flips without waiting for a
                            // refresh. Mirrors the like/save pattern above.
                            NotificationCenter.default.post(
                                name: .postInteractionChanged,
                                object: nil,
                                userInfo: ["postId": postId, "action": "repost", "value": true]
                            )

                            let repostHandle = UserHandleCache.shared.handle
                            // Mirror the original post's isShareable flag so the repost
                            // inherits the author's sharing setting. If the original
                            // author chose "don't allow sharing", the repost carries
                            // that forward — the share-card button stays hidden on
                            // the repost too. Previously reposts hardcoded
                            // `isShareable: true`, overriding the original author's
                            // intent in an anonymous/privacy-first app.
                            let originalIsShareable = data["isShareable"] as? Bool ?? true

                            var repostData: [String: Any] = [
                                "authorId": uid,
                                "authorHandle": repostHandle,
                                "text": postText,
                                "likeCount": 0,
                                "repostCount": 0,
                                "replyCount": 0,
                                "isShareable": originalIsShareable,
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
}
