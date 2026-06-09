const { onDocumentDeleted, onDocumentCreated, onDocumentUpdated, onDocumentWritten } = require("firebase-functions/v2/firestore");
const { containsNameOrIdentifyingInfo, aggressiveNormalizeForNameMatch } = require("./moderation");
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

// Bounded paginated deletion of every doc in a collection. Caps at
// `maxBatches` 499-doc commits per invocation so a single call can't
// run past a function's timeout — earlier shape was an `while (true)`
// loop, fine for typical per-post subcollections but capable of
// stranding a viral post's 100k+ likes mid-cleanup.
//
// Returns `{ totalDeleted, capHit }`. Most callers ignore the return —
// the cap is just a safety net. Callers that orchestrate continuation
// (cleanupPostsForUid + the userDeletionCleanupQueue path) check
// capHit and queue the rest.
async function deleteCollection(collectionRef, maxBatches = 100) {
  const batchSize = 499;
  let batches = 0;
  let totalDeleted = 0;
  while (batches < maxBatches) {
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
    batches++;
    totalDeleted += snapshot.size;
    if (snapshot.size < batchSize) break;
  }
  const capHit = batches >= maxBatches;
  if (capHit) {
    // Loud warning is the signal: somewhere a subcollection grew large
    // enough to hit the cap. The legacy unbounded loop hid this; surface
    // it now so we can add a continuation path before it becomes data
    // loss in production.
    console.warn(
      `deleteCollection cap hit on ${collectionRef.path}: ` +
      `deleted ${totalDeleted} this pass, more remain.`
    );
  }
  return { totalDeleted, capHit };
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

// Paginated cleanup of mirror follow edges for a deleted user. Each follow
// relationship lives in two places:
//   - the follower's `following/{followee}` doc
//   - the followee's `followers/{follower}` doc
// Previously the cascade did unbounded `.get()` calls on the deleted user's
// followers and following subcollections, then issued one Firestore call per
// edge — for users with five-figure social graphs that exceeded memory or
// timed out before completing.
//
// Now: paginate at 100 edges per pass, batch-delete both sides (the deleted
// user's local edge AND the mirror in the peer's subcollection), and return
// capHit so resumeUserCleanup can drain the rest across hourly sweeps.
//
// Counter decrements stay owned by onFollowDeletedUpdateCounts. The trigger
// fires on `users/{userId}/following/{followedId}` deletes only — so two
// of the four delete shapes here fire a trigger:
//   - peer/following/{deletedUid}    (fires; -1 peer.followingCount, -1 deletedUid.followerCount)
//   - deletedUid/following/{peer}    (fires; -1 deletedUid.followingCount, -1 peer.followerCount)
// Net: each peer loses one follow on the relevant side. The deletedUid's own
// counters become moot once the user doc is gone (writes silently no-op on
// a missing doc, matching how the previous shape worked).
async function cleanupMirrorFollowsForUid(uid, maxIterations) {
  let batchCount = 0;
  let totalDeleted = 0;

  // Followers side: peers who follow uid. Delete their `following/{uid}`
  // mirror (fires trigger) AND uid's local `followers/{peer}` row.
  while (batchCount < maxIterations) {
    const snap = await db.collection("users").doc(uid).collection("followers")
      .limit(100)
      .get();
    if (snap.empty) break;
    const batch = db.batch();
    for (const doc of snap.docs) {
      batch.delete(db.collection("users").doc(doc.id).collection("following").doc(uid));
      batch.delete(doc.ref);
    }
    try {
      await batch.commit();
    } catch (err) {
      console.warn("cleanupMirrorFollowsForUid followers batch failed:", err.message);
      break;
    }
    batchCount++;
    totalDeleted += snap.size;
    if (snap.size < 100) break;
  }

  // Following side: peers uid follows. Delete their `followers/{uid}` row
  // (no trigger) AND uid's local `following/{peer}` row (fires trigger).
  while (batchCount < maxIterations) {
    const snap = await db.collection("users").doc(uid).collection("following")
      .limit(100)
      .get();
    if (snap.empty) break;
    const batch = db.batch();
    for (const doc of snap.docs) {
      batch.delete(db.collection("users").doc(doc.id).collection("followers").doc(uid));
      batch.delete(doc.ref);
    }
    try {
      await batch.commit();
    } catch (err) {
      console.warn("cleanupMirrorFollowsForUid following batch failed:", err.message);
      break;
    }
    batchCount++;
    totalDeleted += snap.size;
    if (snap.size < 100) break;
  }

  return { totalDeleted, capHit: batchCount >= maxIterations };
}

// Paginated deletion of reposts of a deleted user's content. Reposts live in
// the top-level `posts` collection with `originalAuthorId == <deleted uid>`
// and remain visible on third-party profiles (ProfileView renders them with
// `originalHandle` as the byline) long after the original author deleted
// their account. Same shape as cleanupPostsForUid — also deletes per-post
// subcollections so the repost's own likes/replies/reflections don't orphan.
//
// `originalAuthorId` is a single-field equality filter — Firestore auto-
// indexes that, no composite needed.
async function cleanupRepostsForUid(uid, maxIterations) {
  let batchCount = 0;
  let totalDeleted = 0;
  while (batchCount < maxIterations) {
    const batch = await db.collection("posts")
      .where("originalAuthorId", "==", uid)
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

// Paginated deletion of a deleted user's orphaned cross-user notifications.
// Notifications authored by `uid` (likes, replies, follows, etc.) live in
// the *recipient's* notifications subcollection — addressable via
// collectionGroup. Previously inlined in onUserDocDeleted with a 50-iter
// cap and no continuation; for users with > 25K orphaned notifications
// the leftovers stayed in recipients' inboxes showing a deleted user's
// stale handle. Pulled into a helper so resumeUserCleanup can drain the
// remainder across subsequent runs (same shape as cleanupPostsForUid).
async function cleanupNotificationsForUid(uid, maxIterations) {
  let batchCount = 0;
  let totalDeleted = 0;
  while (batchCount < maxIterations) {
    const snap = await db.collectionGroup("notifications")
      .where("fromUserId", "==", uid)
      .limit(500)
      .get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    batchCount++;
    totalDeleted += snap.size;
    if (snap.size < 500) break;
  }
  return { totalDeleted, capHit: batchCount >= maxIterations };
}

// Paginated deletion of feeling-circle messages authored by a deleted
// user. Same shape as the notification helper — collectionGroup query,
// 500-doc batch, returns capHit so the caller can queue continuation.
//
// Feeling-circle messages only — NOT DMs. The collectionGroup query
// filters on `authorId`, which is the field circle messages use; DM
// messages use `senderId` instead, so they don't match. DM cleanup
// happens via the conversations cascade in onUserDocDeleted (entire
// conversation doc + messages subcollection deleted when uid is a
// participant).
async function cleanupCircleMessagesForUid(uid, maxIterations) {
  let batchCount = 0;
  let totalDeleted = 0;
  while (batchCount < maxIterations) {
    const snap = await db.collectionGroup("messages")
      .where("authorId", "==", uid)
      .limit(500)
      .get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    batchCount++;
    totalDeleted += snap.size;
    if (snap.size < 500) break;
  }
  return { totalDeleted, capHit: batchCount >= maxIterations };
}

// Paginated deletion of reflections authored by a deleted user on OTHER
// users' posts. Reflections under the deleted user's own posts are
// already cleaned up by cleanupPostsForUid (which deletes the per-post
// reflections subcollection before deleting the post). What's left are
// reflections this user wrote on someone else's post — visible to that
// post's author via PostDetailView reflection enumeration with the
// deleted handle attached. Same shape as cleanupNotificationsForUid:
// collectionGroup query on `authorId`, paginate, return capHit so
// resumeUserCleanup can drain across hourly sweeps.
async function cleanupReflectionsForUid(uid, maxIterations) {
  let batchCount = 0;
  let totalDeleted = 0;
  while (batchCount < maxIterations) {
    const snap = await db.collectionGroup("reflections")
      .where("authorId", "==", uid)
      .limit(500)
      .get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    batchCount++;
    totalDeleted += snap.size;
    if (snap.size < 500) break;
  }
  return { totalDeleted, capHit: batchCount >= maxIterations };
}

// Paginated deletion of replies authored by a deleted user under OTHER
// users' posts. Replies on the deleted user's own posts are gone with
// the post (cleanupPostsForUid deletes the replies subcollection before
// deleting the parent). What's left are this user's replies elsewhere —
// which still render with `authorHandle: "@<deletedHandle>"` to the
// post author and any reader. If a new account later claims the same
// handle, every surviving reply by the deleted user reads as bylined
// to the new account: byline-impersonation across reply threads.
//
// Same shape as cleanupNotificationsForUid: collectionGroup query on
// `authorId`, paginate, return capHit. The replies/(authorId ASC,
// createdAt DESC) collection-group index already exists in
// firestore.indexes.json (used elsewhere). Each delete fires
// onReplyDeletedUpdateCount which legitimately decrements the parent
// post's replyCount — correct: the reply genuinely no longer exists.
async function cleanupRepliesForUid(uid, maxIterations) {
  let batchCount = 0;
  let totalDeleted = 0;
  while (batchCount < maxIterations) {
    const snap = await db.collectionGroup("replies")
      .where("authorId", "==", uid)
      .limit(500)
      .get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    batchCount++;
    totalDeleted += snap.size;
    if (snap.size < 500) break;
  }
  return { totalDeleted, capHit: batchCount >= maxIterations };
}

// F-2 (2026-06-08 audit): a deleted user's LIKE docs on OTHER users' posts and
// replies are keyed by the liker's uid (posts/{p}/likes/{uid},
// posts/{p}/replies/{r}/likes/{uid}) and carry no authorId field, so a
// collectionGroup("likes") query can't locate them by owner. The user's own
// reverse indices DO enumerate them: users/{uid}/liked/{postId} and
// users/{uid}/likedReplies/{replyId} (payload carries the parent postId). Walk
// those indices and delete BOTH the like doc on the third-party content (which
// fires onLikeDeletedUpdateCounts → corrects the post's likeCount and the post
// author's totalLikes) AND the index entry itself. Without this, a deleted
// user's likes persisted on everyone else's posts forever — a GDPR Art. 17
// residue and permanently inflated likeCount/totalLikes.
//
// This helper now OWNS liked/likedReplies cleanup, so those are dropped from
// the generic subs loop in onUserDocDeleted; deleting the index entry as we go
// (rather than relying on the subs loop) keeps resume idempotent — a resumed
// pass re-reads only the entries that remain. Page size is 250 because each
// index doc fans out to two deletes (third-party like + index entry) and a
// Firestore batch caps at 500 writes.
async function cleanupLikesForUid(uid, maxIterations) {
  let batchCount = 0;
  let totalDeleted = 0;
  // Post likes via users/{uid}/liked (doc id == postId).
  const likedRef = db.collection("users").doc(uid).collection("liked");
  while (batchCount < maxIterations) {
    const snap = await likedRef.limit(250).get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((doc) => {
      batch.delete(db.collection("posts").doc(doc.id).collection("likes").doc(uid));
      batch.delete(doc.ref);
    });
    await batch.commit();
    batchCount++;
    totalDeleted += snap.size;
    if (snap.size < 250) break;
  }
  if (batchCount >= maxIterations) return { totalDeleted, capHit: true };
  // Reply likes via users/{uid}/likedReplies (doc id == replyId, data.postId == parent).
  const likedRepliesRef = db.collection("users").doc(uid).collection("likedReplies");
  while (batchCount < maxIterations) {
    const snap = await likedRepliesRef.limit(250).get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((doc) => {
      const postId = doc.data()?.postId;
      if (typeof postId === "string" && postId.length > 0) {
        batch.delete(db.collection("posts").doc(postId)
          .collection("replies").doc(doc.id).collection("likes").doc(uid));
      }
      batch.delete(doc.ref);
    });
    await batch.commit();
    batchCount++;
    totalDeleted += snap.size;
    if (snap.size < 250) break;
  }
  return { totalDeleted, capHit: batchCount >= maxIterations };
}

// Paginated cleanup of conversations where a deleted user is a participant.
// Per-convo work: deleteCollection(messages), then scrub the deleted user's
// slot from participantHandles so the surviving participant's UI doesn't
// show a tombstoned handle.
//
// The previous shape did `where(participants array-contains uid).get()` with
// no pagination — for a heavy DM user (10K+ convos) that single get() risked
// OOM/timeout on the cascade. This helper walks the same query in 50-doc
// pages with __name__ ordering for stable cursoring across invocations.
//
// Idempotency on resume: this helper does NOT mark convos as "processed."
// On resume, we restart from the beginning of the participants-contains-uid
// query and re-walk pages we already finished. Because deleteCollection on
// an empty messages subcollection is a single read and FieldValue.delete on
// an absent key is a no-op, re-processing is correct, just wasteful — fine
// for the tail-end resume case where we'd otherwise need a separate
// "processed" marker collection. Power-users with >2.5K convos pay a few
// extra reads per resume; that's the trade.
async function cleanupUserConversationsForUid(uid, maxIterations) {
  let pageCount = 0;
  let totalProcessed = 0;
  let cursor = null;
  while (pageCount < maxIterations) {
    let q = db.collection("conversations")
      .where("participants", "array-contains", uid)
      .orderBy("__name__")
      .limit(50);
    if (cursor) q = q.startAfter(cursor);
    const snap = await q.get();
    if (snap.empty) break;
    for (const convoDoc of snap.docs) {
      try {
        await deleteCollection(convoDoc.ref.collection("messages"));
        await convoDoc.ref.update({
          [`participantHandles.${uid}`]: FieldValue.delete(),
        });
      } catch (err) {
        // Don't abort the page for a single convo — log and move on.
        console.warn(`convo cleanup failed for ${convoDoc.id}:`, err.message);
      }
    }
    totalProcessed += snap.size;
    pageCount++;
    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < 50) break;
  }
  return { totalDeleted: totalProcessed, capHit: pageCount >= maxIterations };
}

// Paginated deletion of pending reports filed by a deleted user. Reports
// filed *against* this user must persist (moderation history survives
// deletion); reports they themselves filed are cleaned up so the queue
// doesn't attribute pending items to a tombstoned uid.
async function cleanupSubmittedReportsForUid(uid, maxIterations) {
  let batchCount = 0;
  let totalDeleted = 0;
  while (batchCount < maxIterations) {
    const snap = await db.collection("reports")
      .where("reportedBy", "==", uid)
      .where("status", "==", "pending")
      .limit(500)
      .get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    batchCount++;
    totalDeleted += snap.size;
    if (snap.size < 500) break;
  }
  return { totalDeleted, capHit: batchCount >= maxIterations };
}

// Structured-log a single-write counter trigger that failed AFTER its
// dedup claim was set. Single-write triggers (reply, repost, tag, stage,
// message) claim the eventId BEFORE writing the counter; if the write
// then fails (rule denial, invariant violation, transient unavailable),
// Eventarc redelivery will see the claim already set and skip the
// retry — the counter silently drifts off by one and there's no
// recovery path.
//
// The fix here is an alert hook, not a re-architecture: emit a JSON log
// entry with a recognizable `tag` so a Cloud Monitoring policy can fire
// on `jsonPayload.tag = "counter_drift"` and surface the drift to the
// on-call instead of letting it accumulate silently. The previous
// console.warn shape was indistinguishable from benign warnings.
//
// The structural fix (move single-write counters to claimedTransaction
// + retry: true so a failed write retries cleanly) is deferred — it
// requires unwinding the per-counter dedup-key shape and is bigger than
// a security-audit pass. This logging closes the silence gap until
// then.
function logCounterDrift(triggerName, eventId, err, extras = {}) {
  console.error(JSON.stringify({
    severity: "ERROR",
    tag: "counter_drift",
    trigger: triggerName,
    eventId,
    errorMessage: err?.message || String(err),
    ...extras,
  }));
}

// Randomized delay before a moderation-driven delete, sized to overlap with
// the typical "happy-path" trigger-completion envelope so a client probing
// the identifying-info detector can't infer "flagged vs not" from how
// quickly their post disappears. Without this, name-containing posts get
// deleted by validatePost in ~50ms while published posts only stop being
// observable on the client ~1-3s later (post-trigger indexing); the
// difference is a measurable timing oracle that lets an evasion-tuner
// figure out which spellings trip the detector.
//
// Applied only to the identifying-info / name-detection delete path. The
// blank / over-length / repost-mismatch deletes don't need this — those
// shapes are trivially self-checkable from client code (a tampered client
// already knows whether they wrote a blank or 5KB text), so masking the
// server's response timing offers no privacy.
async function moderationDeleteJitter() {
  const ms = 1500 + Math.floor(Math.random() * 1500);
  await new Promise((resolve) => setTimeout(resolve, ms));
}

// ============================================================
// Pending-review system — moderationStatus field on posts.
//
// Replaces the old "auto-delete on PII" + "leave-visible on flagged /
// concerning" behavior. Every post starts at moderationStatus="live" (or
// inferred-live for legacy docs missing the field, post-backfill). When
// any detection path trips, the post flips to "pending_review" so the
// iOS feed query (whereField moderationStatus == "live") drops it from
// every reader except the author and admins. Admin dashboard "pending"
// tab is the only path to flip back to "live" (approve) or delete.
//
// pendingReason values:
//   "pii"               — containsNameOrIdentifyingInfo trip (validatePost / edit)
//   "crisis"            — isPostConcerning / isPostExplicitCrisis trip
//   "abuse_hate"        — MOD_HATE wordlist trip
//   "abuse_harassment"  — MOD_HARASSMENT phrase trip
//   "abuse_threat"      — MOD_THREAT phrase trip
//   "abuse_sexual"      — MOD_SEXUAL pattern trip
//   "abuse_link"        — containsURL trip
//   "user_reports"      — onReportCreatedAutoHide: 3+ distinct reporters in 24h
//
// Idempotent: re-calling with the same reason on an already-pending post
// is a no-op (skip Firestore write to keep pendingDetectedAt stable and
// avoid trigger recursion in onPostUpdated).
// ============================================================
async function setPendingReview(postRef, reason, extraFields = {}) {
  const snap = await postRef.get();
  if (!snap.exists) return false;
  const data = snap.data() || {};
  // First-detected reason wins. If validatePost flips to "pii" first and
  // onPostCreated then finds an abuse trigger, we DON'T overwrite — the
  // original detection is more informative for admin triage (the post
  // was already a takedown regardless of whether a second rule also
  // matches), and overwriting would shuffle the reason label the author
  // sees in their banner. extraFields ARE still merged in case the
  // second call wants to add audit fields (e.g. autoHiddenReportCount)
  // without changing the pending reason.
  if (data.moderationStatus === "pending_review") {
    if (Object.keys(extraFields).length > 0) {
      await postRef.update(extraFields);
    }
    return false;
  }
  await postRef.update({
    moderationStatus: "pending_review",
    pendingReason: reason,
    pendingDetectedAt: FieldValue.serverTimestamp(),
    ...extraFields,
  });
  return true;
}

// ============================================================
// Post visibility promotion (2026-06-01 audit)
//
// Posts are created by the client WITHOUT a moderationStatus field. The feed
// queries pin `moderationStatus == "live"` (an equality filter does NOT match
// docs missing the field), so a freshly-created post is naturally HIDDEN from
// feeds until something promotes it — i.e. the system is already "start
// hidden". The gap: nothing ever set clean posts to "live", so clean posts
// never appeared in the global feed (only the author saw them, via the
// authorId-scoped ProfileView query). validatePost now promotes clean posts
// here after its blank/length/PII checks; reconcilePostVisibility is the
// scheduled backstop if this trigger ever fails.
//
// Guarded so we never override a hold: if onPostCreated / onReportCreatedAutoHide
// concurrently set "pending_review", that wins and the post stays hidden,
// regardless of trigger ordering. Idempotent on an already-live post.
async function setPostLive(postRef) {
  try {
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(postRef);
      if (!snap.exists) return;
      const status = snap.data().moderationStatus;
      if (status === "pending_review" || status === "live") return;
      tx.update(postRef, { moderationStatus: "live" });
    });
  } catch (err) {
    console.warn(`setPostLive ${postRef.id} failed:`, err.message);
  }
}

// A text post is clean (safe to promote to live) only when it trips none of
// the moderation axes. Mirrors the union of validatePost's PII check and
// onPostCreated's flag/crisis checks, so validatePost only promotes posts
// that onPostCreated would NOT subsequently hold — closing the brief-visible
// window for flagged/crisis posts.
function isPostClean(text) {
  if (typeof text !== "string") return false;
  return !containsNameOrIdentifyingInfo(text)
    && !computePostFlagReason(text)
    && !isPostConcerning(text);
}

// Symmetric helper-runner for the onUserDocDeleted cascade. Every cleanup
// helper goes through this so the audit's asymmetric-resume gap is closed:
// previously cleanupReflectionsForUid was the only helper that queued resume
// on a thrown error; the others (notifications, circle messages, submitted
// reports, follows, reposts, replies, convos) silently dropped on transient
// failures and lost data forever — a GDPR Art. 17 risk that compounds with
// scale. With this wrapper, every helper:
//   - queues a resume continuation on capHit (the bounded-progress case)
//   - queues a resume continuation on catch (the transient-failure case)
//   - logs a recognizable message in either case
//   - never re-throws (the parent `try` in onUserDocDeleted already bails
//     on top-level errors; in-helper failures should not abort siblings)
async function runWithResume(uid, type, helperFn, friendlyLabel) {
  try {
    const result = await helperFn(uid, 50);
    if ((result?.totalDeleted || 0) > 0) {
      console.log(`Deleted ${result.totalDeleted} ${friendlyLabel} for user ${uid}`);
    }
    if (result?.capHit) {
      await queueUserCleanupContinuation(uid, type, result.totalDeleted || 0);
      console.warn(`${friendlyLabel} cleanup cap hit for ${uid}; queued for resume.`);
    }
  } catch (err) {
    console.warn(`${friendlyLabel} cleanup failed for ${uid}:`, err.message);
    try {
      await queueUserCleanupContinuation(uid, type, 0);
    } catch (queueErr) {
      console.warn(`Failed to queue ${type} resume for ${uid}:`, queueErr.message);
    }
  }
}

// Write a continuation marker that resumeUserCleanup picks up. Keyed by
// `${uid}_${type}` for idempotency — re-queuing the same type is a no-op
// rewrite of the same fields. cumulativeDeleted is set on initial queue
// and FieldValue.increment'd by resume passes.
async function queueUserCleanupContinuation(uid, type, totalDeleted) {
  try {
    await db.collection("userDeletionCleanupQueue")
      .doc(`${uid}_${type}`)
      .set({
        uid,
        type,
        queuedAt: FieldValue.serverTimestamp(),
        cumulativeDeleted: totalDeleted,
      });
  } catch (err) {
    console.error(`userDeletionCleanupQueue write failed for ${uid}/${type}:`, err.message);
  }
}

// ============================================================
// Counter-trigger event dedup
//
// Eventarc/Pub/Sub deliver Firestore document events with at-least-once
// semantics. Counter triggers below use `FieldValue.increment(±1)` which
// is NOT idempotent under redelivery — a single physical create-event
// delivered twice would double the count. `sendPushNotification` already
// guards against this via a transactional `processed: true` claim on the
// notification doc; counter triggers had no equivalent.
//
// Pattern: at trigger entry, runTransaction-set `processedTriggerEvents/
// {event.id}`. If the doc already exists, return without doing the
// counter update (already processed). The event.id is the Eventarc
// CloudEvent id, stable across retries of the same delivery.
//
// `expiresAt` is for a Firestore TTL policy on the collection (configure
// once via Firebase Console → Firestore → TTL → field path
// `processedTriggerEvents.expiresAt`). Without TTL the collection grows
// unbounded; the scheduled `cleanupProcessedTriggerEvents` sweep below is
// a fallback for projects where TTL isn't configured yet.
// ============================================================
async function claimTriggerEvent(eventId) {
  // No event id available (test env, malformed event) → run without dedup.
  // Better to over-count once than to silently drop the counter update.
  if (!eventId || typeof eventId !== "string") return true;
  const claimRef = db.collection("processedTriggerEvents").doc(eventId);
  const expiresAt = Timestamp.fromDate(new Date(Date.now() + 7 * 24 * 60 * 60 * 1000));
  try {
    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(claimRef);
      if (snap.exists) return false;
      tx.set(claimRef, {
        processedAt: FieldValue.serverTimestamp(),
        expiresAt,
      });
      return true;
    });
  } catch (err) {
    // Failing open here is the right call: a transient Firestore hiccup
    // shouldn't permanently skip a real counter update. The cost is one
    // potential double-count per Firestore-outage event — same shape as
    // the pre-fix behavior. Log so persistent issues surface.
    console.warn(`claimTriggerEvent ${eventId} errored, failing open:`, err.message);
    return true;
  }
}

// ============================================================
// Atomic claim+write for multi-write counter triggers.
//
// The plain `claimTriggerEvent` pattern (claim FIRST, then do writes)
// has a partial-failure trap: if the claim is set but a subsequent write
// fails, Eventarc redelivery sees the claim and skips the entire trigger
// — leaving the failed counter update permanently un-applied. For
// triggers that issue two related writes (e.g., post.likeCount AND
// user.totalLikes), this can cause silent counter drift on the second
// write that has no self-correcting path.
//
// `claimedTransaction` rolls the claim INTO the user-supplied transaction
// so claim-set and writes are atomic: if any write throws, the whole
// transaction rolls back including the claim, and Eventarc retry can
// re-attempt cleanly. Each call gets its own subKey so two paired writes
// (e.g., "post" + "user" sub-events) can fail/retry independently.
//
// On commit failure we RE-THROW so the trigger function fails and
// Eventarc redelivers. This requires the trigger to be declared with
// `{ retry: true }` — without that flag, v2 Firestore triggers default
// to no retry on failure and the drift would persist. The trigger
// declarations below set retry: true; if you add a new caller, set it
// there too. Idempotency is provided by the per-subKey claim doc, so
// repeated retries can't double-apply.
//
// transactionFn must do all its tx.get reads BEFORE any tx.update/set
// writes (Firestore transaction constraint); the claim's tx.set lands
// last. transactionFn may return a value which becomes the resolved
// promise's value; on already-processed, undefined is returned.
// ============================================================
async function claimedTransaction(eventId, subKey, transactionFn) {
  if (!eventId || typeof eventId !== "string") {
    // Local/test fallback: no event ID means no idempotency key, so we
    // can't safely retry — swallow to avoid runaway local emulator loops.
    try { return await db.runTransaction(transactionFn); }
    catch (err) {
      console.warn(`claimedTransaction (no eventId, ${subKey}) failed:`, err.message);
      return undefined;
    }
  }
  const claimRef = db.collection("processedTriggerEvents").doc(`${eventId}_${subKey}`);
  const expiresAt = Timestamp.fromDate(new Date(Date.now() + 7 * 24 * 60 * 60 * 1000));
  try {
    return await db.runTransaction(async (tx) => {
      const claimSnap = await tx.get(claimRef);
      if (claimSnap.exists) return undefined; // already processed by a prior delivery
      const result = await transactionFn(tx);
      tx.set(claimRef, {
        processedAt: FieldValue.serverTimestamp(),
        expiresAt,
      });
      return result;
    });
  } catch (err) {
    // Transaction rolled back, claim NOT set. Re-throw so the trigger
    // function fails and Eventarc redelivers — on the next attempt the
    // already-succeeded sibling sub-claim is set and skips, while this
    // one re-runs. Caller must declare retry: true on the trigger.
    console.warn(`claimedTransaction ${eventId}/${subKey} failed, re-throwing for redelivery:`, err.message);
    throw err;
  }
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
// Allow-list of endpoint identifiers so a future caller that parameterizes
// the endpoint string can't bypass the bucket by varying case, whitespace,
// or unicode confusables. Today the only callers are confirmAdult,
// giphyProxy, and reconcileMyCounts; extend this list when a new endpoint
// adds rate limiting. An unknown endpoint throws — better to crash the
// invocation than to silently route into a fresh, isolated bucket that
// gives the caller infinite capacity.
const RATE_LIMIT_ALLOWED_ENDPOINTS = new Set([
  "confirmAdult",
  "giphyProxy",
  "reconcileMyCounts",
  "report",  // per-reporter cap
  "report_target",  // per-target cap (audit P1: report flooding)
]);

async function checkRateLimit(uid, endpoint, maxRequests, windowSeconds, failClosed = false) {
  if (!RATE_LIMIT_ALLOWED_ENDPOINTS.has(endpoint)) {
    throw new Error(`checkRateLimit: unknown endpoint "${endpoint}"`);
  }
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
    // F-5 (2026-06-08 audit): callers guarding an EXTERNAL PAID quota
    // (giphyProxy) pass failClosed=true so a Firestore outage that disables
    // the rate-limiter can't be used to storm the Giphy API. For purely
    // internal features (confirmAdult, reconcileMyCounts, reports) we still
    // fail OPEN — a Firestore hiccup shouldn't lock legitimate users out.
    console.warn(`checkRateLimit ${endpoint} for ${uid} errored, failing ${failClosed ? "closed" : "open"}:`, err.message);
    return !failClosed;
  }
}

// ============================================================
// Account deletion cleanup
// ============================================================

exports.onUserDocDeleted = onDocumentDeleted("users/{userId}", async (event) => {
  const uid = event.params.userId;
  console.log("Cleaning up data for deleted user:", uid);

  try {
    // 2026-06-02: the "last thing they said" feature was removed. Account
    // deletion no longer archives the user's final post — deletion now means
    // full erasure, matching the in-app delete copy ("everything you said here
    // goes with it") and the GDPR right-to-erasure expectation. (Previously
    // this block copied the user's most recent post — text + handle — into a
    // world-readable finalPosts/{uid} doc that outlived the account.)

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

    // Follower/following cleanup runs through the paginated helper so a
    // heavy social graph doesn't OOM the cascade or time out before
    // completing. The helper deletes both sides (peer mirror + uid's local
    // edge) in batched commits, so we drop "following"/"followers" from the
    // generic subs loop below — they're already empty by the time we get
    // there.
    await runWithResume(uid, "follows", cleanupMirrorFollowsForUid, "follow edges");

    // F-2: clean the user's like docs on OTHER users' posts/replies (and the
    // liked/likedReplies indices that enumerate them). MUST run before the
    // subs loop below so the indices still exist to walk; this helper now owns
    // liked/likedReplies cleanup, so they're removed from `subs`.
    await runWithResume(uid, "likesOnOthers", cleanupLikesForUid, "likes on others' content");

    // `drafts` is included so a user's pre-publish rehearsal text doesn't
    // survive their account delete. Without it, drafts persist forever
    // (rules deny reads to anyone but the now-deleted owner — orphaned
    // tombstones with no GC path).
    //
    // capHit handling: deleteCollection caps at 100 batches × 499 ≈ 50K
    // docs per call. For a typical user every subcollection is well under
    // that cap, but a heavy user (a moderator's `notifications`, an abuse
    // account's `liked`, a power-user's `drafts`) could hit it. Without
    // queuing a resume, the cap silently drops everything past 50K. We
    // queue per-(uid, sub) so resumeUserCleanup drains the remainder
    // hourly until each subcollection is empty.
    // likedReplies/savedReplies are the reply-engagement reverse indices
    // written by PostInteractionManager (iOS). Deleting the parent user doc
    // does NOT delete subcollections, and nothing else cleans these, so
    // without them here the deleted user's reply like/save history (replyId +
    // parent postId) survives account deletion as owner-only orphans — a GDPR
    // Art. 17 gap and a storage leak.
    // liked/likedReplies are intentionally NOT here — cleanupLikesForUid
    // (F-2, above) owns them so it can also delete the corresponding like docs
    // on third-party content before the index entries are removed.
    const subs = ["saved", "savedReplies", "notifications", "blocked", "presence", "private", "drafts"];
    for (const sub of subs) {
      try {
        const result = await deleteCollection(db.collection("users").doc(uid).collection(sub));
        if (result?.capHit) {
          await queueUserCleanupContinuation(uid, `sub_${sub}`, result.totalDeleted || 0);
          console.warn(`Subcollection cleanup cap hit for ${uid}/${sub}; queued for resume.`);
        }
      } catch (err) {
        console.warn(`Subcollection cleanup failed for ${uid}/${sub}:`, err.message);
        // Queue resume so a transient failure doesn't strand the cleanup.
        try {
          await queueUserCleanupContinuation(uid, `sub_${sub}`, 0);
        } catch (queueErr) {
          console.warn(`Failed to queue ${sub} resume for ${uid}:`, queueErr.message);
        }
      }
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

    // Cross-user cleanup helpers. Each runs through `runWithResume` so
    // capHit AND transient errors both queue a resume continuation —
    // previously only `reflections` symmetrized this. Order is roughly
    // "highest visibility leak first" so a partial cascade run still
    // closes the most-visible identity-impersonation surfaces:
    //   convos       — DM message bodies + participant-handle slots
    //   notifications— cross-user inbox docs with the deleted handle
    //   replies      — byline-impersonation gap (audit P1-4): replies
    //                  authored by uid under other users' posts
    //   reposts      — third-party reposts referencing the deleted user
    //   reflections  — uid's reflections under other users' posts
    //   circleMessages — feeling-circle messages by uid
    //   reports      — pending reports uid filed (kept-against-uid persist)
    await runWithResume(uid, "convos", cleanupUserConversationsForUid, "DM conversations");
    await runWithResume(uid, "notifications", cleanupNotificationsForUid, "orphaned notifications");
    await runWithResume(uid, "replies", cleanupRepliesForUid, "cross-user replies");
    await runWithResume(uid, "reposts", cleanupRepostsForUid, "third-party reposts");
    await runWithResume(uid, "reflections", cleanupReflectionsForUid, "cross-user reflections");
    await runWithResume(uid, "circleMessages", cleanupCircleMessagesForUid, "feeling-circle messages");
    await runWithResume(uid, "reports", cleanupSubmittedReportsForUid, "pending reports filed");

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
    // Lock-screen privacy. The previous copy interpolated ${fromHandle} into
    // every push title/body, surfacing the sender's anonymous handle on the
    // recipient's lock screen. For an anonymity-first app the *handle* is
    // the identifier — a co-resident attacker (shared iPad, mirrored Apple
    // Watch, iCloud-synced notifications on a shared Mac) reading "@stalker
    // replied" on the victim's device confirms (a) the victim is on Toska,
    // (b) the attacker's own probe handle reached the victim, and (c) over
    // time, builds a map of which handles interact with the victim.
    //
    // The fix: server-authored copy that names no one. The `fromUserId`
    // routing ID is still in the data payload below so the in-app render
    // (post-unlock, where the victim has full control) can resolve handles
    // and avatars normally. Milestone is server-authored count copy that
    // already names no one.
    //
    // fromHandle is no longer read for any title/body field, but
    // sendPushNotification still resolves it from the sender's user doc
    // earlier in this function so future server-authored copy that *needs*
    // a handle (e.g., admin announcements) can still use it explicitly.
    switch (type) {
      case "reply":
        title = "someone replied";
        body = "tap to read what they said";
        break;
      case "like":
        title = "someone felt your post";
        body = "tap to read what they said";
        break;
      case "follow":
        title = "new follower";
        body = "someone is following you";
        break;
      case "repost":
        title = "your words are spreading";
        body = "someone reposted your words";
        break;
      case "save":
        title = "someone saved your post";
        body = "tap to see who kept your words";
        break;
      case "milestone":
        // Server-authored milestone copy ("your post reached 25 feels") is
        // safe because it doesn't include the post body, just the count.
        body = message || "your post hit a milestone";
        break;
      case "message":
        title = "new message";
        body = "tap to read";
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
  // retry: true is load-bearing — claimedTransaction re-throws on commit
  // failure so Eventarc redelivers, and the per-subKey claim doc dedups
  // the side that already succeeded so retries can't double-apply.
  { document: "posts/{postId}/likes/{userId}", retry: true },
  async (event) => {
    const postId = event.params.postId;
    const postRef = db.collection("posts").doc(postId);

    // Atomic claim+increment likeCount. Read post inside the transaction
    // so a missing-post case short-circuits without faulting the
    // tx.update call (otherwise NOT_FOUND rolls back the claim and
    // Eventarc spins until retry-budget exhaustion).
    await claimedTransaction(event.id, "post", async (tx) => {
      const snap = await tx.get(postRef);
      if (!snap.exists) return;
      tx.update(postRef, { likeCount: FieldValue.increment(1) });
    });

    // Atomic claim+increment totalLikes on the post author. Independent
    // sub-claim so a failure here doesn't stall the post-counter retry
    // (and vice versa). Reads postRef itself so this transaction can
    // run cleanly on Eventarc redelivery even if the closure that
    // captured authorId from the first transaction was discarded.
    await claimedTransaction(event.id, "user", async (tx) => {
      const postSnap = await tx.get(postRef);
      if (!postSnap.exists) return;
      const authorId = postSnap.data().authorId;
      if (!authorId) return;
      const userRef = db.collection("users").doc(authorId);
      const userSnap = await tx.get(userRef);
      if (!userSnap.exists) return; // author deleted between like create and trigger
      tx.update(userRef, { totalLikes: FieldValue.increment(1) });
    });
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
  { document: "posts/{postId}/likes/{userId}", retry: true },
  async (event) => {
    const postId = event.params.postId;
    const postRef = db.collection("posts").doc(postId);

    await claimedTransaction(event.id, "post", async (tx) => {
      const snap = await tx.get(postRef);
      if (!snap.exists) return;
      tx.update(postRef, { likeCount: FieldValue.increment(-1) });
    });

    await claimedTransaction(event.id, "user", async (tx) => {
      const postSnap = await tx.get(postRef);
      if (!postSnap.exists) return;
      const authorId = postSnap.data().authorId;
      if (!authorId) return;
      const userRef = db.collection("users").doc(authorId);
      const userSnap = await tx.get(userRef);
      if (!userSnap.exists) return;
      tx.update(userRef, { totalLikes: FieldValue.increment(-1) });
    });
  }
);

// ============================================================
// Counter: reply count (server-side only)
// ============================================================

exports.onReplyCreatedUpdateCount = onDocumentCreated(
  // F-1 (2026-06-08 audit): migrated from the claim-first claimTriggerEvent
  // shape (which drifted permanently if the increment failed after the claim
  // was set) to the atomic claimedTransaction + retry:true pattern. The claim
  // now lands inside the same transaction as the increment, so a failed write
  // rolls back the claim and Eventarc redelivers cleanly.
  { document: "posts/{postId}/replies/{replyId}", retry: true },
  async (event) => {
    const postId = event.params.postId;
    const replyData = event.data.data();
    if (!replyData) return;
    // Basic validity check — only increment for replies with actual text
    if (typeof replyData.text !== "string" || replyData.text.trim().length === 0) return;
    if (!replyData.authorId) return;

    const postRef = db.collection("posts").doc(postId);
    await claimedTransaction(event.id, "replyCount", async (tx) => {
      const snap = await tx.get(postRef);
      if (!snap.exists) return; // parent post deleted before this trigger
      tx.update(postRef, { replyCount: FieldValue.increment(1) });
    });
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
  { document: "posts/{postId}/replies/{replyId}", retry: true },
  async (event) => {
    const postId = event.params.postId;
    // #1 (2026-06-09 audit): a HELD reply (moderationStatus == "pending_review")
    // was already decremented out of replyCount when it was held (by
    // onReplyVisibilityCountAdjust), so deleting it must NOT decrement again —
    // otherwise a held-then-deleted reply drives the count one too low.
    const deletedData = event.data?.data();
    if (deletedData?.moderationStatus === "pending_review") return;
    const postRef = db.collection("posts").doc(postId);
    await claimedTransaction(event.id, "replyCount", async (tx) => {
      const snap = await tx.get(postRef);
      if (!snap.exists) return;
      tx.update(postRef, { replyCount: FieldValue.increment(-1) });
    });
  }
);

// #1 (2026-06-09 audit): replyCount must track VISIBLE replies, not all replies.
// A reply is counted at create (onReplyCreatedUpdateCount) regardless of
// moderation; this trigger adjusts the count when a reply crosses the
// visible<->hidden boundary:
//   - held      (moderationStatus -> "pending_review"): -1
//   - un-held / admin-approved (-> not "pending_review"): +1
// Without it, a user could inflate any post's replyCount by spamming held
// (PII) replies — each fired the create-increment but stayed hidden. No-op on
// non-visibility updates (text edits, like-count writes). Atomic + deduped via
// claimedTransaction + retry, same discipline as the other counters (F-1).
exports.onReplyVisibilityCountAdjust = onDocumentUpdated(
  { document: "posts/{postId}/replies/{replyId}", retry: true },
  async (event) => {
    const before = event.data?.before?.data() || {};
    const after = event.data?.after?.data() || {};
    const wasHidden = before.moderationStatus === "pending_review";
    const nowHidden = after.moderationStatus === "pending_review";
    if (wasHidden === nowHidden) return; // no visibility transition
    const delta = wasHidden ? 1 : -1;    // hidden->visible: +1; visible->hidden: -1
    const postRef = db.collection("posts").doc(event.params.postId);
    await claimedTransaction(event.id, "replyVisCount", async (tx) => {
      const snap = await tx.get(postRef);
      if (!snap.exists) return;
      tx.update(postRef, { replyCount: FieldValue.increment(delta) });
    });
  }
);

// ============================================================
// Counter: reply-like count (server-side only)
//
// Full parity with post-like counters (onLikeCreatedUpdateCount /
// onLikeDeletedUpdateCount). When a user likes a reply, the like doc
// lands at posts/{postId}/replies/{replyId}/likes/{likeUserId} (firestore.
// rules permits this nested write). These triggers maintain the
// `likeCount` field on the parent reply doc so the iOS UI doesn't have
// to count likes by listing the subcollection on every render.
//
// Same atomic increment / decrement pattern as post-like counters —
// FieldValue.increment commutes under concurrent create + delete races
// without the upward-drift bug safeDecrement caused. Idempotent via
// claimTriggerEvent.
// ============================================================

exports.onReplyLikeCreatedUpdateCount = onDocumentCreated(
  { document: "posts/{postId}/replies/{replyId}/likes/{likeUserId}", retry: true },
  async (event) => {
    const { postId, replyId } = event.params;
    const replyRef = db.collection("posts").doc(postId).collection("replies").doc(replyId);
    await claimedTransaction(event.id, "replyLikeCount", async (tx) => {
      const snap = await tx.get(replyRef);
      if (!snap.exists) return;
      tx.update(replyRef, { likeCount: FieldValue.increment(1) });
    });
  }
);

exports.onReplyLikeDeletedUpdateCount = onDocumentDeleted(
  { document: "posts/{postId}/replies/{replyId}/likes/{likeUserId}", retry: true },
  async (event) => {
    const { postId, replyId } = event.params;
    const replyRef = db.collection("posts").doc(postId).collection("replies").doc(replyId);
    await claimedTransaction(event.id, "replyLikeCount", async (tx) => {
      const snap = await tx.get(replyRef);
      if (!snap.exists) return;
      tx.update(replyRef, { likeCount: FieldValue.increment(-1) });
    });
  }
);

// ============================================================
// Counter: repost count (server-side only)
// ============================================================

exports.onRepostCreatedUpdateCount = onDocumentCreated(
  { document: "posts/{postId}", retry: true },
  async (event) => {
    const postData = event.data.data();
    if (!postData) return;
    if (postData.isRepost !== true) return;
    // Reply-repost path is handled by onReplyRepostCreatedUpdateCount —
    // increment goes to the reply doc's repostCount, not the parent post's.
    // Without this guard, a reply-repost would bump BOTH the reply AND the
    // parent post's repostCount, double-counting.
    if (postData.originalReplyId && typeof postData.originalReplyId === "string"
        && postData.originalReplyId.length > 0) return;
    const originalPostId = postData.originalPostId;
    if (!originalPostId || typeof originalPostId !== "string") return;
    // Atomic claim+increment (F-1): the claim lands inside the transaction so
    // a failed increment rolls it back and Eventarc redelivers. Non-repost
    // create events short-circuit above before any claim is written.
    const originalRef = db.collection("posts").doc(originalPostId);
    await claimedTransaction(event.id, "repostCount", async (tx) => {
      const snap = await tx.get(originalRef);
      if (!snap.exists) return;
      tx.update(originalRef, { repostCount: FieldValue.increment(1) });
    });
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
  { document: "posts/{postId}", retry: true },
  async (event) => {
    const postData = event.data.data();
    if (!postData) return;
    if (postData.isRepost !== true) return;
    // Same exclusion as onRepostCreatedUpdateCount — reply-repost deletes
    // decrement the reply doc's repostCount via onReplyRepostDeletedUpdateCount,
    // not the parent post's.
    if (postData.originalReplyId && typeof postData.originalReplyId === "string"
        && postData.originalReplyId.length > 0) return;
    const originalPostId = postData.originalPostId;
    if (!originalPostId || typeof originalPostId !== "string") return;

    const originalRef = db.collection("posts").doc(originalPostId);
    await claimedTransaction(event.id, "repostCount", async (tx) => {
      const snap = await tx.get(originalRef);
      if (!snap.exists) return;
      tx.update(originalRef, { repostCount: FieldValue.increment(-1) });
    });
  }
);

// ============================================================
// Counter: reply-repost count (server-side only)
//
// When a user reposts a REPLY (not a post), the new top-level post doc
// carries isRepost: true + originalReplyId: <replyId> + originalPostId:
// <parentPostId>. These triggers maintain `repostCount` on the reply doc.
// The existing onRepostCreated/DeletedUpdateCount triggers skip these
// events (originalReplyId guard) to avoid double-counting.
// ============================================================

exports.onReplyRepostCreatedUpdateCount = onDocumentCreated(
  { document: "posts/{postId}", retry: true },
  async (event) => {
    const postData = event.data.data();
    if (!postData) return;
    if (postData.isRepost !== true) return;
    const originalReplyId = postData.originalReplyId;
    const originalPostId = postData.originalPostId;
    if (!originalReplyId || typeof originalReplyId !== "string" || originalReplyId.length === 0) return;
    if (!originalPostId || typeof originalPostId !== "string") return;

    const replyRef = db.collection("posts").doc(originalPostId)
      .collection("replies").doc(originalReplyId);
    await claimedTransaction(event.id, "replyRepostCount", async (tx) => {
      const snap = await tx.get(replyRef);
      if (!snap.exists) return;
      tx.update(replyRef, { repostCount: FieldValue.increment(1) });
    });
  }
);

exports.onReplyRepostDeletedUpdateCount = onDocumentDeleted(
  { document: "posts/{postId}", retry: true },
  async (event) => {
    const postData = event.data.data();
    if (!postData) return;
    if (postData.isRepost !== true) return;
    const originalReplyId = postData.originalReplyId;
    const originalPostId = postData.originalPostId;
    if (!originalReplyId || typeof originalReplyId !== "string" || originalReplyId.length === 0) return;
    if (!originalPostId || typeof originalPostId !== "string") return;

    const replyRef = db.collection("posts").doc(originalPostId)
      .collection("replies").doc(originalReplyId);
    await claimedTransaction(event.id, "replyRepostCount", async (tx) => {
      const snap = await tx.get(replyRef);
      if (!snap.exists) return;
      tx.update(replyRef, { repostCount: FieldValue.increment(-1) });
    });
  }
);

// Cleanup hook: when an original (non-repost) post is deleted, every
// repost pointing at it is now orphaned with originalPostId referencing
// nothing. PostDetailView's iOS delete path already tries to clean these
// up at line 803-807, but rules deny non-author repost deletes from the
// client (allow delete: authorId == auth.uid OR isAdmin) — those `try?`
// calls silently fail and the reposts stick around forever. Server-side
// trigger uses the Admin SDK and bypasses rules, so it actually works.
//
// Also fires on admin-deleted posts, validatePost-deleted posts (size /
// blank / name-PII takedowns), onPostUpdated-deleted posts (edited-in
// name detection), and cleanupExpiredPosts — every path that produces a
// post delete. The trigger is naturally idempotent: if the iOS path
// already deleted everything, the second pass finds an empty result.
//
// Bounded at 50 iterations × 100 reposts = 5000 cleared per invocation.
// Re-firing on a future event isn't an option (the parent post is gone),
// so for posts with > 5000 reposts the leftovers would orphan; if that
// becomes a concern, swap in the queueUserCleanupContinuation pattern
// keyed by originalPostId.
// Delete up to maxBatches×100 reposts of a now-deleted original post, plus
// each repost's replies/likes/reflections subcollections. Returns capHit so
// callers can queue a continuation.
async function clearRepostsOfPost(postId, maxBatches) {
  let totalDeleted = 0;
  let batches = 0;
  for (; batches < maxBatches; batches++) {
    const snap = await db.collection("posts")
      .where("isRepost", "==", true)
      .where("originalPostId", "==", postId)
      .limit(100)
      .get();
    if (snap.empty) break;
    for (const repostDoc of snap.docs) {
      await deleteCollection(repostDoc.ref.collection("replies"));
      await deleteCollection(repostDoc.ref.collection("likes"));
      await deleteCollection(repostDoc.ref.collection("reflections"));
      try {
        await repostDoc.ref.delete();
      } catch (err) {
        console.warn(`clearRepostsOfPost: failed to delete repost ${repostDoc.id}:`, err.message);
      }
    }
    totalDeleted += snap.size;
    if (snap.size < 100) break;
  }
  return { totalDeleted, capHit: batches >= maxBatches };
}

exports.onPostDeletedCleanupReposts = onDocumentDeleted("posts/{postId}", async (event) => {
  const postData = event.data.data();
  if (!postData) return;
  // Only original posts can have reposts pointing at them. Repost-of-
  // repost is forbidden by PostInteractionManager.repost (line 290 in
  // PostInteractionManager.swift), so a repost being deleted never has
  // children to clean up.
  if (postData.isRepost === true) return;
  const postId = event.params.postId;

  const { totalDeleted, capHit } = await clearRepostsOfPost(postId, 50);
  if (totalDeleted > 0) {
    console.log(`onPostDeletedCleanupReposts: cleared ${totalDeleted} reposts of ${postId}`);
  }
  // F-6 (2026-06-08 audit): for a viral post with >5000 reposts the single
  // invocation can't clear them all, and the parent post is already gone so
  // this trigger will never re-fire — the leftovers would orphan forever.
  // Queue a marker for the scheduled resumeRepostCleanup sweep to drain.
  if (capHit) {
    try {
      await db.collection("repostCleanupQueue").doc(postId).set({
        originalPostId: postId,
        queuedAt: FieldValue.serverTimestamp(),
        cumulativeDeleted: totalDeleted,
      });
      console.warn(`onPostDeletedCleanupReposts: cap hit for ${postId}; queued for resume.`);
    } catch (err) {
      console.error(`repostCleanupQueue write failed for ${postId}:`, err.message);
    }
  }
});

// ============================================================
// Counter: follow counts (server-side only)
// ============================================================

exports.onFollowCreatedUpdateCounts = onDocumentCreated(
  { document: "users/{userId}/following/{followedId}", retry: true },
  async (event) => {
    const userId = event.params.userId;
    const followedId = event.params.followedId;

    // Atomic claim+increment for each side of the follow edge. Independent
    // sub-claims so a failure on one side (e.g., target user already
    // deleted) doesn't stall the other from retrying.
    await claimedTransaction(event.id, "follower", async (tx) => {
      const ref = db.collection("users").doc(userId);
      const snap = await tx.get(ref);
      if (!snap.exists) return;
      tx.update(ref, { followingCount: FieldValue.increment(1) });
    });

    await claimedTransaction(event.id, "followed", async (tx) => {
      const ref = db.collection("users").doc(followedId);
      const snap = await tx.get(ref);
      if (!snap.exists) return;
      tx.update(ref, { followerCount: FieldValue.increment(1) });
    });
  }
);

// Atomic FieldValue.increment(-1) for the same race-safety reason
// documented on onReplyDeletedUpdateCount above. safeDecrement's
// transactional `current > 0` guard skipped the decrement under a
// rapid follow→unfollow race where the create-trigger increment hadn't
// landed yet, leaving permanent upward drift.
exports.onFollowDeletedUpdateCounts = onDocumentDeleted(
  { document: "users/{userId}/following/{followedId}", retry: true },
  async (event) => {
    const userId = event.params.userId;
    const followedId = event.params.followedId;

    await claimedTransaction(event.id, "follower", async (tx) => {
      const ref = db.collection("users").doc(userId);
      const snap = await tx.get(ref);
      if (!snap.exists) return;
      tx.update(ref, { followingCount: FieldValue.increment(-1) });
    });

    await claimedTransaction(event.id, "followed", async (tx) => {
      const ref = db.collection("users").doc(followedId);
      const snap = await tx.get(ref);
      if (!snap.exists) return;
      tx.update(ref, { followerCount: FieldValue.increment(-1) });
    });
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
// Breakup-stage aggregate — feeds the onboarding "you're not alone
// tonight" crystallization beat with a real number.
//
// Triggered on every write to users/{uid}/private/data (the only doc
// in the private subcollection that carries breakupStage). Compares
// before / after; if the value changed, atomically increments the new
// stage's count and decrements the old stage's count at
// meta/breakupStageCounts/{stage}. First-time set increments only
// (no prior to decrement).
//
// At-least-once dedup via claimTriggerEvent — same shape as the other
// counter triggers. Without it a redelivered event would double-count
// a stage transition. The claim is gated below the docId/stage-change
// short-circuits so unrelated private/data writes (mood, fcmToken,
// notify prefs) don't burn a processedTriggerEvents row apiece.
//
// Mirror of OnboardingView.swift:30-38. A tampered client could write
// any string into private/data.breakupStage; without the allowlist,
// meta/breakupStageCounts would accumulate adversarial keys (storage
// pollution, no UI surface today since ExploreView iterates a fixed
// stage list, but the meta doc is unbounded).
// ============================================================
const ALLOWED_BREAKUP_STAGES = new Set([
  "it just happened",
  "a few weeks in",
  "months in",
  "a year or more",
  "still in it",
  "they left",
  "i left",
]);

exports.onBreakupStageChanged = onDocumentWritten(
  { document: "users/{userId}/private/{docId}", retry: true },
  async (event) => {
    if (event.params.docId !== "data") return;

    const before = event.data?.before?.data() || {};
    const after  = event.data?.after?.data()  || {};
    const rawBefore = typeof before.breakupStage === "string" ? before.breakupStage : null;
    const rawAfter  = typeof after.breakupStage  === "string" ? after.breakupStage  : null;
    if (rawBefore === rawAfter) return;

    // Drop stage values not in the allowlist so the meta doc only
    // accumulates keys we actually display. A delta between two junk
    // values short-circuits to no-op; a junk → real or real → junk
    // transition only counts the legitimate side.
    const beforeStage = rawBefore && ALLOWED_BREAKUP_STAGES.has(rawBefore) ? rawBefore : null;
    const afterStage  = rawAfter  && ALLOWED_BREAKUP_STAGES.has(rawAfter)  ? rawAfter  : null;
    if (!beforeStage && !afterStage) return;

    const ref = db.collection("meta").doc("breakupStageCounts");
    const updates = { updatedAt: FieldValue.serverTimestamp() };
    if (afterStage)  updates[afterStage]  = FieldValue.increment(1);
    if (beforeStage) updates[beforeStage] = FieldValue.increment(-1);
    // Atomic claim+set (F-1). tx.set with merge is safe on a missing meta doc,
    // so no read is required; the claim rolls back with the write on failure.
    await claimedTransaction(event.id, "breakupStageCounts", async (tx) => {
      tx.set(ref, updates, { merge: true });
    });
  }
);

// ============================================================
// Tag count maintenance — keeps meta/tagCounts updated so
// clients read one document instead of 200 posts.
// ============================================================

exports.onPostCreatedUpdateTagCounts = onDocumentCreated(
  { document: "posts/{postId}", retry: true },
  async (event) => {
    const postData = event.data.data();
    if (!postData) return;
    const tag = postData.tag;
    if (!tag || typeof tag !== "string") return;
    if (postData.isRepost === true) return;

    // Atomic claim+set (F-1); non-tag-bearing posts short-circuit above
    // before any claim doc is written.
    const ref = db.collection("meta").doc("tagCounts");
    await claimedTransaction(event.id, "tagCounts", async (tx) => {
      tx.set(ref,
        { [tag]: FieldValue.increment(1), updatedAt: FieldValue.serverTimestamp() },
        { merge: true });
    });
  }
);

// Atomic FieldValue.increment(-1) — same rationale as the other counter
// triggers. The previous transactional shape with a `current > 0` guard
// was the asymmetric pattern that caused upward drift on concurrent
// create+delete races (the no-op delete branch left the matching
// increment to land afterward and stick). Tag counts can briefly dip
// negative under concurrent create+delete and converge correctly once
// both writes complete.
exports.onPostDeletedUpdateTagCounts = onDocumentDeleted(
  { document: "posts/{postId}", retry: true },
  async (event) => {
    const postData = event.data.data();
    if (!postData) return;
    const tag = postData.tag;
    if (!tag || typeof tag !== "string") return;
    if (postData.isRepost === true) return;

    const ref = db.collection("meta").doc("tagCounts");
    await claimedTransaction(event.id, "tagCounts", async (tx) => {
      tx.set(ref,
        { [tag]: FieldValue.increment(-1), updatedAt: FieldValue.serverTimestamp() },
        { merge: true });
    });
  }
);

// ============================================================
// Server-side post validation
// ============================================================

exports.validatePost = onDocumentCreated("posts/{postId}", async (event) => {
  const postId = event.params.postId;
  const postData = event.data.data();
  if (!postData) return;

  // Reposts now run through their own validation path. Previously this
  // trigger early-returned on isRepost === true, which let a tampered
  // client write a repost doc with arbitrary text + originalAuthorId
  // attributing fabricated content to any other user (PROFILE rendering
  // in ProfileView.swift uses originalHandle as the byline). The legit
  // iOS writer (PostInteractionManager.repost) copies the original's
  // text/authorId verbatim — if those don't match, the repost is
  // fabricated and gets the same takedown the blank/over-length branches
  // get below.
  //
  // Counter math is symmetric either way: onRepostCreatedUpdateCount
  // increments and onRepostDeletedUpdateCount decrements, so a bad-repost
  // delete here ends up net-zero on the original's repostCount regardless
  // of which trigger lands first.
  if (postData.isRepost === true) {
    // Reply-repost path: when originalReplyId is set, this post is a
    // repost of a REPLY, not of a top-level post. The rule layer (firestore.
    // rules) defers full text/authorId validation to this function for
    // reply-reposts to keep its get() count bounded; here we do the
    // existence + text + authorId match check that the rule would have
    // done. Same delete-on-mismatch policy as the post-repost branch.
    const originalReplyId = postData.originalReplyId;
    const originalPostId = postData.originalPostId;
    if (typeof originalReplyId === "string" && originalReplyId.length > 0) {
      if (typeof originalPostId !== "string" || !originalPostId) {
        console.warn(`Deleting reply-repost ${postId} — missing originalPostId`);
        await db.collection("posts").doc(postId).delete();
        return;
      }
      const replySnap = await db.collection("posts").doc(originalPostId)
        .collection("replies").doc(originalReplyId).get();
      if (!replySnap.exists) {
        console.warn(`Deleting reply-repost ${postId} — original reply ${originalReplyId} not found under post ${originalPostId}`);
        await db.collection("posts").doc(postId).delete();
        return;
      }
      const replyData = replySnap.data();
      if (postData.text !== replyData.text) {
        console.warn(`Deleting reply-repost ${postId} — text mismatch with original reply`);
        await db.collection("posts").doc(postId).delete();
        return;
      }
      if (postData.originalAuthorId !== replyData.authorId) {
        console.warn(`Deleting reply-repost ${postId} — originalAuthorId mismatch with reply.authorId`);
        await db.collection("posts").doc(postId).delete();
        return;
      }
      // originalHandle intentionally not equality-checked — same rationale
      // as the post-repost branch (handle may have rotated since fetch).
      // Valid repost of already-moderated content — promote to live so it
      // appears in feeds (guarded against overriding a concurrent hold).
      await setPostLive(db.collection("posts").doc(postId));
      return;
    }

    if (typeof originalPostId !== "string" || !originalPostId) {
      console.warn(`Deleting repost ${postId} — missing originalPostId`);
      await db.collection("posts").doc(postId).delete();
      return;
    }
    const originalSnap = await db.collection("posts").doc(originalPostId).get();
    if (!originalSnap.exists) {
      console.warn(`Deleting repost ${postId} — original ${originalPostId} not found`);
      await db.collection("posts").doc(postId).delete();
      return;
    }
    const originalData = originalSnap.data();
    if (originalData.isRepost === true) {
      console.warn(`Deleting repost ${postId} — cannot repost a repost`);
      await db.collection("posts").doc(postId).delete();
      return;
    }
    if (postData.text !== originalData.text) {
      console.warn(`Deleting repost ${postId} — text mismatch with original`);
      await db.collection("posts").doc(postId).delete();
      return;
    }
    if (postData.originalAuthorId !== originalData.authorId) {
      console.warn(`Deleting repost ${postId} — originalAuthorId mismatch`);
      await db.collection("posts").doc(postId).delete();
      return;
    }
    // originalHandle is intentionally not equality-checked: the original
    // author may have rotated their handle between when the reposter
    // fetched the original and when this trigger fires. The display would
    // be slightly stale but isn't an attribution forgery.
    // Valid repost of already-moderated content — promote to live.
    await setPostLive(db.collection("posts").doc(postId));
    return;
  }

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

  // Server-side mirror of FeedView.swift::containsNameOrIdentifyingInfo.
  // The iOS pre-publish detector grew aggressive evasion-hardening (Unicode
  // confusables, leet, separator collapse, last names, dotted initials) in
  // the 2026-05-01 pre-launch sprint. Prior policy was to DELETE on detect;
  // 2026-05-31 switched to flip moderationStatus="pending_review" so admin
  // can rescue false positives (e.g. real names that are the author's own
  // in a quote). Effect on readers is the same — pending posts are hidden
  // from non-author / non-admin feed queries by the rules + iOS filter.
  if (containsNameOrIdentifyingInfo(text)) {
    const createdAtMs = postData.createdAt?.toMillis?.() || 0;
    const detectMs = Date.now();
    console.warn(`Pending-review post ${postId} — server-side identifying-info detector tripped`);
    // 2026-05-31 fix: flip status FIRST, then jitter. Previously the
    // 1.5-3s jitter ran before the flip, widening the PII visibility
    // window by that amount. The original jitter was a timing-oracle
    // defense (so an evasion-tuner couldn't measure "did this exact
    // phrasing trip the detector?" from response time). After the flip,
    // the post is already hidden — jitter on the no-op log line below
    // preserves the same timing-oracle property without keeping a PII
    // post visible during the jitter sleep.
    await setPendingReview(db.collection("posts").doc(postId), "pii");
    await moderationDeleteJitter();
    const pendedMs = Date.now();
    // Observability for the visibility window — i.e., how long the post
    // existed at moderationStatus=live (or pre-field) where snapshot
    // listeners could see it before the flip hid it. createdAt is the
    // server timestamp pinned in the rule; detect→pending is the function
    // body itself. Field name kept (pii_delete_window) so existing log
    // filters keep matching; field semantics: detect_to_delete_ms is now
    // detect_to_pending_ms, total_visibility_ms is now hidden_at - created.
    console.log(
      `pii_delete_window post=${postId} ` +
      `create_to_detect_ms=${createdAtMs ? detectMs - createdAtMs : -1} ` +
      `detect_to_delete_ms=${pendedMs - detectMs} ` +
      `total_visibility_ms=${createdAtMs ? pendedMs - createdAtMs : -1}`
    );
    return;
  }

  // Clean on the PII axis here. Promote to live only if ALSO clean on the
  // flag/crisis axes that onPostCreated enforces, so we never briefly surface
  // a post that onPostCreated is about to hold.
  //
  // F-4 (2026-06-08 audit): previously the not-clean case was a no-op that
  // relied entirely on onPostCreated (and, if that failed, the 30-min
  // reconcilePostVisibility backstop) to apply the hold. Now validatePost
  // applies the same flag/crisis/PII hold itself via holdReconciledPost, so a
  // post can't sit field-less/hidden waiting on a sibling trigger.
  // setPendingReview is idempotent (first reason wins), so onPostCreated
  // running concurrently is a safe no-op.
  if (isPostClean(text)) {
    await setPostLive(db.collection("posts").doc(postId));
  } else {
    await holdReconciledPost(db.collection("posts").doc(postId), text);
  }
});

// Apply the pending-review hold for a post the reconciler found unresolved,
// setting the same tab markers (flagged / concerningContent) that
// onPostCreated would have. Most-severe-first, mirroring onPostCreated.
async function holdReconciledPost(postRef, text) {
  const flagReason = computePostFlagReason(text);
  const concerning = isPostConcerning(text);
  if (concerning) {
    const extra = { concerningContent: true, flaggedAt: FieldValue.serverTimestamp() };
    if (flagReason) { extra.flagged = true; extra.flagReason = flagReason; }
    await setPendingReview(postRef, "crisis", extra);
  } else if (flagReason) {
    await setPendingReview(postRef, flagReasonToPendingReason(flagReason), {
      flagged: true, flaggedAt: FieldValue.serverTimestamp(), flagReason,
    });
  } else {
    // PII-only (containsNameOrIdentifyingInfo) or otherwise not "clean".
    await setPendingReview(postRef, "pii");
  }
}

// Scheduled backstop for the start-hidden model (2026-06-01 audit). If
// validatePost ever fails to resolve a post, it stays WITHOUT a
// moderationStatus and is invisible to feeds forever (the equality filter
// drops field-less docs). Firestore can't query for a missing field, so scan
// the recent window and re-decide any still-unresolved posts. Window: older
// than 10 min (well past trigger latency + Eventarc retries) and newer than
// 24h (bounded scan).
exports.reconcilePostVisibility = onSchedule("every 30 minutes", async () => {
  const now = Date.now();
  const olderThan = Timestamp.fromDate(new Date(now - 10 * 60 * 1000));
  const newerThan = Timestamp.fromDate(new Date(now - 24 * 60 * 60 * 1000));
  let snap;
  try {
    snap = await db.collection("posts")
      .where("createdAt", "<", olderThan)
      .where("createdAt", ">", newerThan)
      .orderBy("createdAt", "desc")
      .limit(500)
      .get();
  } catch (err) {
    console.warn("reconcilePostVisibility query failed:", err.message);
    return;
  }
  let promoted = 0, held = 0;
  for (const doc of snap.docs) {
    const d = doc.data();
    // Resolve posts still unvalidated: no moderationStatus (old clients) OR
    // "pending_validation" (new clients that start hidden). Skip posts already
    // resolved to "live" or held at "pending_review".
    if (d.moderationStatus && d.moderationStatus !== "pending_validation") continue;
    if (d.isRepost === true || isPostClean(d.text)) {
      await setPostLive(doc.ref);
      promoted++;
    } else {
      await holdReconciledPost(doc.ref, d.text);
      held++;
    }
  }
  if (promoted || held) {
    console.log(`reconcilePostVisibility: promoted ${promoted}, held ${held} of ${snap.size} scanned`);
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

// M-1 (2026-06-08 audit): recoverable hold for replies, mirroring posts.
// Previously a reply that tripped the (high-false-positive) PII detector was
// HARD-DELETED with no banner, appeal, or recovery — silently destroying
// legitimate grief replies that merely mention a name. Now PII replies are
// held at moderationStatus="pending_review" instead: hidden from other
// readers (firestore.rules reply read gate), still visible to their author
// with an "under review" banner, and rescuable by an admin via the
// pending-replies tab in admin.html. Hard-delete is retained only for the
// low-false-positive abuse categories (hate/threat/sexual/harassment) in
// applyReplyModeration. Idempotent: first reason wins, like setPendingReview.
async function setReplyPendingReview(replyRef, reason) {
  const snap = await replyRef.get();
  if (!snap.exists) return false;
  const data = snap.data() || {};
  if (data.moderationStatus === "pending_review") return false;
  await replyRef.update({
    moderationStatus: "pending_review",
    pendingReason: reason,
    pendingDetectedAt: FieldValue.serverTimestamp(),
  });
  return true;
}

// Promote a clean reply to moderationStatus="live" (M-1). Unlike posts, the
// client doesn't write a create-time moderationStatus on replies, so a clean
// reply would otherwise have NO field — and the iOS thread query
// (where moderationStatus == "live") can't match a missing field. validateReply
// stamps "live" on clean replies so they're queryable. Transactional + guarded
// exactly like setPostLive: never override a concurrent pending_review hold,
// idempotent on an already-live reply.
async function setReplyLive(replyRef) {
  try {
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(replyRef);
      if (!snap.exists) return;
      const status = snap.data().moderationStatus;
      if (status === "pending_review" || status === "live") return;
      tx.update(replyRef, { moderationStatus: "live" });
    });
  } catch (err) {
    console.warn(`setReplyLive ${replyRef.id} failed:`, err.message);
  }
}

exports.validateReply = onDocumentCreated(
  // retry:true (2026-06-08 re-review): the handler is idempotent (setReplyLive
  // / setReplyPendingReview / delete are all no-ops on re-run). Without retry,
  // a transient Firestore error mid-moderation would leave the reply field-less
  // — and a field-less CLEAN reply is invisible to everyone but its author
  // forever (the client thread query filters moderationStatus == "live").
  // Replies have no reconcilePostVisibility backstop, so retry is the safety net.
  { document: "posts/{postId}/replies/{replyId}", retry: true },
  async (event) => {
    const postId = event.params.postId;
    const replyId = event.params.replyId;
    const replyData = event.data.data();
    if (!replyData) return;
    const replyRef = db.collection("posts").doc(postId).collection("replies").doc(replyId);

    const text = replyData.text;
    // Blank / over-length stay HARD deletes — those aren't recoverable content
    // (a blank reply is nothing; >500 chars is a tampered client past the UI
    // cap). Counter decrements are handled by onReplyDeletedUpdateCount.
    if (typeof text !== "string" || text.trim().length === 0) {
      console.warn(`Deleting reply ${replyId} — missing or blank text`);
      await replyRef.delete();
      return;
    }

    if (text.length > 500) {
      console.warn(`Deleting reply ${replyId} — text too long (${text.length} chars)`);
      await replyRef.delete();
      return;
    }

    // PII → recoverable HOLD (M-1), not delete. The reply is hidden from other
    // readers but preserved for the author + admin rescue. Jitter before the
    // status flip preserves the timing-oracle defense (same as validatePost).
    // #2 (2026-06-09 audit): the detector trips on both names and URLs; label
    // a URL-bearing reply "abuse_link" so the admin queue shows the right
    // category ("contains link") rather than "names / contact info".
    if (containsNameOrIdentifyingInfo(text)) {
      const reason = containsURL(text) ? "abuse_link" : "pii";
      console.warn(`Holding reply ${replyId} on post ${postId} for review — identifying-info detector tripped (${reason})`);
      await moderationDeleteJitter();
      await setReplyPendingReview(replyRef, reason);
      return;
    }

    // Clean on PII. Promote to live only if ALSO clean on the flag/abuse axes
    // that onReplyCreatedModerate enforces (mirror of validatePost/isPostClean),
    // so we never briefly surface a reply onReplyCreatedModerate is about to
    // hold/delete — and so clean replies carry a queryable moderationStatus.
    if (!computeReplyFlagReason(text)) {
      await setReplyLive(replyRef);
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
  // Defense in depth: validatePost / validateReply already delete on the
  // create trigger, but onPostUpdated / onReplyUpdated / onMessageCreated
  // moderation runs through this helper. Without delegation here, an editor
  // (or a tampered client editing into an existing doc) could slip a name
  // past the soft-flag pipeline. The delegated detector is a strict
  // superset of the checks above; the redundant calls above are kept for
  // clarity and because they run cheaply on early returns.
  if (containsNameOrIdentifyingInfo(text)) return true;
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

// Explicit, high-urgency crisis statements — held AND page admins
// (onPostCreatedAlertAdmins). 2026-06-01: expanded with direct vocabulary,
// common slang/euphemisms, contractions, and frequent misspellings. Matching
// runs through matchesCrisisPhrase, which normalizes leet/unicode/spaced
// evasions, so we list canonical lowercase forms here.
const MOD_CRISIS_EXPLICIT = [
  // direct suicide vocabulary + common misspellings
  "suicidal", "suicide", "suicidel", "sucide", "sucidal", "suiside", "suacide",
  // self-killing intent
  "kill myself", "killing myself", "kill my self", "want to kill myself",
  "wanna kill myself", "going to kill myself", "gonna kill myself",
  "off myself", "end myself", "delete myself", "unalive", "unalive myself",
  "hang myself", "hanging myself", "neck myself",
  // ending my life
  "end my life", "ending my life", "end it all", "ending it all",
  "take my own life", "take my life", "want to end my life",
  // wanting to die / be dead
  "want to die", "wanna die", "want to be dead", "ready to die",
  "wish i was dead", "wish i were dead", "wish i could die",
  "better off dead", "rather be dead",
  // self-harm
  "hurt myself", "want to hurt myself", "harm myself", "self harm",
  "self-harm", "selfharm", "cut myself", "cutting myself", "burn myself",
  // not wanting to exist / wake up
  "don't want to wake up", "dont want to wake up", "don't want to be here",
  "dont want to be here", "don't want to exist", "dont want to exist",
  "want to disappear", "want to vanish",
];

// Softer distress / hopelessness — held for review (concerningContent) but
// NOT paged, to avoid fatiguing the admin alert with everyday venting.
const MOD_CRISIS_SOFT = [
  "can't go on", "cant go on", "can't do this anymore", "cant do this anymore",
  "can't keep going", "can't take it anymore", "cant take it anymore",
  "no reason to live", "nothing to live for", "no point in living",
  "no point anymore", "not worth living", "give up on everything",
  "want to give up", "done with life", "done with everything",
  "tired of living", "tired of being alive", "better off without me",
  "everyone better off without me", "no one would care", "no one would notice",
  "nobody cares", "nobody would miss me", "won't be missed",
  "disappear forever", "why am i still here", "wish i wasn't here",
  "wish i didn't exist", "want it to stop", "want it all to end", "nothing left",
];

// Derived so MOD_EXPLICIT_CRISIS is, by construction, a subset of
// MOD_CONCERNING — preventing the 2026-06-01 class of bug where an explicit
// phrase ("suicidal") was paged-worthy but absent from the hold list.
const MOD_EXPLICIT_CRISIS = MOD_CRISIS_EXPLICIT;
const MOD_CONCERNING = [...MOD_CRISIS_EXPLICIT, ...MOD_CRISIS_SOFT];

// Evasion-resistant crisis matcher (2026-06-01). A plain lowercase
// `includes` misses leetspeak ("su1c1dal"), unicode confusables/fullwidth
// ("𝐬𝐮𝐢𝐜𝐢𝐝𝐚𝐥"), and spaced-out letters ("s u i c i d e"). We reuse the PII
// detector's aggressiveNormalizeForNameMatch (canonicalize → fold unicode →
// de-leet → collapse single-letter chains) and also test a punctuation/space-
// stripped form so "kill myself" matches "k i l l m y s e l f" → "killmyself".
// Crisis posts are HELD for review (not deleted), so leaning toward
// over-detection is the intended, safe direction.
function matchesCrisisPhrase(rawText, list) {
  const lowered = (rawText || "").toLowerCase();
  const normalized = aggressiveNormalizeForNameMatch(rawText || "");
  const noSpace = normalized.replace(/[^a-z0-9]/g, "");
  return list.some((phrase) => {
    if (lowered.includes(phrase) || normalized.includes(phrase)) return true;
    // Space/punct-insensitive fallback, length-guarded so short tokens
    // (e.g. "kms") don't false-positive against arbitrary letter runs.
    const pNoSpace = phrase.replace(/[^a-z0-9]/g, "");
    return pNoSpace.length >= 6 && noSpace.includes(pNoSpace);
  });
}

function isPostExplicitCrisis(rawText) {
  return matchesCrisisPhrase(rawText, MOD_EXPLICIT_CRISIS);
}

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
  // 2026-05-31: added MOD_HARASSMENT for posts. Previously only replies
  // checked it (computeReplyFlagReason at line 2350), so a user could
  // publish a top-level post with "kys" / "drink bleach" and have it
  // bypass auto-detection entirely. Ordered AFTER threat so a post
  // containing both ("im gonna kill you, kys") routes to the more
  // severe "targeted_threat" reason instead of "harassment".
  if (MOD_THREAT.some((phrase) => text.includes(phrase))) return "targeted_threat";
  if (MOD_HARASSMENT.some((phrase) => text.includes(phrase))) return "harassment";
  if (MOD_SEXUAL.some((p) => p.test(text))) return "sexual_content";
  if (containsPII(rawText || "")) return "personal_information";
  if (containsURL(rawText || "")) return "contains_link";
  return null;
}

function isPostConcerning(rawText) {
  return matchesCrisisPhrase(rawText, MOD_CONCERNING);
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
    // F-3 (2026-06-08 audit): order by flaggedAt DESC before the limit so a
    // user with >20 all-time flagged posts has their MOST RECENT flags
    // examined, not an arbitrary 20. Without the orderBy, a determined
    // offender could accumulate >20 old flags and have the recent-window
    // count silently under-read, evading auto-restriction. Requires the
    // composite index posts(authorId ASC, flagged ASC, flaggedAt DESC) —
    // added to firestore.indexes.json.
    const flaggedSnap = await db.collection("posts")
      .where("authorId", "==", authorId)
      .where("flagged", "==", true)
      .orderBy("flaggedAt", "desc")
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
      // Idempotency: if the user is already inside an active system
      // restriction window, leave it alone. Without this guard, every
      // subsequent flagged post inside the rolling 7-day count above the
      // 5-flag threshold rewrote restrictedUntil to now+48h — letting a user
      // who keeps tripping the threshold get trapped in a perpetually
      // extending auto-restriction. Admin restrictions (restrictedBy != "system")
      // are untouched here either way; this branch only fires when the
      // existing restriction was itself system-set.
      const userSnap = await db.collection("users").doc(authorId).get();
      const userData = userSnap.exists ? userSnap.data() : {};
      const alreadyRestricted = userData.restricted === true
        && userData.restrictedBy === "system"
        && userData.restrictedUntil
        && typeof userData.restrictedUntil.toDate === "function"
        && userData.restrictedUntil.toDate().getTime() > Date.now();
      if (alreadyRestricted) {
        console.log(`User ${authorId} already in active system restriction; skipping extension`);
        return;
      }
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

  if (concerning) {
    // 2026-06-01 audit (most-severe-first): crisis is evaluated BEFORE the
    // abuse/PII flag. Previously this was `else if (concerning)`, so a post
    // in crisis that ALSO tripped a milder flag (e.g. "i can't do this
    // anymore, find me on tiktok" → personal_information) never set
    // concerningContent — it was silently downgraded to a generic abuse/PII
    // takedown, never appeared on the admin crisis tab (which queries
    // concerningContent==true), and got no crisis triage. We now always set
    // concerningContent so the post reaches crisis review; if it ALSO
    // tripped a flagReason we fold the flagged markers in so the "flagged"
    // admin tab (flagged==true) and repeat-offender logic still see it. The
    // explicit-crisis admin page is a separate trigger
    // (onPostCreatedAlertAdmins) keyed independently on the text.
    const extra = {
      concerningContent: true,
      flaggedAt: FieldValue.serverTimestamp(),
    };
    if (flagReason) {
      extra.flagged = true;
      extra.flagReason = flagReason;
    }
    await setPendingReview(db.collection("posts").doc(postId), "crisis", extra);
    console.log(
      `Post ${postId} concerning + pending_review` +
        (flagReason ? ` (also ${flagReason})` : "")
    );
    if (flagReason) await checkRepeatOffenderPosts(postData.authorId);
  } else if (flagReason) {
    // 2026-05-31: flagged posts flip to pending_review AND keep the
    // legacy flagged=true marker so the existing "flagged posts" admin
    // tab keeps showing them. Single combined write — atomic, no
    // intermediate "flagged but still visible" window if the second
    // write would have failed. setPendingReview's extraFields path
    // applies these alongside the visibility flip in one update().
    await setPendingReview(
      db.collection("posts").doc(postId),
      flagReasonToPendingReason(flagReason),
      {
        flagged: true,
        flaggedAt: FieldValue.serverTimestamp(),
        flagReason,
      }
    );
    console.log(`Post ${postId} flagged + pending_review: ${flagReason}`);
    await checkRepeatOffenderPosts(postData.authorId);
  }
});

// Maps the existing flagReason taxonomy (hate_speech, harassment,
// targeted_threat, sexual_content, personal_information, contains_link)
// onto the pendingReason taxonomy used by the admin dashboard pending
// tab. Kept here near onPostCreated so the two stay in sync; if a new
// flagReason is added to computePostFlagReason, add it here too or it
// falls through to a generic "abuse" reason.
function flagReasonToPendingReason(flagReason) {
  switch (flagReason) {
    case "hate_speech": return "abuse_hate";
    case "harassment": return "abuse_harassment";
    case "targeted_threat": return "abuse_threat";
    case "sexual_content": return "abuse_sexual";
    case "personal_information": return "pii";
    case "contains_link": return "abuse_link";
    case "spam_or_commercial": return "abuse_spam";
    default: return "abuse";
  }
}

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
  const identifying = containsNameOrIdentifyingInfo(after.text);

  // 2026-06-01 audit (most-severe-first): mirror onPostCreated. Crisis is
  // evaluated BEFORE the PII early-return and the abuse flag so an edit that
  // introduces crisis text alongside PII/abuse still sets concerningContent
  // and reaches the crisis tab instead of being masked as a "pii" takedown.
  if (concerning) {
    // Skip the rewrite only when nothing material would change — already on
    // the crisis tab AND the flag state is already correct. flaggedAt stays
    // pinned to the original detection time in that case.
    const flagAlreadyCorrect = flagReason
      ? after.flagged === true && after.flagReason === flagReason
      : true;
    if (after.concerningContent === true && flagAlreadyCorrect) return;
    const extra = {
      concerningContent: true,
      flaggedAt: FieldValue.serverTimestamp(),
    };
    if (flagReason) {
      extra.flagged = true;
      extra.flagReason = flagReason;
    }
    await setPendingReview(db.collection("posts").doc(postId), "crisis", extra);
    console.log(
      `Post ${postId} concerning + pending_review after edit` +
        (flagReason ? ` (also ${flagReason})` : "")
    );
    if (flagReason) await checkRepeatOffenderPosts(after.authorId);
    return;
  }

  // Identifying-info detection on edit: 2026-05-31 switched from DELETE
  // to pending-review flip, mirroring validatePost. Author can still
  // see + further edit; admin must approve.
  if (identifying) {
    console.warn(`Pending-review post ${postId} after edit — identifying-info detector tripped`);
    await setPendingReview(db.collection("posts").doc(postId), "pii");
    return;
  }

  if (flagReason) {
    // Don't rewrite the doc if it's already flagged with the same reason —
    // saves a Firestore write per no-change re-flag and keeps flaggedAt
    // pinned to the original detection time.
    if (after.flagged === true && after.flagReason === flagReason) return;
    // Same single-write pattern as onPostCreated (see comment there).
    await setPendingReview(
      db.collection("posts").doc(postId),
      flagReasonToPendingReason(flagReason),
      {
        flagged: true,
        flaggedAt: FieldValue.serverTimestamp(),
        flagReason,
      }
    );
    console.log(`Post ${postId} re-flagged + pending_review after edit: ${flagReason}`);
    await checkRepeatOffenderPosts(after.authorId);
  }
});

// ============================================================
// Admin crisis alert — pages registered admins when a post trips an
// EXPLICIT crisis phrase ("kill myself", "end my life", etc.). Softer
// phrases (in MOD_CONCERNING but not MOD_EXPLICIT_CRISIS) still flag the
// post as concerningContent and hide it from feeds, but don't page —
// alert fatigue would defeat the point.
//
// Recipients are configured in Firestore at `system/crisisAlertRecipients`
// with shape `{ uids: ["<adminUid1>", ...] }`. FCM tokens are read from
// each recipient's `users/{uid}/private/data.fcmToken`. If neither doc is
// present, the function logs and returns — no crash, no retry storm.
//
// The alert routes to the admin dashboard at https://www.toskaapp.com/admin
// on tap (apple-developer-app-association handles deep linking to the
// post id, but since the dashboard is a web page, a regular URL works).
// ============================================================

exports.onPostCreatedAlertAdmins = onDocumentCreated("posts/{postId}", async (event) => {
  const data = event.data?.data();
  if (!data || data.isRepost === true || typeof data.text !== "string") return;
  if (!isPostExplicitCrisis(data.text)) return;

  const postId = event.params.postId;

  // Idempotency (2026-06-01 audit): Eventarc is at-least-once, so a
  // redelivery of this create event would page admins twice. Claim before
  // sending. NOTE: the dedup key is namespaced per-post (`crisisAlert_<id>`)
  // rather than `event.id` on purpose — four other triggers share this
  // `posts/{postId}` create path and onPostCreatedUpdateTagCounts already
  // claims `event.id`. If Eventarc hands co-path triggers the same event id,
  // claiming event.id here could let the tag-count claim starve the crisis
  // page (or vice versa). One post = one page, so the post id is the correct,
  // collision-free dedup unit.
  if (!await claimTriggerEvent(`crisisAlert_${postId}`)) return;

  // Fallback admin uid baked in so the function alerts you even before
  // `system/crisisAlertRecipients` is seeded in Firestore. To add or
  // change admins later without redeploying, write `{ uids: [...] }` to
  // that doc — Firestore values override this fallback.
  //
  // A-1 (2026-06-09 audit): corrected from fKcz0r7wYih8ePNg5019ZEOhSWB2 (which
  // is a TEST account, not an admin — confirmed via checkAdminUid.js) to the
  // real prod admin uid (salinarotess@gmail.com). With the wrong uid, crisis
  // pages routed to a non-admin's (possibly absent) FCM token and were dropped.
  // Best practice: seed system/crisisAlertRecipients so this literal is moot.
  const FALLBACK_ADMIN_UIDS = ["alcxPIqLQZcTIwF5wjJMkK1yPlW2"];
  try {
    const cfgSnap = await db.collection("system").doc("crisisAlertRecipients").get();
    const configured = (cfgSnap.data()?.uids || []).filter((u) => typeof u === "string");
    const adminUids = configured.length > 0 ? configured : FALLBACK_ADMIN_UIDS;
    if (adminUids.length === 0) {
      console.log(`crisis-alert: post ${postId} tripped explicit-crisis but no admin uids configured`);
      return;
    }

    const tokens = [];
    for (const uid of adminUids) {
      const privSnap = await db.collection("users").doc(uid).collection("private").doc("data").get();
      const token = privSnap.data()?.fcmToken;
      if (typeof token === "string" && token.length > 0) tokens.push(token);
    }
    if (tokens.length === 0) {
      console.log(`crisis-alert: post ${postId} tripped explicit-crisis but no FCM tokens for ${adminUids.length} admins`);
      return;
    }

    // L-1 (2026-06-08 audit): do NOT put raw post text (or the author handle)
    // in the push — it lands on the admin's lock screen / notification mirror,
    // exactly the leak the user-facing pushes were hardened against. Send a
    // neutral body; the admin taps through to the crisis tab in admin.html
    // (gated by App Check + the admins/{uid} check) to read the content. Only
    // the non-identifying postId rides in the data payload for deep-linking.
    const message = {
      notification: {
        title: "crisis post",
        body: "a post needs review in the crisis queue",
      },
      data: {
        type: "admin_crisis_alert",
        postId,
      },
      tokens,
    };

    const messaging = getMessaging();
    const resp = await messaging.sendEachForMulticast(message);
    console.log(`crisis-alert: post ${postId} sent to ${resp.successCount}/${tokens.length} admin devices`);
  } catch (err) {
    console.warn(`crisis-alert: failed to alert admins for post ${postId}: ${err.message}`);
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
  const replyRef = db.collection("posts").doc(postId).collection("replies").doc(replyId);
  if (flagReason === "personal_information" || flagReason === "contains_link") {
    // M-1: high-false-positive categories (names/links) get a recoverable
    // HOLD (hidden pending admin review) rather than the old visible-but-
    // flagged state — consistent with validateReply and posts. pendingReason
    // mirrors the admin.html label keys ("pii" / "abuse_link").
    await setReplyPendingReview(replyRef, flagReason === "contains_link" ? "abuse_link" : "pii");
    console.log(`Reply ${replyId} on post ${postId} held for review: ${flagReason}`);
  } else {
    // Abuse (hate/threat/sexual/harassment): low false-positive, genuinely
    // removable — keep the hard delete. Counter decrement is handled by
    // onReplyDeletedUpdateCount on the subsequent delete trigger.
    await replyRef.delete();
    console.log(`Reply ${replyId} on post ${postId} deleted: ${flagReason}`);
  }
}

exports.onReplyCreatedModerate = onDocumentCreated(
  // retry:true (2026-06-08 re-review): idempotent (applyReplyModeration →
  // setReplyPendingReview/delete are no-ops on re-run). Without it, a transient
  // error on a flag-reason reply leaves it field-less/invisible with no backstop.
  { document: "posts/{postId}/replies/{replyId}", retry: true },
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
  // retry:true (2026-06-08 re-review): idempotent re-moderation on edit; the
  // before.text === after.text guard still holds on redelivery.
  { document: "posts/{postId}/replies/{replyId}", retry: true },
  async (event) => {
    const before = (event.data && event.data.before && event.data.before.data()) || {};
    const after = (event.data && event.data.after && event.data.after.data()) || {};
    if (before.text === after.text) return;

    const replyRef = db.collection("posts").doc(event.params.postId)
      .collection("replies").doc(event.params.replyId);

    // PII introduced on edit → recoverable HOLD (M-1), not delete.
    // #2: label a URL-bearing edit "abuse_link" rather than "pii".
    if (containsNameOrIdentifyingInfo(after.text)) {
      const reason = containsURL(after.text) ? "abuse_link" : "pii";
      console.warn(`Holding reply ${event.params.replyId} on post ${event.params.postId} after edit — identifying-info detector tripped (${reason})`);
      await setReplyPendingReview(replyRef, reason);
      return;
    }

    const flagReason = computeReplyFlagReason(after.text);
    if (!flagReason) return;
    // Skip if already held for the same kind of reason (idempotent re-run).
    if (after.moderationStatus === "pending_review"
        && (flagReason === "personal_information" || flagReason === "contains_link")) {
      return;
    }
    await applyReplyModeration(event.params.postId, event.params.replyId, flagReason);
  }
);

// DMs were cut (2026-06-03): onMessageCreatedModerate removed. The
// conversations/messages collections are denied in firestore.rules, so no
// message docs can be created and this trigger has nothing to moderate.

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

// Fallback cleanup for processedTriggerEvents — the Firestore TTL policy
// on `expiresAt` is the primary mechanism, but if TTL isn't configured on
// a project (staging fresh-start, ops oversight) this scheduled sweep
// keeps the collection from growing unbounded. Daily cadence is plenty —
// each entry already lives 7 days for in-flight Eventarc retries to land.
// 24h SLA tripwire on the moderation queue. The in-app + App Store description
// promise that "reports are reviewed within 24 hours" — but until now there
// was no automated overdue signal beyond the dashboard badge, so a forgotten
// queue could quietly miss the SLA. This scheduled function queries pending
// reports older than 24h and emits a structured log per overdue report
// (capped to avoid log spam during a sustained backlog). The companion
// log-based metric `reports_aged_24h` plus an alert policy on it
// (count > 0 for 30 min → Toska Alerts) page someone before the SLA breaks
// in user-visible ways. RUNBOOK section "24h SLA — concrete wiring" has the
// gcloud commands to wire the metric + alert policy.
//
// Index requirement: reports (status asc, createdAt desc) — already in
// firestore.indexes.json from the original moderation-queue queries.
//
// Cap of 100 log entries/run prevents a sustained backlog from emitting
// thousands of log entries per hour. The summary line is always emitted so
// the metric tracks the true overdue count even when the per-report cap
// kicks in.
exports.checkReportSLA = onSchedule("every 60 minutes", async () => {
  const cutoff = Timestamp.fromDate(new Date(Date.now() - 24 * 60 * 60 * 1000));
  const PER_REPORT_LOG_CAP = 100;

  let snap;
  try {
    snap = await db.collection("reports")
      .where("status", "==", "pending")
      .where("createdAt", "<", cutoff)
      .orderBy("createdAt", "asc")
      .limit(500)
      .get();
  } catch (err) {
    console.warn("checkReportSLA query failed:", err.message);
    return;
  }

  const overdueCount = snap.size;
  if (overdueCount === 0) return;

  // One structured log per overdue report so triage can link directly.
  // Capped — the summary line below is the source of truth for the metric.
  for (let i = 0; i < Math.min(overdueCount, PER_REPORT_LOG_CAP); i++) {
    const doc = snap.docs[i];
    const data = doc.data();
    console.log(JSON.stringify({
      tag: "report_aged_24h",
      reportId: doc.id,
      ageHours: Math.round((Date.now() - (data.createdAt?.toMillis?.() || Date.now())) / (60 * 60 * 1000)),
      reportedBy: data.reportedBy || null,
      status: data.status || null,
    }));
  }

  // Always emit a summary so the metric reflects the true count even when
  // per-report logging is capped.
  console.log(JSON.stringify({
    tag: "report_aged_24h_summary",
    overdueCount,
    capReached: overdueCount > PER_REPORT_LOG_CAP,
  }));
});

exports.cleanupProcessedTriggerEvents = onSchedule("every 24 hours", async () => {
  const now = Timestamp.now();
  let totalDeleted = 0;
  // Bounded sweep: 5 batches × 500 = 2500 deletions per run. At our
  // expected event volume that's more than the daily inflow; if we ever
  // fall behind, the next run picks up where we left off.
  for (let i = 0; i < 5; i++) {
    const snap = await db.collection("processedTriggerEvents")
      .where("expiresAt", "<=", now)
      .limit(500)
      .get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    try {
      await batch.commit();
    } catch (err) {
      console.warn("cleanupProcessedTriggerEvents batch failed:", err.message);
      break;
    }
    totalDeleted += snap.size;
    if (snap.size < 500) break;
  }
  if (totalDeleted > 0) {
    console.log(`cleanupProcessedTriggerEvents: deleted ${totalDeleted} expired entries`);
  }
});

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

// Reply notifications: server-only `message` backfill.
//
// The notification create rule was previously permissive about the `message`
// field — any authenticated user could write a notification doc with type
// 'reply' (no `exists()` check on a real reply doc, only postId existence
// + recipient-is-author + deterministic notifId) and stuff arbitrary text
// into a `message` field that NotificationsView rendered as a preview
// ("@handle replied: \"…\""). That was a free-text targeted-abuse channel
// that bypassed validateReply moderation entirely and could carry
// deanonymizing payloads to a victim.
//
// The fix is two-layered:
//   1. The rule now drops `message` from the client-writable schema for
//      notification creates. A client write that includes the field is
//      rejected.
//   2. This trigger backfills `message` from the actual reply doc via the
//      Admin SDK (which bypasses rules) so the legitimate UX still works:
//      the recipient's NotificationsView listener delivers an empty-message
//      notification first ("@handle replied to your post" fallback) and a
//      second snapshot once the trigger updates the field.
//
// If no reply doc exists for (fromUserId, postId), the notification is
// bogus — the actor never replied. Delete it.
exports.enrichReplyNotification = onDocumentCreated(
  "users/{userId}/notifications/{notifId}",
  async (event) => {
    const userId = event.params.userId;
    const notifId = event.params.notifId;
    const notifData = event.data.data();
    if (!notifData) return;
    if (notifData.type !== "reply") return;

    const fromUserId = notifData.fromUserId;
    const postId = notifData.postId;
    const notifRef = event.data.ref;

    if (!fromUserId || !postId) {
      console.log("Reply notification missing fromUserId/postId; deleting:", notifRef.path);
      try {
        await notifRef.delete();
      } catch (err) {
        console.warn("enrichReplyNotification delete-bogus failed:", err.message);
      }
      return;
    }

    // Most-recent reply by this actor on this post. Subcollection-scoped query;
    // backed by the (authorId asc, createdAt desc) COLLECTION-scoped index in
    // firestore.indexes.json. Bounded at 1 doc — any reply by this actor on
    // this post is sufficient proof the notification is real; we use the
    // newest one's text for preview.
    let replyText = "";
    try {
      const replySnap = await db.collection("posts").doc(postId)
        .collection("replies")
        .where("authorId", "==", fromUserId)
        .orderBy("createdAt", "desc")
        .limit(1)
        .get();

      if (replySnap.empty) {
        console.log(
          "Reply notification has no backing reply doc; deleting:",
          notifRef.path,
          { postId, fromUserId }
        );
        try {
          await notifRef.delete();
        } catch (err) {
          console.warn("enrichReplyNotification delete-no-reply failed:", err.message);
        }
        return;
      }

      // M-1 (2026-06-08 audit): if the backing reply is HELD for review
      // (moderationStatus == "pending_review"), do NOT leak its text into the
      // recipient's in-app notification preview — the whole point of the hold
      // is that this recipient can't see the (possibly PII) reply. Leave the
      // message unset so NotificationsView shows the generic "replied to your
      // post" fallback; if an admin later approves the reply it rejoins the
      // thread normally.
      if (replySnap.docs[0].data().moderationStatus === "pending_review") {
        console.log("enrichReplyNotification: backing reply is held; suppressing preview:", notifRef.path);
        return;
      }
      replyText = replySnap.docs[0].data().text || "";
    } catch (err) {
      console.warn("enrichReplyNotification reply lookup failed:", err.message);
      // On query failure, leave the notification with no message field. The
      // NotificationsView renderer falls back to "@handle replied to your
      // post" when message is empty, which is the safe default.
      return;
    }

    // 200-char cap matches the prior PostInteractionManager.sendNotification
    // truncation. NotificationsView shows prefix(80) of this; the larger
    // server cap absorbs any future renderer change without re-deploying.
    const truncated = replyText.slice(0, 200).trim();
    if (truncated.length === 0) return;

    try {
      await notifRef.update({ message: truncated });
    } catch (err) {
      console.warn("enrichReplyNotification message update failed:", err.message);
    }
  }
);

// Two-tiered rate limit on reports.
//
// Tier 1 (per-reporter, 20/hour): caps a single uid from flooding the
// moderation queue solo. Mirrors rateLimitNotifications.
//
// Tier 2 (per-target, 10/hour): caps the total reports filed against any
// one user/post/conversation by ANY source in a rolling hour. Without this,
// 10–20 coordinated sock-puppet accounts can each post 1 report against
// the same victim, sail past Tier 1, and burn admin attention. Tier 2 is
// the audit-finding fix; the threshold is intentionally low (10) because
// legitimate reports against one target are rare and a flagged target
// already sits in the admin queue once — additional reports just inflate
// the noise.
//
// Index requirement: reports/(reportedBy ASC, createdAt DESC) and
// reports/(reportedUserId ASC, createdAt DESC) — both added to
// firestore.indexes.json.
exports.rateLimitReports = onDocumentCreated(
  "reports/{reportId}",
  async (event) => {
    const reportData = event.data.data();
    if (!reportData) return;
    const reportedBy = reportData.reportedBy;
    if (!reportedBy) return;

    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    const since = Timestamp.fromDate(oneHourAgo);

    // Tier 1: per-reporter cap.
    const recentSnap = await db.collection("reports")
      .where("reportedBy", "==", reportedBy)
      .where("createdAt", ">", since)
      .orderBy("createdAt", "desc")
      .limit(25)
      .get();
    if (recentSnap.size > 20) {
      console.log("Report rate limit exceeded for reporter:", reportedBy);
      await db.collection("reports").doc(event.params.reportId).delete();
      return;
    }

    // Tier 2: per-target cap. Skip when reportedUserId is absent (older
    // clients, edge cases) — the per-reporter cap still applies.
    const reportedUserId = reportData.reportedUserId;
    if (!reportedUserId) return;
    const recentByTargetSnap = await db.collection("reports")
      .where("reportedUserId", "==", reportedUserId)
      .where("createdAt", ">", since)
      .orderBy("createdAt", "desc")
      .limit(15)
      .get();
    if (recentByTargetSnap.size > 10) {
      console.log("Report rate limit exceeded for target:", reportedUserId,
        "from", reportedBy);
      await db.collection("reports").doc(event.params.reportId).delete();
    }
  }
);

// ============================================================
// Auto-hide a post into pending-review when 3+ distinct users report it
// within a 24-hour window. Mirrors the user-decision: "reports queue
// auto-hide pending review after N reports." Threshold = 3 (chosen as
// the balance between catching real problems and being abuse-proof: a
// single bad actor can't silence someone they disagree with).
//
// Counts DISTINCT reportedBy uids (so the same reporter spamming "report"
// 5 times on the same post still counts as 1). Reports older than 24h
// don't count — the window resets, matching how user perception of "this
// post is bad right now" works.
//
// No-ops when the post is already pending_review (setPendingReview is
// idempotent on same-reason; here we'd be overwriting with a different
// reason which would lose the original detection signal — guard upfront
// instead). Skips reports targeting replies / users / conversations —
// those have their own admin paths and don't hide source posts.
//
// Index requirement: reports/(type ASC, postId ASC, createdAt DESC) —
// added to firestore.indexes.json.
// ============================================================
exports.onReportCreatedAutoHide = onDocumentCreated(
  "reports/{reportId}",
  async (event) => {
    const reportData = event.data.data();
    if (!reportData) return;
    if (reportData.type !== "post") return;
    const postId = reportData.postId;
    if (typeof postId !== "string" || !postId) return;

    const postRef = db.collection("posts").doc(postId);
    const postSnap = await postRef.get();
    if (!postSnap.exists) return;
    const postData = postSnap.data() || {};
    if (postData.moderationStatus === "pending_review") return; // already hidden

    const since = Timestamp.fromDate(new Date(Date.now() - 24 * 60 * 60 * 1000));
    // Bound the read (2026-06-01 audit): we only need to know whether >= 3
    // DISTINCT reporters exist. This trigger re-runs on every new report, so
    // a bounded most-recent window can't miss a genuine brigade — the 3rd
    // distinct reporter's own report re-fires this with their doc in-window.
    // 60 comfortably clears the threshold given the per-target rate limit
    // (Tier 2: 10/hr), while capping memory if that limiter is ever bypassed.
    // Uses the existing (type, postId, createdAt DESC) composite index.
    const reportsSnap = await db.collection("reports")
      .where("type", "==", "post")
      .where("postId", "==", postId)
      .where("createdAt", ">", since)
      .orderBy("createdAt", "desc")
      .limit(60)
      .get();

    // Distinct reporter uids (Set semantics) — same user reporting twice
    // counts as one. Skip docs missing reportedBy (shouldn't happen given
    // rule enforcement, but defensive).
    const distinctReporters = new Set();
    reportsSnap.forEach((d) => {
      const r = d.get("reportedBy");
      if (typeof r === "string" && r) distinctReporters.add(r);
    });

    const THRESHOLD = 3;
    if (distinctReporters.size < THRESHOLD) return;

    console.log(`auto-hide post ${postId} — ${distinctReporters.size} distinct reports in 24h`);
    await setPendingReview(postRef, "user_reports", {
      autoHiddenReportCount: distinctReporters.size,
    });
  }
);

// DMs were cut (2026-06-03): onMessageCreatedUpdateCount removed. No message
// docs can be created (conversations/messages denied in firestore.rules), so
// there is no per-conversation message count to maintain.

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

// F-6 (2026-06-08 audit): drains repostCleanupQueue markers written by
// onPostDeletedCleanupReposts when a viral post had more reposts than one
// trigger invocation could clear. Each pass clears up to 5000 more and only
// removes the marker once the originalPostId has no remaining reposts.
exports.resumeRepostCleanup = onSchedule("every 60 minutes", async () => {
  const queueSnap = await db.collection("repostCleanupQueue").limit(10).get();
  if (queueSnap.empty) return;

  for (const queueDoc of queueSnap.docs) {
    const postId = queueDoc.id;
    try {
      const result = await clearRepostsOfPost(postId, 50);
      if (result.capHit) {
        await queueDoc.ref.update({
          lastResumedAt: FieldValue.serverTimestamp(),
          cumulativeDeleted: FieldValue.increment(result.totalDeleted),
        });
        console.log(`Partial repost cleanup for ${postId}: +${result.totalDeleted}, staying in queue.`);
      } else {
        console.log(`Completed repost cleanup for ${postId}: +${result.totalDeleted} this pass.`);
        await queueDoc.ref.delete();
      }
    } catch (err) {
      console.error(`resumeRepostCleanup failed for ${postId}:`, err.message);
    }
  }
});

// ============================================================
// Scheduled stale pendingDeletions monitor — runs every hour
// ============================================================

// ============================================================
// Resume orphaned-data cleanup for heavy deleted users — M-3 fix
// ============================================================
//
// Drains userDeletionCleanupQueue entries written by onUserDocDeleted
// when a single invocation hit its iteration cap. Each queue doc is
// keyed by `${uid}_${type}` where type ∈ {notifications, circleMessages,
// reports}. We process up to 20 entries per run and drop the entry
// when the corresponding helper reports capHit=false (i.e., the
// collection is empty for that uid).
//
// Mirrors resumePostDeletion's shape so future cleanup types can be
// added by extending the dispatch table without changing the schedule.
// ============================================================

exports.resumeUserCleanup = onSchedule("every 60 minutes", async () => {
  const queueSnap = await db.collection("userDeletionCleanupQueue").limit(20).get();
  if (queueSnap.empty) {
    console.log("userDeletionCleanupQueue is empty.");
    return;
  }

  const dispatch = {
    notifications: cleanupNotificationsForUid,
    circleMessages: cleanupCircleMessagesForUid,
    reports: cleanupSubmittedReportsForUid,
    reposts: cleanupRepostsForUid,
    follows: cleanupMirrorFollowsForUid,
    reflections: cleanupReflectionsForUid,
    replies: cleanupRepliesForUid,
    convos: cleanupUserConversationsForUid,
    likesOnOthers: cleanupLikesForUid,
  };

  // sub_* types resume the owner-only subcollection cleanup that the main
  // cascade does inline (saved, liked, notifications, blocked, presence,
  // private, drafts). Each suffix maps to a fixed collection path; we use
  // a separate dispatcher rather than passing arbitrary paths through the
  // queue doc to keep a closed allow-list of subcollections.
  const ALLOWED_SUB_RESUME = new Set([
    "saved", "liked", "notifications", "blocked", "presence", "private", "drafts",
  ]);

  for (const doc of queueSnap.docs) {
    const { uid, type } = doc.data();

    // sub_* continuation: deleteCollection until empty, returning capHit.
    if (typeof type === "string" && type.startsWith("sub_")) {
      const sub = type.substring("sub_".length);
      if (!ALLOWED_SUB_RESUME.has(sub)) {
        console.warn(`Unknown sub-cleanup target ${sub} for ${uid}; dropping queue entry.`);
        await doc.ref.delete();
        continue;
      }
      try {
        const result = await deleteCollection(db.collection("users").doc(uid).collection(sub));
        if (result?.capHit) {
          await doc.ref.update({
            lastResumedAt: FieldValue.serverTimestamp(),
            cumulativeDeleted: FieldValue.increment(result.totalDeleted || 0),
          });
          console.log(`Partial sub cleanup for ${uid}/${sub}: +${result?.totalDeleted || 0}, staying in queue.`);
        } else {
          console.log(`Completed sub cleanup for ${uid}/${sub}: +${result?.totalDeleted || 0} this pass.`);
          await doc.ref.delete();
        }
      } catch (err) {
        console.error(`resumeUserCleanup sub_${sub} failed for ${uid}:`, err.message);
        // Leave in queue; next invocation will retry.
      }
      continue;
    }

    const handler = dispatch[type];
    if (!handler) {
      console.warn(`Unknown cleanup type ${type} for ${uid}; dropping queue entry.`);
      await doc.ref.delete();
      continue;
    }
    try {
      const result = await handler(uid, 50);
      if (result.capHit) {
        await doc.ref.update({
          lastResumedAt: FieldValue.serverTimestamp(),
          cumulativeDeleted: FieldValue.increment(result.totalDeleted),
        });
        console.log(`Partial cleanup for ${uid}/${type}: +${result.totalDeleted}, staying in queue.`);
      } else {
        console.log(`Completed cleanup for ${uid}/${type}: +${result.totalDeleted} this pass.`);
        await doc.ref.delete();
      }
    } catch (err) {
      console.error(`resumeUserCleanup failed for ${uid}/${type}:`, err.message);
      // Leave in queue; next invocation will retry.
    }
  }
});

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

// Migrated from onRequest to onCall on 2026-05-08. The previous shape
// manually verified an App Check header + a Bearer ID token because
// `enforceAppCheck` only applies to onCall. The callable shape moves both
// checks into the framework — `enforceAppCheck: true` rejects unattested
// callers before the handler runs, and `request.auth` is auto-populated
// from the caller's Firebase ID token (no manual verifyIdToken). Net:
// fewer hand-rolled boundary checks, identical security properties, and
// the iOS callsite drops ~30 lines of token-fetching boilerplate (it now
// uses Functions().httpsCallable). Old onRequest-shape iOS binaries will
// fail to call this — acceptable because the same TestFlight cut that
// gets the rule-tightening also gets the new callable.
exports.giphyProxy = onCall(
  { secrets: [GIPHY_KEY], enforceAppCheck: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "sign-in required");
    }
    const uid = request.auth.uid;

    // 60 GIF picker calls per minute per uid is comfortably above legitimate
    // browsing (one search + a few page loads) but well below what a tampered
    // client would need to exhaust the Giphy free-tier quota in a day.
    // F-5: fail closed — Giphy is an external paid quota, so a rate-limiter
    // outage must not become an unthrottled-storm vector.
    const allowed = await checkRateLimit(uid, "giphyProxy", 60, 60, true);
    if (!allowed) {
      throw new HttpsError("resource-exhausted", "rate limit exceeded");
    }

    const data = request.data || {};
    const mode = data.mode === "search" ? "search" : "trending";
    const limit = Math.min(parseInt(data.limit, 10) || 30, 50);
    const rating = "pg-13";

    let upstream;
    if (mode === "search") {
      const q = (data.q || "").toString().slice(0, 100);
      if (!q.trim()) {
        throw new HttpsError("invalid-argument", "missing q for search mode");
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
        throw new HttpsError("unavailable", "upstream unavailable");
      }
      // Defend against an upstream returning a runaway payload (compromised
      // upstream, DNS hijack, mistaken API change). Real Giphy responses for
      // limit=30 are < 100KB. 500KB cap is loose enough to avoid false
      // positives but tight enough to bound the client memory we'd hand it.
      const text = await r.text();
      if (text.length > 500_000) {
        console.warn(`giphyProxy oversized response: ${text.length} bytes`);
        throw new HttpsError("unavailable", "upstream response too large");
      }
      try {
        return JSON.parse(text);
      } catch (parseErr) {
        console.warn("giphyProxy upstream returned non-JSON");
        throw new HttpsError("unavailable", "upstream malformed");
      }
    } catch (err) {
      // Re-throw HttpsErrors as-is; they're already shape-correct and don't
      // contain api_key=… in their messages.
      if (err instanceof HttpsError) throw err;
      // Defense in depth: Node fetch can include the request URL in error
      // messages (DNS failures, abort traces, etc.) which would log the
      // GIPHY_KEY query parameter to Cloud Logging. Strip api_key=...
      // before any error message reaches console.
      const sanitize = (s) => (s || "").replace(/api_key=[^&\s"]*/g, "api_key=***");
      console.warn("giphyProxy failed:", sanitize(err.message));
      throw new HttpsError("unavailable", "upstream failure");
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
      // 2026-06-01 audit: count-then-write must be atomic. Previously the
      // count().get() reads and the update() were separate, so an
      // onFollow{Created,Deleted}UpdateCounts increment landing in between
      // was clobbered (counter drifted to the stale count). Doing the
      // aggregation reads and the write inside one transaction makes a
      // concurrent increment conflict and retry, so the written value
      // reflects a consistent snapshot. (firebase-admin >=13 supports
      // aggregation reads via transaction.get.)
      const { followerCount, followingCount } = await db.runTransaction(async (tx) => {
        const [followerSnap, followingSnap] = await Promise.all([
          tx.get(userRef.collection("followers").count()),
          tx.get(userRef.collection("following").count()),
        ]);
        const fc = followerSnap.data().count;
        const fg = followingSnap.data().count;
        tx.update(userRef, { followerCount: fc, followingCount: fg });
        return { followerCount: fc, followingCount: fg };
      });
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

// Audit admin moderation actions on posts (2026-06-01 audit: the most
// sensitive moderation surface — approving/unflagging or crisis-reviewing a
// held post — previously left no tamper-evident record). Gated strictly on an
// admin stamp field newly appearing (pendingApprovedBy / crisisReviewedBy),
// which only the admin client writes, so the automated auto-hide writes
// (setPendingReview from onPostCreated/onPostUpdated/onReportCreatedAutoHide)
// do NOT generate audit noise. Writes only to adminAuditLog → no trigger loop.
exports.auditPostModeration = onDocumentUpdated(
  "posts/{postId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after  = event.data.after.data() || {};

    const newlyApproved =
      before.pendingApprovedBy == null && after.pendingApprovedBy != null;
    const newlyCrisisReviewed =
      before.crisisReviewedBy == null && after.crisisReviewedBy != null;
    // unflagPost (docs/admin.html) restores previously-flagged content —
    // including content auto-held as crisis/PII — back to public feeds. That
    // reversal must be audited; key on unflaggedBy newly appearing so the
    // trigger's own no-op rewrites don't re-emit it.
    const newlyUnflagged =
      before.unflaggedBy == null && after.unflaggedBy != null;
    if (!newlyApproved && !newlyCrisisReviewed && !newlyUnflagged) return;

    if (newlyApproved) {
      await writeAuditEntry({
        action: "post.approve",
        adminUid: after.pendingApprovedBy || "unknown",
        targetType: "post",
        targetId: event.params.postId,
        targetHandle: after.authorHandle || before.authorHandle || null,
        before: { moderationStatus: before.moderationStatus || null, flagged: before.flagged ?? null },
        after:  { moderationStatus: after.moderationStatus  || null, flagged: after.flagged ?? null },
      });
    }
    if (newlyCrisisReviewed) {
      await writeAuditEntry({
        action: "post.crisis_reviewed",
        adminUid: after.crisisReviewedBy || "unknown",
        targetType: "post",
        targetId: event.params.postId,
        targetHandle: after.authorHandle || before.authorHandle || null,
        before: { concerningContent: before.concerningContent ?? null },
        after:  { concerningContent: after.concerningContent ?? null },
      });
    }
    if (newlyUnflagged) {
      await writeAuditEntry({
        action: "post.unflag",
        adminUid: after.unflaggedBy || "unknown",
        targetType: "post",
        targetId: event.params.postId,
        targetHandle: after.authorHandle || before.authorHandle || null,
        before: {
          flagged: before.flagged ?? null,
          concerningContent: before.concerningContent ?? null,
          flagReason: before.flagReason ?? null,
        },
        after: {
          flagged: after.flagged ?? null,
          concerningContent: after.concerningContent ?? null,
          flagReason: after.flagReason ?? null,
        },
      });
    }
  }
);

// Audit post deletions. The admin dashboard's removePost/deletePost
// (docs/admin.html) update the post with deletedBy/deletedAt immediately
// before the delete, so this onDocumentDeleted reads the doc's last state to
// record who removed it. Author self-deletes (no deletedBy) are recorded as
// "author".
exports.auditPostDeletion = onDocumentDeleted(
  "posts/{postId}",
  async (event) => {
    const data = event.data?.data() || {};
    await writeAuditEntry({
      action: "post.delete",
      adminUid: data.deletedBy || "author",
      targetType: "post",
      targetId: event.params.postId,
      targetHandle: data.authorHandle || null,
      before: {
        authorId: data.authorId || null,
        moderationStatus: data.moderationStatus || null,
        flagged: data.flagged ?? null,
      },
      after: null,
    });
  }
);

// ============================================================
// New-report admin notification — H-1 from pre-submission review
// ============================================================
//
// Emits a structured warning log on every new pending report so a
// Cloud Logging-based alert policy in Cloud Monitoring can match and
// route to the existing Toska Alerts notification channel
// (salte@saltedevelopments.com). The in-app ReportSheet promises
// "reports are reviewed within 24 hours" — without this, the admin
// only sees new reports when they happen to open admin.html.
//
// One-time setup on prod (toska-4ebf4): create a log-based alert
// policy that filters on jsonPayload.tag = "new_report_for_review"
// and notifies the Toska Alerts channel. Same shape on staging if
// you want staging-environment alerts too.
//
// Severity is set to WARNING so it doesn't get mixed in with the
// rate-limited ERROR-rate alert that already exists for runtime
// failures of sendPushNotification / onUserDocDeleted / validatePost.
// ============================================================

exports.notifyAdminsOfNewReport = onDocumentCreated(
  "reports/{reportId}",
  async (event) => {
    const data = event.data?.data();
    if (!data) return;
    // JSON.stringify the payload so Cloud Logging parses each field
    // into jsonPayload.* — the alert filter then reads jsonPayload.tag.
    console.warn(JSON.stringify({
      tag: "new_report_for_review",
      reportId: event.params.reportId,
      type: data.type || "unknown",
      reason: data.reason || "unknown",
      // L-2 (2026-06-08 audit): log the uid, not the handle. In an
      // anonymity-first app the handle is the user-facing identifier, and
      // Cloud Logging would otherwise persist a durable handle↔report linkage.
      // An admin can resolve the uid in the dashboard when triaging.
      reportedUserId: data.reportedUserId || null,
      severity: "WARNING",
    }));
  }
);

// ============================================================
// Test-only exports (consumed by functions-tests/functions.test.js).
// Firebase deploy only deploys exports that are CloudFunctions, so this
// plain object is inert in production. Exposing the internal Admin-SDK
// helpers + the shared db handle lets the emulator suite exercise the
// remediation logic directly (deletion cascade, the M-1 reply hold,
// counter dedup, rate limiting) without the flaky trigger machinery, and
// reusing this module's `db` avoids a second firebase-admin instance.
// ============================================================
module.exports.__test = {
  db,
  FieldValue,
  Timestamp,
  setReplyPendingReview,
  setReplyLive,
  setPendingReview,
  setPostLive,
  cleanupLikesForUid,
  cleanupRepliesForUid,
  clearRepostsOfPost,
  claimedTransaction,
  claimTriggerEvent,
  checkRateLimit,
  // Moderation classifiers (pure — no Firestore). #1 crisis/abuse coverage.
  isPostExplicitCrisis,
  isPostConcerning,
  computePostFlagReason,
  computeReplyFlagReason,
  containsURL,
  matchesCrisisPhrase,
  MOD_EXPLICIT_CRISIS,
  MOD_CONCERNING,
};