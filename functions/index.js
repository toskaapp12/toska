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

    const subs = ["saved", "liked", "following", "followers", "notifications", "blocked", "presence"];
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
    const fromHandle = notifData.fromHandle || "someone";
    const message = notifData.message || "";

    const userDoc = await db.collection("users").doc(userId).get();
    if (!userDoc.exists) return;

    const userData = userDoc.data();
    const fcmToken = userData.fcmToken;
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

    switch (type) {
      case "reply":
        title = `${fromHandle} replied`;
        body = message ? message.substring(0, 100) : "someone responded to your post";
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
        await db.collection("users").doc(userId).update({
          fcmToken: FieldValue.delete(),
        });
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
  ];

  const hatePatterns = [
    /\b(n[i1]gg[ae]r|f[a@]gg[o0]t|ch[i1]nk|sp[i1]c|k[i1]ke|tr[a@]nny)\b/i,
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
  }

  const isConcerning = concerningPhrases.some((phrase) => text.includes(phrase));

  if (flagReason) {
    await db.collection("posts").doc(postId).update({
      flagged: true,
      flaggedAt: FieldValue.serverTimestamp(),
      flagReason,
    });
    console.log(`Post ${postId} flagged: ${flagReason}`);
  } else if (isConcerning) {
    await db.collection("posts").doc(postId).update({
      concerningContent: true,
      flaggedAt: FieldValue.serverTimestamp(),
    });
    console.log(`Post ${postId} marked as concerning content`);
  }
});

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

    const batch = db.batch();
    for (const doc of expiredSnap.docs) {
      batch.delete(doc.ref);
    }
    await batch.commit();

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