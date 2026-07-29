// One-off backfill (2026-07-28 A.5 #9 migration, phase 3): for every existing
// users/{uid} doc, mirror the moderation / adult-gate fields into
// users/{uid}/private/data and create the restrictedUsers/{uid} admin-index
// row for currently-restricted accounts — the same writes the
// mirrorModerationState trigger performs for all FUTURE user-doc writes.
// Idempotent: merge-writes the same values the trigger would.
//
// NOTE: restrictedBy is usually ABSENT on the main doc (auditUserRestriction
// scrubs it after attribution — M-1), so pre-existing restrictions may mirror
// without attribution; the adminAuditLog remains the attribution source for
// those.
//
// Usage:
//   cd functions && GCLOUD_PROJECT=toskastaging node backfillModerationMirror.js [--dry-run]
//   cd functions && GCLOUD_PROJECT=toska-4ebf4 node backfillModerationMirror.js --prod
const admin = require("firebase-admin");

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
console.log(`Backfilling moderation mirror on project: ${PROJECT}${DRY_RUN ? " (dry run)" : ""}`);

const MIRRORED = ["restricted", "restrictedAt", "restrictedUntil", "confirmedAdult", "confirmedAdultAt"];

async function main() {
  let mirrored = 0;
  let restrictedRows = 0;
  let skipped = 0;

  // Paginated (unlike the older one-off scripts — §10.2 OOM note).
  let last = null;
  for (;;) {
    let q = db.collection("users").orderBy("__name__").limit(300);
    if (last) q = q.startAfter(last);
    const snap = await q.get();
    if (snap.empty) break;
    for (const userDoc of snap.docs) {
      const data = userDoc.data();
      const mirror = {};
      for (const f of MIRRORED) if (data[f] !== undefined) mirror[f] = data[f];
      if (data.restrictedBy != null) mirror.restrictedBy = data.restrictedBy;
      if (Object.keys(mirror).length === 0) { skipped++; continue; }
      if (!DRY_RUN) {
        await db.doc(`users/${userDoc.id}/private/data`).set(mirror, { merge: true });
      }
      mirrored++;
      if (data.restricted === true) {
        if (!DRY_RUN) {
          const row = {
            handle: data.handle ?? null,
            restrictedAt: data.restrictedAt ?? null,
            restrictedUntil: data.restrictedUntil ?? null,
          };
          if (data.restrictedBy != null) row.restrictedBy = data.restrictedBy;
          await db.doc(`restrictedUsers/${userDoc.id}`).set(row, { merge: true });
        }
        restrictedRows++;
      }
    }
    last = snap.docs[snap.docs.length - 1];
  }

  console.log(`Done. ${DRY_RUN ? "would mirror" : "mirrored"}: ${mirrored}, restricted index rows: ${restrictedRows}, nothing-to-mirror: ${skipped}`);
}

main().catch((err) => { console.error(err); process.exit(1); });
