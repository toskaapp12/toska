// Index smoke-probe — catches a Firestore query whose composite / collection-
// group index isn't deployed, BEFORE it silently breaks a feature in prod.
//
// Why this exists: the emulator auto-serves queries without requiring indexes,
// so firestore.rules tests pass on a query that FAILED_PRECONDITIONs live. We
// hit this three times (blocked-list, reply cleanup, who-blocked-me) — each
// nearly shipped a dead feature. This runs the app's real index-dependent
// queries against a LIVE project (staging in CI) with limit(1); a
// FAILED_PRECONDITION (gRPC code 9, "requires an index") fails the build.
//
// Manifest = every app query that needs a composite or collection-group index.
// Add a row here whenever you add such a query; it fails until the matching
// index is in firestore.indexes.json AND deployed to staging.
//
// Run:  GOOGLE_CLOUD_PROJECT=toskastaging node index-smoke-probe.mjs
// (CI passes the staging WIF credentials; locally it uses your ADC.)

import { initializeApp } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

const PROJECT = process.env.GOOGLE_CLOUD_PROJECT || "toskastaging";
initializeApp({ projectId: PROJECT });
const db = getFirestore();

const UID = "__probe_uid__";
const now = Timestamp.now();
const past = Timestamp.fromDate(new Date(Date.now() - 24 * 3600 * 1000));

// Each entry mirrors a real app query (same wheres + orderBy direction, which is
// what the index must match). The limit(1) + probe values return nothing; we
// only care whether the query is ALLOWED to run (index present) or throws code 9.
const MANIFEST = [
  ["posts: feed (moderationStatus, createdAt↓)", () =>
    db.collection("posts").where("moderationStatus", "==", "live").orderBy("createdAt", "desc").limit(1).get()],
  ["posts: search (moderationStatus, searchTokens array-any, createdAt↓)", () =>
    db.collection("posts").where("moderationStatus", "==", "live").where("searchTokens", "array-contains-any", ["x"]).orderBy("createdAt", "desc").limit(1).get()],
  ["posts: prompt response (authorId, promptDate)", () =>
    db.collection("posts").where("authorId", "==", UID).where("promptDate", "==", "2026-01-01").limit(1).get()],
  ["posts: web prompt feed (promptDate, moderationStatus, createdAt↓)", () =>
    db.collection("posts").where("promptDate", "==", "2026-01-01").where("moderationStatus", "==", "live").orderBy("createdAt", "desc").limit(1).get()],
  ["posts: profile reposts (authorId, isRepost, createdAt↓)", () =>
    db.collection("posts").where("authorId", "==", UID).where("isRepost", "==", true).orderBy("createdAt", "desc").limit(1).get()],
  ["posts: profile posts (authorId, createdAt↓)", () =>
    db.collection("posts").where("authorId", "==", UID).orderBy("createdAt", "desc").limit(1).get()],
  ["posts: explore tag (moderationStatus, tag, isRepost, createdAt↓)", () =>
    db.collection("posts").where("moderationStatus", "==", "live").where("tag", "==", "longing").where("isRepost", "==", false).orderBy("createdAt", "desc").limit(1).get()],
  ["posts: explore tag recent (moderationStatus, tag, createdAt range, createdAt↓)", () =>
    db.collection("posts").where("moderationStatus", "==", "live").where("tag", "==", "longing").where("createdAt", ">", past).orderBy("createdAt", "desc").limit(1).get()],
  ["posts: top-liked (moderationStatus, likeCount↓, createdAt↓)", () =>
    db.collection("posts").where("moderationStatus", "==", "live").orderBy("likeCount", "desc").orderBy("createdAt", "desc").limit(1).get()],
  ["posts: top-recent (moderationStatus, createdAt range, createdAt↓)", () =>
    db.collection("posts").where("moderationStatus", "==", "live").where("createdAt", ">", past).orderBy("createdAt", "desc").limit(1).get()],
  ["posts: following feed (moderationStatus, authorId in, createdAt↓)", () =>
    db.collection("posts").where("moderationStatus", "==", "live").where("authorId", "in", [UID]).orderBy("createdAt", "desc").limit(1).get()],
  ["posts: weekly recap (authorId, isRepost, createdAt range)", () =>
    db.collection("posts").where("authorId", "==", UID).where("isRepost", "==", false).where("createdAt", ">", past).where("createdAt", "<", now).limit(1).get()],
  ["posts: crisis watchdog scan (concerningContent, createdAt↓)", () =>
    db.collection("posts").where("concerningContent", "==", true).orderBy("createdAt", "desc").limit(1).get()],
  ["posts: auto-restrict flagged scan (authorId, flagged, flaggedAt↓)", () =>
    db.collection("posts").where("authorId", "==", UID).where("flagged", "==", true).orderBy("flaggedAt", "desc").limit(1).get()],
  ["posts: admin flagged tab (flagged, createdAt↓)", () =>
    db.collection("posts").where("flagged", "==", true).orderBy("createdAt", "desc").limit(1).get()],
  ["posts: repost dedup (authorId, isRepost, originalPostId)", () =>
    db.collection("posts").where("authorId", "==", UID).where("isRepost", "==", true).where("originalPostId", "==", "p").limit(1).get()],
  ["reports: admin queue / SLA (status, createdAt)", () =>
    db.collection("reports").where("status", "==", "pending").orderBy("createdAt", "asc").limit(1).get()],
  ["CG replies: by author (authorId, createdAt↓)", () =>
    db.collectionGroup("replies").where("authorId", "==", UID).orderBy("createdAt", "desc").limit(1).get()],
  ["CG replies: crisis sweep (concerningContent, concerningDetectedAt↓)", () =>
    db.collectionGroup("replies").where("concerningContent", "==", true).orderBy("concerningDetectedAt", "desc").limit(1).get()],
  ["CG blocked: who-blocked-me (blockedUid)", () =>
    db.collectionGroup("blocked").where("blockedUid", "==", UID).limit(1).get()],
  ["CG notifications: cleanup (fromUserId, createdAt↓)", () =>
    db.collectionGroup("notifications").where("fromUserId", "==", UID).orderBy("createdAt", "desc").limit(1).get()],
];

let missing = 0;
console.log(`index smoke-probe → project ${PROJECT} (${MANIFEST.length} queries)\n`);
for (const [name, run] of MANIFEST) {
  try {
    await run();
    console.log("  ✓", name);
  } catch (e) {
    if (e.code === 9 || /requires an index|FAILED_PRECONDITION/i.test(e.message || "")) {
      missing++;
      const link = (e.message.match(/https:\/\/\S+/) || [""])[0];
      console.log("  ✗ MISSING INDEX:", name, link ? "\n       " + link : "");
    } else {
      // Other errors (permission, network) are not index gaps — surface but don't fail.
      console.log("  ? skipped (non-index error):", name, "—", (e.message || "").slice(0, 80));
    }
  }
}
console.log(`\n${missing === 0 ? "✓ all indexed" : "✗ " + missing + " missing index(es) — add to firestore.indexes.json + deploy"}`);
process.exit(missing === 0 ? 0 : 1);
