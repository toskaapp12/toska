const { onDocumentDeleted, onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

initializeApp();
const db = getFirestore();

// ============================================================
// Helper functions
// ============================================================

async function deleteCollection(collectionRef) {
  const batchSize = 499;
  while (true) {
    const snapshot = await collectionRef.limit(batchSize).get();
    if (snapshot.empty) break;
    const batch = db.batch();
    snapshot.docs.forEach((doc) => batch.delete(doc.ref));
    try {
      await batch.commit();
    } catch (err) {
      console.warn("deleteCollection batch failed:", err.message);
      break;
    }
    if (snapshot.size < batchSize) break;
  }
}

async function safeDecrement(docRef, field) {
  try {
    await db.runTransaction(async (transaction) => {
      const snap = await transaction.get(docRef);
      const current = snap.exists ? snap.data()[field] || 0 : 0;
      if (current > 0) {
        transaction.update(docRef, { [field]: current - 1 });
      }
    });
  } catch (err) {
    console.warn("safeDecrement failed:", err.message);
  }
}

// ============================================================
// Rate limiting helper
// ============================================================

async function isRateLimited(authorId, collection, cooldownSeconds) {
  const cutoff = new Date(Date.now() - cooldownSeconds * 1000);
  const recentSnap = await db.collection(collection)
    .where("authorId", "==", authorId)
    .where("createdAt", ">", Timestamp.fromDate(cutoff))
    .orderBy("createdAt", "desc")
    .limit(5)
    .get();
  return recentSnap.size >= 5;
}

// ============================================================
// Account deletion cleanup
// ============================================================

exports.onUserDocDeleted = onDocumentDeleted("users/{userId}", async (event) => {
  const uid = event.params.userId;
  const data = event.data.data();
  console.log("Cleaning up data for deleted user:", uid);

  try {
    const postsSnap = await db.collection("posts")
      .where("authorId", "==", uid)
      .orderBy("createdAt", "desc")
      .limit(1)
      .get();
    if (!postsSnap.empty) {
      const postData = postsSnap.docs[0].data();
      await db.collection("finalPosts").add({
        authorHandle: postData.authorHandle || data.handle || "anonymous",
        text: postData.text || "",
        tag: postData.tag || null,
        likeCount: postData.likeCount || 0,
        createdAt: postData.createdAt || new Date(),
        leftAt: new Date(),
      });
    }

    const allPosts = await db.collection("posts").where("authorId", "==", uid).get();
    for (const postDoc of allPosts.docs) {
      await deleteCollection(postDoc.ref.collection("replies"));
      await deleteCollection(postDoc.ref.collection("likes"));
      await deleteCollection(postDoc.ref.collection("reflections"));
      await postDoc.ref.delete();
    }

    const followersSnap = await db.collection("users").doc(uid).collection("followers").get();
    for (const doc of followersSnap.docs) {
      await db.collection("users").doc(doc.id).collection("following").doc(uid).delete();
      await safeDecrement(db.collection("users").doc(doc.id), "followingCount");
    }
    const followingSnap = await db.collection("users").doc(uid).collection("following").get();
    for (const doc of followingSnap.docs) {
      await db.collection("users").doc(doc.id).collection("followers").doc(uid).delete();
      await safeDecrement(db.collection("users").doc(doc.id), "followerCount");
    }

    const subs = ["saved", "liked", "following", "followers", "notifications", "blocked", "presence", "private"];
    for (const sub of subs) {
      await deleteCollection(db.collection("users").doc(uid).collection(sub));
    }

    await db.collection("pendingDeletions").doc(uid).delete().catch(() => {});

    const convoSnap = await db.collection("conversations")
      .where("participants", "array-contains", uid)
      .get();
    for (const convoDoc of convoSnap.docs) {
      await deleteCollection(convoDoc.ref.collection("messages"));
      await convoDoc.ref.update({
        [`participantHandles.${uid}`]: FieldValue.delete(),
      }).catch(() => {});
    }

    // Cross-user notifications authored by the deleted user — likes,
    // replies, follows, reposts, saves, messages all leave a doc in
    // the *recipient's* notifications subcollection with fromUserId
    // set to the actor. The user-doc trigger never visits those, so
    // they used to linger forever showing a deleted user's old handle.
    // collectionGroup walks every user's notifications in one query.
    try {
      let totalDeletedNotifs = 0;
      while (true) {
        const orphanedNotifs = await db.collectionGroup("notifications")
          .where("fromUserId", "==", uid)
          .limit(500)
          .get();
        if (orphanedNotifs.empty) break;
        const batch = db.batch();
        orphanedNotifs.docs.forEach((doc) => batch.delete(doc.ref));
        await batch.commit();
        totalDeletedNotifs += orphanedNotifs.size;
        if (orphanedNotifs.size < 500) break;
      }
      if (totalDeletedNotifs > 0) {
        console.log(`Deleted ${totalDeletedNotifs} orphaned notifications for user:`, uid);
      }
    } catch (err) {
      console.warn("Orphaned notification cleanup failed:", err.message);
    }

    // Feeling-circle messages authored by the deleted user. The circles
    // themselves expire on their own schedule (cleanupExpiredCircles),
    // but their messages are addressable via collectionGroup and would
    // otherwise stay visible inside still-active circles.
    try {
      const orphanedCircleMsgs = await db.collectionGroup("messages")
        .where("authorId", "==", uid)
        .limit(500)
        .get();
      if (!orphanedCircleMsgs.empty) {
        const batch = db.batch();
        orphanedCircleMsgs.docs.forEach((doc) => batch.delete(doc.ref));
        await batch.commit();
        console.log(`Deleted ${orphanedCircleMsgs.size} feeling-circle messages for user:`, uid);
      }
    } catch (err) {
      console.warn("Feeling-circle message cleanup failed:", err.message);
    }

    // Reports submitted by the deleted user. We keep reports filed
    // *against* this user (moderation history must survive deletion)
    // but clear the ones they filed so the moderation queue doesn't
    // attribute pending items to a tombstoned uid.
    try {
      const submittedReports = await db.collection("reports")
        .where("reportedBy", "==", uid)
        .where("status", "==", "pending")
        .limit(500)
        .get();
      if (!submittedReports.empty) {
        const batch = db.batch();
        submittedReports.docs.forEach((doc) => batch.delete(doc.ref));
        await batch.commit();
        console.log(`Deleted ${submittedReports.size} pending reports filed by user:`, uid);
      }
    } catch (err) {
      console.warn("Pending-report cleanup failed:", err.message);
    }

    console.log("Cleanup complete for user:", uid);
  } catch (error) {
    console.error("Cleanup failed for user:", uid, error);
    throw error;
  }
});

// ============================================================
// Push notifications on new notification doc
// ============================================================

exports.sendPushNotification = onDocumentCreated(
  "users/{userId}/notifications/{notificationId}",
  async (event) => {
    const userId = event.params.userId;

    const notifRef = event.data.ref;
    const notifSnap = await notifRef.get();
    if (!notifSnap.exists) return;
    if (notifSnap.data()?.processed === true) return;
    await notifRef.update({ processed: true });

    const notifData = notifSnap.data();
    if (!notifData) return;

    const type = notifData.type || "";
    const message = notifData.message || "";

    // Server-side fromHandle validation: a malicious client could write
    // a notification doc with a forged fromHandle pretending to be
    // someone else. Look up the real handle from the sender's user doc
    // and use that instead of trusting the client-provided field.
    let fromHandle = "someone";
    if (notifData.fromUserId) {
      const senderSnap = await db.collection("users").doc(notifData.fromUserId).get();
      if (senderSnap.exists) {
        fromHandle = senderSnap.data().handle || "someone";
      }
    }

    const userDoc = await db.collection("users").doc(userId).get();
    if (!userDoc.exists) return;

    const userData = userDoc.data();

    // FCM token now lives in the owner-only private subcollection so it
    // isn't readable by other clients via the broader users-doc reads
    // policy. Fall back to the legacy main-doc field for users created
    // before the migration; their token will move on next refresh.
    let fcmToken;
    const privateSnap = await db
      .collection("users").doc(userId)
      .collection("private").doc("data")
      .get();
    if (privateSnap.exists) {
      fcmToken = privateSnap.data().fcmToken;
    }
    if (!fcmToken) {
      fcmToken = userData.fcmToken;
    }
    if (!fcmToken) return;

    if (userData.pushEnabled === false) return;

    const settingsMap = {
      like: "notifyLikes",
      reply: "notifyReplies",
      follow: "notifyFollows",
      repost: "notifyReposts",
      save: "notifySaves",
      milestone: "notifyMilestones",
      message: "notifyMessages",
    };

    const settingKey = settingsMap[type];
    if (settingKey && userData[settingKey] === false) return;

    // Block check: never push from a user the recipient has blocked. Without
    // this, blocked users can still trigger pushes by liking/replying/etc.
    // We check the recipient's blocked subcollection — if the sender's uid
    // is present, drop the notification entirely (it stays in Firestore for
    // the in-app history but the silent-block experience matches what
    // BlockedUsersCache does on the client).
    const fromUserId = notifData.fromUserId;
    if (fromUserId) {
      const blockedSnap = await db
        .collection("users").doc(userId)
        .collection("blocked").doc(fromUserId)
        .get();
      if (blockedSnap.exists) {
        console.log(`Push suppressed: ${userId} blocked ${fromUserId}`);
        return;
      }
    }

    let title = "toska";
    let body = "";

    // Push payloads transit APNS — never include user-authored content
    // (post text, reply text, message text). For an anonymity-first app
    // a notification body that quotes "i miss them so much" leaks both
    // who's posting AND what they posted to anyone with access to the
    // device's notification logs (lock screen photos, notification
    // history extensions, etc.). Tap-through surfaces the content
    // in-app where the user has full control.
    switch (type) {
      case "reply":
        title = `${fromHandle} replied`;
        body = "tap to read what they said";
        break;
      case "like":
        title = "someone felt your post";
        body = `${fromHandle} felt what you said`;
        break;
      case "follow":
        title = "new follower";
        body = `${fromHandle} followed you`;
        break;
      case "repost":
        title = "your words are spreading";
        body = `${fromHandle} reposted your words`;
        break;
      case "save":
        title = "someone saved your post";
        body = `${fromHandle} kept your words`;
        break;
      case "milestone":
        // Server-authored milestone copy ("your post reached 25 feels") is
        // safe because it doesn't include the post body, just the count.
        body = message || "your post hit a milestone";
        break;
      case "message":
        title = `${fromHandle}`;
        body = "sent you a message";
        break;
      default:
        body = "you have a new notification";
    }

    const payload = {
      token: fcmToken,
      notification: { title, body },
      data: {
        type,
        // Forward all routing IDs so the client can deep-link to the right
        // surface based on `type`: post → PostDetailView, follow → profile,
        // message → conversation. Empty strings preserve compatibility with
        // older clients that only checked postId.
        postId: notifData.postId || "",
        fromUserId: notifData.fromUserId || "",
        conversationId: notifData.conversationId || "",
      },
      apns: {
        payload: {
          aps: {
            sound: "default",
            badge: 1,
          },
        },
      },
    };

    try {
      await getMessaging().send(payload);
    } catch (error) {
      if (
        error.code === "messaging/invalid-registration-token" ||
        error.code === "messaging/registration-token-not-registered"
      ) {
        // Delete from both the new private location and the legacy main
        // doc so we don't keep retrying an already-dead token.
        await db.collection("users").doc(userId)
          .collection("private").doc("data")
          .update({ fcmToken: FieldValue.delete() })
          .catch(() => {});
        await db.collection("users").doc(userId)
          .update({ fcmToken: FieldValue.delete() })
          .catch(() => {});
      }
      console.error("Push send failed:", error.code);
    }
  }
);

// ============================================================
// Trigger account cleanup when pendingDeletions doc is written
// ============================================================

exports.onPendingDeletionCreated = onDocumentCreated(
  "pendingDeletions/{userId}",
  async (event) => {
    const uid = event.params.userId;

    const fresh = await db.collection("pendingDeletions").doc(uid).get();
    if (!fresh.exists) return;
    if (fresh.data()?.cancelled === true) {
      console.log("Deletion cancelled for user:", uid);
      return;
    }

    console.log("Pending deletion detected for user:", uid);

    try {
      await db.collection("users").doc(uid).delete();
      console.log("User document deleted, cleanup handoff complete:", uid);
    } catch (error) {
      console.error("Failed to delete user document for:", uid, error);
      throw error;
    }
  }
);

// ============================================================
// Counter: like count + totalLikes (server-side only)
// ============================================================

exports.onLikeCreatedUpdateCounts = onDocumentCreated(
  "posts/{postId}/likes/{userId}",
  async (event) => {
    const postId = event.params.postId;
    const postRef = db.collection("posts").doc(postId);

    try {
      await postRef.update({ likeCount: FieldValue.increment(1) });
    } catch (err) {
      console.warn("onLikeCreatedUpdateCounts: likeCount increment failed:", err.message);
    }

    // Increment the post author's totalLikes
    try {
      const postSnap = await postRef.get();
      if (!postSnap.exists) return;
      const authorId = postSnap.data().authorId;
      if (!authorId) return;
      await db.collection("users").doc(authorId).update({
        totalLikes: FieldValue.increment(1),
      });
    } catch (err) {
      console.warn("onLikeCreatedUpdateCounts: totalLikes increment failed:", err.message);
    }
  }
);

exports.onLikeDeletedUpdateCounts = onDocumentDeleted(
  "posts/{postId}/likes/{userId}",
  async (event) => {
    const postId = event.params.postId;
    const postRef = db.collection("posts").doc(postId);

    await safeDecrement(postRef, "likeCount");

    // Decrement the post author's totalLikes
    try {
      const postSnap = await postRef.get();
      if (!postSnap.exists) return;
      const authorId = postSnap.data().authorId;
      if (!authorId) return;
      await safeDecrement(db.collection("users").doc(authorId), "totalLikes");
    } catch (err) {
      console.warn("onLikeDeletedUpdateCounts: totalLikes decrement failed:", err.message);
    }
  }
);

// ============================================================
// Counter: reply count (server-side only)
// ============================================================

exports.onReplyCreatedUpdateCount = onDocumentCreated(
  "posts/{postId}/replies/{replyId}",
  async (event) => {
    const postId = event.params.postId;
    const replyData = event.data.data();
    if (!replyData) return;
    // Basic validity check — only increment for replies with actual text
    if (typeof replyData.text !== "string" || replyData.text.trim().length === 0) return;
    if (!replyData.authorId) return;

    try {
      await db.collection("posts").doc(postId).update({
        replyCount: FieldValue.increment(1),
      });
    } catch (err) {
      console.warn("onReplyCreatedUpdateCount failed:", err.message);
    }
  }
);

// ============================================================
// Counter: repost count (server-side only)
// ============================================================

exports.onRepostCreatedUpdateCount = onDocumentCreated(
  "posts/{postId}",
  async (event) => {
    const postData = event.data.data();
    if (!postData) return;
    if (postData.isRepost !== true) return;
    const originalPostId = postData.originalPostId;
    if (!originalPostId || typeof originalPostId !== "string") return;

    try {
      await db.collection("posts").doc(originalPostId).update({
        repostCount: FieldValue.increment(1),
      });
    } catch (err) {
      console.warn("onRepostCreatedUpdateCount failed:", err.message);
    }
  }
);

// ============================================================
// Counter: follow counts (server-side only)
// ============================================================

exports.onFollowCreatedUpdateCounts = onDocumentCreated(
  "users/{userId}/following/{followedId}",
  async (event) => {
    const userId = event.params.userId;
    const followedId = event.params.followedId;

    try {
      await db.collection("users").doc(userId).update({
        followingCount: FieldValue.increment(1),
      });
    } catch (err) {
      console.warn("onFollowCreatedUpdateCounts: followingCount increment failed:", err.message);
    }

    try {
      await db.collection("users").doc(followedId).update({
        followerCount: FieldValue.increment(1),
      });
    } catch (err) {
      console.warn("onFollowCreatedUpdateCounts: followerCount increment failed:", err.message);
    }
  }
);

exports.onFollowDeletedUpdateCounts = onDocumentDeleted(
  "users/{userId}/following/{followedId}",
  async (event) => {
    const userId = event.params.userId;
    const followedId = event.params.followedId;

    await safeDecrement(db.collection("users").doc(userId), "followingCount");
    await safeDecrement(db.collection("users").doc(followedId), "followerCount");
  }
);

// ============================================================
// Milestone tracking — fires when a like doc is created
// ============================================================

exports.onLikeWritten = onDocumentCreated(
  "posts/{postId}/likes/{likeId}",
  async (event) => {
    const postId = event.params.postId;
    const likerId = event.params.likeId;

    const postRef = db.collection("posts").doc(postId);
    const postSnap = await postRef.get();
    if (!postSnap.exists) return;

    const postData = postSnap.data();
    const authorId = postData.authorId;
    if (!authorId) return;

    const likeCount = postData.likeCount || 0;

    const milestones = [10, 25, 50, 100, 250, 500, 1000];
    if (!milestones.includes(likeCount)) return;

    if (likerId === authorId) return;

    const notifId = `milestone_${postId}_${likeCount}`;
    await db.collection("users").doc(authorId).collection("notifications").doc(notifId).set({
      type: "milestone",
      fromUserId: likerId,
      postId,
      message: `your post reached ${likeCount} feels`,
      isRead: false,
      createdAt: FieldValue.serverTimestamp(),
    });
  }
);

// ============================================================
// Tag count maintenance — keeps meta/tagCounts updated so
// clients read one document instead of 200 posts.
// ============================================================

exports.onPostCreatedUpdateTagCounts = onDocumentCreated("posts/{postId}", async (event) => {
  const postData = event.data.data();
  if (!postData) return;
  const tag = postData.tag;
  if (!tag || typeof tag !== "string") return;
  if (postData.isRepost === true) return;

  try {
    await db.collection("meta").doc("tagCounts").set(
      { [tag]: FieldValue.increment(1), updatedAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
  } catch (err) {
    console.warn("onPostCreatedUpdateTagCounts failed:", err.message);
  }
});

exports.onPostDeletedUpdateTagCounts = onDocumentDeleted("posts/{postId}", async (event) => {
  const postData = event.data.data();
  if (!postData) return;
  const tag = postData.tag;
  if (!tag || typeof tag !== "string") return;
  if (postData.isRepost === true) return;

  try {
    await db.runTransaction(async (transaction) => {
      const ref = db.collection("meta").doc("tagCounts");
      const snap = await transaction.get(ref);
      const current = snap.exists ? (snap.data()[tag] || 0) : 0;
      if (current > 0) {
        transaction.set(
          ref,
          { [tag]: current - 1, updatedAt: FieldValue.serverTimestamp() },
          { merge: true }
        );
      }
    });
  } catch (err) {
    console.warn("onPostDeletedUpdateTagCounts failed:", err.message);
  }
});

// ============================================================
// Server-side post validation
// ============================================================

exports.validatePost = onDocumentCreated("posts/{postId}", async (event) => {
  const postId = event.params.postId;
  const postData = event.data.data();
  if (!postData) return;

  if (postData.isRepost === true) return;

  const text = postData.text;

  if (typeof text !== "string" || text.trim().length === 0) {
    console.warn(`Deleting post ${postId} — missing or blank text`);
    await db.collection("posts").doc(postId).delete();
    return;
  }

  if (text.length > 2000) {
    console.warn(`Deleting post ${postId} — text too long (${text.length} chars)`);
    await db.collection("posts").doc(postId).delete();
    return;
  }
});

// ============================================================
// Server-side reply validation (mirror of validatePost)
// ============================================================
//
// Client enforces text.length ≤ 500 in PostDetailView, but a malicious
// client bypassing the UI could write reply documents with arbitrary
// length text — DoS vector and data-integrity risk. This guard matches
// the firestore.rules text-length cap and runs on the same trigger as
// rateLimitReplies for parity.

exports.validateReply = onDocumentCreated(
  "posts/{postId}/replies/{replyId}",
  async (event) => {
    const postId = event.params.postId;
    const replyId = event.params.replyId;
    const replyData = event.data.data();
    if (!replyData) return;

    const text = replyData.text;
    if (typeof text !== "string" || text.trim().length === 0) {
      console.warn(`Deleting reply ${replyId} — missing or blank text`);
      await db.collection("posts").doc(postId).collection("replies").doc(replyId).delete();
      await safeDecrement(db.collection("posts").doc(postId), "replyCount");
      return;
    }

    if (text.length > 500) {
      console.warn(`Deleting reply ${replyId} — text too long (${text.length} chars)`);
      await db.collection("posts").doc(postId).collection("replies").doc(replyId).delete();
      await safeDecrement(db.collection("posts").doc(postId), "replyCount");
      return;
    }
  }
);

// ============================================================
// Server-side rate limiting — posts
// ============================================================

exports.rateLimitPosts = onDocumentCreated("posts/{postId}", async (event) => {
  const postId = event.params.postId;
  const postData = event.data.data();
  if (!postData) return;

  const authorId = postData.authorId;
  if (!authorId) return;

  const fiveMinAgo = new Date(Date.now() - 5 * 60 * 1000);
  const recentSnap = await db.collection("posts")
    .where("authorId", "==", authorId)
    .where("createdAt", ">", Timestamp.fromDate(fiveMinAgo))
    .orderBy("createdAt", "desc")
    .limit(10)
    .get();

  if (recentSnap.size > 5) {
    console.log("Rate limit exceeded for user:", authorId, "— flagging post:", postId);
    await db.collection("posts").doc(postId).update({
      flagged: true,
      flaggedAt: FieldValue.serverTimestamp(),
      flagReason: "rate_limit_exceeded",
    });
  }
});

// ============================================================
// PII and URL detection helpers (shared across moderation triggers)
// ============================================================

const socialPatterns = [
  /\b(instagram|insta|snapchat|tiktok|twitter|facebook|linkedin|discord|reddit|telegram|whatsapp|signal|bluesky|threads)\b/i,
  /@[a-zA-Z][a-zA-Z0-9._]{2,}/,
];

function hasPhoneNumber(text) {
  const stripped = text.replace(/[\s\-\(\)\.]/g, '');
  const digits = stripped.replace(/[^\d]/g, '');
  const crisisNumbers = ['988', '741741', '18002738255', '18007997233', '18006564673'];
  let cleaned = digits;
  for (const num of crisisNumbers) {
    cleaned = cleaned.replace(num, '');
  }
  return cleaned.length >= 10;
}

const emailPattern = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/;
const addressPattern = /\d+\s+[A-Za-z]+\s+(street|st|avenue|ave|boulevard|blvd|drive|dr|lane|ln|road|rd|way|place|pl|court|ct|circle|cir|terrace|trail|parkway|pkwy)\b/i;

const identifyingPhrases = [
  "her name is", "his name is", "their name is",
  "lives at", "lives in", "lives on",
  "works at", "goes to", "school name",
  "phone number", "my number", "text me", "call me",
  "dm me", "follow me", "find me", "look me up",
  "last name", "full name", "address",
  "apartment", "apt ", "suite ",
];

function containsPII(text) {
  const lower = text.toLowerCase();
  if (socialPatterns.some((p) => p.test(text))) return true;
  if (hasPhoneNumber(text)) return true;
  if (emailPattern.test(text)) return true;
  if (addressPattern.test(text)) return true;
  if (identifyingPhrases.some((phrase) => lower.includes(phrase))) return true;
  return false;
}

const urlPatterns = [
  /https?:\/\//i,
  /www\./i,
  /[a-z0-9]+\.(com|net|org|io|co|app|xyz|gg|tv|me)\b/i,
  /bit\.ly|tinyurl|linktr\.ee/i,
];

function containsURL(text) {
  return urlPatterns.some((p) => p.test(text));
}

// ============================================================
// Content moderation — flag posts with prohibited content
// ============================================================

exports.onPostCreated = onDocumentCreated("posts/{postId}", async (event) => {
  const postId = event.params.postId;
  const postData = event.data.data();
  if (!postData) return;

  if (postData.flagged === true) return;

  const text = (postData.text || "").toLowerCase();

  const spamPatterns = [
    /\b(buy|sell|discount|promo|click here|free money|crypto|bitcoin|investment)\b/i,
    /https?:\/\//i,
    /\b(www\.)\b/i,
    /\b(buy now|act now|limited time|earn money|make money)\b/i,
    /\b(ethereum|nft)\b/i,
    /\b(follow my|check my bio|link in bio)\b/i,
    /\b(discount code|promo code|use code)\b/i,
    /\b(dm me for|dm for)\b/i,
    /\b(cashapp|venmo me|paypal me)\b/i,
    /\b(onlyfans|only fans)\b/i,
  ];

  const hatePatterns = [
    /n[i1!]gg/i,
    /f[a@]gg/i,
    /r[e3]t[a@]rd/i,
    /tr[a@]nny/i,
    /d[yi1]ke/i,
    /ch[i1]nk/i,
    /sp[i1]ck?/i,
    /k[i1]ke/i,
    /w[e3]tb[a@]ck/i,
    /g[o0][o0]k/i,
    /c[o0][o0]n/i,
    /towelhead/i,
    /raghead/i,
    /beaner/i,
    /zipperhead/i,
  ];

  // Targeted threats — NOT crisis/self-harm content (handled separately)
  const threatPhrases = [
    "kill you", "kill him", "kill her", "kill them",
    "shoot you", "shoot him", "shoot her", "shoot them", "shoot up",
    "stab you", "stab him", "stab her", "stab them",
    "shoot up the", "blow up", "burn down",
    "rape you", "rape her", "rape him",
    "find you and", "find where you live", "know where you live",
    "hunt you down", "come for you",
    "gonna hurt you", "going to hurt you",
    "beat you", "beat the shit",
  ];

  // Sexual content
  const sexualPatterns = [
    /porn/i, /hentai/i, /\bxxx\b/i,
    /\bnudes\b/i, /send nudes/i, /dick pic/i, /pussy pic/i,
    /jerk off/i, /jack off/i, /masturbat/i,
    /cum on/i, /cum in/i, /creampie/i,
    /blowjob/i, /blow job/i, /handjob/i, /hand job/i,
    /anal sex/i, /oral sex/i,
    /sex tape/i, /sextape/i, /sext me/i, /sexting/i,
  ];

  const concerningPhrases = [
    "end it all", "can't go on", "no reason to live",
    "want to die", "kill myself", "better off without me",
    "no point anymore", "nobody cares", "disappear forever",
    "not worth it", "give up on everything",
    "want to hurt myself", "hurt myself", "self harm", "self-harm",
    "end my life", "don't want to wake up", "don't want to be here",
    "want to disappear", "better off dead", "no one would care",
    "no one would notice", "can't do this anymore", "done with life",
    "want it to stop", "want it all to end", "nothing left",
    "not worth living", "why am i still here", "wish i wasn't here",
    "wish i was dead", "take my own life", "don't want to exist",
  ];

  let flagReason = null;

  if (spamPatterns.some((p) => p.test(text))) {
    flagReason = "spam_or_commercial";
  } else if (hatePatterns.some((p) => p.test(text))) {
    flagReason = "hate_speech";
  } else if (threatPhrases.some((phrase) => text.includes(phrase))) {
    flagReason = "targeted_threat";
  } else if (sexualPatterns.some((p) => p.test(text))) {
    flagReason = "sexual_content";
  } else if (containsPII(postData.text || "")) {
    flagReason = "personal_information";
  } else if (containsURL(postData.text || "")) {
    flagReason = "contains_link";
  }

  const isConcerning = concerningPhrases.some((phrase) => text.includes(phrase));

  if (flagReason) {
    await db.collection("posts").doc(postId).update({
      flagged: true,
      flaggedAt: FieldValue.serverTimestamp(),
      flagReason,
    });
    console.log(`Post ${postId} flagged: ${flagReason}`);

    // Repeat offender tracking: if the author has >= 3 flagged posts,
    // mark their user document as restricted.
    const authorId = postData.authorId;
    if (authorId) {
      try {
        const flaggedSnap = await db.collection("posts")
          .where("authorId", "==", authorId)
          .where("flagged", "==", true)
          .limit(3)
          .get();
        if (flaggedSnap.size >= 3) {
          await db.collection("users").doc(authorId).update({
            restricted: true,
            restrictedAt: FieldValue.serverTimestamp(),
          });
          console.log(`User ${authorId} restricted — ${flaggedSnap.size} flagged posts`);
        }
      } catch (err) {
        console.warn("Repeat offender check failed:", err.message);
      }
    }
  } else if (isConcerning) {
    await db.collection("posts").doc(postId).update({
      concerningContent: true,
      flaggedAt: FieldValue.serverTimestamp(),
    });
    console.log(`Post ${postId} marked as concerning content`);
  }
});

// ============================================================
// Content moderation — flag replies with prohibited content
// ============================================================

exports.onReplyCreatedModerate = onDocumentCreated(
  "posts/{postId}/replies/{replyId}",
  async (event) => {
    const postId = event.params.postId;
    const replyId = event.params.replyId;
    const data = event.data.data();
    if (!data) return;

    const text = (data.text || "").toLowerCase();

    const hatePatterns = [/n[i1!]gg/i, /f[a@]gg/i, /r[e3]t[a@]rd/i, /tr[a@]nny/i, /d[yi1]ke/i, /ch[i1]nk/i, /sp[i1]ck/i, /k[i1]ke/i, /w[e3]tb[a@]ck/i, /g[o0][o0]k/i, /c[o0][o0]n/i, /towelhead/i, /raghead/i, /beaner/i, /zipperhead/i];
    const threatPhrases = ["kill you", "kill him", "kill her", "kill them", "shoot you", "shoot up", "stab you", "rape you", "rape her", "hunt you down", "know where you live", "find where you live", "slit your throat", "put a bullet"];
    const sexualPatterns = [/porn/i, /hentai/i, /\bxxx\b/i, /onlyfans/i, /send nudes/i, /blowjob/i, /blow job/i, /sext/i, /nsfw/i];
    const harassmentPhrases = ["kill yourself", "kys", "go die", "you should die", "hope you die", "drink bleach", "neck yourself", "nobody likes you", "youre worthless", "you deserve to die"];

    let flagReason = null;
    if (hatePatterns.some((p) => p.test(text))) flagReason = "hate_speech";
    else if (harassmentPhrases.some((p) => text.includes(p))) flagReason = "harassment";
    else if (threatPhrases.some((p) => text.includes(p))) flagReason = "targeted_threat";
    else if (sexualPatterns.some((p) => p.test(text))) flagReason = "sexual_content";
    else if (containsPII(data.text || "")) flagReason = "personal_information";
    else if (containsURL(data.text || "")) flagReason = "contains_link";

    if (flagReason) {
      if (flagReason === "personal_information" || flagReason === "contains_link") {
        // PII and links: flag for review instead of deleting (higher false positive rate)
        await db.collection("posts").doc(postId).collection("replies").doc(replyId).update({
          flagged: true,
          flaggedAt: FieldValue.serverTimestamp(),
          flagReason,
        });
        console.log(`Reply ${replyId} on post ${postId} flagged: ${flagReason}`);
      } else {
        await db.collection("posts").doc(postId).collection("replies").doc(replyId).delete();
        await safeDecrement(db.collection("posts").doc(postId), "replyCount");
        console.log(`Reply ${replyId} on post ${postId} deleted: ${flagReason}`);
      }
    }
  }
);

// ============================================================
// Content moderation — flag DM messages with prohibited content
// ============================================================

exports.onMessageCreatedModerate = onDocumentCreated(
  "conversations/{convoId}/messages/{messageId}",
  async (event) => {
    const convoId = event.params.convoId;
    const messageId = event.params.messageId;
    const data = event.data.data();
    if (!data) return;

    const text = (data.text || "").toLowerCase();

    const hatePatterns = [/n[i1!]gg/i, /f[a@]gg/i, /r[e3]t[a@]rd/i, /tr[a@]nny/i, /d[yi1]ke/i, /ch[i1]nk/i, /sp[i1]ck/i, /k[i1]ke/i, /w[e3]tb[a@]ck/i, /g[o0][o0]k/i, /c[o0][o0]n/i, /towelhead/i, /raghead/i];
    const threatPhrases = ["kill you", "kill him", "kill her", "shoot you", "stab you", "rape you", "rape her", "hunt you down", "know where you live", "find where you live", "slit your throat"];
    const harassmentPhrases = ["kill yourself", "kys", "go die", "you should die", "hope you die", "drink bleach", "neck yourself"];

    let flagReason = null;
    if (hatePatterns.some((p) => p.test(text))) flagReason = "hate_speech";
    else if (harassmentPhrases.some((p) => text.includes(p))) flagReason = "harassment";
    else if (threatPhrases.some((p) => text.includes(p))) flagReason = "targeted_threat";
    else if (containsPII(data.text || "")) flagReason = "personal_information";
    else if (containsURL(data.text || "")) flagReason = "contains_link";

    if (flagReason) {
      if (flagReason === "personal_information" || flagReason === "contains_link") {
        // PII and links: flag for review instead of deleting (higher false positive rate)
        await db.collection("conversations").doc(convoId).collection("messages").doc(messageId).update({
          flagged: true,
          flaggedAt: FieldValue.serverTimestamp(),
          flagReason,
        });
        console.log(`Message ${messageId} in convo ${convoId} flagged: ${flagReason}`);
      } else {
        await db.collection("conversations").doc(convoId).collection("messages").doc(messageId).delete();
        console.log(`Message ${messageId} in convo ${convoId} deleted: ${flagReason}`);
      }
    }
  }
);

// ============================================================
// Server-side rate limiting — replies
// ============================================================

exports.rateLimitReplies = onDocumentCreated(
  "posts/{postId}/replies/{replyId}",
  async (event) => {
    const postId = event.params.postId;
    const replyId = event.params.replyId;
    const replyData = event.data.data();
    if (!replyData) return;

    const authorId = replyData.authorId;
    if (!authorId) return;

    const fiveMinAgo = new Date(Date.now() - 5 * 60 * 1000);
    const recentSnap = await db.collectionGroup("replies")
      .where("authorId", "==", authorId)
      .where("createdAt", ">", Timestamp.fromDate(fiveMinAgo))
      .orderBy("createdAt", "desc")
      .limit(15)
      .get();

    if (recentSnap.size > 10) {
      console.log("Reply rate limit exceeded for user:", authorId);
      await db.collection("posts").doc(postId).collection("replies").doc(replyId).delete();
      await safeDecrement(db.collection("posts").doc(postId), "replyCount");
      console.log("Spam reply deleted:", replyId);
    }
  }
);

// ============================================================
// Scheduled post expiration cleanup — runs every hour
// ============================================================

exports.cleanupExpiredPosts = onSchedule("every 60 minutes", async () => {
  const now = Timestamp.now();
  console.log("Running expired post cleanup at:", now.toDate());

  try {
    const expiredSnap = await db.collection("posts")
      .where("expiresAt", "<=", now)
      .limit(100)
      .get();

    if (expiredSnap.empty) {
      console.log("No expired posts found.");
      return;
    }

    for (const doc of expiredSnap.docs) {
      await deleteCollection(doc.ref.collection("replies"));
      await deleteCollection(doc.ref.collection("likes"));
      await deleteCollection(doc.ref.collection("reflections"));
      await doc.ref.delete();
    }

    console.log(`Deleted ${expiredSnap.size} expired posts.`);
  } catch (error) {
    console.error("Expired post cleanup failed:", error);
    throw error;
  }
});

// ============================================================
// Scheduled cleanup — expired feeling circles
// ============================================================

exports.cleanupExpiredCircles = onSchedule("every 60 minutes", async () => {
  const now = Timestamp.now();
  console.log("Running expired circle cleanup at:", now.toDate());

  try {
    const expiredSnap = await db.collection("feelingCircles")
      .where("expiresAt", "<=", now)
      .limit(50)
      .get();

    if (expiredSnap.empty) {
      console.log("No expired circles found.");
      return;
    }

    for (const circleDoc of expiredSnap.docs) {
      await deleteCollection(circleDoc.ref.collection("messages"));
      await circleDoc.ref.delete();
    }

    console.log(`Cleaned up ${expiredSnap.size} expired feeling circles.`);
  } catch (error) {
    console.error("Expired circle cleanup failed:", error);
    throw error;
  }
});

// ============================================================
// Server-side rate limiting — notifications
// ============================================================

exports.rateLimitNotifications = onDocumentCreated(
  "users/{userId}/notifications/{notifId}",
  async (event) => {
    const userId = event.params.userId;
    const notifId = event.params.notifId;
    const notifData = event.data.data();
    if (!notifData) return;

    const fromUserId = notifData.fromUserId;
    if (!fromUserId) return;

    const fiveMinAgo = new Date(Date.now() - 5 * 60 * 1000);
    const recentSnap = await db.collectionGroup("notifications")
      .where("fromUserId", "==", fromUserId)
      .where("createdAt", ">", Timestamp.fromDate(fiveMinAgo))
      .orderBy("createdAt", "desc")
      .limit(25)
      .get();

    if (recentSnap.size > 20) {
      console.log("Notification rate limit exceeded for sender:", fromUserId);
      await db.collection("users").doc(userId).collection("notifications").doc(notifId).delete();
      console.log("Spam notification deleted:", notifId);
    }
  }
);

// ============================================================
// Counter: DM message count (server-side only)
// ============================================================

exports.onMessageCreatedUpdateCount = onDocumentCreated(
  "conversations/{convoId}/messages/{messageId}",
  async (event) => {
    const convoId = event.params.convoId;
    const messageData = event.data.data();
    if (!messageData) return;

    const senderId = messageData.senderId;
    if (!senderId) return;

    try {
      await db.collection("conversations").doc(convoId).update({
        [`messageCount.${senderId}`]: FieldValue.increment(1),
      });
    } catch (err) {
      console.warn("onMessageCreatedUpdateCount failed:", err.message);
    }
  }
);

// ============================================================
// Scheduled stale pendingDeletions monitor — runs every hour
// ============================================================

exports.monitorPendingDeletions = onSchedule("every 60 minutes", async () => {
  const tenMinutesAgo = Timestamp.fromDate(new Date(Date.now() - 10 * 60 * 1000));

  const staleSnap = await db.collection("pendingDeletions")
    .where("requestedAt", "<=", tenMinutesAgo)
    .limit(50)
    .get();

  if (staleSnap.empty) {
    console.log("No stale pending deletions found.");
    return;
  }

  for (const doc of staleSnap.docs) {
    const data = doc.data();
    if (data.cancelled === true) {
      await doc.ref.delete();
      continue;
    }

    const uid = doc.id;
    console.log("Retrying stale pending deletion for user:", uid);

    try {
      const userSnap = await db.collection("users").doc(uid).get();
      if (userSnap.exists) {
        await db.collection("users").doc(uid).delete();
        console.log("Retry: user document deleted for:", uid);
      } else {
        await doc.ref.delete();
        console.log("Retry: user document already deleted, cleaned up pending record for:", uid);
      }
    } catch (error) {
      console.error("Retry failed for pending deletion:", uid, error);
    }
  }
});