import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import UserNotifications
@MainActor
class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()
    
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
        // Also clear any legacy field on the main user doc so re-reads on
        // older accounts don't pick up a stale value the server might
        // still try to push to.
        Firestore.firestore().collection("users").document(uid).updateData([
            "fcmToken": FieldValue.delete()
        ])
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
        let postId = userInfo["postId"] as? String ?? ""
        let fromUserId = userInfo["fromUserId"] as? String ?? ""
        let conversationId = userInfo["conversationId"] as? String ?? ""

        // Route based on notification type. The Cloud Function forwards
        // postId, fromUserId, and conversationId in the data payload so we
        // can pick the right surface for each kind of notification.
        Task { @MainActor in
            switch type {
            case "message" where !conversationId.isEmpty:
                NotificationCenter.default.post(
                    name: NSNotification.Name("OpenConversationFromPush"),
                    object: nil,
                    userInfo: ["conversationId": conversationId, "otherUserId": fromUserId]
                )
            case "follow" where !fromUserId.isEmpty:
                NotificationCenter.default.post(
                    name: NSNotification.Name("OpenProfileFromPush"),
                    object: nil,
                    userInfo: ["userId": fromUserId]
                )
            default:
                // like / reply / repost / save / milestone — all open the post
                if !postId.isEmpty {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("OpenPostFromPush"),
                        object: nil,
                        userInfo: ["postId": postId]
                    )
                }
            }
        }

        completionHandler()
    }
}

