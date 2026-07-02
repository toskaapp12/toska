// One-off backfill: create a handles/{handle.lowercased()} uniqueness-registry
// row for every existing users/{uid} doc (see firestore.rules — new signups
// batch-create the row; accounts created before 2026-07-01 don't have one, so
// until backfilled their handles are claimable by a new signup, which would
// then collide).
//
// Collision policy: the registry can hold ONE uid per handle. If two existing
// user docs carry the same handle (possible pre-registry — the generator's
// uniqueness check was best-effort), the OLDER account (createdAt) keeps the
// handle and the collision is REPORTED but not auto-fixed — renaming a user's
// identity is an owner decision, not a script's. Re-run after resolving.
//
// Usage:
//   cd functions && GCLOUD_PROJECT=toskastaging node backfillHandles.js [--dry-run]
//   cd functions && GCLOUD_PROJECT=toska-4ebf4 node backfillHandles.js --prod
//
// Safe to re-run: rows are keyed by handle; an existing row owned by the same
// uid is skipped, a row owned by a different uid is reported as a collision.

const admin = require("firebase-admin");

// Project must be chosen explicitly (no hardcoded prod default) so this
// can't accidentally run against prod. Mirrors backfillModerationStatus.js.
const PROJECT = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
if (!PROJECT) {
  console.error("Set GCLOUD_PROJECT (e.g. toskastaging or toska-4ebf4).");
  process.exit(1);
}
if (PROJECT === "toska-4ebf4" && !process.argv.includes("--prod")) {
  console.error("Refusing to run against prod without --prod. (project=toska-4ebf4)");
  process.exit(1);
}
const DRY_RUN = process.argv.includes("--dry-run");
admin.initializeApp({ projectId: PROJECT });
const db = admin.firestore();
console.log(`Backfilling handle registry on project: ${PROJECT}${DRY_RUN ? " (dry run)" : ""}`);

const VALID_HANDLE = /^[a-zA-Z0-9_-]{1,30}$/;

async function main() {
  let created = 0;
  let skipped = 0;
  let collisions = 0;
  let invalid = 0;

  const usersSnap = await db.collection("users").get();
  console.log(`${usersSnap.size} user docs to examine`);

  for (const userDoc of usersSnap.docs) {
    const uid = userDoc.id;
    const data = userDoc.data();
    const handle = data.handle;
    if (typeof handle !== "string" || !VALID_HANDLE.test(handle)) {
      invalid++;
      console.warn(`INVALID handle on users/${uid}: ${JSON.stringify(handle)} — fix manually`);
      continue;
    }
    const rowRef = db.collection("handles").doc(handle.toLowerCase());
    const rowSnap = await rowRef.get();
    if (rowSnap.exists) {
      if (rowSnap.data().uid === uid) {
        skipped++;
        continue;
      }
      // Collision: decide by account age — older account keeps the handle.
      collisions++;
      const otherUid = rowSnap.data().uid;
      const otherSnap = await db.collection("users").doc(otherUid).get();
      const otherCreated = otherSnap.exists ? otherSnap.data().createdAt?.toMillis?.() : null;
      const thisCreated = data.createdAt?.toMillis?.() ?? null;
      console.warn(
        `COLLISION on "${handle}": row owned by ${otherUid} (createdAt ${otherCreated}), ` +
        `also carried by ${uid} (createdAt ${thisCreated}). ` +
        ((thisCreated != null && otherCreated != null && thisCreated < otherCreated)
          ? `users/${uid} is OLDER — consider reassigning the row and re-handling ${otherUid}.`
          : `row owner keeps it — users/${uid} needs a new handle.`)
      );
      continue;
    }
    if (DRY_RUN) {
      created++;
      continue;
    }
    await rowRef.set({ uid });
    created++;
  }

  console.log(`Done. rows ${DRY_RUN ? "would be " : ""}created: ${created}, already-correct: ${skipped}, collisions: ${collisions}, invalid handles: ${invalid}`);
  if (collisions > 0 || invalid > 0) process.exitCode = 2;
}

main().catch((err) => { console.error(err); process.exit(1); });
