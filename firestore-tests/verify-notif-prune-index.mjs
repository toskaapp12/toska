// Read-only verification that the notifications collectionGroup createdAt index
// serves the pruneOldNotifications query. NO writes, NO deletes. Uses Admin SDK
// (bypasses rules) — the point is the INDEX, not rules. Run against a project via
//   GOOGLE_CLOUD_PROJECT=toskastaging node verify-notif-prune-index.mjs
import admin from "firebase-admin";
const PROJECT = process.env.GOOGLE_CLOUD_PROJECT || process.env.GCLOUD_PROJECT;
if (!PROJECT) { console.error("set GOOGLE_CLOUD_PROJECT"); process.exit(1); }
admin.initializeApp({ projectId: PROJECT });
const db = admin.firestore();
const cutoff = admin.firestore.Timestamp.fromDate(new Date(Date.now() - 90 * 24 * 60 * 60 * 1000));
try {
  const snap = await db.collectionGroup("notifications").where("createdAt", "<", cutoff).limit(1).get();
  console.log(`✓ [${PROJECT}] prune query executed WITHOUT FAILED_PRECONDITION (matched ${snap.size} doc(s), read-only)`);
  process.exit(0);
} catch (e) {
  console.error(`✗ [${PROJECT}] prune query FAILED: ${e.code || ""} ${e.message}`);
  process.exit(1);
}
