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
    enum Kind { case post, conversation, profile }
    let kind: Kind
    let postId: String
    let conversationId: String
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
            Firestore.firestore()
                .collection("users").document(uid)
                .collection("private").document("data")
                .setData([
                    "fcmToken": token,
                    "fcmTokenUpdatedAt": FieldValue.serverTimestamp()
                ], merge: true)
        }

    func clearFCMToken() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore()
            .collection("users").document(uid)
            .collection("private").document("data")
            .updateData([
                "fcmToken": FieldValue.delete()
            ])
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
        guard let token = fcmToken else { return }
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
        // unvalidated postId/conversationId/userId can send the app to
        // arbitrary screens or crash views downstream that assume a Firestore
        // doc ID pattern. `isValidFirestoreDocId` lives in FirestoreExtensions.
        let rawPostId = userInfo["postId"] as? String ?? ""
        let rawFromUserId = userInfo["fromUserId"] as? String ?? ""
        let rawConversationId = userInfo["conversationId"] as? String ?? ""
        let postId = isValidFirestoreDocId(rawPostId) ? rawPostId : ""
        let fromUserId = isValidFirestoreDocId(rawFromUserId) ? rawFromUserId : ""
        let conversationId = isValidFirestoreDocId(rawConversationId) ? rawConversationId : ""

        // Route based on notification type. The Cloud Function forwards
        // postId, fromUserId, and conversationId in the data payload so we
        // can pick the right surface for each kind of notification.
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
            case "message" where !conversationId.isEmpty:
                Self.shared.pendingIntent = PendingPushIntent(
                    kind: .conversation,
                    postId: "",
                    conversationId: conversationId,
                    userId: fromUserId
                )
                NotificationCenter.default.post(
                    name: .openConversationFromPush,
                    object: nil,
                    userInfo: ["conversationId": conversationId, "otherUserId": fromUserId]
                )
            case "follow" where !fromUserId.isEmpty:
                Self.shared.pendingIntent = PendingPushIntent(
                    kind: .profile,
                    postId: "",
                    conversationId: "",
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
                        conversationId: "",
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

