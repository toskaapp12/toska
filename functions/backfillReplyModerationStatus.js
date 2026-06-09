// One-off backfill (M-1, 2026-06-08 audit): stamp moderationStatus="live" on
// every existing REPLY that doesn't already have one.
//
// Required because the new reply pending-review hold gates reply reads on
// `moderationStatus == "live"` (firestore.rules) and the iOS thread reads
// replies with a `.where("moderationStatus", "==", "live")` query. An equality
// filter does NOT match docs missing the field, so without this backfill every
// existing reply would vanish from threads the moment the new rules + client
// deploy.
//
// DEPLOY ORDER: run this BEFORE deploying the new firestore.rules / client.
//
// Usage:
//   cd functions && node backfillReplyModerationStatus.js [--dry-run]
//
// Paginated over the collectionGroup("replies") by document name so it scales
// past a single .get(). Safe to re-run: only touches docs missing the field.

const admin = require("firebase-admin");

// Project must be chosen explicitly (no hardcoded prod default) so this
// can't accidentally run against prod. Pass via GCLOUD_PROJECT, e.g.
//   GCLOUD_PROJECT=toskastaging node backfillReplyModerationStatus.js --dry-run
// Running against prod (toska-4ebf4) additionally requires --prod.
const PROJECT = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
if (!PROJECT) {
  console.error("Set GCLOUD_PROJECT (e.g. toskastaging or toska-4ebf4).");
  process.exit(1);
}
if (PROJECT === "toska-4ebf4" && !process.argv.includes("--prod")) {
  console.error("Refusing to run against prod without --prod. (project=toska-4ebf4)");
  process.exit(1);
}
admin.initializeApp({ projectId: PROJECT });
console.log(`Backfilling reply moderationStatus on project: ${PROJECT}`);

const db = admin.firestore();
const DRY_RUN = process.argv.includes("--dry-run");
const PAGE_SIZE = 500;
const BATCH_SIZE = 400; // Firestore batch limit is 500 writes

(async () => {
  let lastDoc = null;
  let scanned = 0;
  let written = 0;
  let sampleShown = 0;

  // eslint-disable-next-line no-constant-condition
  while (true) {
    let q = db.collectionGroup("replies").orderBy("__name__").limit(PAGE_SIZE);
    if (lastDoc) q = q.startAfter(lastDoc);
    const snap = await q.get();
    if (snap.empty) break;
    scanned += snap.size;
    lastDoc = snap.docs[snap.docs.length - 1];

    const needsBackfill = snap.docs.filter((d) => !d.get("moderationStatus"));

    if (DRY_RUN) {
      for (const d of needsBackfill) {
        if (sampleShown < 5) {
          console.log(`  would set live: ${d.ref.path}  authorId=${d.get("authorId")}`);
          sampleShown++;
        }
      }
      written += needsBackfill.length;
    } else {
      for (let i = 0; i < needsBackfill.length; i += BATCH_SIZE) {
        const batch = db.batch();
        needsBackfill.slice(i, i + BATCH_SIZE)
          .forEach((d) => batch.update(d.ref, { moderationStatus: "live" }));
        await batch.commit();
        written += Math.min(BATCH_SIZE, needsBackfill.length - i);
      }
    }

    console.log(`  ...scanned ${scanned}, ${DRY_RUN ? "would backfill" : "backfilled"} ${written}`);
    if (snap.size < PAGE_SIZE) break;
  }

  if (DRY_RUN) {
    console.log(`\nDRY RUN — no writes. ${written} of ${scanned} replies need moderationStatus.`);
  } else {
    console.log(`\n✔ Backfilled moderationStatus="live" on ${written} of ${scanned} replies.`);
  }
  process.exit(0);
})().catch((err) => {
  console.error("\n✖ reply backfill failed:", err.message);
  process.exit(1);
});
