const { onDocumentDeleted, onDocumentCreated, onDocumentUpdated, onDocumentWritten } = require("firebase-functions/v2/firestore");
const { containsNameOrIdentifyingInfo, aggressiveNormalizeForNameMatch, containsURL } = require("./moderation");
// Pure moderation classifiers + phrase-list constants (no Firestore) live in
// ./moderationLogic — extracted from this file as a functional no-op refactor.
// The Cloud Function triggers below compose these.
const {
  matchesCrisisPhrase,
  isPostExplicitCrisis,
  isPostConcerning,
  computePostFlagReason,
  computeReplyFlagReason,
  MOD_EXPLICIT_CRISIS,
  MOD_CONCERNING,
} = require("./moderationLogic");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onRequest, onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { setGlobalOptions } = require("firebase-functions/v2");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue, Timestamp, AggregateField } = require("firebase-admin/firestore");
const { getAuth } = require("firebase-admin/auth");
const { getAppCheck } = require("firebase-admin/app-check");
const { getMessaging } = require("firebase-admin/messaging");

// IMPROVE (2026-06-11): project-wide function defaults. region pins every
// function to us-central1 (matching the deployed set); maxInstances caps the
// fan-out so a like/reply burst on a viral post can't spawn unbounded counter-
// trigger instances and run up cost. Per-function options still override these
// (e.g. the deletion cascade can raise memory/timeout at its own declaration).
setGlobalOptions({ region: "us-central1", maxInstances: 40 });

initializeApp();
const db = getFirestore();

// Giphy API key — bound at runtime via Firebase Secret Manager so the value
// never lives in source control or function logs. Set with:
//   firebase functions:secrets:set GIPHY_KEY
const GIPHY_KEY = defineSecret("GIPHY_KEY");
// Block-re-signup (2026-07-29): HMAC pepper for the bannedIdentities one-way
// hashes (see bannedIdentities.js). Set per-project via
// `firebase functions:secrets:set BANNED_ID_PEPPER`.
const BANNED_ID_PEPPER = defineSecret("BANNED_ID_PEPPER");
const { beforeUserCreated, HttpsError: IdentityHttpsError } = require("firebase-functions/v2/identity");
const { identityHash, extractIdentities } = require("./bannedIdentities");

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
  let commitFailed = false;
  while (batches < maxBatches) {
    const snapshot = await collectionRef.limit(batchSize).get();
    if (snapshot.empty) break;
    const batch = db.batch();
    snapshot.docs.forEach((doc) => batch.delete(doc.ref));
    try {
      await batch.commit();
    } catch (err) {
      // A failed commit means this page's docs still exist — work REMAINS.
      // Reporting capHit=false here (the pre-2026-08-05 shape) made
      // runWithResume / the sub-cleanup loop treat the pass as complete and
      // queue no continuation, silently stranding everything past this page
      // forever. Surface it as capHit=true so the caller queues a resume;
      // the hourly sweep re-runs until a pass completes clean. No tight
      // retry loop is possible: we break out of this invocation immediately,
      // and the resume queue is rate-bounded (hourly schedule, ≤20 entries
      // per run, bounded pages per pass) — a persistent failure loops
      // loudly in logs instead of deleting the queue entry.
      console.warn("deleteCollection batch failed:", err.message);
      commitFailed = true;
      break;
    }
    batches++;
    totalDeleted += snapshot.size;
    if (snapshot.size < batchSize) break;
  }
  const capHit = commitFailed || batches >= maxBatches;
  if (batches >= maxBatches) {
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
      // Reply docs carry a nested likes subcollection; deleteCollection is
      // non-recursive, so drain each reply's likes first or they persist as
      // orphaned uid-keyed docs invisible to every later sweep (the post and
      // reply docs above them are gone).
      const replySnap = await postDoc.ref.collection("replies").get();
      for (const replyDoc of replySnap.docs) {
        await deleteCollection(replyDoc.ref.collection("likes"));
      }
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
  // A failed batch commit leaves the page's edges in place — work remains.
  // Both loops below break on commit failure, and this flag forces
  // capHit=true so runWithResume queues a continuation instead of treating
  // the pass as complete (which stranded the remaining mirror edges forever;
  // 2026-08-05). Safe against looping: the invocation stops immediately and
  // the resume queue only retries hourly until a pass completes clean.
  let commitFailed = false;

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
      commitFailed = true;
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
      commitFailed = true;
      break;
    }
    batchCount++;
    totalDeleted += snap.size;
    if (snap.size < 100) break;
  }

  return { totalDeleted, capHit: commitFailed || batchCount >= maxIterations };
}

// Generic paginated batch-delete loop shared by the byte-identical cleanup
// helpers (notifications, circle messages, reflections, replies, submitted
// reports). Each of those used to inline the same shape: run a bounded query,
// batch-delete the page, loop until the page comes back short or we hit the
// iteration cap. The ONLY thing that differed between them was the query, so
// the caller passes a `queryFn(pageSize)` that returns the fully-formed
// Firestore Query INCLUDING its own `.limit(pageSize)`. Letting the caller
// build the whole query is deliberate: cleanupRepliesForUid MUST attach an
// `.orderBy("createdAt","desc")` so its collectionGroup query uses the existing
// composite (authorId+createdAt) index instead of throwing FAILED_PRECONDITION
// (see that helper's call site for the full rationale) — a generic "where + limit"
// factory couldn't express that, but a "caller hands back a Query" factory can.
//
// Contract preserved exactly: returns { totalDeleted, capHit } where capHit is
// true iff we exhausted maxIterations (bounded-progress case), so the caller can
// queue a resume continuation. Default page size 500 matches the helpers folded
// in here (a Firestore batch caps at 500 writes, one delete per doc).
async function paginatedBatchDelete(queryFn, maxIterations, pageSize = 500) {
  let batchCount = 0;
  let totalDeleted = 0;
  while (batchCount < maxIterations) {
    const snap = await queryFn(pageSize).get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    batchCount++;
    totalDeleted += snap.size;
    if (snap.size < pageSize) break;
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
      // Reply docs carry a nested likes subcollection; deleteCollection is
      // non-recursive, so drain each reply's likes first or they persist as
      // orphaned uid-keyed docs invisible to every later sweep (the post and
      // reply docs above them are gone).
      const replySnap = await postDoc.ref.collection("replies").get();
      for (const replyDoc of replySnap.docs) {
        await deleteCollection(replyDoc.ref.collection("likes"));
      }
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
  return paginatedBatchDelete((pageSize) => db.collectionGroup("notifications")
    .where("fromUserId", "==", uid)
    .limit(pageSize), maxIterations);
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
  return paginatedBatchDelete((pageSize) => db.collectionGroup("messages")
    .where("authorId", "==", uid)
    .limit(pageSize), maxIterations);
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
  return paginatedBatchDelete((pageSize) => db.collectionGroup("reflections")
    .where("authorId", "==", uid)
    .limit(pageSize), maxIterations);
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
  // #4 (2026-06-11 security re-review): a bare `where(authorId==)` on the
  // replies collection group needs a SINGLE-FIELD collection-group index on
  // authorId, which doesn't exist — only the composite (authorId+createdAt)
  // is defined/deployed. Without the orderBy the query threw FAILED_PRECONDITION
  // and the cascade stranded a deleted user's replies on OTHER users' posts
  // forever (GDPR Art. 17 residue + byline-impersonation gap). Adding the
  // createdAt order makes it use the EXISTING composite index — no new index
  // to build. Every reply carries createdAt (rules pin it), so none are
  // excluded by the order. The orderBy is part of the query this caller hands
  // to paginatedBatchDelete, so it MUST stay here and survive any DRY pass.
  return paginatedBatchDelete((pageSize) => db.collectionGroup("replies")
    .where("authorId", "==", uid)
    .orderBy("createdAt", "desc")
    .limit(pageSize), maxIterations);
}

// S-2 (2026-06-16): a deleted user's OWN blocked subcollection is removed by
// the `subs` loop in onUserDocDeleted. What survives is the REVERSE direction —
// every OTHER user's `users/{blocker}/blocked/{deletedUid}` entry, keyed by the
// deleted user's uid. Nothing else cleans these, so they persisted as uid-keyed
// residue (GDPR Art. 17 gap) in every blocker's tree. The client writes a
// queryable `blockedUid` field (== the doc id) precisely so this collectionGroup
// sweep can find them. Same shape as cleanupRepliesForUid: equality filter +
// orderBy on the always-present blockedAt so it uses the composite
// collection-group index (blockedUid ASC, blockedAt DESC) in firestore.indexes.json.
// NOTE: block docs created before this field shipped lack `blockedUid` and are
// not matched here (legacy residue); a one-time backfill can address those.
async function cleanupBlockedByForUid(uid, maxIterations) {
  return paginatedBatchDelete((pageSize) => db.collectionGroup("blocked")
    .where("blockedUid", "==", uid)
    .orderBy("blockedAt", "desc")
    .limit(pageSize), maxIterations);
}

// Release the deleted user's handle-uniqueness registry row(s)
// (handles/{handleLower}, uid field — see firestore.rules). Queried by uid
// rather than derived from the deleted doc's handle so stray rows from any
// earlier state are swept too. Frees the handle for future signups.
// Rate-limit buckets are keyed rateLimits/{uid}_{endpoint} — a raw uid in the
// doc id (2026-08-06 accuracy audit). Nothing deleted them: not the cascade,
// not a TTL, not a sweep, so they survived "delete everything" indefinitely and
// were disclosed nowhere. The endpoint set is fixed and small, so this is a
// bounded set of point-deletes rather than a query (the collection has no
// uid field to query on). `report_target` is included because a deleted user
// can be the TARGET of that bucket, not just its caller.
async function cleanupRateLimitsForUid(uid) {
  let totalDeleted = 0;
  for (const endpoint of RATE_LIMIT_ALLOWED_ENDPOINTS) {
    try {
      await db.collection("rateLimits").doc(`${uid}_${endpoint}`).delete();
      totalDeleted++;
    } catch (err) {
      console.warn(`cleanupRateLimitsForUid(${uid}/${endpoint}) failed:`, err.message);
      throw err;   // let runWithResume queue a continuation
    }
  }
  return { totalDeleted, capHit: false };
}

async function cleanupHandleRegistryForUid(uid, maxIterations) {
  return paginatedBatchDelete((pageSize) => db.collection("handles")
    .where("uid", "==", uid)
    .limit(pageSize), maxIterations);
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
  return paginatedBatchDelete((pageSize) => db.collection("reports")
    .where("reportedBy", "==", uid)
    .where("status", "==", "pending")
    .limit(pageSize), maxIterations);
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
// NOTE: the original `claimTriggerEvent` (claim-first dedup helper) was
// removed — every live trigger now uses `claimedTransaction` below, which
// closes the partial-failure trap described next. The `processedTriggerEvents`
// collection + TTL documented above are still used by `claimedTransaction`.

// ============================================================
// Atomic claim+write for multi-write counter triggers.
//
// The plain claim-first pattern (claim FIRST, then do writes)
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
// Sharing-consent backfill
// ============================================================
// isShareable is stamped onto each post at CREATE time from the author's
// allowSharing setting, so without this trigger, turning the setting off
// never protected posts already written — revocation must be retroactive
// (and the privacy policy says it is). Mirrors the new value onto the
// user's original posts (letters/whispers stay unshareable) and onto
// reposts of their posts (the repost doc carries its own isShareable copy).
exports.onAllowSharingChanged = onDocumentUpdated("users/{userId}", async (event) => {
  const before = event.data?.before.data()?.allowSharing;
  const after = event.data?.after.data()?.allowSharing;
  if (before === after || typeof after !== "boolean") return;
  const uid = event.params.userId;
  // Toggle-race guard: trigger deliveries are not ordered, so a rapid OFF→ON
  // (two events) can run with the OFF delivery LAST and leave posts shareable
  // after a revocation (or vice versa). Before every commit, re-read the
  // user's CURRENT setting and abort if this delivery is stale — the delivery
  // carrying the current value will (re)apply the right target. Aborting
  // mid-backfill is safe: partially-applied docs are corrected by that run.
  const userRef = db.collection("users").doc(uid);
  const isStale = async () => {
    const cur = (await userRef.get()).data()?.allowSharing;
    return typeof cur === "boolean" && cur !== after;
  };
  const apply = async (snap, compute) => {
    let batch = db.batch(); let n = 0;
    for (const doc of snap.docs) {
      const target = compute(doc.data());
      if (doc.data().isShareable === target) continue;
      batch.update(doc.ref, { isShareable: target });
      if (++n % 400 === 0) {
        if (await isStale()) return -1;
        await batch.commit(); batch = db.batch();
      }
    }
    if (n % 400 !== 0) {
      if (await isStale()) return -1;
      await batch.commit();
    }
    return n;
  };
  const ownSnap = await db.collection("posts")
    .where("authorId", "==", uid).where("isRepost", "==", false).get();
  // isMidnightPost joins the exclusion (2026-08-06): turning sharing back ON
  // must not re-stamp an expiring post as shareable, same reasoning as
  // whispers — a share card outlives the post.
  const own = await apply(ownSnap,
    (d) => after && d.isLetter !== true && d.isWhisper !== true && d.isMidnightPost !== true);
  if (own === -1) {
    console.log(`onAllowSharingChanged(${uid}): stale delivery (setting changed again) — aborted`);
    return;
  }
  // Reposts must honor the ORIGINAL's letter/whisper unshareability, exactly
  // like the own-posts leg: a re-enable must not flip a repost-of-a-letter
  // shareable when the letter itself never is. The repost doc doesn't carry
  // those flags, but every original is in the own-posts snapshot above —
  // collect the unshareable ids there instead of paying a get() per repost.
  const unshareableOriginals = new Set();
  for (const doc of ownSnap.docs) {
    const d = doc.data();
    if (d.isLetter === true || d.isWhisper === true) unshareableOriginals.add(doc.id);
  }
  const repostSnap = await db.collection("posts")
    .where("originalAuthorId", "==", uid).where("isRepost", "==", true).get();
  const reposts = await apply(repostSnap,
    (d) => after && !unshareableOriginals.has(d.originalPostId));
  if (reposts === -1) {
    console.log(`onAllowSharingChanged(${uid}): stale delivery (setting changed again) — aborted`);
    return;
  }
  console.log(`onAllowSharingChanged(${uid}): allowSharing=${after} — updated ${own} posts, ${reposts} reposts`);
});

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
    // cleanupPostsForUid is the first and heaviest cascade step. A transient
    // Firestore error here (an un-wrapped .get()/delete() inside the helper)
    // must NOT abort the whole cascade: every sibling cleanup below runs after
    // this line, and the outer catch only logs (doesn't re-throw), so a bare
    // throw would strand follows/likes/subs/replies/reposts/etc. AND write no
    // resume marker. The user doc is already deleted by the time this trigger
    // runs, so monitorPendingDeletions won't re-run the cascade either —
    // orphaning data + permanently inflating third-party counts. Catch the
    // throw, queue a resume marker (via the capHit path below), and continue.
    let postCleanup;
    try {
      postCleanup = await cleanupPostsForUid(uid, POST_CLEANUP_MAX_ITERATIONS);
    } catch (err) {
      console.error(`cleanupPostsForUid threw for ${uid}, queuing resume:`, err.message);
      postCleanup = { capHit: true, totalDeleted: 0 };
    }
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
    await runWithResume(uid, "blockedBy", cleanupBlockedByForUid, "others' block entries");
    await runWithResume(uid, "handleRegistry", cleanupHandleRegistryForUid, "handle registry rows");
    await runWithResume(uid, "rateLimits", cleanupRateLimitsForUid, "rate-limit buckets");

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

// totalLikes parity on post deletion (2026-07-08 audit). When a post doc is
// deleted BEFORE its likes drain — admin dashboard deleteDoc, or the >500-like
// remainder of a client self-delete — the per-like decrement above bails on
// the missing post (like docs carry no authorId fallback), permanently
// inflating the author's totalLikes on every moderation removal. Settle the
// remainder here from the deleted snapshot's likeCount: any like doc still
// existing at deletion time never got (and never will get) its per-like
// user-leg decrement, because that leg reads the now-missing post first.
// Paths that drain likes BEFORE deleting (client ≤500 self-delete, expiry
// cleanup) arrive here with likeCount already decremented to whatever their
// lagging like-triggers hadn't yet applied — the two mechanisms converge on
// the correct total. Residual known race: a like-trigger that decremented
// the post-leg but lost its user-leg to the deletion window under-counts by
// one; strictly smaller than the leak this closes.
exports.onPostDeletedAdjustTotalLikes = onDocumentDeleted(
  { document: "posts/{postId}", retry: true },
  async (event) => {
    const data = (event.data && event.data.data()) || {};
    const likeCount = typeof data.likeCount === "number" ? data.likeCount : 0;
    const authorId = data.authorId;
    if (likeCount <= 0 || !authorId) return;
    await claimedTransaction(event.id, "totalLikes", async (tx) => {
      const userRef = db.collection("users").doc(authorId);
      const userSnap = await tx.get(userRef);
      if (!userSnap.exists) return; // account-deletion cascade: nothing to fix
      tx.update(userRef, { totalLikes: FieldValue.increment(-likeCount) });
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
    // Mirror the create trigger's gate (onReplyCreatedUpdateCount only +1's a
    // reply with real text AND an authorId). A blank/authorless reply was never
    // counted, so decrementing it on delete drives replyCount permanently
    // negative — a blank reply written then deleted by validateReply nets -1
    // with no matching +1, repeatable and non-self-correcting.
    if (typeof deletedData?.text !== "string" || deletedData.text.trim().length === 0) return;
    if (!deletedData.authorId) return;
    const postRef = db.collection("posts").doc(postId);
    await claimedTransaction(event.id, "replyCount", async (tx) => {
      const snap = await tx.get(postRef);
      if (!snap.exists) return;
      tx.update(postRef, { replyCount: FieldValue.increment(-1) });
    });
  }
);

// N-16 (2026-06-10 re-review): when a reply is deleted, any reply-reposts
// (top-level posts with isRepost:true + originalReplyId == this reply) were
// orphaned with a dangling originalReplyId — no trigger cleaned them (only
// onReplyRepostDeletedUpdateCount adjusts a count). They surface on the
// reposter's profile pointing at content that no longer exists. Delete them
// here; each reply-repost is itself a post, so its own
// onPostDeletedCleanupSubtree drains its subtree.
//
// 2026-08-05: match on (originalReplyId AND originalPostId) — never
// originalReplyId alone. Reply doc ids are only unique PER replies
// subcollection, and firestore.rules lets the writing client choose the reply
// doc id — so an attacker could create posts/{ownPost}/replies/{victimReplyId},
// delete it, and a replyId-only match here would sweep every reply-repost of
// the VICTIM's reply. The postId check runs in code rather than as a second
// `where` (that would demand a new composite index); pagination therefore uses
// a cursor, because non-matching docs survive each pass and a re-run of the
// bare query would re-read the same first page forever.
exports.onReplyDeletedCleanupReposts = onDocumentDeleted(
  "posts/{postId}/replies/{replyId}",
  async (event) => {
    const replyId = event.params.replyId;
    const postId = event.params.postId;
    let cleared = 0;
    let cursor = null;
    for (let i = 0; i < 50; i++) {
      let query = db.collection("posts")
        .where("originalReplyId", "==", replyId)
        .limit(100);
      // startAfter rides the implicit __name__ ordering — no orderBy (and no
      // extra index) needed for an equality filter. Deleted docs sort before
      // the cursor, so advancing past a page is safe whether or not any of
      // its docs were deleted.
      if (cursor) query = query.startAfter(cursor);
      const snap = await query.get();
      if (snap.empty) break;
      cursor = snap.docs[snap.docs.length - 1];
      const matching = snap.docs.filter((d) => d.get("originalPostId") === postId);
      if (matching.length > 0) {
        const batch = db.batch();
        matching.forEach((d) => batch.delete(d.ref));
        try {
          await batch.commit();
        } catch (err) {
          console.warn(`onReplyDeletedCleanupReposts batch failed for reply ${replyId}:`, err.message);
          break;
        }
        cleared += matching.length;
      }
      if (snap.size < 100) break;
    }
    if (cleared > 0) {
      console.log(`onReplyDeletedCleanupReposts: cleared ${cleared} repost(s) of reply ${replyId}`);
    }
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
      // Reply docs carry a nested likes subcollection; deleteCollection is
      // non-recursive, so drain each reply's likes BEFORE deleting the reply
      // docs (same discipline as cleanupPostsForUid / clearPostSubtree /
      // cleanupExpiredPosts). Deleting the replies first strands their likes
      // as orphaned uid-keyed docs no later sweep can reach: the repost
      // delete below does fire onPostDeletedCleanupSubtree, but
      // clearPostSubtree finds nested likes by walking the replies
      // subcollection — already-deleted reply docs hide them forever.
      const replySnap = await repostDoc.ref.collection("replies").get();
      for (const replyDoc of replySnap.docs) {
        await deleteCollection(replyDoc.ref.collection("likes"));
      }
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

// N-2 (2026-06-09 re-review): clears a deleted post's OWN subtree — its
// replies (and each reply's nested likes), its likes, and its reflections.
// Previously NOTHING did this on a single-post delete: onPostDeletedCleanupReposts
// only clears reposts POINTING AT the post, and the post's own subcollections
// were swept solely by the account-deletion cascade (cleanupPostsForUid) and
// cleanupExpiredPosts. So every admin.html removePost/deletePost — and any
// direct delete — orphaned the subtree forever (parent gone → no re-fire).
// That's storage/cost residue AND a GDPR/anonymity problem, because held
// pending_review replies (which may carry real PII — the whole reason for the
// M-1 hold) persisted under a deleted parent. Firestore deletes don't cascade
// to subcollections, so this must be explicit.
//
// Bounded to `maxReplyPages` pages of 100 replies per invocation so a
// mega-thread drains across the resume scheduler instead of timing out.
// Idempotent: deletes only what's still present, safe to re-run. The reply
// and reply-like deletes fire onReplyDeleted*/onReplyLike* counter triggers,
// but those read the (now-deleted) parent post in a transaction and no-op when
// it's missing, so no errant counter writes result. Returns capHit.
async function clearPostSubtree(postId, maxReplyPages = 20) {
  const postRef = db.collection("posts").doc(postId);
  let pages = 0;
  let capHit = false;
  for (; pages < maxReplyPages; pages++) {
    const snap = await postRef.collection("replies").limit(100).get();
    if (snap.empty) break;
    // Clear each reply's nested likes BEFORE deleting the reply doc, so the
    // likes aren't stranded (a delete doesn't cascade to subcollections).
    for (const reply of snap.docs) {
      await deleteCollection(reply.ref.collection("likes"));
    }
    const batch = db.batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    try {
      await batch.commit();
    } catch (err) {
      console.warn(`clearPostSubtree replies batch failed for ${postId}:`, err.message);
      capHit = true;
      break;
    }
    if (snap.size < 100) break;
  }
  if (pages >= maxReplyPages) capHit = true;
  const lk = await deleteCollection(postRef.collection("likes"));
  const rf = await deleteCollection(postRef.collection("reflections"));
  if (lk.capHit || rf.capHit) capHit = true;
  return capHit;
}

// Fires on EVERY post delete (originals AND reposts — both can carry replies/
// likes). On the account-deletion / expired-post paths the subcollections are
// already drained before the post doc is deleted, so this trigger does a few
// empty reads and returns — harmless and idempotent.
exports.onPostDeletedCleanupSubtree = onDocumentDeleted("posts/{postId}", async (event) => {
  const postId = event.params.postId;
  let capHit = false;
  try {
    capHit = await clearPostSubtree(postId, 20);
  } catch (err) {
    console.error(`onPostDeletedCleanupSubtree failed for ${postId}:`, err.message);
    capHit = true; // re-queue so the subtree isn't stranded
  }
  if (capHit) {
    try {
      await db.collection("postSubtreeCleanupQueue").doc(postId).set({
        postId,
        queuedAt: FieldValue.serverTimestamp(),
      });
      console.warn(`onPostDeletedCleanupSubtree: cap hit for ${postId}; queued for resume.`);
    } catch (err) {
      console.error(`postSubtreeCleanupQueue write failed for ${postId}:`, err.message);
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
// Block → tear down the follow graph in BOTH directions.
//
// The client (OtherProfileView.blockUser) can only legally delete follow docs
// under ITS OWN tree; firestore.rules forbids it from deleting the blocked
// user's `following/{me}` doc, so its atomic batch FAILS entirely whenever the
// blocked user follows the blocker (the single most common block trigger) —
// leaving the blocker's posts visible in the blocked user's following feed and
// followerCount inflated. The Admin SDK bypasses rules, so do the teardown here.
// Deleting each `following/{x}` doc fires onFollowDeletedUpdateCounts to fix
// both counts; the `followers` mirror docs have no trigger, so delete them here.
// ============================================================
exports.onBlockCreatedCleanupFollows = onDocumentCreated(
  { document: "users/{uid}/blocked/{blockedId}", retry: true },
  async (event) => {
    const uid = event.params.uid;             // the blocker
    const blockedId = event.params.blockedId; // the blocked user
    if (!uid || !blockedId || uid === blockedId) return;
    const refs = [
      db.collection("users").doc(uid).collection("following").doc(blockedId),        // I follow them
      db.collection("users").doc(blockedId).collection("followers").doc(uid),        //   (mirror)
      db.collection("users").doc(blockedId).collection("following").doc(uid),        // they follow me
      db.collection("users").doc(uid).collection("followers").doc(blockedId),        //   (mirror)
    ];
    // Collect per-delete failures and re-throw at the end so the trigger's
    // retry:true actually redelivers. Previously every failure was swallowed,
    // so a transient error left a follow edge alive — a block bypass (the
    // blocked user keeps following the blocker) and an inflated follower/
    // following count with no self-healing path. All four deletes are
    // idempotent (get()+if-exists), so a retry re-runs cleanly.
    const failures = [];
    await Promise.all(refs.map(async (ref) => {
      try {
        const s = await ref.get();
        if (s.exists) await ref.delete();
      } catch (e) {
        console.warn(`onBlockCreatedCleanupFollows: failed to delete ${ref.path}:`, e.message);
        failures.push(ref.path);
      }
    }));
    if (failures.length > 0) {
      throw new Error(
        `onBlockCreatedCleanupFollows incomplete for ${uid}->${blockedId}; ` +
        `retrying deletes: ${failures.join(", ")}`);
    }
    console.log(`Block follow-graph teardown: ${uid} blocked ${blockedId}`);
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

    // Milestone-race fix (2026-07-20 launch testing): the stored `likeCount` is
    // maintained by a SEPARATE trigger (onLikeCreatedUpdateCounts) on this SAME
    // like-create event, so reading it here almost always returns the PRE-
    // increment value (off by one) — a post hitting exactly 10 likes read as 9,
    // so the milestone notification never fired. Count the likes subcollection
    // directly: at this trigger the just-created like doc already exists, so the
    // count is the true current total (10 at the 10th like). Falls back to the
    // stored value + 1 (accounting for this like's pending increment) if the
    // aggregate read fails. Confirmed live: a live multi-user test showed a post
    // reaching 10 likes produced NO milestone before this change.
    let likeCount;
    try {
      const agg = await postRef.collection("likes").count().get();
      likeCount = Number(agg.data().count);
    } catch (err) {
      console.warn(`onLikeWritten likes count failed for ${postId}, falling back:`, err.message);
      likeCount = (postData.likeCount || 0) + 1;
    }

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

// Mirror of sharedTags (FeedView.swift). Bounds meta/tagCounts to the fixed
// tag set so an unrecognized tag can never become a new key on the shared doc
// (defense-in-depth behind the firestore.rules tag enum-lock).
const ALLOWED_POST_TAGS = new Set([
  "longing",
  "numb",
  "anger",
  "regret",
  "acceptance",
  "confusion",
  "unsent",
  "moving on",
  "still love you",
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
    // Allowlist guard (defense-in-depth, mirrors ALLOWED_BREAKUP_STAGES): the
    // firestore.rules tag enum-lock is the primary boundary. Applied to BOTH
    // the create and delete triggers so counts stay symmetric — an unrecognized
    // tag that somehow exists is neither incremented nor decremented.
    if (!ALLOWED_POST_TAGS.has(tag)) return;
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
    // NOTE: intentionally NO allowlist guard here (unlike the create trigger).
    // Legacy posts created before the tag enum-lock could carry any string tag
    // that WAS incremented at create time; their deletion must still decrement
    // so those stale keys clean up. Post-fix the rules block any non-allowlisted
    // tag at create, so this looser gate can never decrement something that was
    // never incremented (no negative drift).
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
      // Mirror the post-repost F-1 guard: don't promote a repost of a HELD /
      // non-live reply. The rule layer (firestore.rules requires the original
      // reply be moderationStatus=='live') is the primary guard; this keeps the
      // two server validators symmetric so a future rule regression or an
      // Admin-SDK write can't republish a held reply live.
      if ((replyData.moderationStatus || "live") !== "live") {
        console.warn(`Deleting reply-repost ${postId} — original reply ${originalReplyId} not live (${replyData.moderationStatus})`);
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
    // F-1 (2026-06-30): don't promote a repost of a HELD post (defense-in-depth;
    // the rule now blocks this at write time). An author reposting their own
    // report-hidden/held post must not republish it live.
    if ((originalData.moderationStatus || "live") === "pending_review") {
      console.warn(`Deleting repost ${postId} — original ${originalPostId} is held for review`);
      await db.collection("posts").doc(postId).delete();
      return;
    }
    // Ephemeral originals can't be reposted (2026-07-08 audit): the repost doc
    // copies neither the whisper/midnight flags nor expiresAt, so it would be
    // a permanent, unbadged, externally-shareable copy of content the author
    // was promised disappears. Blocked at the rule layer too; this backstops
    // tampered clients and any pre-rule window.
    if (originalData.isWhisper === true || originalData.isMidnightPost === true) {
      console.warn(`Deleting repost ${postId} — original ${originalPostId} is ephemeral (whisper/midnight)`);
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
// Reply-notification preview sync (2026-07-08 audit). The `message` preview
// on a reply notification may only ever contain text of a reply that is
// currently VISIBLE (live, or legacy with no status field). Two writers keep
// that invariant:
//   - setReplyLive → backfill (the reply just became visible)
//   - setReplyPendingReview → scrub (the reply just got hidden — without
//     this, held PII/crisis text stayed in the recipient's notification
//     forever, defeating the M-1 hold)
// enrichReplyNotification also backfills, but only for already-live/legacy
// replies: at notification-create time a fresh reply is still
// pending_validation, so the common path gets its preview from setReplyLive
// AFTER moderation cleared it — which closes the enrich-vs-hold race.
async function syncReplyNotifPreview(postRef, replyAuthorId, mode) {
  if (!replyAuthorId) return;
  try {
    const postSnap = await postRef.get();
    if (!postSnap.exists) return;
    const recipient = postSnap.data().authorId;
    if (!recipient || recipient === replyAuthorId) return; // self-reply: no notif
    const notifSnap = await db.collection("users").doc(recipient)
      .collection("notifications")
      .where("type", "==", "reply")
      .where("fromUserId", "==", replyAuthorId)
      .where("postId", "==", postRef.id)
      .limit(10)
      .get();
    if (notifSnap.empty) return;
    const batch = db.batch();
    let writes = 0;
    if (mode === "scrub") {
      // Over-broad by design: every preview from this actor on this post is
      // dropped, even ones backed by a still-live older reply. The generic
      // "replied to your post" fallback is the safe direction.
      for (const doc of notifSnap.docs) {
        if (doc.data().message !== undefined) {
          batch.update(doc.ref, { message: FieldValue.delete() });
          writes++;
        }
      }
    } else {
      // Backfill from the newest reply by this actor (same semantics as
      // enrichReplyNotification), but only if that reply is visible, and only
      // into notifications that don't already carry a preview.
      const replySnap = await postRef.collection("replies")
        .where("authorId", "==", replyAuthorId)
        .orderBy("createdAt", "desc")
        .limit(1)
        .get();
      if (replySnap.empty) return;
      const reply = replySnap.docs[0].data();
      if (reply.moderationStatus !== undefined && reply.moderationStatus !== "live") return;
      const truncated = (reply.text || "").slice(0, 200).trim();
      if (!truncated) return;
      for (const doc of notifSnap.docs) {
        if (doc.data().message === undefined) {
          batch.update(doc.ref, { message: truncated });
          writes++;
        }
      }
    }
    if (writes > 0) await batch.commit();
  } catch (err) {
    console.warn(`syncReplyNotifPreview(${mode}) failed:`, err.message);
  }
}

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
  await syncReplyNotifPreview(replyRef.parent.parent, data.authorId, "scrub");
  return true;
}

// Promote a clean reply to moderationStatus="live" (M-1). The client writes
// 'pending_validation' at create (T-2, 2026-06-11) — so a clean reply starts
// hidden, exactly like posts, and validateReply promotes it to "live" so the
// iOS thread query (where moderationStatus == "live") can match it. (Legacy
// replies created before T-2 have NO field and default-read as live; this still
// stamps them on first moderation pass.) Transactional + guarded exactly like
// setPostLive: never override a concurrent pending_review hold, idempotent on an
// already-live reply, and promotes from pending_validation OR a missing field.
async function setReplyLive(replyRef) {
  try {
    let promotedAuthorId = null;
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(replyRef);
      if (!snap.exists) return;
      const status = snap.data().moderationStatus;
      if (status === "pending_review" || status === "live") return;
      promotedAuthorId = snap.data().authorId || null;
      tx.update(replyRef, { moderationStatus: "live" });
    });
    // The reply just became visible — now (and only now) its text may appear
    // as the recipient's notification preview. enrichReplyNotification saw the
    // reply at pending_validation and deliberately left the preview generic.
    if (promotedAuthorId) {
      await syncReplyNotifPreview(replyRef.parent.parent, promotedAuthorId, "backfill");
    }
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
      // T-2 (2026-06-11): flip the status FIRST, then jitter — mirroring the
      // validatePost fix (2026-05-31). The previous order (jitter THEN hold) ran
      // the 1.5-3s jitter while the PII reply was still live-readable, widening
      // the exposure window. Combined with replies now starting hidden
      // ('pending_validation' at create), a held PII reply is never third-party-
      // readable. The jitter (timing-oracle defense) now runs after the hold, on
      // the no-op return — same as validatePost.
      await setReplyPendingReview(replyRef, reason);
      await moderationDeleteJitter();
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
    // setPendingReview, not a bare flagged:true: every other flag path pairs
    // the flag with a pending_review hold. A flag-only write leaves
    // moderationStatus "live", so any surface that filters solely on
    // moderationStatus (the future web portal, admin "pending" queries)
    // would still serve the spam — hiding relied entirely on clients also
    // filtering `flagged`. checkRepeatOffenderPosts excludes
    // rate_limit_exceeded from the auto-restrict count, so this adds no
    // double-jeopardy.
    await setPendingReview(db.collection("posts").doc(postId), "rate_limit", {
      flagged: true,
      flaggedAt: FieldValue.serverTimestamp(),
      flagReason: "rate_limit_exceeded",
    });
  }
});

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
    case "minor_safety": return "minor_safety";
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
// Repost copies are full denormalized snapshots of the original's text with
// their OWN moderationStatus, so two kinds of original-doc changes must fan
// out to them or the copies keep serving what the original no longer shows
// (2026-07-08 audit):
//   - moderation transitions between live and pending_review — a report-based
//     or admin hold on the original was otherwise silently ineffective on
//     every copy, and an approve must symmetrically release them;
//   - text edits — an author's self-redaction of missed PII stayed live on
//     every copy forever.
// Text fan-out lets each copy re-moderate itself (its own onPostUpdated pass
// fires on the text change); status cascades apply directly, since the admin
// verdict on the original's text applies verbatim to identical copies.
// Reply-reposts carry the REPLY's text, so post-level fan-out must skip them
// (they match the originalPostId query too); onReplyUpdated fans out to them.
async function fanOutToRepostCopies({ originalPostId, originalReplyId, shouldUpdate, update }) {
  const base = originalReplyId
    ? db.collection("posts").where("originalReplyId", "==", originalReplyId).where("isRepost", "==", true)
    : db.collection("posts").where("originalPostId", "==", originalPostId).where("isRepost", "==", true);
  // M3 (2026-07-22 deep audit): paginate instead of one unbounded get() — a
  // viral original's edit/hold cascade could otherwise OOM/timeout the
  // function and (with retry:true) redeliver forever. Cursor on __name__
  // (equality filters sort by doc id implicitly, so no composite index).
  // Page size stays under the 500-writes batch cap.
  const PAGE = 300;
  let n = 0;
  let cursor = null;
  for (;;) {
    let q = base.orderBy("__name__").limit(PAGE);
    if (cursor) q = q.startAfter(cursor);
    const snap = await q.get();
    if (snap.empty) break;
    const batch = db.batch();
    let inBatch = 0;
    for (const doc of snap.docs) {
      if (!originalReplyId && doc.data().originalReplyId) continue;
      if (!shouldUpdate(doc.data())) continue;
      batch.update(doc.ref, update);
      inBatch++;
    }
    if (inBatch) await batch.commit();
    n += inBatch;
    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < PAGE) break;
  }
  return n;
}

// Shared by onPostUpdated / onReplyUpdated. `id` is the original's doc id;
// pass `kind: "reply"` to target reply-reposts. Idempotent (status-filtered),
// so safe under retry redelivery.
async function cascadeModerationToCopies(kind, id, before, after) {
  const beforeStatus = before.moderationStatus || "live";
  const afterStatus = after.moderationStatus || "live";
  if (beforeStatus === afterStatus) return;
  const target = kind === "reply" ? { originalReplyId: id } : { originalPostId: id };
  if (afterStatus === "pending_review") {
    const n = await fanOutToRepostCopies({
      ...target,
      shouldUpdate: (d) => (d.moderationStatus || "live") === "live",
      update: {
        moderationStatus: "pending_review",
        // Fixed provenance stamp (NOT the original's reason): the release
        // branch below frees ONLY cascade-held copies, so a copy that was
        // independently held (its own reports, a prior flag) keeps its hold
        // and its reason when the original bounces held→live.
        pendingReason: "original_held",
        pendingDetectedAt: FieldValue.serverTimestamp(),
      },
    });
    if (n) console.log(`cascadeModerationToCopies(${kind} ${id}): held ${n} repost copies`);
  } else if (afterStatus === "live" && beforeStatus === "pending_review") {
    const n = await fanOutToRepostCopies({
      ...target,
      // Release only what this cascade held, and never a copy that has since
      // crossed the community-report auto-hide threshold on its own.
      shouldUpdate: (d) => d.moderationStatus === "pending_review"
        && d.pendingReason === "original_held"
        && !(typeof d.autoHiddenReportCount === "number" && d.autoHiddenReportCount >= 3),
      update: {
        moderationStatus: "live",
        pendingReason: FieldValue.delete(),
        pendingDetectedAt: FieldValue.delete(),
      },
    });
    if (n) console.log(`cascadeModerationToCopies(${kind} ${id}): released ${n} repost copies`);
  }
  // pending_validation transitions (every fresh doc's promotion) fall through
  // both branches without running a query — copies can't exist pre-promotion.
}

exports.onPostUpdated = onDocumentUpdated(
  // retry:true (2026-07-01): every write below is idempotent (setPendingReview
  // no-ops when already pending, checkRepeatOffenderPosts recounts + guards
  // the restriction window, the crisis page dedups on its claim doc, the
  // fan-outs are status-filtered/converging), and the before.text ===
  // after.text guard makes redelivery cheap.
  { document: "posts/{postId}", retry: true },
  async (event) => {
  const postId = event.params.postId;
  const before = (event.data && event.data.before && event.data.before.data()) || {};
  const after = (event.data && event.data.after && event.data.after.data()) || {};

  // Original→copy status cascade runs BEFORE the text guard: a moderation
  // transition arrives with text unchanged and must still fan out. Copies
  // themselves never cascade (no repost-of-repost, and their hold/release is
  // driven from the original).
  if (after.isRepost !== true) {
    await cascadeModerationToCopies("post", postId, before, after);
  }

  // Skip when text didn't change. This covers two cases:
  //   - The trigger's own writes (flagged, flaggedAt, flagReason,
  //     concerningContent) keep `text` constant — without this guard the
  //     update we issue below re-fires this handler in an infinite loop.
  //   - Any other unrelated field update (editedAt without text, future
  //     metadata fields, etc.) doesn't need a moderation pass.
  if (before.text === after.text) return;

  // Text-change side effects that must run even when the moderation branches
  // below early-return (crisis path returns, PII path returns, …):
  if (after.isRepost !== true) {
    // An edit invalidates the human curation decision — a webFeatured slot
    // must not silently morph into text no admin reviewed.
    if (after.webFeatured === true) {
      try {
        await db.collection("posts").doc(postId).update({ webFeatured: FieldValue.delete() });
      } catch (err) {
        if (err.code !== 5) throw err; // NOT_FOUND: deleted concurrently
      }
    }
    const n = await fanOutToRepostCopies({
      originalPostId: postId,
      shouldUpdate: () => true,
      update: { text: after.text },
    });
    if (n) console.log(`onPostUpdated(${postId}): propagated edit to ${n} repost copies`);
  }

  // Repost copies do NOT re-moderate themselves (2026-07-08 re-review): their
  // text is owned by the original, whose own moderation pass plus the status
  // cascade above hold/release every copy with correct provenance. Running the
  // pipeline below on copies attributed flags to the REPOSTER — feeding
  // checkRepeatOffenderPosts strikes for words they didn't write (an edit-in-
  // violation by the original author could auto-restrict innocent reposters)
  // — and paged admins once per copy (crisisAlert_<copyId> claims are
  // per-doc, so one crisis edit with N reposts paged N+1 times).
  if (after.isRepost === true) return;

  const flagReason = computePostFlagReason(after.text);
  const concerning = isPostConcerning(after.text);
  const identifying = containsNameOrIdentifyingInfo(after.text);

  // 2026-06-01 audit (most-severe-first): mirror onPostCreated. Crisis is
  // evaluated BEFORE the PII early-return and the abuse flag so an edit that
  // introduces crisis text alongside PII/abuse still sets concerningContent
  // and reaches the crisis tab instead of being masked as a "pii" takedown.
  if (concerning) {
    // A crisisReviewedAt stamp covers the OLD text: the admin reviewed what
    // the post said then, not the crisis text this edit just introduced.
    // Without clearing it, the admin crisis queue (which filters
    // !crisisReviewedAt) never resurfaces the post — a fresh disclosure edited
    // into an already-reviewed post was shown NOWHERE.
    const needsReReview = Boolean(after.crisisReviewedAt);
    // Skip the rewrite only when nothing material would change — already on
    // the crisis tab, not yet reviewed, AND the flag state is already correct.
    // flaggedAt stays pinned to the original detection time in that case.
    const flagAlreadyCorrect = flagReason
      ? after.flagged === true && after.flagReason === flagReason
      : true;
    if (after.concerningContent === true && flagAlreadyCorrect && !needsReReview) return;
    const extra = {
      concerningContent: true,
      flaggedAt: FieldValue.serverTimestamp(),
    };
    if (needsReReview) extra.crisisReviewedAt = FieldValue.delete();
    if (flagReason) {
      extra.flagged = true;
      extra.flagReason = flagReason;
    }
    await setPendingReview(db.collection("posts").doc(postId), "crisis", extra);
    console.log(
      `Post ${postId} concerning + pending_review after edit` +
        (flagReason ? ` (also ${flagReason})` : "")
    );
    // Page on explicit crisis introduced by edit — create-only paging left
    // the edit path silent. The per-post claim (`crisisAlert_<id>`) dedups
    // against the create-time page, so a post that already paged won't
    // re-page on later edits.
    if (isPostExplicitCrisis(after.text)) {
      await pageAdminsForCrisis({
        claimRef: db.collection("processedTriggerEvents").doc(`crisisAlert_${postId}`),
        title: "crisis post",
        body: "a post needs review in the crisis queue",
        dataPayload: { type: "admin_crisis_alert", postId },
        logLabel: `crisis-alert-edit(${postId})`,
      });
    }
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

// Idempotency (2026-06-01 audit; P-1 fix 2026-06-16): Eventarc is
// at-least-once, so a redelivery of this create event could page admins
// twice. The dedup unit is the POST id (`crisisAlert_<id>`), not `event.id`:
// four other triggers share this `posts/{postId}` create path and
// onPostCreatedUpdateTagCounts already claims `event.id`, so reusing it here
// could let the tag-count claim starve the crisis page. One post = one page.
//
// P-1: PAGE-then-CLAIM (see pageAdminsForCrisis). A failed page throws and
// `retry: true` makes Eventarc redeliver — without that flag v2 Firestore
// triggers default to no retry and a single transient FCM failure would drop
// the crisis page forever. A dropped crisis page is far worse than a rare
// duplicate, so this errs toward delivering.
//
// L-1 (2026-06-08 audit): do NOT put raw post text (or the author handle)
// in the push — it lands on the admin's lock screen / notification mirror,
// exactly the leak the user-facing pushes were hardened against. Send a
// neutral body; the admin taps through to the crisis tab in admin.html
// (gated by App Check + the admins/{uid} check) to read the content. Only
// the non-identifying postId rides in the data payload for deep-linking.
//
// The FALLBACK_ADMIN_UIDS literal inside pageAdminsForCrisis alerts the owner
// even before `system/crisisAlertRecipients` is seeded (A-1 2026-06-09: the
// uid is the real prod admin, salinarotess@gmail.com — an earlier literal was
// a TEST account and pages were dropped). Seed the doc so the literal is moot.
exports.onPostCreatedAlertAdmins = onDocumentCreated(
  { document: "posts/{postId}", retry: true },
  async (event) => {
    const data = event.data?.data();
    if (!data || data.isRepost === true || typeof data.text !== "string") return;
    if (!isPostExplicitCrisis(data.text)) return;
    const postId = event.params.postId;
    await pageAdminsForCrisis({
      claimRef: db.collection("processedTriggerEvents").doc(`crisisAlert_${postId}`),
      title: "crisis post",
      body: "a post needs review in the crisis queue",
      dataPayload: { type: "admin_crisis_alert", postId },
      logLabel: `crisis-alert(${postId})`,
    });
  }
);

// Shared admin crisis-paging (PAGE-then-CLAIM, neutral push body, no content on
// the lock screen). Used by both crisis alerts below. `claimRef` dedups per
// artifact id; `dataPayload` deep-links the admin into the right surface.
//
// THROWS on any failure to page (config/token read error, send error, zero
// successful deliveries). Callers MUST be declared `{ retry: true }` — the
// PAGE-then-CLAIM design only delivers its "a failed send is retried until it
// lands" guarantee if the trigger fails and Eventarc redelivers; a swallowed
// error here completes the function "successfully" and drops the page forever.
// Exponential backoff bounds the retry cost; the claim doc bounds duplicates.
// Only the claim read (fail open → worst case a duplicate page) and the claim
// write (fail open → duplicate on next redelivery) are non-fatal.
async function pageAdminsForCrisis({ claimRef, title, body, dataPayload, logLabel }) {
  try {
    if ((await claimRef.get()).exists) return; // already paged
  } catch (err) {
    console.warn(`${logLabel}: claim read failed, proceeding:`, err.message);
  }
  const FALLBACK_ADMIN_UIDS = ["alcxPIqLQZcTIwF5wjJMkK1yPlW2"];
  const cfgSnap = await db.collection("system").doc("crisisAlertRecipients").get();
  // `uids` is hand-seeded (see A-1 note above) — if someone writes it as a
  // map/string instead of an array, `.filter` throws, the trigger fails, and
  // Eventarc redelivery turns EVERY explicit-crisis post into a retry storm
  // that pages nobody. Treat a malformed field as unconfigured: fall through
  // to FALLBACK_ADMIN_UIDS (and the email-backup tag below still fires), and
  // log loudly so the operator fixes the doc.
  const rawUids = cfgSnap.data()?.uids;
  if (rawUids !== undefined && !Array.isArray(rawUids)) {
    console.error(`${logLabel}: system/crisisAlertRecipients.uids is not an array (got ${typeof rawUids}); using fallback admin uids — fix the doc`);
  }
  const configured = (Array.isArray(rawUids) ? rawUids : []).filter((u) => typeof u === "string");
  const adminUids = configured.length > 0 ? configured : FALLBACK_ADMIN_UIDS;
  if (adminUids.length === 0) {
    console.log(`${logLabel}: tripped explicit-crisis but no admin uids configured`);
    return;
  }
  // Email backup channel (independent of FCM): a structured tag the
  // "Toska — crisis post (email backup)" Cloud Monitoring policy alerts on, so
  // a crisis page reaches the admin by email even if every FCM push fails or
  // the admin's phone is off. Emitted after the dedup gate, before the send,
  // so a total FCM failure still triggers the email. Neutral — only the label
  // (postId), no post content (L-1: content stays off notification surfaces);
  // the admin taps into the crisis queue in admin.html to read it.
  console.log(JSON.stringify({ tag: "crisis_needs_review", label: logLabel }));
  const tokens = [];
  for (const uid of adminUids) {
    // Same legacy fallback as sendPushNotification: tokens moved to the
    // owner-only private subcollection, but pre-migration users still carry
    // fcmToken on the main doc. Without the fallback those admins are
    // silently unpageable while their normal pushes keep working.
    const privSnap = await db.collection("users").doc(uid).collection("private").doc("data").get();
    let token = privSnap.data()?.fcmToken;
    if (!token) {
      const userSnap = await db.collection("users").doc(uid).get();
      token = userSnap.data()?.fcmToken;
    }
    if (typeof token === "string" && token.length > 0) tokens.push(token);
  }
  if (tokens.length === 0) {
    // A crisis page with no deliverable token is exactly the dropped-page
    // scenario: fail so redelivery retries — the admin's device may refresh
    // its token between attempts. The admin.html crisis queue is the durable
    // backstop either way.
    throw new Error(`${logLabel}: no FCM tokens for ${adminUids.length} admins`);
  }
  const resp = await getMessaging().sendEachForMulticast({
    notification: { title, body }, data: dataPayload, tokens,
  });
  console.log(`${logLabel}: sent to ${resp.successCount}/${tokens.length} admin devices`);
  // Log the per-token failure reason. This is a safety-critical path — when a
  // crisis page can't be delivered, the SPECIFIC FCM error (APNs credential vs
  // unregistered token vs sender mismatch) is what an operator needs to fix it.
  resp.responses.forEach((r, i) => {
    if (!r.success) {
      console.warn(`${logLabel}: token[${i}] send failed: ${r.error?.code} — ${(r.error?.message || "").slice(0, 160)}`);
    }
  });
  if (resp.successCount === 0) {
    throw new Error(`${logLabel}: all ${tokens.length} sends failed`);
  }
  const expiresAt = Timestamp.fromDate(new Date(Date.now() + 7 * 24 * 60 * 60 * 1000));
  await claimRef.set({ processedAt: FieldValue.serverTimestamp(), expiresAt })
    .catch((err) => console.warn(`${logLabel}: claim write failed:`, err.message));
}

// Crisis disclosures posted as REPLIES previously got no admin page at all
// (onPostCreatedAlertAdmins is posts-only). Page admins on an explicit-crisis
// reply, deep-linking to the parent post so it can be reviewed. Dedup keyed on
// the reply id.
exports.onReplyCreatedAlertAdmins = onDocumentCreated(
  { document: "posts/{postId}/replies/{replyId}", retry: true },
  async (event) => {
    const data = event.data?.data();
    if (!data || typeof data.text !== "string") return;
    if (!isPostExplicitCrisis(data.text)) return;
    await pageAdminsForCrisis({
      claimRef: db.collection("processedTriggerEvents").doc(`crisisAlertReply_${event.params.replyId}`),
      title: "crisis reply",
      body: "a reply needs review in the crisis queue",
      dataPayload: { type: "admin_crisis_alert", postId: event.params.postId, replyId: event.params.replyId },
      logLabel: `crisis-alert-reply(${event.params.replyId})`,
    });
  }
);

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

async function applyReplyModeration(postId, replyId, flagReason) {
  if (!flagReason) return;
  const replyRef = db.collection("posts").doc(postId).collection("replies").doc(replyId);
  if (flagReason === "minor_safety") {
    // 2026-07-27 minor-safety: HOLD (never hard-delete) so an admin reviews the
    // underage disclosure and acts on the account per ToS. Distinct pendingReason
    // so the admin queue surfaces it as urgent.
    await setReplyPendingReview(replyRef, "minor_safety");
    console.log(`Reply ${replyId} on post ${postId} HELD — minor-safety review`);
  } else if (flagReason === "personal_information" || flagReason === "contains_link") {
    // M-1: high-false-positive categories (names/links) get a recoverable
    // HOLD (hidden pending admin review) rather than the old visible-but-
    // flagged state — consistent with validateReply and posts. pendingReason
    // mirrors the admin.html label keys ("pii" / "abuse_link").
    await setReplyPendingReview(replyRef, flagReason === "contains_link" ? "abuse_link" : "pii");
    console.log(`Reply ${replyId} on post ${postId} held for review: ${flagReason}`);
  } else if (flagReason === "harassment" || flagReason === "targeted_threat") {
    // HOLD (recoverable) instead of hard-delete. MOD_HARASSMENT/MOD_THREAT
    // lists substring-match supportive NEGATED reach-outs — "please don't kill
    // yourself, call 988, you matter" contains "kill yourself" — which are the
    // exact replies a breakup peer-support thread exists to protect. Hard-
    // deleting them destroys the support with no recovery. Holding hides a
    // genuine attack from its target just the same, but is reviewable and
    // releasable by an admin instead of silently gone. NOTE: the reason string
    // is "targeted_threat" (from computeReplyFlagReason), NOT "threat" — the
    // earlier guard used "threat" and silently fell through to hard-delete.
    // Use flagReasonToPendingReason so admin.html shows the real category
    // ("abuse_harassment" / "abuse_threat") instead of a generic label.
    await setReplyPendingReview(replyRef, flagReasonToPendingReason(flagReason));
    console.log(`Reply ${replyId} on post ${postId} held for review: ${flagReason}`);
  } else {
    // hate / sexual: low false-positive, genuinely removable — keep the hard
    // delete. Counter decrement is handled by onReplyDeletedUpdateCount on the
    // subsequent delete trigger.
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
    // Crisis/concerning text in a reply: queue it for human review but do NOT
    // hide it — in a peer-support thread a reach-out shouldn't be censored,
    // and onReplyCreatedAlertAdmins pages a human on explicit crisis. The
    // author sees crisis resources client-side at send time. This runs
    // independently of the abuse/PII flag below.
    if (isPostConcerning(data.text)) {
      // 2026-07-17 privacy audit (C-1, reply surface): crisis replies stay
      // LIVE by design (a peer reach-out shouldn't vanish from its thread),
      // so the crisis marker must NOT be written onto the reply doc — a live
      // reply is readable by every authenticated client, and a machine-
      // assigned health-adjacent flag on a pseudonymous author's words is
      // exactly the metadata this app promises not to leak. The durable
      // review queue now lives in the admin-only crisisReplyQueue collection
      // (rules: read/update isAdmin, create server-only). Deterministic doc
      // id + set(merge) keeps this idempotent under retry redelivery; a
      // retried event re-setting reviewed:false is harmless (the human
      // review window dwarfs the retry window). Unlike the old on-doc
      // update, this can't NOT_FOUND — a concurrently-deleted reply just
      // leaves an orphan queue entry the admin loader skips (and can prune).
      await db.collection("crisisReplyQueue")
        .doc(`${event.params.postId}_${event.params.replyId}`)
        .set({
          postId: event.params.postId,
          replyId: event.params.replyId,
          reviewed: false,
          detectedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
    }
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

    // Original→copy fan-out for reply-reposts, mirroring onPostUpdated:
    // status transitions cascade even when text is unchanged; text edits
    // propagate so each copy re-moderates itself. Every clean reply's
    // pending_validation→live promotion falls through without a query.
    await cascadeModerationToCopies("reply", event.params.replyId, before, after);

    if (before.text === after.text) return;

    const editFanOut = await fanOutToRepostCopies({
      originalReplyId: event.params.replyId,
      shouldUpdate: () => true,
      update: { text: after.text },
    });
    if (editFanOut) console.log(`onReplyUpdated(${event.params.replyId}): propagated edit to ${editFanOut} repost copies`);

    const replyRef = db.collection("posts").doc(event.params.postId)
      .collection("replies").doc(event.params.replyId);

    // Crisis text introduced by edit — same policy as create: queue for
    // review (crisisReplyQueue, never on the world-readable reply doc — C-1
    // 2026-07-17), don't hide, page on explicit.
    if (isPostConcerning(after.text)) {
      // Same crisisReplyQueue routing as the create path (C-1) — and the
      // reviewed:false merge IS the resurfacing semantics the old
      // crisisReviewedAt-delete provided: an already-reviewed reply edited
      // into fresh crisis language re-enters the unreviewed queue.
      await db.collection("crisisReplyQueue")
        .doc(`${event.params.postId}_${event.params.replyId}`)
        .set({
          postId: event.params.postId,
          replyId: event.params.replyId,
          reviewed: false,
          detectedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
      if (isPostExplicitCrisis(after.text)) {
        // Same per-reply claim as onReplyCreatedAlertAdmins: a reply that
        // already paged at create won't re-page on edit.
        await pageAdminsForCrisis({
          claimRef: db.collection("processedTriggerEvents").doc(`crisisAlertReply_${event.params.replyId}`),
          title: "crisis reply",
          body: "a reply needs review in the crisis queue",
          dataPayload: { type: "admin_crisis_alert", postId: event.params.postId, replyId: event.params.replyId },
          logLabel: `crisis-alert-reply-edit(${event.params.replyId})`,
        });
      }
    }

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

// ============================================================
// abuseSpikeWatch — hourly anomaly detector for moderation spikes
//
// The per-artifact triggers (onPostCreated moderation, crisis paging) see one
// item at a time; they can't see PATTERNS. This catches the two that matter:
//   - one author flooding held content (spammer / targeted-harassment burst)
//   - a global surge of auto-held posts (coordinated campaign / brigading)
// Emits structured INFO logs (console.log, NOT console.error — so it does not
// trip the broad function-error alert); the "Toska — abuse spike" Cloud
// Monitoring policy matches the tag and emails the admin. Same log→alert
// pattern as checkReportSLA. Thresholds are conservative — tune from real
// volume. Equality-only query (auto single-field index) + in-code time
// window, so no composite index is required.
// ============================================================
exports.abuseSpikeWatch = onSchedule("every 60 minutes", async () => {
  const AUTHOR_THRESHOLD = 5;   // held posts from ONE author in the window
  const GLOBAL_THRESHOLD = 20;  // held posts total in the window
  const cutoffMs = Date.now() - 60 * 60 * 1000;

  let snap;
  try {
    snap = await db.collection("posts")
      .where("moderationStatus", "==", "pending_review")
      .limit(500)
      .get();
  } catch (err) {
    console.warn("abuseSpikeWatch query failed:", err.message);
    return;
  }

  const byAuthor = new Map();
  let recentTotal = 0;
  snap.forEach((doc) => {
    const d = doc.data();
    const heldAtMs = d.pendingDetectedAt?.toMillis?.() ?? d.createdAt?.toMillis?.() ?? 0;
    if (heldAtMs < cutoffMs) return; // only the last hour
    recentTotal++;
    const a = d.authorId || "unknown";
    byAuthor.set(a, (byAuthor.get(a) || 0) + 1);
  });

  if (recentTotal === 0) return;

  for (const [authorId, count] of byAuthor) {
    if (count >= AUTHOR_THRESHOLD) {
      console.log(JSON.stringify({
        tag: "abuse_spike_author",
        authorId,
        heldInLastHour: count,
        threshold: AUTHOR_THRESHOLD,
      }));
    }
  }

  if (recentTotal >= GLOBAL_THRESHOLD) {
    console.log(JSON.stringify({
      tag: "abuse_spike_global",
      heldInLastHour: recentTotal,
      distinctAuthors: byAuthor.size,
      threshold: GLOBAL_THRESHOLD,
    }));
  }
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

// Prune inbox notifications older than 90 days. The privacy policy
// (legal/PRIVACY_POLICY.md §6, docs/privacy.html) states "Notifications in
// your inbox — pruned after 90 days"; nothing else enforces that window (the
// per-sender spam limiter only trims a burst, the deletion cascade only clears
// a departed sender's notifications), so a reply notification's server-enriched
// `message` text preview would otherwise persist in the recipient's inbox
// forever. This keeps the written retention promise.
//
// The collectionGroup inequality on `createdAt` needs an EXPLICIT
// collection-group single-field index — the automatic single-field indexes are
// collection-scope only and do NOT cover collectionGroup() queries. That index
// is declared in firestore.indexes.json (fieldOverrides → notifications /
// createdAt, COLLECTION_GROUP ASCENDING; the COLLECTION ASC+DESC entries there
// preserve the per-user NotificationsView createdAt-DESC ordering the override
// would otherwise disable). Without it this query throws FAILED_PRECONDITION,
// which the catch below swallows — pruning silently no-ops and the 90-day
// retention promise goes unmet. Notifications have no onDelete trigger, so
// deletes carry no counter/side effects. Bounded at 20 pages × 500 = 10k/run;
// the next daily run drains any remainder, matching cleanupProcessedTriggerEvents.
async function pruneNotificationsOlderThan(cutoff, maxPages = 20) {
  let totalDeleted = 0;
  for (let page = 0; page < maxPages; page++) {
    let snap;
    try {
      snap = await db.collectionGroup("notifications")
        .where("createdAt", "<", cutoff)
        .limit(500)
        .get();
    } catch (err) {
      console.warn("pruneOldNotifications query failed:", err.message);
      return { totalDeleted, capHit: false };
    }
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    try {
      await batch.commit();
    } catch (err) {
      console.warn("pruneOldNotifications batch failed:", err.message);
      break;
    }
    totalDeleted += snap.size;
    if (snap.size < 500) break;
  }
  return { totalDeleted, capHit: totalDeleted >= maxPages * 500 };
}

exports.pruneOldNotifications = onSchedule("every 24 hours", async () => {
  const cutoff = Timestamp.fromDate(new Date(Date.now() - 90 * 24 * 60 * 60 * 1000));
  const { totalDeleted } = await pruneNotificationsOlderThan(cutoff);
  if (totalDeleted > 0) {
    console.log(`pruneOldNotifications: deleted ${totalDeleted} notifications older than 90 days`);
  }
});

// Every 10 minutes, not hourly (2026-08-05). The rules layer cannot gate reads
// on expiresAt — rules are not filters, so a single expired doc in a feed query
// would deny the WHOLE query — which means the promise "this disappears
// tonight" is enforced only by this sweep plus Firestore TTL, and TTL collects
// on its own schedule (documented as typically within 24h of the timestamp).
// Until the expired doc is actually deleted, a tampered client that drops the
// client-side expiry filter can still read it. Hourly left a window of up to an
// hour on a product whose wedge is ephemerality; this shortens it to minutes.
// Cheap: the steady-state run is one indexed query that returns empty.
exports.cleanupExpiredPosts = onSchedule("every 10 minutes", async () => {
  const now = Timestamp.now();
  console.log("Running expired post cleanup at:", now.toDate());

  try {
    // Loop until the expired set is drained (2026-07-08 audit): a single
    // limit(100) pass let a backlog build without bound whenever the expiry
    // rate beat 100/hour or a prior run errored — and expired-but-undeleted
    // whispers stay readable to tampered clients (the read rule can't check
    // expiresAt without breaking every list query). Bounded at 50 pages as a
    // runaway backstop; the next hourly run picks up any remainder.
    let totalDeleted = 0;
    for (let page = 0; page < 50; page++) {
      const expiredSnap = await db.collection("posts")
        .where("expiresAt", "<=", now)
        .limit(100)
        .get();
      if (expiredSnap.empty) break;

      for (const doc of expiredSnap.docs) {
        // Drain each reply's nested likes first — deleteCollection is
        // non-recursive, and once the reply docs are gone these are
        // permanently orphaned (the post-delete backstop queries an
        // already-empty replies collection).
        //
        // Paged, not a bare .get() (2026-08-05): an unbounded read of a
        // mega-thread's replies can exhaust memory or blow the timeout, and
        // because the outer query re-reads the SAME first page every run, one
        // such post wedges the entire expiry pipeline behind it — expired
        // whispers platform-wide then stay readable indefinitely. Deleting
        // each reply as we go means a page is never re-read. Mirrors
        // clearPostSubtree's paging.
        for (let replyPage = 0; replyPage < 50; replyPage++) {
          const replySnap = await doc.ref.collection("replies").limit(100).get();
          if (replySnap.empty) break;
          for (const replyDoc of replySnap.docs) {
            await deleteCollection(replyDoc.ref.collection("likes"));
            await replyDoc.ref.delete();
          }
        }
        await deleteCollection(doc.ref.collection("replies"));
        // Likes drain BEFORE the post doc delete so each per-like trigger
        // still sees the post and decrements likeCount + author totalLikes.
        await deleteCollection(doc.ref.collection("likes"));
        await deleteCollection(doc.ref.collection("reflections"));
        await doc.ref.delete();
      }
      totalDeleted += expiredSnap.size;
      if (expiredSnap.size < 100) break;
    }

    console.log(totalDeleted === 0 ? "No expired posts found." : `Deleted ${totalDeleted} expired posts.`);
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

      // M-1 (2026-06-08 audit, tightened 2026-07-08): only a VISIBLE reply's
      // text may become the recipient's preview. The original guard skipped
      // only "pending_review", but a fresh reply is still "pending_validation"
      // here (this trigger races — and usually beats — validateReply), so a
      // reply that moderation was about to hold had its PII/crisis text
      // backfilled anyway, permanently. Now: pending_validation replies get
      // their preview from setReplyLive AFTER moderation clears them;
      // setReplyPendingReview scrubs on any later hold. Legacy replies with
      // no status field default-read as live and enrich here as before.
      const replyStatus = replySnap.docs[0].data().moderationStatus;
      if (replyStatus !== undefined && replyStatus !== "live") {
        console.log(`enrichReplyNotification: backing reply is ${replyStatus}; deferring preview:`, notifRef.path);
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

// Generic queue-drainer shared by resumePostDeletion and resumeRepostCleanup —
// the two schedulers that walk a doc-id-keyed cleanup queue and run a worker
// returning { capHit, totalDeleted }. Both had the identical drain shape:
//   - read up to `limit` queue docs,
//   - per doc, call `worker(docId, cap)`,
//   - on capHit (bounded-progress): bump lastResumedAt + cumulativeDeleted and
//     LEAVE the entry in the queue for the next sweep,
//   - else: log completion and delete the marker,
//   - on throw: log and leave in queue so the next invocation retries.
//
// The only things that varied were the queue collection, the worker + its
// per-pass cap, the log strings, and whether an empty queue / per-doc start
// got logged — all of which are now config. Behavior is preserved exactly,
// including the hourly cadence drain-until-empty semantics and the capHit
// re-queue contract that prevents stranding GDPR Art. 17 residue.
//
// resumePostSubtreeCleanup and resumeUserCleanup are deliberately NOT routed
// through this: the subtree drainer's worker returns a bare boolean capHit
// (no totalDeleted, and its update writes only lastResumedAt), and the user
// drainer reads {uid,type} from doc data, dispatches through a table, and has
// a separate sub_* continuation branch — materially different shapes.
async function drainQueue({
  collectionName,
  limit,
  worker,
  workerCap,
  schedulerName,
  emptyLog,
  startLog,
  partialLog,
  completedLog,
}) {
  const queueSnap = await db.collection(collectionName).limit(limit).get();
  if (queueSnap.empty) {
    if (emptyLog) console.log(emptyLog);
    return;
  }

  for (const queueDoc of queueSnap.docs) {
    const id = queueDoc.id;
    if (startLog) console.log(startLog(id));
    try {
      const result = await worker(id, workerCap);
      if (result.capHit) {
        // Still more remains. Update marker with incremental progress and
        // leave the entry in the queue for the next sweep.
        await queueDoc.ref.update({
          lastResumedAt: FieldValue.serverTimestamp(),
          cumulativeDeleted: FieldValue.increment(result.totalDeleted),
        });
        console.log(partialLog(id, result.totalDeleted));
      } else {
        console.log(completedLog(id, result.totalDeleted));
        await queueDoc.ref.delete();
      }
    } catch (err) {
      console.error(`${schedulerName} failed for ${id}:`, err.message);
      // Leave in queue; next invocation will retry.
    }
  }
}

exports.resumePostDeletion = onSchedule("every 60 minutes", async () => {
  await drainQueue({
    collectionName: "postDeletionQueue",
    limit: 10,
    worker: cleanupPostsForUid,
    workerCap: 500,
    schedulerName: "resumePostDeletion",
    emptyLog: "postDeletionQueue is empty.",
    startLog: (uid) => `Resuming post deletion for user ${uid}`,
    partialLog: (uid, n) => `Partial cleanup for ${uid}: +${n} posts, staying in queue.`,
    completedLog: (uid, n) => `Completed post deletion for ${uid}: +${n} posts this pass.`,
  });
});

// F-6 (2026-06-08 audit): drains repostCleanupQueue markers written by
// onPostDeletedCleanupReposts when a viral post had more reposts than one
// trigger invocation could clear. Each pass clears up to 5000 more and only
// removes the marker once the originalPostId has no remaining reposts.
exports.resumeRepostCleanup = onSchedule("every 60 minutes", async () => {
  await drainQueue({
    collectionName: "repostCleanupQueue",
    limit: 10,
    worker: clearRepostsOfPost,
    workerCap: 50,
    schedulerName: "resumeRepostCleanup",
    emptyLog: null,
    startLog: null,
    partialLog: (postId, n) => `Partial repost cleanup for ${postId}: +${n}, staying in queue.`,
    completedLog: (postId, n) => `Completed repost cleanup for ${postId}: +${n} this pass.`,
  });
});

// N-2 (2026-06-09 re-review): drains postSubtreeCleanupQueue markers written by
// onPostDeletedCleanupSubtree when a mega-thread had more replies than one
// trigger invocation could clear. Each pass clears up to 50 more reply pages
// and only removes the marker once the post's subtree is fully empty.
exports.resumePostSubtreeCleanup = onSchedule("every 60 minutes", async () => {
  const queueSnap = await db.collection("postSubtreeCleanupQueue").limit(10).get();
  if (queueSnap.empty) return;

  for (const queueDoc of queueSnap.docs) {
    const postId = queueDoc.id;
    try {
      const capHit = await clearPostSubtree(postId, 50);
      if (capHit) {
        await queueDoc.ref.update({ lastResumedAt: FieldValue.serverTimestamp() });
        console.log(`Partial post-subtree cleanup for ${postId}: staying in queue.`);
      } else {
        console.log(`Completed post-subtree cleanup for ${postId}.`);
        await queueDoc.ref.delete();
      }
    } catch (err) {
      console.error(`resumePostSubtreeCleanup failed for ${postId}:`, err.message);
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
// keyed by `${uid}_${type}`; the dispatch table below MUST cover every
// type string passed to runWithResume in the cascade — an unknown type
// takes the "drop queue entry" path, which permanently deletes the
// continuation and strands the remaining data (that's how handleRegistry
// rows survived deletion until 2026-08-05). We process up to 20 entries
// per run and drop the entry when the corresponding helper reports
// capHit=false (i.e., the collection is empty for that uid).
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
    blockedBy: cleanupBlockedByForUid,
    // Queued at the end of the onUserDocDeleted cascade but MISSING here
    // until 2026-08-05: the unknown-type path below dropped the queue entry,
    // so a capHit/error on handle-registry cleanup left handles/{handleLower}
    // pointing at a deleted uid forever — and the handle could never be
    // re-registered.
    handleRegistry: cleanupHandleRegistryForUid,
    rateLimits: cleanupRateLimitsForUid,
  };

  // sub_* types resume the owner-only subcollection cleanup that the main
  // cascade does inline (saved, liked, notifications, blocked, presence,
  // private, drafts). Each suffix maps to a fixed collection path; we use
  // a separate dispatcher rather than passing arbitrary paths through the
  // queue doc to keep a closed allow-list of subcollections.
  const ALLOWED_SUB_RESUME = new Set([
    // Must mirror the `subs` list in cleanupPostsForUid (T-3, 2026-06-11):
    // savedReplies was queued as `sub_savedReplies` on cap-hit but was missing
    // here, so resumeUserCleanup dropped the queue entry and stranded any
    // savedReplies past the deleteCollection cap (GDPR Art. 17 residue).
    "saved", "savedReplies", "liked", "notifications", "blocked", "presence", "private", "drafts",
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

    // Mirror onPendingDeletionCreated: only cascade once the AUTH user is
    // confirmed GONE. auth.delete() commonly fails with requiresRecentLogin; if
    // the user then can't write the `cancelled` marker within 10 min (app killed,
    // offline), this backstop would otherwise erase a legit, still-usable
    // account's data while their auth account lives on. Leave it queued instead.
    let authUserGone = false;
    try {
      await getAuth().getUser(uid);
    } catch (e) {
      if (e.code === "auth/user-not-found") {
        authUserGone = true;
      } else {
        console.warn("Retry: auth lookup failed (transient); leaving queued for:", uid, e.message);
        continue;
      }
    }
    if (!authUserGone) {
      console.log("Retry: auth user still exists; leaving pending deletion queued for:", uid);
      continue;
    }

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
// Counter drift detector (detect + guarded auto-correct)
// ============================================================
// like/reply/repost/totalLikes/tagCounts counters have NO self-healing path
// (only follower counts get reconcileMyCounts), so any drift from an optimistic-
// UI race, a dropped trigger, or a partial cascade is PERMANENT and invisible.
// This daily sweep samples recent posts, recomputes the two UNAMBIGUOUS counters
// (likeCount = size of the likes subcollection; repostCount = count of reposts
// pointing at the post) directly from source, records any mismatch to
// system/counterDriftReport + logs it, and repairs the drifted field(s) via a
// compare-and-set transaction (see the in-loop comment for why a blind
// overwrite would itself introduce drift). replyCount/totalLikes/
// tagCounts need bespoke recompute (the replyCount gate excludes pending_review
// and legacy docs) and are intentionally out of this v1.
// timeoutSeconds: up to ~600 sequential count() round-trips; the default 60s
// can be exceeded on a slow day, silently killing the scan.
exports.detectCounterDrift = onSchedule({schedule: "every 24 hours", timeoutSeconds: 540}, async () => {
  const SAMPLE = 300;
  const MAX_REPORTED = 100;
  // Skip posts younger than this: a like/repost landing mid-scan (subcollection
  // written, trigger not yet fired) reads as one-off phantom drift.
  const FRESH_MS = 10 * 60 * 1000;
  const snap = await db.collection("posts")
    .orderBy("createdAt", "desc")
    .limit(SAMPLE)
    .get();

  const drifts = [];
  let corrected = 0;
  for (const postDoc of snap.docs) {
    const data = postDoc.data();
    if (data.isRepost === true) continue; // reposts don't own like/repost counts
    if (data.createdAt?.toMillis && Date.now() - data.createdAt.toMillis() < FRESH_MS) continue;
    const id = postDoc.id;
    // Seeded App Review demo content (seedAppStoreDemo.js) carries fabricated
    // like/repost counts with no backing subcollection docs — permanent
    // by-construction "drift" that floods every report and masks real drift.
    if (id.startsWith("demo_")) continue;
    try {
      const likeAgg = await postDoc.ref.collection("likes").count().get();
      const actualLikes = likeAgg.data().count;
      const storedLikes = typeof data.likeCount === "number" ? data.likeCount : 0;

      // Reply-reposts match this query too (they carry the parent post's
      // originalPostId) but are deliberately EXCLUDED from the post's stored
      // repostCount (they increment the reply doc instead) — counting them
      // here produced phantom drift on any post whose reply was ever
      // reposted, i.e. false evidence inviting a wrong manual "correction".
      // count() can't test field absence, so fetch key-only projections and
      // filter; per-post repost sets are small. The filter must mirror
      // onRepostCreatedUpdateCount's guard EXACTLY: the trigger routes the
      // increment to the reply doc only when originalReplyId is a NON-EMPTY
      // string, so a repost carrying originalReplyId:"" or null IS counted
      // in the post's repostCount — an `=== undefined` test here excluded
      // those docs, manufacturing phantom drift and a wrong downward
      // auto-correction.
      const repostSnap = await db.collection("posts")
        .where("originalPostId", "==", id)
        .where("isRepost", "==", true)
        .select("originalReplyId")
        .get();
      const actualReposts = repostSnap.docs.filter((d) => {
        const orid = d.get("originalReplyId");
        return !(typeof orid === "string" && orid.length > 0);
      }).length;
      const storedReposts = typeof data.repostCount === "number" ? data.repostCount : 0;

      if (actualLikes !== storedLikes || actualReposts !== storedReposts) {
        drifts.push({
          postId: id,
          likeCount: { stored: storedLikes, actual: actualLikes },
          repostCount: { stored: storedReposts, actual: actualReposts },
        });
        // Auto-correct (2026-08-03 Phase-2 fix, L2/L3): the counter triggers
        // use bare FieldValue.increment with no dedup ledger, so a rare
        // Eventarc redelivery double-counts; report-only meant sampled drift
        // sat unrepaired until a human acted.
        //
        // The correction MUST be a guarded transaction, not a blind
        // overwrite. A like landing on an OLD post mid-scan makes the
        // aggregate read N+1 while the stored counter (from the sample
        // snapshot) still reads N; overwriting to N+1 and then having the
        // like trigger's increment(1) land yields N+2 — the detector would
        // INTRODUCE drift. (FRESH_MS doesn't cover this: it skips posts
        // CREATED recently, not posts ENGAGED recently.) Invariant enforced
        // here: write only if the stored counters still equal the values the
        // scan observed — i.e. no trigger moved them underneath — and write
        // only the field(s) that actually drifted, so a clean counter is
        // never touched. If they moved, skip; the next daily run
        // re-measures. Residual window: a subcollection write whose trigger
        // increment hasn't COMMITTED by transaction time is still invisible,
        // so a rare off-by-one can slip through — but the next run repairs
        // it, so the error is bounded and self-healing rather than silent
        // and permanent. A post-doc count write doesn't re-fire a counter
        // trigger (those fire on likes/reposts subdocs, not the post doc)
        // and onPostUpdated bails unless `text` changed. The report still
        // records the pre-correction delta for the drift metric/audit.
        try {
          const didCorrect = await db.runTransaction(async (tx) => {
            const cur = await tx.get(postDoc.ref);
            if (!cur.exists) return false; // post deleted mid-scan
            const curLikes = typeof cur.get("likeCount") === "number" ? cur.get("likeCount") : 0;
            const curReposts = typeof cur.get("repostCount") === "number" ? cur.get("repostCount") : 0;
            if (curLikes !== storedLikes || curReposts !== storedReposts) return false;
            const update = {};
            if (actualLikes !== storedLikes) update.likeCount = actualLikes;
            if (actualReposts !== storedReposts) update.repostCount = actualReposts;
            tx.update(postDoc.ref, update);
            return true;
          });
          if (didCorrect) {
            corrected++;
          } else {
            console.log(`detectCounterDrift: counters moved under post ${id} mid-scan; leaving for next run.`);
          }
        } catch (err) {
          console.warn(`detectCounterDrift: correction write failed for post ${id}:`, err.message);
        }
      }
    } catch (err) {
      console.warn(`detectCounterDrift: recompute failed for post ${id}:`, err.message);
    }
    if (drifts.length >= MAX_REPORTED) break;
  }

  if (drifts.length > 0) {
    console.error(
      `detectCounterDrift: ${drifts.length} post(s) with drifted like/repost ` +
      `counts (of ${snap.size} sampled); auto-corrected ${corrected}. ` +
      `See system/counterDriftReport.`);
    // Full report ONLY when drift is found: a clean run must not clobber
    // `drifts` — the sample is the newest 300 posts, so day-N drift slides
    // out of the window and a clean day-N+1 write would zero the unreviewed
    // evidence a human still needs to act on. `drifts` records the
    // pre-correction deltas even though the counts are now repaired, so the
    // metric/audit still reflects that drift occurred (and correctedCount
    // shows how much self-healed vs. needs a human — e.g. a write that failed).
    await db.collection("system").doc("counterDriftReport").set({
      generatedAt: FieldValue.serverTimestamp(),
      sampled: snap.size,
      driftCount: drifts.length,
      correctedCount: corrected,
      drifts: drifts.slice(0, MAX_REPORTED),
    }, { merge: true });
  } else {
    console.log(`detectCounterDrift: no like/repost drift in ${snap.size} sampled posts.`);
    // Freshness stamp on clean runs (merge — preserves any prior drift
    // evidence) so a stale report is distinguishable from current drift:
    // lastCleanRunAt > generatedAt ⇒ the listed drift predates a clean scan.
    await db.collection("system").doc("counterDriftReport").set({
      lastCleanRunAt: FieldValue.serverTimestamp(),
      lastCleanSampled: snap.size,
    }, { merge: true });
  }

  // ---- Phase 2 (2026-09-04): users.totalLikes. This is the profile "felt"
  // number. It's maintained by three bare increments (like +1, unlike -1,
  // post-delete -likeCount) with no ledger, and seed scripts write
  // likeCount directly without touching it — a prod sweep found 5 of 13
  // users drifted, one at -111, and the demo account Apple reviews showed
  // "-1 felt". Invariant (mirrors the triggers exactly): totalLikes ==
  // SUM(likeCount) over posts where authorId == uid, reposts INCLUDED (a
  // like on a repost row credits the reposter; delete decrements by that
  // row's likeCount). Server-side sum() aggregation, one round-trip per
  // user; same guarded compare-and-set as the post phase.
  const USER_SAMPLE = 500;
  const userSnap = await db.collection("users")
    .orderBy("createdAt", "desc")
    .limit(USER_SAMPLE)
    .select("totalLikes")
    .get();
  const userDrifts = [];
  let usersCorrected = 0;
  for (const userDoc of userSnap.docs) {
    const stored = typeof userDoc.get("totalLikes") === "number" ? userDoc.get("totalLikes") : 0;
    try {
      const agg = await db.collection("posts")
        .where("authorId", "==", userDoc.id)
        .aggregate({ total: AggregateField.sum("likeCount") })
        .get();
      const actual = agg.data().total || 0;
      if (actual === stored) continue;
      userDrifts.push({ uid: userDoc.id, totalLikes: { stored, actual } });
      const didCorrect = await db.runTransaction(async (tx) => {
        const cur = await tx.get(userDoc.ref);
        if (!cur.exists) return false;
        const curVal = typeof cur.get("totalLikes") === "number" ? cur.get("totalLikes") : 0;
        if (curVal !== stored) return false; // a like/unlike moved it mid-scan
        tx.update(userDoc.ref, { totalLikes: actual });
        return true;
      });
      if (didCorrect) usersCorrected++;
      else console.log(`detectCounterDrift: totalLikes moved under user ${userDoc.id} mid-scan; leaving for next run.`);
    } catch (err) {
      console.warn(`detectCounterDrift: totalLikes recompute failed for user ${userDoc.id}:`, err.message);
    }
    if (userDrifts.length >= MAX_REPORTED) break;
  }
  if (userDrifts.length > 0) {
    console.error(
      `detectCounterDrift: ${userDrifts.length} user(s) with drifted totalLikes ` +
      `(of ${userSnap.size} sampled); auto-corrected ${usersCorrected}.`);
    await db.collection("system").doc("counterDriftReport").set({
      userGeneratedAt: FieldValue.serverTimestamp(),
      userSampled: userSnap.size,
      userDriftCount: userDrifts.length,
      userCorrectedCount: usersCorrected,
      userDrifts: userDrifts.slice(0, MAX_REPORTED),
    }, { merge: true });
  } else {
    console.log(`detectCounterDrift: no totalLikes drift in ${userSnap.size} sampled users.`);
    await db.collection("system").doc("counterDriftReport").set({
      userLastCleanRunAt: FieldValue.serverTimestamp(),
      userLastCleanSampled: userSnap.size,
    }, { merge: true });
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
    // Clamp both ends: a negative limit (e.g. "-100") is truthy so `|| 30`
    // wouldn't fire and a negative value would be forwarded to Giphy.
    const parsedLimit = parseInt(data.limit, 10);
    const limit = Number.isFinite(parsedLimit) ? Math.min(Math.max(parsedLimit, 1), 50) : 30;
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

// ============================================================
// Public read-only feed for toskaapp.com (roadmap phase-2 slice)
// ============================================================
// Serves a small curated JSON of recent posts for the marketing site's
// "from the feed" section. Privacy invariants (same rules as share cards —
// words leave the platform, identity never does):
//   - isShareable only (the author's "allow sharing" consent toggle)
//   - moderationStatus live, no reposts, no ephemeral (whisper/midnight)
//   - returns text/tag/likeCount/age only — NO handle, NO authorId, NO doc id
// No App Check: this is deliberately public data. Abuse surface is capped by
// the fixed 12-post response, no pagination, and the per-instance memo below
// (the site calls the raw cloudfunctions.net URL — nothing fronts it, so the
// s-maxage header alone caps nothing; the memo makes repeat hits within 10
// minutes cost zero Firestore reads per warm instance).
let publicFeedMemo = { at: 0, body: null };
exports.publicFeed = onRequest(
  { cors: ["https://toskaapp.com", "https://www.toskaapp.com"] },
  async (req, res) => {
    if (req.method !== "GET") {
      res.status(405).json({ error: "method not allowed" });
      return;
    }
    try {
      if (publicFeedMemo.body && Date.now() - publicFeedMemo.at < 600e3) {
        res.set("Cache-Control", "public, max-age=600, s-maxage=600");
        res.json(publicFeedMemo.body);
        return;
      }
      // Direct query on the curation flag (single-field index, no composite);
      // the featured set is small, so ordering happens in memory below. The
      // window must stay comfortably above the human-curated set's size: the
      // in-memory recency sort runs on what THIS query returns, so a too-small
      // limit silently pins the feed to an arbitrary (docId-ordered) subset.
      const snap = await db.collection("posts")
        .where("webFeatured", "==", true)
        .limit(300)
        .get();
      const now = Date.now();
      const posts = [];
      const docs = [...snap.docs].sort((a, b) =>
        (b.data().createdAt?.toMillis?.() ?? 0) - (a.data().createdAt?.toMillis?.() ?? 0));
      for (const doc of docs) {
        const d = doc.data();
        if (d.moderationStatus !== "live") continue;
        if (d.isRepost === true || d.isShareable !== true) continue;
        if (d.isWhisper === true || d.isMidnightPost === true) continue;
        // Letters too (2026-08-06): sharePage.js gates them off /p/ pages, but
        // this feed never did — so a curated letter would publish to
        // toskaapp.com while Privacy §4 promises letters are "never
        // shareable". Both public paths must carry the same gate, and rules
        // can't do it: a tampered client can write isLetter + isShareable.
        if (d.isLetter === true) continue;
        // Curation gate: only posts an admin explicitly flagged for the web.
        // The live feed contains tester noise and PII-shaped test posts —
        // author consent (isShareable) is necessary but NOT sufficient for
        // the marketing site. Flag via: posts/{id}.webFeatured = true.
        if (d.webFeatured !== true) continue;
        if (typeof d.text !== "string" || d.text.length < 40 || d.text.length > 500) continue;
        const ageH = d.createdAt?.toMillis ? Math.max(1, Math.round((now - d.createdAt.toMillis()) / 3600e3)) : null;
        posts.push({
          text: d.text,
          tag: typeof d.tag === "string" ? d.tag : null,
          felt: typeof d.likeCount === "number" ? d.likeCount : 0,
          ageHours: ageH,
        });
        if (posts.length >= 12) break;
      }
      publicFeedMemo = { at: Date.now(), body: { posts } };
      res.set("Cache-Control", "public, max-age=600, s-maxage=600");
      res.json({ posts });
    } catch (err) {
      console.error("publicFeed:", err);
      res.status(500).json({ error: "unavailable" });
    }
  },
);

// ============================================================
// Server-rendered public share pages — /p/{postId} + posts sitemap
// (roadmap phase-2 share/SEO layer)
// ============================================================
// Firebase Hosting rewrites /p/** and /sitemap.xml to these (firebase.json).
// Crawlers can't sign in and the rules require auth, so this is the ONE
// unauthenticated read path for full post content; every privacy gate lives
// in sharePage.evaluateSharePage (live + isShareable + never whisper/midnight/
// expired; reposts 301 to the original; identity never rendered; indexing is
// admin-curated via webFeatured, same rationale as publicFeed above). No App
// Check — deliberately public, like publicFeed; abuse is capped by the CDN
// cache headers plus one doc read per uncached miss.
const share = require("./sharePage");

exports.sharePage = onRequest(async (req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.status(405).send("method not allowed");
    return;
  }
  res.set("X-Content-Type-Options", "nosniff");
  res.set("Referrer-Policy", "no-referrer");
  // Everything on the page is inline markup — lock the rest down. img-src
  // data: covers the inline SVG favicon.
  res.set("Content-Security-Policy",
    "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'");
  const notFound = () => {
    res.set("Cache-Control", "public, max-age=60, s-maxage=300");
    res.status(404).send(share.renderNotFoundHtml());
  };
  try {
    const parts = req.path.split("/").filter(Boolean); // ["p", "{postId}"]
    const postId = parts.length === 2 && parts[0] === "p" ? parts[1] : null;
    if (!share.isValidDocId(postId)) {
      notFound();
      return;
    }
    const snap = await db.collection("posts").doc(postId).get();
    const verdict = share.evaluateSharePage(snap.exists ? snap.data() : null, Date.now());
    if (verdict.outcome === "redirect") {
      // The repost→original edge never changes; if the original is (or later
      // becomes) unshareable, the target itself 404s.
      res.set("Cache-Control", "public, max-age=300, s-maxage=600");
      res.redirect(301, `/p/${verdict.to}`);
      return;
    }
    if (verdict.outcome !== "render") {
      notFound();
      return;
    }
    const post = snap.data();
    // Takedown latency bound: a post moderated/unshared after caching stays
    // visible at most s-maxage (10 min) on the CDN edge.
    res.set("Cache-Control", "public, max-age=300, s-maxage=600");
    res.status(200).send(share.renderPostHtml(postId, post, {
      indexable: verdict.indexable,
      createdAtMs: post.createdAt?.toMillis?.(),
    }));
  } catch (err) {
    console.error("sharePage:", err);
    res.set("Cache-Control", "no-store");
    res.status(500).send("unavailable");
  }
});

// The 1200×630 og:image card for a share page (/og/{postId}.png). Same gate
// as the page itself — evaluateSharePage must say "render" — so a taken-down
// or unshared post's card 404s in lockstep. shareCard.js (native canvas) is
// required lazily: every function instance loads this file, and only this
// endpoint should pay the native-module cold-start cost.
exports.shareCardImage = onRequest({ memory: "512MiB" }, async (req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.status(405).send("method not allowed");
    return;
  }
  res.set("X-Content-Type-Options", "nosniff");
  const notFound = () => {
    res.set("Cache-Control", "public, max-age=60, s-maxage=300");
    res.status(404).send("not found");
  };
  try {
    const m = req.path.match(/^\/og\/([^/]+)\.png$/);
    const postId = m ? m[1] : null;
    if (!share.isValidDocId(postId)) {
      notFound();
      return;
    }
    const snap = await db.collection("posts").doc(postId).get();
    const verdict = share.evaluateSharePage(snap.exists ? snap.data() : null, Date.now());
    if (verdict.outcome !== "render") {
      // Reposts included: the page 301s to the original, whose og:image is
      // the original's card — a card for the repost id has no consumer.
      notFound();
      return;
    }
    const post = snap.data();
    const { renderShareCardPNG } = require("./shareCard");
    const png = renderShareCardPNG({
      text: post.text,
      tag: typeof post.tag === "string" ? post.tag : null,
      likeCount: typeof post.likeCount === "number" ? post.likeCount : 0,
    });
    res.set("Content-Type", "image/png");
    res.set("Cache-Control", "public, max-age=300, s-maxage=600");
    res.status(200).send(png);
  } catch (err) {
    console.error("shareCardImage:", err);
    res.set("Cache-Control", "no-store");
    res.status(500).send("unavailable");
  }
});

exports.postsSitemap = onRequest(async (req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.status(405).send("method not allowed");
    return;
  }
  try {
    // Same single-field query as publicFeed: the curated set is small, and
    // evaluateSharePage re-applies the full render+indexable gate per doc so
    // a featured-but-since-unshared post drops out of the sitemap too.
    const snap = await db.collection("posts")
      .where("webFeatured", "==", true)
      .limit(500)
      .get();
    const now = Date.now();
    const entries = [];
    for (const doc of snap.docs) {
      const verdict = share.evaluateSharePage(doc.data(), now);
      if (verdict.outcome === "render" && verdict.indexable) {
        entries.push({ postId: doc.id, createdAtMs: doc.data().createdAt?.toMillis?.() });
      }
    }
    res.set("Content-Type", "application/xml; charset=utf-8");
    res.set("Cache-Control", "public, max-age=3600, s-maxage=3600");
    res.status(200).send(share.renderSitemapXml(entries));
  } catch (err) {
    console.error("postsSitemap:", err);
    res.set("Cache-Control", "no-store");
    res.status(500).send("unavailable");
  }
});

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
    // failClosed=true (2026-06-12 security re-review): this runs an Admin-SDK
    // aggregation transaction (2 count() reads + a write) per call. A fail-OPEN
    // limiter let a tampered client storm those during a Firestore-degradation
    // window (cost/DoS amplifier). Deny rather than amplify if the limiter
    // itself can't be checked.
    const allowed = await checkRateLimit(uid, "reconcileMyCounts", 6, 86400, true);
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
// blockBannedSignups — Identity Platform blocking function (2026-07-29).
// Runs synchronously before ANY account creation (email, Google, Apple);
// rejects when the new account's email or Apple/Google provider uid matches a
// bannedIdentities hash captured by adminDeleteAccount. Registered into the
// project's "Before account creation" slot automatically on deploy (requires
// the Identity Platform upgrade, done 2026-07-29).
//
// FAIL-OPEN on infrastructure errors: a bug or Firestore outage in this
// function must degrade to "bans not enforced for that signup", never to
// "nobody can create an account" (blocking functions fail-closed by default,
// so every non-rejection error is caught). The deliberate rejection is the
// only thrown error, with a neutral message — silent-removal policy, the
// banned user isn't told why.
exports.blockBannedSignups = beforeUserCreated(
  { secrets: [BANNED_ID_PEPPER] },
  async (event) => {
    try {
      const user = event.data;
      if (!user) return;
      const ids = extractIdentities(user);
      if (ids.length === 0) return;
      const pepper = BANNED_ID_PEPPER.value();
      const refs = ids.map((id) =>
        db.collection("bannedIdentities").doc(identityHash(pepper, id.kind, id.value)));
      const snaps = await db.getAll(...refs);
      if (snaps.some((s) => s.exists)) {
        console.log(`blockBannedSignups: rejected signup matching ${snaps.filter((s) => s.exists).length} banned identity hash(es)`);
        throw new IdentityHttpsError("permission-denied", "account cannot be created");
      }
    } catch (err) {
      if (err instanceof IdentityHttpsError) throw err;
      console.error("blockBannedSignups check failed (failing open):", err.message);
    }
  },
);

// adminDeleteAccount — admin-initiated full account deletion
//
// The moderation dashboard (docs/admin.html) can already RESTRICT a user
// (freeze posting) via a plain users/{uid} write. This callable is the
// stronger action: permanently DELETE an account — used for underage users
// (Terms §2: "we remove accounts we discover to be underage") and other
// terminate-worthy violations.
//
// Why a callable and not a direct client write: deleting a user requires
// removing the Firebase Auth user (Admin SDK only) AND deleting the
// users/{uid} doc. The rules deliberately do NOT let an admin delete another
// user's doc (G-2 self-delete-escape guard covers deletes), so this runs
// server-side with the Admin SDK, which bypasses rules.
//
// Sequence mirrors the in-app SettingsView.deleteAccount ordering:
//   1. delete the Auth user (so the cascade sees auth/user-not-found)
//   2. delete users/{uid} → fires onUserDocDeleted, which cascades full
//      content cleanup (posts, replies, likes, saves, follows, notifications,
//      reposts, conversations, blocked-index) exactly as a self-delete does.
//   3. write an adminAuditLog entry (attribution is trusted here — it comes
//      from request.auth.uid, not client-supplied data).
//
// Gating: App Check enforced + caller must be admins/{uid}.role == "admin"
// (the SAME predicate as rules isAdmin()). Refuses to delete the caller's own
// account or any other admin account through this path.
exports.adminDeleteAccount = onCall(
  { enforceAppCheck: true, secrets: [BANNED_ID_PEPPER] },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "must be signed in");
    }

    // Admin gate — mirror rules isAdmin(): admins/{uid}.role == "admin".
    const callerAdmin = await db.collection("admins").doc(callerUid).get();
    if (!callerAdmin.exists || callerAdmin.get("role") !== "admin") {
      throw new HttpsError("permission-denied", "admin only");
    }

    const targetUid = request.data?.uid;
    if (typeof targetUid !== "string" || !targetUid) {
      throw new HttpsError("invalid-argument", "missing uid");
    }
    if (targetUid === callerUid) {
      throw new HttpsError("failed-precondition", "cannot delete your own account here");
    }
    // Never let this path delete another admin — admin removal is an
    // out-of-band operation, not a dashboard button.
    const targetAdmin = await db.collection("admins").doc(targetUid).get();
    if (targetAdmin.exists) {
      throw new HttpsError("failed-precondition", "target is an admin");
    }

    const reason = typeof request.data?.reason === "string"
      ? request.data.reason.slice(0, 200)
      : "";

    // 0.5 — Block-re-signup (2026-07-29): capture the account's sign-in
    // identities as one-way HMAC hashes BEFORE deletion. Ordering matters:
    // after the Auth delete the identities are gone forever, so a capture
    // failure throws (the admin retries the whole deletion — the earlier
    // steps are idempotent). Absorb user-not-found: a re-invocation after a
    // partial prior failure already captured on the first pass.
    try {
      const userRecord = await getAuth().getUser(targetUid).catch((err) => {
        if (err.code === "auth/user-not-found") return null;
        throw err;
      });
      if (userRecord) {
        const pepper = BANNED_ID_PEPPER.value();
        const batch = db.batch();
        for (const id of extractIdentities(userRecord)) {
          batch.set(
            db.collection("bannedIdentities").doc(identityHash(pepper, id.kind, id.value)),
            {
              kind: id.kind, // which identifier class the hash came from — NO plaintext
              bannedAt: FieldValue.serverTimestamp(),
              bannedBy: callerUid,
              targetUid,
              reason,
            },
            { merge: true },
          );
        }
        await batch.commit();
      }
    } catch (err) {
      console.error("adminDeleteAccount identity capture failed:", err.message);
      throw new HttpsError("internal", "identity capture failed — retry the deletion");
    }

    // 1. Delete the Auth user. Absorb user-not-found so a re-invocation after
    //    a partial prior failure still completes (idempotent).
    try {
      await getAuth().deleteUser(targetUid);
    } catch (err) {
      if (err.code !== "auth/user-not-found") {
        console.error("adminDeleteAccount auth delete failed:", err.message);
        throw new HttpsError("internal", "auth deletion failed");
      }
    }

    // 2. Delete the user doc → onUserDocDeleted cascades content cleanup.
    try {
      await db.collection("users").doc(targetUid).delete();
    } catch (err) {
      console.error("adminDeleteAccount user-doc delete failed:", err.message);
      throw new HttpsError("internal", "user doc deletion failed");
    }

    // 3. Audit (trusted attribution from request.auth).
    await writeAuditEntry({
      action: "adminDeleteAccount",
      targetUid,
      actedBy: callerUid,
      reason,
    });

    return { ok: true };
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

async function writeAuditEntry(entry, dedupeId) {
  try {
    const payload = { ...entry, createdAt: FieldValue.serverTimestamp() };
    const col = db.collection("adminAuditLog");
    if (dedupeId) {
      // Deterministic id keyed on the trigger event so an at-least-once
      // Eventarc redelivery of the same update overwrites the same row
      // instead of appending a duplicate audit entry.
      await col.doc(dedupeId).set(payload);
    } else {
      await col.add(payload);
    }
  } catch (err) {
    // 2026-07-18 re-audit: THROW instead of swallowing. The audit triggers
    // scrub the attribution stamp right after this call — a swallowed write
    // failure let the scrub outrun the audit entry, silently losing the
    // trail. Every audit trigger now carries retry:true, so a transient
    // failure redelivers the SAME event (before/after unchanged → the
    // newly-appeared gate re-fires → this write retries, dedupe id keeps it
    // single) and the scrub only ever runs after the entry has landed.
    console.error("adminAuditLog write failed (will retry):", err.message);
    throw err;
  }
}

exports.auditUserRestriction = onDocumentUpdated(
  { document: "users/{userId}", retry: true },
  async (event) => {
    const before = event.data.before.data() || {};
    const after  = event.data.after.data() || {};

    if (before.restricted !== after.restricted) {
      const action = after.restricted === true ? "user.restrict" : "user.unrestrict";
      await writeAuditEntry({
        action,
        adminUid: after.restrictedBy || before.restrictedBy || "unknown",
        targetType: "user",
        targetId: event.params.userId,
        targetHandle: after.handle || before.handle || null,
        before: { restricted: before.restricted ?? false },
        after:  { restricted: after.restricted ?? false },
      }, event.id);
    }

    // M-1 (2026-07-17): restrictedBy is an admin uid on the MAIN user doc,
    // which other authenticated users can read (public-projection rule leg).
    // It exists to attribute the audit entry above — scrub it now. The scrub
    // runs OUTSIDE the restricted-changed gate (2026-07-17 review):
    // restrictUserDirect (docs/admin.html) writes restrictedBy
    // unconditionally, so restricting an already-restricted user produces an
    // update where `restricted` never flips — the old early-return skipped
    // the scrub and the admin uid stranded on the readable doc. No loop
    // either way: the scrub's own event has restrictedBy == null. The
    // `restricted` flag itself stays (firestore.rules' notRestricted() reads
    // it) and the scrub doesn't flip it.
    if (after.restrictedBy != null) {
      try {
        await event.data.after.ref.update({ restrictedBy: FieldValue.delete() });
      } catch (err) {
        if (err.code !== 5) throw err;
      }
    }
  }
);

// 2026-07-28 A.5 #9 migration (phase 2 — dual-write): mirror the moderation /
// adult-gate state from the world-readable users/{uid} doc into
// users/{uid}/private/data, and maintain the admin-only restrictedUsers/{uid}
// dashboard index (firestore.rules match block of the same name). Every
// writer (confirmAdult callable, system auto-restrict, admin.html / iOS admin
// restrict+unrestrict) writes the MAIN doc, so this single trigger keeps both
// mirrors current without touching any writer; the eventual phase-4 rules
// flip then only changes readers. restrictedBy is mirrored only when PRESENT:
// auditUserRestriction scrubs it from the main doc right after attribution
// (M-1), and that scrub must not erase the private copy — the scrub event
// changes no other mirrored field, so the change-guard skips it entirely
// (no ping-pong writes). The guard also makes this a cheap no-op on the
// high-frequency counter-bump updates every user doc receives.
exports.mirrorModerationState = onDocumentWritten(
  { document: "users/{userId}", retry: true },
  async (event) => {
    const userId = event.params.userId;
    const rowRef = db.collection("restrictedUsers").doc(userId);
    if (!event.data?.after?.exists) {
      // User doc deleted → drop the index row. (users/{uid}/private/* is
      // removed by the onUserDocDeleted cascade; this row lives outside the
      // user tree, so it's cleaned here — keeps the deletion-cascade probe's
      // "no residue" sweep honest.)
      await rowRef.delete().catch((err) => console.warn(`mirrorModerationState(${userId}): row cleanup failed:`, err.message));
      return;
    }
    const after = event.data.after.data() || {};
    const before = event.data.before?.exists ? event.data.before.data() : {};
    const MIRRORED = ["restricted", "restrictedAt", "restrictedUntil", "confirmedAdult", "confirmedAdultAt"];
    const key = (v) => (v && typeof v.toMillis === "function") ? `t:${v.toMillis()}` : JSON.stringify(v === undefined ? null : v);
    const changed = MIRRORED.some((f) => key(before[f]) !== key(after[f]))
      || (after.restrictedBy != null && key(before.restrictedBy) !== key(after.restrictedBy));
    if (!changed) return;
    // Late-redelivery resurrection guard (2026-08-05): Eventarc can redeliver
    // an old UPDATE event after the user doc was deleted and the deletion
    // cascade drained users/{uid}/private. The merge-set below would then
    // re-CREATE private/data (and, if restricted, the restrictedUsers row)
    // under a deleted uid — restricted/confirmedAdult residue with no
    // remaining GC path, since the cascade fires once and never re-runs.
    // Re-read the live parent doc and skip the mirror when it's gone; the
    // delete event's own branch above owns the row cleanup. Placed after the
    // change-guard so the extra read isn't paid on every counter-bump write.
    const liveParent = await db.doc(`users/${userId}`).get();
    if (!liveParent.exists) {
      console.log(`mirrorModerationState(${userId}): user doc gone (late redelivery) — skipping mirror`);
      return;
    }
    const mirror = {};
    for (const f of MIRRORED) mirror[f] = after[f] === undefined ? FieldValue.delete() : after[f];
    if (after.restrictedBy != null) mirror.restrictedBy = after.restrictedBy;
    await db.doc(`users/${userId}/private/data`).set(mirror, { merge: true });
    if (after.restricted === true) {
      const row = {
        handle: after.handle ?? null,
        restrictedAt: after.restrictedAt ?? null,
        restrictedUntil: after.restrictedUntil ?? null,
      };
      if (after.restrictedBy != null) row.restrictedBy = after.restrictedBy;
      await rowRef.set(row, { merge: true });
    } else {
      await rowRef.delete();
    }
  }
);

// Audit crisis-reply reviews. Replaces the old on-doc crisisReviewedBy stamp
// (which sat on a world-readable live reply — C-1 2026-07-17): the review now
// flips `reviewed` on the admin-only crisisReplyQueue entry, so the actor uid
// can live right on the queue doc and the audit keys on the flip.
exports.auditCrisisReplyReview = onDocumentUpdated(
  { document: "crisisReplyQueue/{entryId}", retry: true },
  async (event) => {
    const before = event.data.before.data() || {};
    const after  = event.data.after.data() || {};
    if (before.reviewed === true || after.reviewed !== true) return;
    await writeAuditEntry({
      action: "reply.crisis_reviewed",
      adminUid: after.reviewedBy || "unknown",
      targetType: "reply",
      targetId: `${after.postId || "?"}/${after.replyId || event.params.entryId}`,
      targetHandle: null,
      before: { reviewed: before.reviewed ?? false },
      after:  { reviewed: true },
    }, event.id);
  }
);

exports.auditReportResolution = onDocumentUpdated(
  { document: "reports/{reportId}", retry: true },
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
    }, event.id);
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
  { document: "posts/{postId}", retry: true },
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
      }, `${event.id}_approve`);
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
      }, `${event.id}_crisis`);
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
      }, `${event.id}_unflag`);
    }

    // 2026-07-17 privacy audit (M-1): the *By stamps exist purely to
    // attribute the audit entries above — they must not persist on the post
    // doc, which any authenticated client can read once the post is (or
    // returns to) "live". An admin uid on a world-readable doc deanonymizes
    // the moderator (the data-export path already strips restrictedBy on the
    // same principle). Scrub each stamp now that its entry is written. The
    // scrub is its own update: the newly-appearing gates above see
    // non-null → null and emit nothing, so there's no trigger loop. NOT_FOUND
    // (doc deleted in the window) is swallowed — a deleted doc leaks nothing.
    const scrub = {};
    if (newlyApproved) scrub.pendingApprovedBy = FieldValue.delete();
    if (newlyCrisisReviewed) scrub.crisisReviewedBy = FieldValue.delete();
    if (newlyUnflagged) scrub.unflaggedBy = FieldValue.delete();
    try {
      await event.data.after.ref.update(scrub);
    } catch (err) {
      if (err.code !== 5) throw err;
    }
  }
);

// Audit + scrub reply approvals (2026-07-17 review). approvePendingReply
// (docs/admin.html) stamps pendingApprovedBy on the reply doc as it goes
// live — the same M-1 exposure auditPostModeration closes for posts (a live
// reply is readable by every authenticated client), and until this trigger
// existed the stamp persisted forever AND the approval never reached
// adminAuditLog: restoring a PII/link-held reply to a public thread was the
// one moderation reversal with no audit entry. Mirrors auditPostModeration
// (audit keyed on the stamp newly appearing, then scrub), with one
// deliberate difference: the scrub keys on any stamp PRESENT, not newly
// appearing, so a stamp that survives a lost event or failed scrub (update
// triggers don't retry by default) self-heals on the reply's next write.
// unflaggedBy / crisisReviewedBy have no reply-side writer today (crisis
// review is queue-based, unflag is post-only) — scrubbing them unaudited is
// defense-in-depth for the same invariant. Loop-safe: the scrub's own event
// carries no stamps and returns at the gate.
exports.auditReplyModeration = onDocumentUpdated(
  { document: "posts/{postId}/replies/{replyId}", retry: true },
  async (event) => {
    const before = event.data.before.data() || {};
    const after  = event.data.after.data() || {};

    const stamps = ["pendingApprovedBy", "unflaggedBy", "crisisReviewedBy"]
      .filter((k) => after[k] != null);
    if (stamps.length === 0) return;

    const newlyApproved =
      before.pendingApprovedBy == null && after.pendingApprovedBy != null;
    if (newlyApproved) {
      await writeAuditEntry({
        action: "reply.approve",
        adminUid: after.pendingApprovedBy || "unknown",
        targetType: "reply",
        targetId: `${event.params.postId}/${event.params.replyId}`,
        targetHandle: after.authorHandle || before.authorHandle || null,
        before: { moderationStatus: before.moderationStatus || null, pendingReason: before.pendingReason ?? null },
        after:  { moderationStatus: after.moderationStatus  || null, pendingReason: after.pendingReason ?? null },
      }, `${event.id}_approve`);
    }

    const scrub = {};
    for (const k of stamps) scrub[k] = FieldValue.delete();
    try {
      await event.data.after.ref.update(scrub);
    } catch (err) {
      if (err.code !== 5) throw err; // NOT_FOUND: reply deleted in the window — nothing leaks
    }
  }
);

// Audit post deletions. The admin dashboard's removePost/deletePost
// (docs/admin.html) update the post with deletedBy/deletedAt immediately
// before the delete, so this onDocumentDeleted reads the doc's last state to
// record who removed it. Author self-deletes (no deletedBy) are recorded as
// "author".
exports.auditPostDeletion = onDocumentDeleted(
  { document: "posts/{postId}", retry: true },
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
    }, event.id);
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
  pruneNotificationsOlderThan,
  setReplyPendingReview,
  setReplyLive,
  setPendingReview,
  setPostLive,
  cleanupLikesForUid,
  cleanupRepliesForUid,
  clearRepostsOfPost,
  clearPostSubtree,
  fanOutToRepostCopies,
  claimedTransaction,
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