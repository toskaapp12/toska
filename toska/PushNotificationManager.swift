import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import UserNotifications
/// Pending deep-link intent captured from a push tap. Used to bridge the
/// cold-launch race: when the user taps a notification while the app is
/// killed, AppDelegate's didReceive runs before MainTabView attaches its
/// NotificationCenter observers — the immediate post would be lost. We
/// stash the intent here and MainTabView consumes it on first appear.
struct PendingPushIntent {
    enum Kind { case post, profile }
    let kind: Kind
    let postId: String
    let userId: String
}

@MainActor
class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()
    /// Set when a push tap fires before the app's view tree is ready to
    /// observe it. MainTabView reads + clears this on appear so the deep
    /// link still routes correctly on cold launch.
    var pendingIntent: PendingPushIntent?
    
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in
                            UIApplication.shared.registerForRemoteNotifications()
                        }
        }
    }
    
    /// FCM token lives in the owner-only private subcollection because it
    /// can be used to send arbitrary push notifications to this user's
    /// device. Previously stored on the main user doc, which the broader
    /// firestore.rules reads-policy made readable by any authenticated
    /// user — that's a real impersonation vector.
    func saveFCMToken(_ token: String) {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            recordFcmDiag("saveFCMToken: write issued len=\(token.count)")
            Firestore.firestore()
                .collection("users").document(uid)
                .collection("private").document("data")
                .setData([
                    "fcmToken": token,
                    "fcmTokenUpdatedAt": FieldValue.serverTimestamp()
                ], merge: true)
        }

    // ── FCM diagnostic (build 99, TEMPORARY — remove before public launch) ──
    // debugLog compiles to nothing in release, so to see where FCM
    // re-registration fails on a TestFlight build we append STATUS STRINGS ONLY
    // (no user content) to the signed-in user's own private/data.fcmDiag. Gated
    // to admins (= the owner) via AdminManager so it never writes for ordinary
    // users and carries no uid literal (ACC-06). Blocking removal item: FCM-DIAG
    // in issues/BUGS.md.
    nonisolated func recordFcmDiag(_ status: String) {
        Task { @MainActor in
            guard AdminManager.shared.isAdmin,
                  let uid = Auth.auth().currentUser?.uid else { return }
            let stamp = ISO8601DateFormatter().string(from: Date())
            Firestore.firestore()
                .collection("users").document(uid)
                .collection("private").document("data")
                .setData(["fcmDiag": FieldValue.arrayUnion(["\(stamp) \(status)"])], merge: true)
        }
    }

    /// Explicitly fetch + persist the current FCM token. The registration-token
    /// delegate only fires when the token CHANGES, so on a same-session account
    /// switch (User A signs out → token deleted + regenerated while currentUser
    /// is nil, so saveFCMToken guards out → User B signs in but the token is now
    /// unchanged and the delegate doesn't re-fire) User B's token is never
    /// written and B gets no pushes for the whole session (self-heals only on
    /// the next cold launch). Call this on sign-in to close that window.
    func refreshFCMToken() {
        guard Auth.auth().currentUser?.uid != nil else { return }
        Messaging.messaging().token { [weak self] token, error in
            if let error = error {
                debugLog("⚠️ refreshFCMToken fetch failed: \(error)")
                self?.recordFcmDiag("refreshFCMToken: error \((error as NSError).code)")
                return
            }
            guard let token = token else {
                self?.recordFcmDiag("refreshFCMToken: nil token")
                return
            }
            self?.recordFcmDiag("refreshFCMToken: got token len=\(token.count)")
            Task { @MainActor in self?.saveFCMToken(token) }
        }
    }

    /// Re-establish push registration for the currently signed-in user.
    ///
    /// B94-FCM (2026-10-23): the sign-out path calls `deleteToken`, which
    /// invalidates the FCM token. After that, the registration-token delegate
    /// only re-fires once APNs re-registers and FCM mints a *fresh* token — so
    /// on a same-session sign-out → sign-in (no cold launch) nothing
    /// re-registered APNs, `refreshFCMToken` alone fetched nothing, and the user
    /// silently received no pushes until the next cold launch. Re-enabling the
    /// in-app toggle didn't help either: when iOS permission is already granted,
    /// that path only wrote the `pushEnabled` pref.
    ///
    /// This re-registers with APNs (idempotent — the real heal, since it makes
    /// `didReceiveRegistrationToken` fire with the new token) AND does a
    /// best-effort immediate fetch+save. Gated on the user having actually
    /// granted notifications so we never register when they've declined. Safe to
    /// call on sign-in, on app-foreground while signed in, and when the user
    /// re-enables the push toggle.
    func reregisterForPush() {
        guard Auth.auth().currentUser?.uid != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self?.recordFcmDiag("reregister: authStatus=\(settings.authorizationStatus.rawValue) → registering + refresh")
                Task { @MainActor in
                    UIApplication.shared.registerForRemoteNotifications()
                    self?.refreshFCMToken()
                }
            default:
                // .denied / .notDetermined are handled by requestPermission();
                // registering here would be a no-op the system drops.
                self?.recordFcmDiag("reregister: authStatus=\(settings.authorizationStatus.rawValue) → NOT registering (permission not granted)")
                break
            }
        }
    }

    /// Fire-and-forget token clear. Use ONLY where the user doc is being
    /// deleted server-side anyway (account deletion / gate-decline) — there the
    /// Firestore wipe racing sign-out is harmless because the whole private/data
    /// doc is removed by the cascade. For a plain sign-out use
    /// `clearFCMTokenAndWait()` so the wipe commits while still authenticated.
    func clearFCMToken() {
        Task { await clearFCMTokenAndWait() }
    }

    /// Awaitable token clear. Invalidates the FCM token, then awaits the
    /// Firestore wipe (bounded by a short timeout) so it commits BEFORE the
    /// caller signs out. A fire-and-forget wipe races signOut(): auth clears
    /// first and the write is rejected (request.auth.uid != uid), leaving a
    /// stale fcmToken that — if deleteToken also failed — could route the next
    /// user's pushes to this device.
    func clearFCMTokenAndWait() async {
        // 1. Invalidate the token at the FCM service level. This is the
        //    load-bearing step for cross-account safety: it forces FCM to
        //    issue a fresh token on the next saveFCMToken call. It doesn't need
        //    the Firestore auth session, so keep it fire-and-forget — awaiting
        //    it would let a flaky network stall sign-out.
        Messaging.messaging().deleteToken { error in
            if let error = error {
                debugLog("⚠️ FCM deleteToken failed: \(error)")
                Telemetry.recordError(error, context: "PushNotificationManager.deleteToken")
            }
        }

        guard let uid = Auth.auth().currentUser?.uid else { return }
        // 2. Wipe our copy of the token from the user's private doc, AWAITED so
        //    it lands before sign-out. Bounded by a 3s timeout so an offline /
        //    stalled write can't hang the sign-out UI — the FCM-level
        //    invalidation above plus server self-heal are the backstop if it
        //    doesn't land.
        do {
            try await withTimeout(seconds: 3) {
                try await Firestore.firestore()
                    .collection("users").document(uid)
                    .collection("private").document("data")
                    .updateData(["fcmToken": FieldValue.delete()])
            }
        } catch {
            debugLog("⚠️ clearFCMToken Firestore wipe failed/timed out: \(error)")
            Telemetry.recordError(error, context: "PushNotificationManager.clearFCMToken")
        }
        // Stale legacy fcmToken on the main user doc is cleaned up server-side:
        // sendPushNotification deletes it from both locations the first time
        // it sees an invalid-token error from FCM. We can't delete it from the
        // client because firestore.rules blocks owners from any update that
        // touches fcmToken on the main doc.
    }
}
// MARK: - MessagingDelegate
extension PushNotificationManager: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else {
            recordFcmDiag("didReceiveRegistrationToken: nil")
            return
        }
        recordFcmDiag("didReceiveRegistrationToken: len=\(token.count)")
        Task { @MainActor in
            saveFCMToken(token)
        }
    }
}
// MARK: - UNUserNotificationCenterDelegate
extension PushNotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
    
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let type = userInfo["type"] as? String ?? ""
        // Validate every ID pulled from the push payload before routing.
        // A push sender (or anyone who can plant a notification doc in our
        // subcollection — see firestore.rules) controls this userInfo; an
        // unvalidated postId/userId can send the app to arbitrary screens or
        // crash views downstream that assume a Firestore doc ID pattern.
        // `isValidFirestoreDocId` lives in FirestoreExtensions.
        let rawPostId = userInfo["postId"] as? String ?? ""
        let rawFromUserId = userInfo["fromUserId"] as? String ?? ""
        let postId = isValidFirestoreDocId(rawPostId) ? rawPostId : ""
        let fromUserId = isValidFirestoreDocId(rawFromUserId) ? rawFromUserId : ""

        // Route based on notification type. The Cloud Function forwards
        // postId and fromUserId in the data payload so we can pick the right
        // surface for each kind of notification.
        //
        // We ALSO stash the intent in PushNotificationManager.shared.pendingIntent
        // so MainTabView can consume it on appear. That covers the cold-launch
        // case where AppDelegate fires didReceive before MainTabView's
        // NotificationCenter observers are even attached — the post would
        // otherwise vanish into the void.
        //
        // Call completionHandler() FIRST and synchronously, before kicking off
        // the routing Task. iOS expects this delegate to call back promptly
        // to confirm the notification was processed; if the runtime suspends
        // the app or kills the extension before the @MainActor Task runs,
        // the system may flag the notification as undelivered and retry.
        // The routing work (state mutations, NotificationCenter posts) is
        // independent of when iOS gets its acknowledgement, so detaching
        // completion from the Task is purely a robustness improvement.
        completionHandler()
        Task { @MainActor in
            switch type {
            case "follow" where !fromUserId.isEmpty:
                Self.shared.pendingIntent = PendingPushIntent(
                    kind: .profile,
                    postId: "",
                    userId: fromUserId
                )
                NotificationCenter.default.post(
                    name: .openProfileFromPush,
                    object: nil,
                    userInfo: ["userId": fromUserId]
                )
            default:
                // like / reply / repost / save / milestone — all open the post
                if !postId.isEmpty {
                    Self.shared.pendingIntent = PendingPushIntent(
                        kind: .post,
                        postId: postId,
                        userId: ""
                    )
                    NotificationCenter.default.post(
                        name: .openPostFromPush,
                        object: nil,
                        userInfo: ["postId": postId]
                    )
                }
            }
        }
    }
}

