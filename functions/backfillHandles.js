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

  // 2026-07-28 (A.5 #6): decide same-run duplicates BEFORE writing anything.
  // Previously the winner of a same-run duplicate was whichever user doc
  // iterated first (Firestore doc-id order), contradicting the header's
  // "older account keeps the handle" policy. Group by lowercased handle and
  // sort each group by createdAt (missing createdAt loses; a full tie falls
  // back to doc-id order so re-runs are deterministic).
  const byHandle = new Map();
  for (const userDoc of usersSnap.docs) {
    const handle = userDoc.data().handle;
    if (typeof handle !== "string" || !VALID_HANDLE.test(handle)) {
      invalid++;
      console.warn(`INVALID handle on users/${userDoc.id}: ${JSON.stringify(handle)} — fix manually`);
      continue;
    }
    const key = handle.toLowerCase();
    if (!byHandle.has(key)) byHandle.set(key, []);
    byHandle.get(key).push(userDoc);
  }

  for (const [key, docs] of byHandle) {
    docs.sort((a, b) => {
      const am = a.data().createdAt?.toMillis?.() ?? Infinity;
      const bm = b.data().createdAt?.toMillis?.() ?? Infinity;
      if (am !== bm) return am - bm;
      return a.id < b.id ? -1 : 1;
    });
    const winner = docs[0];
    for (const loser of docs.slice(1)) {
      collisions++;
      console.warn(
        `SAME-RUN COLLISION on "${key}": older users/${winner.id} keeps it — ` +
        `users/${loser.id} (createdAt ${loser.data().createdAt?.toMillis?.() ?? "missing"}) needs a new handle.`
      );
    }

    const rowRef = db.collection("handles").doc(key);
    if (DRY_RUN) {
      const rowSnap = await rowRef.get();
      if (!rowSnap.exists) created++;
      else if (rowSnap.data().uid === winner.id) skipped++;
      else await reportExistingRowCollision(key, rowSnap.data().uid, winner);
      continue;
    }
    // 2026-07-28 (A.5 #6): transactional create-if-absent. The old plain
    // get()-then-set() could silently OVERWRITE a row a live signup claimed
    // between the two reads — stealing the new user's handle. The transaction
    // re-checks under lock and never overwrites an existing row.
    const outcome = await db.runTransaction(async (tx) => {
      const snap = await tx.get(rowRef);
      if (!snap.exists) {
        tx.set(rowRef, { uid: winner.id });
        return "created";
      }
      return snap.data().uid === winner.id ? "skipped" : `owned:${snap.data().uid}`;
    });
    if (outcome === "created") created++;
    else if (outcome === "skipped") skipped++;
    else await reportExistingRowCollision(key, outcome.slice("owned:".length), winner);
  }

  // Pre-existing-row collision (row already owned by a different uid):
  // advisory only, per the header — renaming a user's identity is an owner
  // decision, not a script's.
  async function reportExistingRowCollision(handle, ownerUid, winnerDoc) {
    collisions++;
    const ownerSnap = await db.collection("users").doc(ownerUid).get();
    const ownerCreated = ownerSnap.exists ? ownerSnap.data().createdAt?.toMillis?.() : null;
    const winnerCreated = winnerDoc.data().createdAt?.toMillis?.() ?? null;
    console.warn(
      `COLLISION on "${handle}": row owned by ${ownerUid} (createdAt ${ownerCreated}), ` +
      `also carried by ${winnerDoc.id} (createdAt ${winnerCreated}). ` +
      ((winnerCreated != null && ownerCreated != null && winnerCreated < ownerCreated)
        ? `users/${winnerDoc.id} is OLDER — consider reassigning the row and re-handling ${ownerUid}.`
        : `row owner keeps it — users/${winnerDoc.id} needs a new handle.`)
    );
  }

  console.log(`Done. rows ${DRY_RUN ? "would be " : ""}created: ${created}, already-correct: ${skipped}, collisions: ${collisions}, invalid handles: ${invalid}`);
  if (collisions > 0 || invalid > 0) process.exitCode = 2;
}

main().catch((err) => { console.error(err); process.exit(1); });
