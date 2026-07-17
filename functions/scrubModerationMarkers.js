// One-off scrub (C-1 / M-1, 2026-07-17 privacy audit): remove moderation and
// crisis metadata from WORLD-READABLE docs, and migrate the crisis-reply
// review queue off reply docs into the admin-only crisisReplyQueue collection.
//
// What it does, per pass:
//   A. posts (live) that carry admin stamps (pendingApprovedBy / unflaggedBy /
//      crisisReviewedBy): delete the stamp uids (audit entries already exist
//      in adminAuditLog) and — when the doc was admin-cleared (approved or
//      unflagged) — the full marker set (concerningContent, flagged,
//      flagReason, flaggedAt, pendingReason, pendingDetectedAt,
//      crisisReviewedAt).
//   B. posts (live) with concerningContent==true and NO admin-clear stamp and
//      NO crisisReviewedAt: left untouched and REPORTED — these are
//      un-reviewed legacy crisis items; scrubbing them would silently drop
//      them from the admin crisis tab. Review them in the dashboard; the
//      fixed approve/unflag paths scrub on action.
//   C. replies (live) carrying crisis/moderation metadata: seed a
//      crisisReplyQueue entry for each concerningContent==true reply
//      (reviewed := crisisReviewedAt already set), then delete
//      concerningContent / concerningDetectedAt / crisisReviewedAt /
//      crisisReviewedBy / pendingApprovedBy / unflaggedBy / stray
//      pendingReason+pendingDetectedAt from the reply doc.
//   D. users carrying restrictedBy: delete restrictedBy (the admin uid) —
//      `restricted` + restrictedAt stay (rules' notRestricted() reads the
//      flag; the timestamp only dates an already-visible state).
//
// DEPLOY ORDER (matters):
//   1. Deploy functions (queue writers + scrub-after-audit triggers).
//   2. Run this scrub (staging first, then prod with --prod).
//   3. Deploy firestore.rules (go-live-clean invariant + crisisReplyQueue).
//   4. Publish docs/admin.html (queue-based crisis-reply tab).
//   Rules before scrub would strand legacy live+concerning docs the admin
//   can't act on; admin.html before functions would query an empty queue.
//
// Usage:
//   cd functions && GCLOUD_PROJECT=toskastaging node scrubModerationMarkers.js [--dry-run]
//   prod additionally requires --prod:
//   GCLOUD_PROJECT=toska-4ebf4 node scrubModerationMarkers.js --prod

const admin = require("firebase-admin");

const PROJECT = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
if (!PROJECT) {
  console.error("Set GCLOUD_PROJECT (e.g. toskastaging or toska-4ebf4).");
  process.exit(1);
}
if (PROJECT === "toska-4ebf4" && !process.argv.includes("--prod")) {
  console.error("Refusing to run against prod without --prod.");
  process.exit(1);
}
const DRY = process.argv.includes("--dry-run");

admin.initializeApp({ projectId: PROJECT });
const db = admin.firestore();
const { FieldValue } = require("firebase-admin/firestore");

const del = FieldValue.delete();
const POST_MARKERS = {
  concerningContent: del, flagged: del, flagReason: del, flaggedAt: del,
  pendingReason: del, pendingDetectedAt: del, crisisReviewedAt: del,
};
const STAMPS = ["pendingApprovedBy", "unflaggedBy", "crisisReviewedBy"];

async function paginate(baseQuery, pageSize, handler) {
  let cursor = null;
  let scanned = 0;
  for (;;) {
    let q = baseQuery.limit(pageSize);
    if (cursor) q = q.startAfter(cursor);
    const snap = await q.get();
    if (snap.empty) break;
    for (const doc of snap.docs) await handler(doc);
    scanned += snap.docs.length;
    cursor = snap.docs[snap.docs.length - 1];
    if (snap.docs.length < pageSize) break;
  }
  return scanned;
}

async function run() {
  console.log(`scrubModerationMarkers → ${PROJECT}${DRY ? " (DRY RUN)" : ""}`);
  let scrubbedPosts = 0, unreviewedLive = 0, scrubbedReplies = 0,
      queueSeeded = 0, scrubbedUsers = 0;

  // ---- Pass A: live posts with admin stamps ----------------------------
  for (const stamp of STAMPS) {
    await paginate(
      db.collection("posts").orderBy(stamp).orderBy(admin.firestore.FieldPath.documentId()),
      300,
      async (doc) => {
        const d = doc.data();
        if ((d.moderationStatus || "live") !== "live") {
          // Held docs are unreadable to non-admins; only scrub the stamp uid
          // (audit already recorded) and leave review markers for the queue.
          if (DRY) { console.log(`[dry] held ${doc.id}: -${stamp}`); return; }
          await doc.ref.update({ [stamp]: del });
          return;
        }
        const adminCleared = d.pendingApprovedAt != null || d.unflaggedAt != null;
        const update = { pendingApprovedBy: del, unflaggedBy: del, crisisReviewedBy: del };
        if (adminCleared) Object.assign(update, POST_MARKERS);
        if (DRY) { console.log(`[dry] post ${doc.id}: stamps${adminCleared ? "+markers" : ""}`); }
        else await doc.ref.update(update);
        scrubbedPosts++;
      }
    );
  }

  // ---- Pass B: live+concerning posts with no admin action — report only --
  await paginate(
    db.collection("posts").where("concerningContent", "==", true),
    300,
    async (doc) => {
      const d = doc.data();
      if ((d.moderationStatus || "live") !== "live") return; // held: fine
      if (d.pendingApprovedAt != null || d.unflaggedAt != null) return; // pass A took it
      if (d.crisisReviewedAt != null) {
        // Reviewed but never cleared: safe to scrub markers (review happened).
        if (DRY) { console.log(`[dry] post ${doc.id}: reviewed live+concerning → markers`); }
        else await doc.ref.update({ ...POST_MARKERS, crisisReviewedBy: del });
        scrubbedPosts++;
        return;
      }
      unreviewedLive++;
      console.log(`NEEDS REVIEW (untouched): live+concerning post ${doc.id}`);
    }
  );

  // ---- Pass C: replies — queue-seed + scrub ----------------------------
  // Rides the existing collection-group composite index
  // replies(concerningContent ASC, concerningDetectedAt DESC).
  await paginate(
    db.collectionGroup("replies")
      .where("concerningContent", "==", true)
      .orderBy("concerningDetectedAt", "desc"),
    300,
    async (doc) => {
      const d = doc.data();
      const postId = doc.ref.parent.parent ? doc.ref.parent.parent.id : null;
      if (postId) {
        const entryRef = db.collection("crisisReplyQueue").doc(`${postId}_${doc.id}`);
        const entry = {
          postId,
          replyId: doc.id,
          reviewed: d.crisisReviewedAt != null,
          detectedAt: d.concerningDetectedAt || d.createdAt || FieldValue.serverTimestamp(),
        };
        if (d.crisisReviewedAt != null) {
          entry.reviewedAt = d.crisisReviewedAt;
          if (d.crisisReviewedBy) entry.reviewedBy = d.crisisReviewedBy;
        }
        if (DRY) console.log(`[dry] queue-seed ${postId}_${doc.id} reviewed=${entry.reviewed}`);
        else await entryRef.set(entry, { merge: true });
        queueSeeded++;
      }
      const update = {
        concerningContent: del, concerningDetectedAt: del,
        crisisReviewedAt: del, crisisReviewedBy: del,
        pendingApprovedBy: del, unflaggedBy: del,
      };
      if ((d.moderationStatus || "live") === "live") {
        update.pendingReason = del;
        update.pendingDetectedAt = del;
      }
      if (DRY) console.log(`[dry] reply ${postId}/${doc.id}: scrub crisis fields`);
      else await doc.ref.update(update);
      scrubbedReplies++;
    }
  );

  // ---- Pass D: users.restrictedBy --------------------------------------
  await paginate(
    db.collection("users").orderBy("restrictedBy").orderBy(admin.firestore.FieldPath.documentId()),
    300,
    async (doc) => {
      if (DRY) { console.log(`[dry] user ${doc.id}: -restrictedBy`); }
      else await doc.ref.update({ restrictedBy: del });
      scrubbedUsers++;
    }
  );

  console.log(
    `done. posts scrubbed: ${scrubbedPosts}, live+concerning left for review: ${unreviewedLive}, ` +
    `replies scrubbed: ${scrubbedReplies} (queue seeded: ${queueSeeded}), users scrubbed: ${scrubbedUsers}`
  );
}

run().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
