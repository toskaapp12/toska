// LIVE-STAGING probe: verify the DEPLOYED moderation pipeline catches the
// 2026-07-17 red-team additions ("kms" soft tier). Self-cleaning.
// Run: node crisis-list-live-probe.mjs   (ADC; staging only)
import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

const app = initializeApp({ credential: applicationDefault(), projectId: "toskastaging" });
const db = getFirestore(app);

const ref = db.collection("posts").doc(`probe_crisislist_${process.pid}`);
await ref.set({
  authorId: "probe-nonexistent-uid",
  text: "honestly kms",
  createdAt: FieldValue.serverTimestamp(),
  likeCount: 0, repostCount: 0, replyCount: 0,
  moderationStatus: "pending_validation",
});
console.log("probe post created:", ref.id);

let ok = false;
for (let i = 0; i < 20; i++) {
  await new Promise((r) => setTimeout(r, 3000));
  const snap = await ref.get();
  if (!snap.exists) { console.log("post deleted by pipeline (also acceptable)"); ok = true; break; }
  const d = snap.data();
  if (d.moderationStatus === "pending_review" && d.concerningContent === true) {
    console.log(`HELD as expected: status=${d.moderationStatus} pendingReason=${d.pendingReason} concerningContent=${d.concerningContent}`);
    ok = true; break;
  }
  if (d.moderationStatus === "live") { console.log("FAIL: promoted to LIVE — deployed lists missing the addition"); break; }
}
const snap = await ref.get();
if (snap.exists) await ref.delete();
console.log(ok ? "PROBE PASS" : "PROBE FAIL (still pending_validation after 60s or went live)");
process.exit(ok ? 0 : 1);
