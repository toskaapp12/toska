const { onDocumentDeleted, onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onRequest, onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getAuth } = require("firebase-admin/auth");
const { getAppCheck } = require("firebase-admin/app-check");
const { getMessaging } = require("firebase-admin/messaging");

initializeApp();
const db = getFirestore();

// Giphy API key — bound at runtime via Firebase Secret Manager so the value
// never lives in source control or function logs. Set with:
//   firebase functions:secrets:set GIPHY_KEY
const GIPHY_KEY = defineSecret("GIPHY_KEY");

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

// Paginated deletion of a user's posts (and their replies/likes/reflections
// subcollections). Shared by the onUserDocDeleted cascade and the
// resumePostDeletion scheduler so a heavy author whose cleanup exceeds a
// single invocation's cap can be drained across multiple runs.
// Returns { totalDeleted, capHit } — capHit=true means there are probably
// more posts to delete and the caller should re-queue.
async function cleanupPostsForUid(uid, maxIterations) {
  let batchCount = 0;
  let totalDeleted = 0;
  while (batchCount < maxIterations) {
    const batch = await db.collection("posts")
      .where("authorId", "==", uid)
      .limit(100)
      .get();
    if (batch.empty) break;
    for (const postDoc of batch.docs) {
      await deleteCollection(postDoc.ref.collection("replies"));
      await deleteCollection(postDoc.ref.collection("likes"));
      await deleteCollection(postDoc.ref.collection("reflections"));
      await postDoc.ref.delete();
    }
    batchCount++;
    totalDeleted += batch.size;
    if (batch.size < 100) break;
  }
  return { totalDeleted, capHit: batchCount >= maxIterations };
}

// ============================================================
// HTTP endpoint rate limiting (per-uid sliding window)
//
// Each (uid, endpoint) gets a doc at rateLimits/{uid}_{endpoint} with
// `count` and `windowStart` (epoch millis). Each call increments count;
// if the window has elapsed we reset. If count exceeds maxRequests, the
// caller is rejected with 429.
//
// Backs the giphyProxy and reconcileMyCounts endpoints — neither has a
// natural Firestore-rule throttle, so without this a single tampered
// client could exhaust the Giphy quota or storm the Admin SDK.
//
// Writes to a collection no client can touch (the catch-all fallthrough
// rule denies everything not explicitly allowed).
// ============================================================
async function checkRateLimit(uid, endpoint, maxRequests, windowSeconds) {
  const docRef = db.collection("rateLimits").doc(`${uid}_${endpoint}`);
  const now = Date.now();
  const windowMs = windowSeconds * 1000;
  try {
    const allowed = await db.runTransaction(async (transaction) => {
      const snap = await transaction.get(docRef);
      const data = snap.exists ? snap.data() : null;
      const windowStart = data?.windowStart || 0;
      const count = data?.count || 0;
      if (now - windowStart > windowMs) {
        transaction.set(docRef, { windowStart: now, count: 1 });
        return true;
      }
      if (count >= maxRequests) return false;
      transaction.set(docRef, { windowStart, count: count + 1 }, { merge: true });
      return true;
    });
    return allowed;
  } catch (err) {
    // Failing open on a transaction error is the right call here — a Firestore
    // hiccup shouldn't lock legitimate users out of features. Log so it shows
    // up if it ever becomes a pattern.
    console.warn(`checkRateLimit ${endpoint} for ${uid} errored, failing open:`, err.message);
    return true;
  }
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
      // Deterministic doc ID (= uid) so a retry of this trigger overwrites
      // the same finalPosts document instead of creating a second copy.
      // Previously addDocument auto-generated an ID, so any retry after a
      // post-write cleanup failure would archive the same user's last post
      // twice. uid is unique per user and the trigger fires exactly once
      // per user lifecycle (on user-doc delete), so collisions are
      // impossible by construction.
      await db.collection("finalPosts").doc(uid).set({
        authorHandle: postData.authorHandle || data.handle || "anonymous",
        text: postData.text || "",
        tag: postData.tag || null,
        likeCount: postData.likeCount || 0,
        createdAt: postData.createdAt || new Date(),
        leftAt: new Date(),
      });
    }

    // Delete the user's posts via the shared helper. Cap at 500 iterations =
    // 50,000 posts per invocation so the function doesn't run past its
    // timeout. If we hit the cap there are still posts to clean up — write
    // a continuation marker to postDeletionQueue; the scheduled
    // resumePostDeletion sweep picks it up on the next run and continues
    // draining until empty.
    const POST_CLEANUP_MAX_ITERATIONS = 500;
    const postCleanup = await cleanupPostsForUid(uid, POST_CLEANUP_MAX_ITERATIONS);
    if (postCleanup.capHit) {
      console.warn(
        `Post cleanup cap hit for user ${uid}: deleted ${postCleanup.totalDeleted} posts this pass. ` +
        "Queued for scheduled resumption."
      );
      try {
        await db.collection("postDeletionQueue").doc(uid).set({
          uid,
          queuedAt: FieldValue.serverTimestamp(),
          cumulativeDeleted: postCleanup.totalDeleted,
        });
      } catch (err) {
        // If the queue write fails we still want the remaining cascade to
        // run. Log and continue — ops can manually re-queue if needed.
        console.error(`postDeletionQueue write failed for ${uid}:`, err.message);
      }
    } else {
      console.log(`Deleted ${postCleanup.totalDeleted} posts for user ${uid}`);
    }

    // Counter decrements are owned by onFollowDeletedUpdateCounts, which
    // fires on every /users/{userId}/following/{followedId} delete. The
    // cascade used to manually safeDecrement here as well, which double-
    // decremented every counter that the trigger had already touched
    // (X.followingCount in the first loop directly; X.followerCount in
    // the second loop via the Phase-below subcollection delete on
    // users/uid/following). Letting the trigger be the single source of
    // truth keeps the math symmetric with normal follow→unfollow flows.
    //
    // First loop deletes the OTHER side of each follower's relationship
    // (their following list pointing at uid). Second loop deletes the
    // OTHER side of each followee's relationship (their followers list
    // pointing at uid). The bulk subcollection delete below handles the
    // mirror docs on uid's own subcollections — which fire the trigger
    // again for users/uid/following entries, decrementing each followee's
    // followerCount.
    const followersSnap = await db.collection("users").doc(uid).collection("followers").get();
    for (const doc of followersSnap.docs) {
      await db.collection("users").doc(doc.id).collection("following").doc(uid).delete();
    }
    const followingSnap = await db.collection("users").doc(uid).collection("following").get();
    for (const doc of followingSnap.docs) {
      await db.collection("users").doc(doc.id).collection("followers").doc(uid).delete();
    }

    const subs = ["saved", "liked", "following", "followers", "notifications", "blocked", "presence", "private"];
    for (const sub of subs) {
      await deleteCollection(db.collection("users").doc(uid).collection(sub));
    }

    // Best-effort: pendingDeletions may already be gone if the cascade was
    // triggered through the normal SettingsView path. NotFound is fine,
    // anything else worth logging so a real misconfiguration shows up.
    try {
      await db.collection("pendingDeletions").doc(uid).delete();
    } catch (err) {
      if (err.code !== 5 /* NOT_FOUND */) {
        console.warn(`pendingDeletions delete for ${uid} failed:`, err.message);
      }
    }

    const convoSnap = await db.collection("conversations")
      .where("participants", "array-contains", uid)
      .get();
    for (const convoDoc of convoSnap.docs) {
      await deleteCollection(convoDoc.ref.collection("messages"));
      try {
        await convoDoc.ref.update({
          [`participantHandles.${uid}`]: FieldValue.delete(),
        });
      } catch (err) {
        // Don't abort the cascade for a single convo update miss, but log
        // so persistent rule/quota issues surface in logs instead of
        // silently leaving orphaned participant handles.
        console.warn(`participantHandle scrub for convo ${convoDoc.id} failed:`, err.message);
      }
    }

    // Cross-user notifications authored by the deleted user — likes,
    // replies, follows, reposts, saves, messages all leave a doc in
    // the *recipient's* notifications subcollection with fromUserId
    // set to the actor. The user-doc trigger never visits those, so
    // they used to linger forever showing a deleted user's old handle.
    // collectionGroup walks every user's notifications in one query.
    try {
      // Hard-cap the loop so a user with millions of orphaned notifications
      // can't stall this function past its timeout. 50 iterations × 500 = 25K
      // notifications cleaned per invocation; any leftovers get swept the next
      // time the trigger replays.
      let totalDeletedNotifs = 0;
      for (let i = 0; i < 50; i++) {
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
    // Don't re-throw. The user document is already deleted by the time
    // this trigger fires, so re-throwing only marks the invocation as
    // failed in Cloud Functions logs and triggers a retry on a state
    // that no longer exists (the trigger is fire-once on document delete;
    // retries can't undo the cascade work that already succeeded). The
    // error is logged above with full context — that's the actionable
    // signal. Subcollection cleanup leftovers are cleaned up by the
    // scheduled monitorPendingDeletions / resumePostDeletion sweeps.
    console.error("Cleanup failed for user:", uid, error);
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

    // Atomically claim this notification. The previous shape was a
    // read-then-write that wasn't transactional — Pub/Sub redelivery
    // (Cloud Functions v2 retries on transient errors) could fire two
    // invocations whose `processed === true` reads both passed before
    // either ran the update, so both got past the gate and both sent
    // an APNs push. The user got duplicate notifications. Wrapping in
    // runTransaction gives a true compare-and-set: only the first
    // invocation to read processed=false claims the doc and proceeds;
    // any concurrent retry sees processed=true and bails.
    let notifData;
    try {
      notifData = await db.runTransaction(async (tx) => {
        const snap = await tx.get(notifRef);
        if (!snap.exists) return null;
        const d = snap.data();
        if (d?.processed === true) return null;
        tx.update(notifRef, { processed: true });
        return d;
      });
    } catch (err) {
      console.warn("sendPushNotification claim transaction failed:", err.message);
      return;
    }
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

    // FCM token + notification preferences now live in the owner-only
    // private subcollection so they aren't readable by other clients via
    // the broader users-doc reads policy. Fall back to the legacy main-doc
    // field for users created before the migration; their data will move
    // on next refresh.
    const privateSnap = await db
      .collection("users").doc(userId)
      .collection("private").doc("data")
      .get();
    const privateData = privateSnap.exists ? privateSnap.data() : {};

    let fcmToken = privateData.fcmToken || userData.fcmToken;
    if (!fcmToken) return;

    // pref(key) returns the value from private/data first (post-migration
    // state), falls back to the legacy main-doc field if private is silent.
    // Without this fallthrough, SettingsView writes the new value to
    // private and FieldValue.deletes the legacy field, leaving this
    // function reading `undefined` and bypassing the user's preference.
    const pref = (key) => {
      if (privateData[key] !== undefined) return privateData[key];
      return userData[key];
    };

    if (pref("pushEnabled") === false) return;

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
    if (settingKey && pref(settingKey) === false) return;

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

    // Badge reflects the recipient's actual unread-notification count so the
    // app-icon badge is meaningful instead of always "1". The new notification
    // was just created with isRead=false so it's already counted here. The
    // query is bounded (the in-app UI caps display at "99+"), and count()
    // aggregations are billed as a single read. Falls back to 1 if the query
    // fails — wrong but non-zero, matching the old behavior rather than
    // dropping the push entirely.
    let badge = 1;
    try {
      const countSnap = await db.collection("users").doc(userId)
        .collection("notifications")
        .where("isRead", "==", false)
        .count()
        .get();
      const unread = Number(countSnap.data().count);
      if (unread > 0) badge = unread;
    } catch (err) {
      console.warn("Badge count query failed, falling back to 1:", err.message);
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
            badge,
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
        // Compare-before-delete: between when we read fcmToken at the top
        // of this function and now, the user could have refreshed their
        // token (FCM rotates them on app reinstall, OS reset, etc.).
        // Naively deleting fcmToken in that window wipes a fresh, valid
        // token because *the previous token* failed. Use a transaction
        // and only delete if the stored value still equals the token
        // that actually failed.
        const failedToken = fcmToken;
        const privateRef = db.collection("users").doc(userId)
          .collection("private").doc("data");
        const userRef = db.collection("users").doc(userId);
        try {
          // Firestore transactions require all reads to complete before any
          // writes. The previous shape interleaved them (read pSnap → write
          // privateRef → read uSnap → write userRef), which throws "Firestore
          // transactions require all reads to be executed before all writes."
          // at runtime — landing in the catch below and silently never
          // cleaning up the dead token. Fixed: both reads first, then both
          // writes.
          await db.runTransaction(async (tx) => {
            const [pSnap, uSnap] = await Promise.all([
              tx.get(privateRef),
              tx.get(userRef),
            ]);
            if (pSnap.exists && pSnap.data()?.fcmToken === failedToken) {
              tx.update(privateRef, { fcmToken: FieldValue.delete() });
            }
            if (uSnap.exists && uSnap.data()?.fcmToken === failedToken) {
              tx.update(userRef, { fcmToken: FieldValue.delete() });
            }
          });
        } catch (delErr) {
          console.warn("FCM token cleanup transaction failed:", delErr.message);
        }
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

    // Grace window + auth-existence check. The client flow is:
    //   1. write pendingDeletions
    //   2. call Auth.auth().currentUser.delete() on the device
    //   3. if the auth delete fails (requiresRecentLogin, etc.), write cancelled=true
    //
    // If this trigger cascaded immediately on create, step 2's failure window
    // could land AFTER the user doc had already been deleted — destroying the
    // user's data even though their deletion was effectively cancelled.
    //
    // Waiting 10 seconds gives the client room to either (a) complete the auth
    // delete, or (b) write cancelled=true. Then we re-read the pendingDeletion
    // doc and verify the auth user is actually gone. If auth.delete() hasn't
    // landed, we defer to monitorPendingDeletions (scheduled every 60 minutes)
    // for eventual cascade.
    await new Promise((resolve) => setTimeout(resolve, 10_000));

    const fresh = await db.collection("pendingDeletions").doc(uid).get();
    if (!fresh.exists) return;
    if (fresh.data()?.cancelled === true) {
      console.log("Deletion cancelled for user:", uid);
      return;
    }

    // Verify the auth user is actually gone before cascading. If the client's
    // auth.delete() hasn't landed yet, bail — the scheduled monitor will pick
    // this up on the next sweep once the doc is older than its 10-minute
    // grace threshold.
    try {
      await getAuth().getUser(uid);
      console.log("Auth user still exists, deferring cascade to monitor:", uid);
      return;
    } catch (err) {
      if (err.code !== "auth/user-not-found") {
        console.warn("Unexpected getUser error for", uid, err.message);
        return;
      }
      // auth/user-not-found — client auth.delete() landed successfully.
    }

    console.log("Pending deletion authorized, cascading cleanup for user:", uid);

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

// Atomic FieldValue.increment(-1) instead of safeDecrement so concurrent
// create+delete races commute: if the delete runs before the create's
// increment lands, the count briefly dips negative and then converges to
// the correct value when the increment arrives. safeDecrement's
// transactional `current > 0` guard caused permanent upward drift in the
// reverse race (delete reads 0, skips the decrement, increment lands
// afterward). Same fix shape as onReplyDeletedUpdateCount above.
exports.onLikeDeletedUpdateCounts = onDocumentDeleted(
  "posts/{postId}/likes/{userId}",
  async (event) => {
    const postId = event.params.postId;
    const postRef = db.collection("posts").doc(postId);

    try {
      await postRef.update({ likeCount: FieldValue.increment(-1) });
    } catch (err) {
      console.warn("onLikeDeletedUpdateCounts: likeCount decrement failed:", err.message);
    }

    // Decrement the post author's totalLikes
    try {
      const postSnap = await postRef.get();
      if (!postSnap.exists) return;
      const authorId = postSnap.data().authorId;
      if (!authorId) return;
      await db.collection("users").doc(authorId).update({
        totalLikes: FieldValue.increment(-1),
      });
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

// Any delete path (user deleting their own reply, moderation, rate-limit,
// post cascade) fires this trigger. Uses atomic FieldValue.increment(-1)
// rather than safeDecrement so concurrent create+delete races commute to
// the correct final value: if the delete trigger runs before the create
// trigger's increment has landed, count briefly dips negative and then
// converges to the right number after the increment. safeDecrement's
// `current > 0` guard is asymmetric with atomic increment and caused
// permanent upward drift when moderation raced the create trigger.
//
// Previously, only onReplyCreatedModerate and rateLimitReplies attempted
// to decrement — both via safeDecrement — and user-deleted replies had no
// decrement path at all. The comment in ProfileView.deleteReply references
// this function by name; now it actually exists.
exports.onReplyDeletedUpdateCount = onDocumentDeleted(
  "posts/{postId}/replies/{replyId}",
  async (event) => {
    const postId = event.params.postId;
    try {
      await db.collection("posts").doc(postId).update({
        replyCount: FieldValue.increment(-1),
      });
    } catch (err) {
      console.warn("onReplyDeletedUpdateCount failed:", err.message);
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

// Mirror of onRepostCreatedUpdateCount. Without this, deleting a repost
// (by its author, by validatePost for blank/too-long text, by moderation,
// or by any other path) leaves the original post's repostCount inflated
// forever. Atomic FieldValue.increment(-1) — see the onReplyDeletedUpdateCount
// rationale for why the previous safeDecrement shape caused upward drift
// under concurrent create+delete races (the `current > 0` guard skipped
// the decrement when the increment hadn't landed yet, then the increment
// landed afterward and stuck).
exports.onRepostDeletedUpdateCount = onDocumentDeleted(
  "posts/{postId}",
  async (event) => {
    const postData = event.data.data();
    if (!postData) return;
    if (postData.isRepost !== true) return;
    const originalPostId = postData.originalPostId;
    if (!originalPostId || typeof originalPostId !== "string") return;

    try {
      await db.collection("posts").doc(originalPostId).update({
        repostCount: FieldValue.increment(-1),
      });
    } catch (err) {
      console.warn("onRepostDeletedUpdateCount failed:", err.message);
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

// Atomic FieldValue.increment(-1) for the same race-safety reason
// documented on onReplyDeletedUpdateCount above. safeDecrement's
// transactional `current > 0` guard skipped the decrement under a
// rapid follow→unfollow race where the create-trigger increment hadn't
// landed yet, leaving permanent upward drift.
exports.onFollowDeletedUpdateCounts = onDocumentDeleted(
  "users/{userId}/following/{followedId}",
  async (event) => {
    const userId = event.params.userId;
    const followedId = event.params.followedId;

    try {
      await db.collection("users").doc(userId).update({
        followingCount: FieldValue.increment(-1),
      });
    } catch (err) {
      console.warn("onFollowDeletedUpdateCounts: followingCount decrement failed:", err.message);
    }
    try {
      await db.collection("users").doc(followedId).update({
        followerCount: FieldValue.increment(-1),
      });
    } catch (err) {
      console.warn("onFollowDeletedUpdateCounts: followerCount decrement failed:", err.message);
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

// Atomic FieldValue.increment(-1) — same rationale as the other counter
// triggers. The previous transactional shape with a `current > 0` guard
// was the asymmetric pattern that caused upward drift on concurrent
// create+delete races (the no-op delete branch left the matching
// increment to land afterward and stick). Tag counts can briefly dip
// negative under concurrent create+delete and converge correctly once
// both writes complete.
exports.onPostDeletedUpdateTagCounts = onDocumentDeleted("posts/{postId}", async (event) => {
  const postData = event.data.data();
  if (!postData) return;
  const tag = postData.tag;
  if (!tag || typeof tag !== "string") return;
  if (postData.isRepost === true) return;

  try {
    await db.collection("meta").doc("tagCounts").set(
      { [tag]: FieldValue.increment(-1), updatedAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
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
    // Counter decrements are handled by onReplyDeletedUpdateCount on the
    // subsequent delete trigger; no safeDecrement needed here (would race
    // with the create-trigger's increment and corrupt the count).
    if (typeof text !== "string" || text.trim().length === 0) {
      console.warn(`Deleting reply ${replyId} — missing or blank text`);
      await db.collection("posts").doc(postId).collection("replies").doc(replyId).delete();
      return;
    }

    if (text.length > 500) {
      console.warn(`Deleting reply ${replyId} — text too long (${text.length} chars)`);
      await db.collection("posts").doc(postId).collection("replies").doc(replyId).delete();
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

// Phrases that strongly indicate someone is sharing identifying info.
// We deliberately removed the looser entries that produced false positives
// on benign sentences:
//   "her/his/their name is" → matches "his name is mud", "her name is karen"
//   "lives in/on" → matches "lives in fear", "lives on hope"
//   "works at" → matches "works at the heart of it"
//   "find me" → matches "find me a reason to..."
//   "goes to" → matches "goes to show that..."
// What remains is wording that is much harder to use innocently in a post.
const identifyingPhrases = [
  "lives at",
  "school name",
  "phone number", "my number", "text me", "call me",
  "dm me", "follow me", "look me up",
  "last name", "full name",
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
// Shared moderation patterns
//
// Previously duplicated inside onPostCreated, onReplyCreatedModerate,
// and onMessageCreatedModerate — three near-identical copies meant any
// new slur, threat phrase, or harassment pattern had to be edited in
// three places. Drift was a real risk. These constants are the single
// source; the three triggers compose them (with surface-specific
// extras like spamPatterns for posts only).
//
// Adding a new pattern: extend the relevant array here. To make it
// surface-specific, keep it inline in the trigger that needs it.
// ============================================================

const MOD_HATE = [
  /n[i1!]gg/i, /f[a@]gg/i, /r[e3]t[a@]rd/i, /tr[a@]nny/i, /d[yi1]ke/i,
  /ch[i1]nk/i, /sp[i1]ck?/i, /k[i1]ke/i, /w[e3]tb[a@]ck/i, /g[o0][o0]k/i,
  /c[o0][o0]n/i, /towelhead/i, /raghead/i, /beaner/i, /zipperhead/i,
];

const MOD_THREAT = [
  "kill you", "kill him", "kill her", "kill them",
  "shoot you", "shoot him", "shoot her", "shoot them", "shoot up",
  "stab you", "stab him", "stab her", "stab them",
  "shoot up the", "blow up", "burn down",
  "rape you", "rape her", "rape him",
  "find you and", "find where you live", "know where you live",
  "hunt you down", "come for you",
  "gonna hurt you", "going to hurt you",
  "beat you", "beat the shit",
  "slit your throat", "put a bullet",
];

const MOD_SEXUAL = [
  /porn/i, /hentai/i, /\bxxx\b/i,
  /\bnudes\b/i, /send nudes/i, /dick pic/i, /pussy pic/i,
  /jerk off/i, /jack off/i, /masturbat/i,
  /cum on/i, /cum in/i, /creampie/i,
  /blowjob/i, /blow job/i, /handjob/i, /hand job/i,
  /anal sex/i, /oral sex/i,
  /sex tape/i, /sextape/i, /sext me/i, /sexting/i,
  /onlyfans/i, /nsfw/i,
];

const MOD_HARASSMENT = [
  "kill yourself", "kys", "go die", "you should die",
  "hope you die", "drink bleach", "neck yourself",
  "nobody likes you", "youre worthless", "you deserve to die",
];

const MOD_CONCERNING = [
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

// ============================================================
// Content moderation — flag posts with prohibited content
//
// Helpers shared by onPostCreated + onPostUpdated. Edits to a post used to
// completely bypass moderation because the original moderation triggers
// fired on `onDocumentCreated` only — a user could publish clean text,
// watch it pass moderation, then edit in slurs/threats/PII/links and
// nothing would re-flag it. Refactoring the pattern lookup into a helper
// (and adding an onPostUpdated trigger below) closes that gap without
// duplicating the pattern lists.
// ============================================================

const SPAM_PATTERNS = [
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

function computePostFlagReason(rawText) {
  const text = (rawText || "").toLowerCase();
  if (SPAM_PATTERNS.some((p) => p.test(text))) return "spam_or_commercial";
  if (MOD_HATE.some((p) => p.test(text))) return "hate_speech";
  if (MOD_THREAT.some((phrase) => text.includes(phrase))) return "targeted_threat";
  if (MOD_SEXUAL.some((p) => p.test(text))) return "sexual_content";
  if (containsPII(rawText || "")) return "personal_information";
  if (containsURL(rawText || "")) return "contains_link";
  return null;
}

function isPostConcerning(rawText) {
  const text = (rawText || "").toLowerCase();
  return MOD_CONCERNING.some((phrase) => text.includes(phrase));
}

// Repeat-offender tracking. Previously 3 flagged posts all-time → permanent
// restriction with no user-facing recovery path (admin unrestrict only),
// which trapped users whose content tripped the (high false-positive-rate)
// PII / link detectors months earlier. The new shape:
//   - count only recent flags (7 days) so stale incidents don't haunt a user
//   - raise threshold to 5 so a single bad afternoon doesn't lock the account
//   - set restrictedUntil = now + 48h so the restriction auto-expires
//     without admin intervention (UserHandleCache consults this timestamp)
// Admin-set restrictions (restrictedBy != "system" and no restrictedUntil)
// still persist until an admin clears them — this only softens the auto path.
//
// Idempotent under repeated invocation: re-restricting an already-restricted
// user just rewrites the same fields; auditUserRestriction skips when the
// `restricted` flag didn't actually flip, so no audit-log noise.
async function checkRepeatOffenderPosts(authorId) {
  if (!authorId) return;
  try {
    const flaggedSnap = await db.collection("posts")
      .where("authorId", "==", authorId)
      .where("flagged", "==", true)
      .limit(20)
      .get();
    const sevenDaysAgoMs = Date.now() - 7 * 24 * 60 * 60 * 1000;
    const recentFlagged = flaggedSnap.docs.filter((doc) => {
      const data = doc.data();
      // Rate-limit flags are already their own throttle punishment
      // (post hidden from feed). Letting them count toward the 5-flag
      // auto-restrict threshold is double-jeopardy and would lock a
      // user out just for posting too fast — not a policy violation.
      // Count only content-violation flags (hate, threat, sexual, PII,
      // spam, etc.).
      if (data.flagReason === "rate_limit_exceeded") return false;
      const flaggedAt = data.flaggedAt;
      if (!flaggedAt || typeof flaggedAt.toDate !== "function") return false;
      return flaggedAt.toDate().getTime() > sevenDaysAgoMs;
    });
    if (recentFlagged.length >= 5) {
      const restrictedUntil = Timestamp.fromDate(new Date(Date.now() + 48 * 60 * 60 * 1000));
      await db.collection("users").doc(authorId).update({
        restricted: true,
        restrictedAt: FieldValue.serverTimestamp(),
        restrictedUntil,
        // Distinguish auto-restrictions from admin actions in adminAuditLog —
        // without this, auditUserRestriction falls back to "unknown". Admin
        // restrictions set restrictedBy to the admin's uid and omit
        // restrictedUntil (no auto-expiry).
        restrictedBy: "system",
      });
      console.log(`User ${authorId} auto-restricted (${recentFlagged.length} recent flags) until ${restrictedUntil.toDate()}`);
    }
  } catch (err) {
    console.warn("Repeat offender check failed:", err.message);
  }
}

exports.onPostCreated = onDocumentCreated("posts/{postId}", async (event) => {
  const postId = event.params.postId;
  const postData = event.data.data();
  if (!postData) return;

  if (postData.flagged === true) return;

  const flagReason = computePostFlagReason(postData.text);
  const concerning = isPostConcerning(postData.text);

  if (flagReason) {
    await db.collection("posts").doc(postId).update({
      flagged: true,
      flaggedAt: FieldValue.serverTimestamp(),
      flagReason,
    });
    console.log(`Post ${postId} flagged: ${flagReason}`);
    await checkRepeatOffenderPosts(postData.authorId);
  } else if (concerning) {
    await db.collection("posts").doc(postId).update({
      concerningContent: true,
      flaggedAt: FieldValue.serverTimestamp(),
    });
    console.log(`Post ${postId} marked as concerning content`);
  }
});

// Re-runs moderation when an existing post's text changes. Without this,
// EditPostView (PostDetailView.swift) lets an author publish clean text,
// pass the create-time moderation pass, then edit slurs/threats/PII into
// the body — the post stays unflagged and visible. The trigger fires on
// every update, but bails fast unless `text` actually changed (this also
// breaks the recursion loop with the trigger's own flagged/flagReason
// writes, which don't touch text).
exports.onPostUpdated = onDocumentUpdated("posts/{postId}", async (event) => {
  const postId = event.params.postId;
  const before = (event.data && event.data.before && event.data.before.data()) || {};
  const after = (event.data && event.data.after && event.data.after.data()) || {};

  // Skip when text didn't change. This covers two cases:
  //   - The trigger's own writes (flagged, flaggedAt, flagReason,
  //     concerningContent) keep `text` constant — without this guard the
  //     update we issue below re-fires this handler in an infinite loop.
  //   - Any other unrelated field update (editedAt without text, future
  //     metadata fields, etc.) doesn't need a moderation pass.
  if (before.text === after.text) return;

  const flagReason = computePostFlagReason(after.text);
  const concerning = isPostConcerning(after.text);

  if (flagReason) {
    // Don't rewrite the doc if it's already flagged with the same reason —
    // saves a Firestore write per no-change re-flag and keeps flaggedAt
    // pinned to the original detection time.
    if (after.flagged === true && after.flagReason === flagReason) return;
    await db.collection("posts").doc(postId).update({
      flagged: true,
      flaggedAt: FieldValue.serverTimestamp(),
      flagReason,
    });
    console.log(`Post ${postId} re-flagged after edit: ${flagReason}`);
    await checkRepeatOffenderPosts(after.authorId);
  } else if (concerning && after.concerningContent !== true) {
    await db.collection("posts").doc(postId).update({
      concerningContent: true,
      flaggedAt: FieldValue.serverTimestamp(),
    });
    console.log(`Post ${postId} marked as concerning content after edit`);
  }
});

// ============================================================
// Content moderation — flag replies with prohibited content
//
// Reply moderation policy mirrors post moderation but with a different
// remediation matrix: hate/harassment/threat/sexual content gets the reply
// deleted outright; PII and link flags get a soft "flagged" marker (the
// false-positive rate on these patterns is high, so we leave the doc and
// let admins review). Edit-after-publish bypassed both routes until the
// onReplyUpdated trigger below — same gap that existed for posts.
// ============================================================

function computeReplyFlagReason(rawText) {
  const text = (rawText || "").toLowerCase();
  if (MOD_HATE.some((p) => p.test(text))) return "hate_speech";
  if (MOD_HARASSMENT.some((p) => text.includes(p))) return "harassment";
  if (MOD_THREAT.some((p) => text.includes(p))) return "targeted_threat";
  if (MOD_SEXUAL.some((p) => p.test(text))) return "sexual_content";
  if (containsPII(rawText || "")) return "personal_information";
  if (containsURL(rawText || "")) return "contains_link";
  return null;
}

async function applyReplyModeration(postId, replyId, flagReason) {
  if (!flagReason) return;
  if (flagReason === "personal_information" || flagReason === "contains_link") {
    // PII and links: flag for review instead of deleting (higher false positive rate)
    await db.collection("posts").doc(postId).collection("replies").doc(replyId).update({
      flagged: true,
      flaggedAt: FieldValue.serverTimestamp(),
      flagReason,
    });
    console.log(`Reply ${replyId} on post ${postId} flagged: ${flagReason}`);
  } else {
    // Counter decrement is handled by onReplyDeletedUpdateCount on the
    // subsequent delete trigger.
    await db.collection("posts").doc(postId).collection("replies").doc(replyId).delete();
    console.log(`Reply ${replyId} on post ${postId} deleted: ${flagReason}`);
  }
}

exports.onReplyCreatedModerate = onDocumentCreated(
  "posts/{postId}/replies/{replyId}",
  async (event) => {
    const data = event.data.data();
    if (!data) return;
    const flagReason = computeReplyFlagReason(data.text);
    if (flagReason) {
      await applyReplyModeration(event.params.postId, event.params.replyId, flagReason);
    }
  }
);

// Re-runs reply moderation when text changes. Reply update is allowed by
// firestore.rules (the reply author can edit their own reply); without this
// trigger, an author could post a clean reply, pass create-time moderation,
// then edit in slurs/threats/PII and the reply would never be re-flagged
// or deleted. iOS doesn't currently expose reply edit, but a tampered
// client can issue the update directly so the server-side gap is real.
//
// Same anti-recursion guard as onPostUpdated — bail unless `text` actually
// changed, so the trigger's own flagged-field updates don't re-fire it.
// (Severe-content path issues a delete, which fires onDocumentDeleted —
// not this handler — so no loop concern there either.)
exports.onReplyUpdated = onDocumentUpdated(
  "posts/{postId}/replies/{replyId}",
  async (event) => {
    const before = (event.data && event.data.before && event.data.before.data()) || {};
    const after = (event.data && event.data.after && event.data.after.data()) || {};
    if (before.text === after.text) return;

    const flagReason = computeReplyFlagReason(after.text);
    if (!flagReason) return;
    // Skip the soft-flag rewrite if it's already flagged with the same reason.
    if (after.flagged === true && after.flagReason === flagReason
        && (flagReason === "personal_information" || flagReason === "contains_link")) {
      return;
    }
    await applyReplyModeration(event.params.postId, event.params.replyId, flagReason);
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

    let flagReason = null;
    if (MOD_HATE.some((p) => p.test(text))) flagReason = "hate_speech";
    else if (MOD_HARASSMENT.some((p) => text.includes(p))) flagReason = "harassment";
    else if (MOD_THREAT.some((p) => text.includes(p))) flagReason = "targeted_threat";
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
        // The client transaction in ConversationView.sendMessage already
        // incremented messageCount.{senderId} and tagged the message with
        // clientCountedV1: true, which makes onMessageCreatedUpdateCount
        // skip its server-side increment. If we delete the message without
        // also decrementing here, the sender's per-conversation count is
        // permanently inflated by one for every moderated message — they
        // hit the 5-message cap with fewer real messages than they sent.
        if (data.senderId) {
          try {
            await db.collection("conversations").doc(convoId).update({
              [`messageCount.${data.senderId}`]: FieldValue.increment(-1),
            });
          } catch (err) {
            console.warn(`messageCount decrement after moderation delete failed:`, err.message);
          }
        }
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
      // Counter decrement handled by onReplyDeletedUpdateCount.
      await db.collection("posts").doc(postId).collection("replies").doc(replyId).delete();
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

// Caps a uid to 20 reports per hour. Without this, a malicious account can
// flood the moderation queue, drowning legitimate reports and degrading the
// admin.html dashboard. Mirrors rateLimitNotifications: query recent docs
// by reportedBy in a sliding window, delete the offending doc if the cap is
// exceeded. Index requirement: reports/(reportedBy ASC, createdAt DESC) —
// added to firestore.indexes.json.
exports.rateLimitReports = onDocumentCreated(
  "reports/{reportId}",
  async (event) => {
    const reportData = event.data.data();
    if (!reportData) return;
    const reportedBy = reportData.reportedBy;
    if (!reportedBy) return;

    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    const recentSnap = await db.collection("reports")
      .where("reportedBy", "==", reportedBy)
      .where("createdAt", ">", Timestamp.fromDate(oneHourAgo))
      .orderBy("createdAt", "desc")
      .limit(25)
      .get();

    if (recentSnap.size > 20) {
      console.log("Report rate limit exceeded for:", reportedBy);
      await db.collection("reports").doc(event.params.reportId).delete();
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

    // Messages from the new client carry clientCountedV1: true because they
    // increment messageCount inside the same transaction as the message
    // create. Skipping here prevents a double-count. Old-client messages
    // (no marker) still get incremented server-side so legacy installs
    // continue to enforce the per-user 5-message cap.
    if (messageData.clientCountedV1 === true) return;

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
// Scheduled post-deletion continuation — drains postDeletionQueue
//
// When onUserDocDeleted's post-cleanup pass hits its per-invocation cap
// (50K posts), it writes a postDeletionQueue/{uid} marker instead of
// leaving the remaining posts orphaned. This scheduler resumes cleanup
// across invocations until the user has no remaining posts.
//
// Processes up to 10 queued users per invocation. Each user gets up to
// 500 iterations × 100 posts = 50K more deleted this pass; if still more
// remain, the queue entry stays in place for the next sweep. Hourly
// cadence means a truly heavy author (>50K extra posts) takes O(hours)
// to drain — acceptable tradeoff vs a bigger-cap run that could time out
// mid-cascade and strand data at an unknown point.
// ============================================================

exports.resumePostDeletion = onSchedule("every 60 minutes", async () => {
  const queueSnap = await db.collection("postDeletionQueue").limit(10).get();
  if (queueSnap.empty) {
    console.log("postDeletionQueue is empty.");
    return;
  }

  for (const queueDoc of queueSnap.docs) {
    const uid = queueDoc.id;
    console.log(`Resuming post deletion for user ${uid}`);
    try {
      const result = await cleanupPostsForUid(uid, 500);
      if (result.capHit) {
        // Still more posts remain. Update marker with incremental progress
        // and leave the entry in the queue for the next sweep.
        await queueDoc.ref.update({
          lastResumedAt: FieldValue.serverTimestamp(),
          cumulativeDeleted: FieldValue.increment(result.totalDeleted),
        });
        console.log(`Partial cleanup for ${uid}: +${result.totalDeleted} posts, staying in queue.`);
      } else {
        console.log(`Completed post deletion for ${uid}: +${result.totalDeleted} posts this pass.`);
        await queueDoc.ref.delete();
      }
    } catch (err) {
      console.error(`resumePostDeletion failed for ${uid}:`, err.message);
      // Leave in queue; next invocation will retry.
    }
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

// ============================================================
// Giphy proxy — keeps the API key off the client.
//
// Replaces the previous pattern where the Giphy API key was hardcoded in
// GifPickerView.swift, exposing it to anyone who unzipped the IPA. The
// client now hits this endpoint with its Firebase ID token in the
// Authorization header; we verify the token before forwarding to Giphy
// so abandoned/anonymous attackers can't burn the quota.
//
// Returns the raw Giphy response shape (data: [...]) so the iOS picker's
// existing JSON parsing keeps working without changes to its data model.
// ============================================================

exports.giphyProxy = onRequest(
  // App Check enforcement is gated manually below because the
  // `enforceAppCheck` option only takes effect on onCall callables —
  // `HttpsOptions` (used by onRequest) explicitly omits it. Confirmed in
  // node_modules/firebase-functions/lib/v2/providers/https.d.ts:14.
  { secrets: [GIPHY_KEY], cors: false },
  async (req, res) => {
    if (req.method !== "GET") {
      res.status(405).json({ error: "method not allowed" });
      return;
    }

    // App Check: validate the X-Firebase-AppCheck header against the
    // Admin SDK. Restricts callers to a Toska binary attested by App
    // Attest (release) or the debug provider (dev). Without this, anyone
    // with a Firebase ID token from any client app pointed at our
    // project can hit the proxy and burn the Giphy quota.
    const appCheckToken = req.get("X-Firebase-AppCheck");
    if (!appCheckToken) {
      res.status(401).json({ error: "missing app check token" });
      return;
    }
    try {
      await getAppCheck().verifyToken(appCheckToken);
    } catch (err) {
      res.status(401).json({ error: "invalid app check token" });
      return;
    }

    // Verify Firebase ID token. Without this, the endpoint is a free
    // anonymous proxy that anyone with the URL can hammer.
    const authHeader = req.get("Authorization") || "";
    const match = authHeader.match(/^Bearer\s+(.+)$/);
    if (!match) {
      res.status(401).json({ error: "missing bearer token" });
      return;
    }
    let giphyUid;
    try {
      const decoded = await getAuth().verifyIdToken(match[1]);
      giphyUid = decoded.uid;
    } catch (err) {
      res.status(401).json({ error: "invalid token" });
      return;
    }

    // 60 GIF picker calls per minute per uid is comfortably above legitimate
    // browsing (one search + a few page loads) but well below what a tampered
    // client would need to exhaust the Giphy free-tier quota in a day.
    const allowed = await checkRateLimit(giphyUid, "giphyProxy", 60, 60);
    if (!allowed) {
      res.status(429).json({ error: "rate limit exceeded" });
      return;
    }

    const mode = req.query.mode === "search" ? "search" : "trending";
    const limit = Math.min(parseInt(req.query.limit, 10) || 30, 50);
    const rating = "pg-13";

    let upstream;
    if (mode === "search") {
      const q = (req.query.q || "").toString().slice(0, 100);
      if (!q.trim()) {
        res.status(400).json({ error: "missing q for search mode" });
        return;
      }
      upstream = `https://api.giphy.com/v1/gifs/search?api_key=${encodeURIComponent(GIPHY_KEY.value())}&q=${encodeURIComponent(q)}&limit=${limit}&rating=${rating}`;
    } else {
      upstream = `https://api.giphy.com/v1/gifs/trending?api_key=${encodeURIComponent(GIPHY_KEY.value())}&limit=${limit}&rating=${rating}`;
    }

    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 10_000);
      const r = await fetch(upstream, { signal: controller.signal });
      clearTimeout(timeout);
      if (!r.ok) {
        // Normalised error so we don't leak that Giphy is the upstream
        // (it's already obvious from CSP / network logs but no need to
        // hand it to a casual probe).
        console.warn(`giphyProxy upstream ${r.status}`);
        res.status(502).json({ error: "upstream unavailable" });
        return;
      }
      // Defend against an upstream returning a runaway payload (compromised
      // upstream, DNS hijack, mistaken API change). Real Giphy responses for
      // limit=30 are < 100KB. 500KB cap is loose enough to avoid false
      // positives but tight enough to bound the client memory we'd hand it.
      const text = await r.text();
      if (text.length > 500_000) {
        console.warn(`giphyProxy oversized response: ${text.length} bytes`);
        res.status(502).json({ error: "upstream response too large" });
        return;
      }
      let json;
      try {
        json = JSON.parse(text);
      } catch (parseErr) {
        console.warn("giphyProxy upstream returned non-JSON");
        res.status(502).json({ error: "upstream malformed" });
        return;
      }
      // Cache the trending feed for a minute at the edge. Search results
      // are user-specific enough that caching them risks cross-user
      // pollution, so they go uncached.
      if (mode === "trending") {
        res.set("Cache-Control", "public, max-age=60");
      }
      res.json(json);
    } catch (err) {
      // Defense in depth: Node fetch can include the request URL in error
      // messages (DNS failures, abort traces, etc.) which would log the
      // GIPHY_KEY query parameter to Cloud Logging. Strip api_key=...
      // before any error message reaches console. Also strips it from
      // the .stack field for the same reason.
      const sanitize = (s) => (s || "").replace(/api_key=[^&\s"]*/g, "api_key=***");
      console.warn("giphyProxy failed:", sanitize(err.message));
      res.status(502).json({ error: "upstream failure" });
    }
  }
);

// ============================================================
// Counter reconciliation — server-authoritative followerCount /
// followingCount for the authenticated user.
//
// Replaces a previous client-side path in ProfileView where the iOS app
// counted the followers/following subcollections itself and wrote the
// numbers back to the main user doc. That worked but meant the client
// was the source of truth on engagement counts — a tampered build could
// inflate them even with no actual followers.
//
// Now: the client calls this endpoint, the function counts the
// subcollections via the Admin SDK (which bypasses Firestore rules), and
// writes the corrected counts. The client never touches the count fields
// directly. We don't need to tighten the rules to forbid client counter
// writes today (would require coordinated rollout), but this is the
// foundation that makes that lockdown safe later.
// ============================================================

exports.reconcileMyCounts = onRequest(
  { cors: false },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "method not allowed" });
      return;
    }

    const appCheckToken = req.get("X-Firebase-AppCheck");
    if (!appCheckToken) {
      res.status(401).json({ error: "missing app check token" });
      return;
    }
    try {
      await getAppCheck().verifyToken(appCheckToken);
    } catch (err) {
      res.status(401).json({ error: "invalid app check token" });
      return;
    }

    const authHeader = req.get("Authorization") || "";
    const match = authHeader.match(/^Bearer\s+(.+)$/);
    if (!match) {
      res.status(401).json({ error: "missing bearer token" });
      return;
    }
    let uid;
    try {
      const decoded = await getAuth().verifyIdToken(match[1]);
      uid = decoded.uid;
    } catch (err) {
      res.status(401).json({ error: "invalid token" });
      return;
    }

    // ProfileView gates this client-side to once per 24h via UserDefaults,
    // but UserDefaults is wipeable by reinstall and the value is not
    // server-trusted. 6 reconciles per day per uid is generous for legitimate
    // multi-device use while still bounding a tampered build's blast radius.
    const allowed = await checkRateLimit(uid, "reconcileMyCounts", 6, 86400);
    if (!allowed) {
      res.status(429).json({ error: "rate limit exceeded" });
      return;
    }

    try {
      const userRef = db.collection("users").doc(uid);
      const [followerSnap, followingSnap] = await Promise.all([
        userRef.collection("followers").count().get(),
        userRef.collection("following").count().get(),
      ]);
      const followerCount  = followerSnap.data().count;
      const followingCount = followingSnap.data().count;
      await userRef.update({ followerCount, followingCount });
      res.json({ followerCount, followingCount });
    } catch (err) {
      console.warn("reconcileMyCounts failed:", err.message);
      res.status(500).json({ error: "reconcile failed" });
    }
  }
);

// ============================================================
// confirmAdult — server-only writer for the age-gate field
//
// Closes the bypass where a tampered client could set
// `confirmedAdult: true` directly on its own user doc to defeat
// the hasConfirmedAdult() rules check. With this endpoint:
//   - firestore.rules denies clients from writing
//     `confirmedAdult` / `confirmedAdultAt` at user-doc create
//     OR update.
//   - This function uses the Admin SDK (which bypasses rules) to
//     write the fields after verifying App Check + ID token.
//   - App Check enforcement (App Attest in release) restricts the
//     endpoint to attested Toska binaries — a tampered or
//     non-attested client cannot call it at all.
//
// Idempotent: safe to invoke any number of times; later calls
// just refresh `confirmedAdultAt`. Used by:
//   - CreateAccountView after the inline age + policy gate
//     (replacing the previous direct field write at user-doc
//     create time)
//   - ToskaTheme.recordPolicyAcceptance for Apple/Google signups
//     that hit the age gate after AppleSignInHelper has already
//     created the user doc
//
// Uses update() rather than set+merge so the function fails loudly
// (NOT_FOUND) if the user doc doesn't exist — the legitimate
// callers always create the doc first.
// ============================================================

// Migrated from onRequest to onCall:
//   - onCall bypasses Cloud Run's allUsers IAM requirement that the
//     toskastaging org policy forbids — call goes through Firebase's
//     own RPC pipeline, not a public Cloud Run HTTP endpoint.
//   - Auth + App Check are handled by the Firebase SDK on the client and
//     verified by onCall's runtime; no manual ID token verification or
//     X-Firebase-AppCheck header parsing here.
//   - Errors are thrown as HttpsError; the iOS client decodes them into
//     typed FunctionsErrorCode values automatically.
//
// `enforceAppCheck: true` rejects requests whose App Check token is
// missing or invalid before our handler runs.
exports.confirmAdult = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "must be signed in");
    }
    const uid = request.auth.uid;

    // 5 calls/hour/uid — see prior commit; same bound applies.
    const allowed = await checkRateLimit(uid, "confirmAdult", 5, 3600);
    if (!allowed) {
      throw new HttpsError("resource-exhausted", "rate limit exceeded");
    }

    try {
      await db.collection("users").doc(uid).update({
        confirmedAdult: true,
        confirmedAdultAt: FieldValue.serverTimestamp(),
      });
      return { ok: true };
    } catch (err) {
      // NOT_FOUND (code 5): user doc doesn't exist yet because the
      // client called us before the signup flow finished creating it.
      // Surface as failed-precondition so the iOS retry path
      // (confirmAdultServerSide's once-with-backoff loop) can decide
      // to retry once after a short sleep.
      if (err.code === 5) {
        throw new HttpsError("failed-precondition", "user doc missing");
      }
      console.warn("confirmAdult failed:", err.message);
      throw new HttpsError("internal", "write failed");
    }
  }
);

// ============================================================
// Admin audit log
//
// Mirrors admin-initiated writes to a write-once adminAuditLog collection
// so we have a record of who did what when. Two surfaces today:
//   - users/{uid} restricted / unrestricted (admin sets restricted=true)
//   - reports/{reportId} status changes (resolve / dismiss)
//
// Firestore triggers don't carry request.auth context, so we infer the
// acting admin from the data itself: user.restrictedBy and report.reviewedBy
// are written by the admin's client and protected by the rules. If those
// fields are ever spoofed by a bug, the audit log will show "unknown" but
// the action itself still fires.
//
// adminAuditLog rules (firestore.rules):
//   read:  admins only
//   write: no one (server-side Admin SDK only)
// ============================================================

async function writeAuditEntry(entry) {
  try {
    await db.collection("adminAuditLog").add({
      ...entry,
      createdAt: FieldValue.serverTimestamp(),
    });
  } catch (err) {
    console.error("adminAuditLog write failed:", err.message);
  }
}

exports.auditUserRestriction = onDocumentUpdated(
  "users/{userId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after  = event.data.after.data() || {};
    if (before.restricted === after.restricted) return; // unrelated update

    const action = after.restricted === true ? "user.restrict" : "user.unrestrict";
    await writeAuditEntry({
      action,
      adminUid: after.restrictedBy || before.restrictedBy || "unknown",
      targetType: "user",
      targetId: event.params.userId,
      targetHandle: after.handle || before.handle || null,
      before: { restricted: before.restricted ?? false },
      after:  { restricted: after.restricted ?? false },
    });
  }
);

exports.auditReportResolution = onDocumentUpdated(
  "reports/{reportId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after  = event.data.after.data() || {};
    if (before.status === after.status) return; // unrelated update

    await writeAuditEntry({
      action: `report.${after.status || "update"}`,
      adminUid: after.reviewedBy || "unknown",
      targetType: "report",
      targetId: event.params.reportId,
      reportType: after.type || before.type || null,
      before: { status: before.status || null },
      after:  { status: after.status  || null, action: after.action || null },
    });
  }
);