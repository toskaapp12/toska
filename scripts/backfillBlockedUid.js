// One-time backfill for S-2 (2026-06-16): stamp `blockedUid` onto legacy
// `users/{blocker}/blocked/{blockedUid}` docs created before the field shipped.
//
// The account-deletion cascade sweeps OTHER users' block entries pointing at a
// deleted uid via collectionGroup("blocked").where("blockedUid","==",uid). Docs
// created before the client started writing `blockedUid` lack that field, so the
// sweep can't find them (GDPR Art. 17 residue). The doc id IS the blocked uid,
// so we just copy it into the field. Idempotent: skips docs that already have a
// correct `blockedUid`.
//
// Usage:
//   NODE_PATH="$PWD/functions/node_modules" node scripts/backfillBlockedUid.js          # dry run (counts only)
//   NODE_PATH="$PWD/functions/node_modules" node scripts/backfillBlockedUid.js --commit  # apply writes
//
// Requires gcloud application-default credentials against prod. If it errors with
// an auth message, run `gcloud auth application-default login` once, then re-run.

const admin = require("firebase-admin");
admin.initializeApp({ projectId: "toska-4ebf4" });
const db = admin.firestore();

const COMMIT = process.argv.includes("--commit");
const PAGE = 400; // < 500 batch write cap

(async () => {
  try {
    let lastDoc = null;
    let scanned = 0;
    let needBackfill = 0;
    let written = 0;

    while (true) {
      let q = db.collectionGroup("blocked").orderBy("__name__").limit(PAGE);
      if (lastDoc) q = q.startAfter(lastDoc);
      const snap = await q.get();
      if (snap.empty) break;
      lastDoc = snap.docs[snap.docs.length - 1];

      let batch = db.batch();
      let batchN = 0;
      for (const doc of snap.docs) {
        scanned++;
        const blockedUid = doc.id; // the doc id is the blocked user's uid
        const current = doc.data().blockedUid;
        if (current === blockedUid) continue; // already correct
        needBackfill++;
        if (COMMIT) {
          batch.set(doc.ref, { blockedUid }, { merge: true });
          batchN++;
        }
      }
      if (COMMIT && batchN > 0) {
        await batch.commit();
        written += batchN;
      }
      if (snap.size < PAGE) break;
    }

    console.log(`scanned ${scanned} blocked doc(s); ${needBackfill} missing/incorrect blockedUid.`);
    if (COMMIT) {
      console.log(`✔ backfilled ${written} doc(s).`);
    } else {
      console.log("dry run — re-run with --commit to apply.");
    }
    process.exit(0);
  } catch (err) {
    console.error("\n✖ failed:", err.message);
    if (/credential|auth|UNAUTHENTICATED|default|rapt/i.test(err.message)) {
      console.error("\nThis looks like an auth error. Run once:");
      console.error("  gcloud auth application-default login");
      console.error("Then re-run: node scripts/backfillBlockedUid.js --commit");
    }
    process.exit(1);
  }
})();
