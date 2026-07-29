// LIVE-STAGING probe: verify the DEPLOYED moderation pipeline enforces the
// 2026-07-28 isUnderageDisclosure hardening (system-review A.5 #1) with the
// intended threshold (<17). Self-cleaning.
// Run: node underage-live-probe.mjs   (ADC; staging only)
import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

const app = initializeApp({ credential: applicationDefault(), projectId: "toskastaging" });
const db = getFirestore(app);

// [slug, text, expectHeld]
const CASES = [
  ["turning15", "im turning 15 next month and he left me", true],
  ["collegefrosh", "im a freshman in college and still lost", false],
  ["seventeen", "im 17 years old and heartbroken", false],
];

let failed = 0;
for (const [slug, text, expectHeld] of CASES) {
  const ref = db.collection("posts").doc(`probe_underage_${slug}_${process.pid}`);
  await ref.set({
    authorId: "probe-nonexistent-uid",
    text,
    createdAt: FieldValue.serverTimestamp(),
    likeCount: 0, repostCount: 0, replyCount: 0,
    moderationStatus: "pending_validation",
  });
  let outcome = "timeout";
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const snap = await ref.get();
    if (!snap.exists) { outcome = "deleted"; break; }
    const d = snap.data();
    if (d.moderationStatus === "pending_review") { outcome = `held(${d.pendingReason})`; break; }
    if (d.moderationStatus === "live") { outcome = "live"; break; }
  }
  const ok = expectHeld
    ? outcome === "held(minor_safety)"
    : outcome === "live";
  if (!ok) failed++;
  console.log(`${ok ? "✓" : "✗ FAIL"} [${text}] => ${outcome} (expected ${expectHeld ? "held(minor_safety)" : "live"})`);
  const snap = await ref.get();
  if (snap.exists) await ref.delete();
}
console.log(failed === 0 ? "PROBE PASS" : `PROBE FAIL (${failed} case(s))`);
process.exit(failed === 0 ? 0 : 1);
