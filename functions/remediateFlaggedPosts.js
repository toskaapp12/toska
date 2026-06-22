// Remediation: the first backfill (backfillModerationStatus.js) stamped
// EVERY existing post with moderationStatus="live", including any that
// were already flagged/concerning. Pre-rule-deploy, iOS hid flagged
// posts client-side; post-rule-deploy the rule defaults missing field
// to "live" and now serves them to everyone.
//
// This script finds posts with flagged=true OR concerningContent=true
// and flips them to pending_review with the appropriate pendingReason,
// matching what the new functions would have written had they fired
// on creation today.
//
// Usage:
//   cd functions && GCLOUD_PROJECT=toskastaging node remediateFlaggedPosts.js [--dry-run]
//   cd functions && GCLOUD_PROJECT=toska-4ebf4 node remediateFlaggedPosts.js --prod
//
// Idempotent: only touches docs whose moderationStatus is not already
// "pending_review".

const admin = require("firebase-admin");

// Project must be chosen explicitly (no hardcoded prod default) so this can't
// accidentally run against prod. Mirrors the backfill scripts.
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
console.log(`Remediating flagged posts on project: ${PROJECT}`);

const db = admin.firestore();
const DRY_RUN = process.argv.includes("--dry-run");

function mapFlagReason(r) {
  switch (r) {
    case "hate_speech":          return "abuse_hate";
    case "harassment":           return "abuse_harassment";
    case "targeted_threat":      return "abuse_threat";
    case "sexual_content":       return "abuse_sexual";
    case "personal_information": return "pii";
    case "contains_link":        return "abuse_link";
    case "spam_or_commercial":   return "abuse_spam";
    default:                     return "abuse";
  }
}

(async () => {
  // Two scans — one per legacy flag field. Firestore doesn't have OR
  // queries with multiple .where() on different fields, so we union
  // client-side. Small dataset (~14 posts in prod today) so a full
  // dual scan is fine.
  const [flaggedSnap, concerningSnap] = await Promise.all([
    db.collection("posts").where("flagged", "==", true).get(),
    db.collection("posts").where("concerningContent", "==", true).get(),
  ]);

  // Union the two snapshots by doc id.
  const byId = new Map();
  flaggedSnap.docs.forEach((d) => byId.set(d.id, d));
  concerningSnap.docs.forEach((d) => byId.set(d.id, d));

  const candidates = Array.from(byId.values()).filter((d) => {
    return d.get("moderationStatus") !== "pending_review";
  });

  console.log(`Found ${byId.size} flagged-or-concerning posts; ${candidates.length} need remediation.`);
  if (candidates.length === 0) {
    process.exit(0);
  }

  if (DRY_RUN) {
    console.log("\nDRY RUN — no writes. Affected docs:");
    candidates.forEach((d) => {
      const data = d.data();
      const reason = data.flagged === true ? mapFlagReason(data.flagReason) : "crisis";
      console.log(`  ${d.id}  → pending_review (${reason})  authorId=${data.authorId}`);
    });
    process.exit(0);
  }

  const batch = db.batch();
  for (const d of candidates) {
    const data = d.data();
    const reason = data.flagged === true ? mapFlagReason(data.flagReason) : "crisis";
    const detectedAt = data.flaggedAt || data.createdAt || admin.firestore.FieldValue.serverTimestamp();
    batch.update(d.ref, {
      moderationStatus: "pending_review",
      pendingReason: reason,
      pendingDetectedAt: detectedAt,
    });
  }
  await batch.commit();

  console.log(`\n✔ Remediated ${candidates.length} posts.`);
  process.exit(0);
})().catch((err) => {
  console.error("\n✖ remediation failed:", err.message);
  process.exit(1);
});
