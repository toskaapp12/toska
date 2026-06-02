// One-off admin script: purge the finalPosts collection.
//
// Context: the "last thing they said" feature was removed on 2026-06-02.
// Account deletion no longer archives a user's final post (see
// onUserDocDeleted in index.js), the iOS LastThingSaidView surface is gone,
// and firestore.rules now denies all read/write on finalPosts. But any docs
// already written before the removal still physically exist — each holds a
// (now-deleted) user's last post text + handle, which is exactly the
// GDPR-erasure residue the removal is meant to eliminate. This script deletes
// them via the Admin SDK (which bypasses the new deny-all rule).
//
// Idempotent: safe to run repeatedly. When the collection is empty it's a
// no-op. Run once against EACH environment (prod toska-4ebf4 and staging
// toskastaging) — point ADC at the right project before each run.
//
// Usage:
//   cd functions
//   node purgeFinalPosts.js                 # dry run (counts, deletes nothing)
//   node purgeFinalPosts.js --apply         # performs the deletes
//
// Requires that ADC credentials (or GOOGLE_APPLICATION_CREDENTIALS env var)
// point at a service account with Firestore write access for the target
// project.

const admin = require("firebase-admin");
admin.initializeApp();
const db = admin.firestore();

const APPLY = process.argv.includes("--apply");

async function main() {
  const col = db.collection("finalPosts");
  let scanned = 0;
  let deleted = 0;

  // Page through in batches so a large collection doesn't OOM, and commit
  // deletes in chunks of 400 (under the 500-write batch limit).
  let last = null;
  for (;;) {
    let q = col.orderBy("__name__").limit(400);
    if (last) q = q.startAfter(last);
    const snap = await q.get();
    if (snap.empty) break;
    scanned += snap.size;
    last = snap.docs[snap.docs.length - 1];

    if (APPLY) {
      const batch = db.batch();
      snap.docs.forEach((d) => batch.delete(d.ref));
      await batch.commit();
      deleted += snap.size;
    }
    if (snap.size < 400) break;
  }

  if (APPLY) {
    console.log(`purgeFinalPosts: deleted ${deleted} finalPosts docs.`);
  } else {
    console.log(`purgeFinalPosts (DRY RUN): ${scanned} finalPosts docs would be deleted. Re-run with --apply.`);
  }
}

main().then(() => process.exit(0)).catch((err) => {
  console.error("purgeFinalPosts failed:", err);
  process.exit(1);
});
