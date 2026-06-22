// One-off backfill: stamp moderationStatus="live" on every existing post
// in prod that doesn't already have one.
//
// Required because the new pending-review system gates feed reads on
// `moderationStatus == "live"` (firestore.rules). Without backfilling,
// the iOS feed query would return zero existing posts the moment the
// new rules deploy.
//
// Usage:
//   cd functions && GCLOUD_PROJECT=toskastaging node backfillModerationStatus.js [--dry-run]
//   cd functions && GCLOUD_PROJECT=toska-4ebf4 node backfillModerationStatus.js --prod
//
// Safe to re-run: only touches docs missing the field.

const admin = require("firebase-admin");

// Project must be chosen explicitly (no hardcoded prod default) so this
// can't accidentally run against prod. Mirrors backfillReplyModerationStatus.js.
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
console.log(`Backfilling post moderationStatus on project: ${PROJECT}`);

const db = admin.firestore();
const DRY_RUN = process.argv.includes("--dry-run");
const BATCH_SIZE = 400; // Firestore batch limit is 500 writes

(async () => {
  const snap = await db.collection("posts").get();
  console.log(`Found ${snap.size} total posts on ${PROJECT}.`);

  const needsBackfill = snap.docs.filter((d) => !d.get("moderationStatus"));
  console.log(`${needsBackfill.length} posts missing moderationStatus.`);
  if (needsBackfill.length === 0) {
    console.log("Nothing to do.");
    process.exit(0);
  }

  if (DRY_RUN) {
    console.log("\nDRY RUN — no writes. Sample of affected docs:");
    needsBackfill.slice(0, 5).forEach((d) => {
      const created = d.get("createdAt");
      console.log(`  ${d.id}  authorId=${d.get("authorId")}  createdAt=${created?.toDate?.()?.toISOString?.() || "(none)"}`);
    });
    process.exit(0);
  }

  let written = 0;
  for (let i = 0; i < needsBackfill.length; i += BATCH_SIZE) {
    const batch = db.batch();
    const chunk = needsBackfill.slice(i, i + BATCH_SIZE);
    chunk.forEach((d) => batch.update(d.ref, { moderationStatus: "live" }));
    await batch.commit();
    written += chunk.length;
    console.log(`  ...${written}/${needsBackfill.length}`);
  }

  console.log(`\n✔ Backfilled moderationStatus="live" on ${written} posts.`);
  process.exit(0);
})().catch((err) => {
  console.error("\n✖ backfill failed:", err.message);
  process.exit(1);
});
