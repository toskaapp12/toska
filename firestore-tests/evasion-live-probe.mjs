// LIVE-STAGING probe: verify the DEPLOYED pipeline enforces the 2026-07-28
// matchesEvasionRegex alignment (system-review A.5 #2) — padded/extra-leet
// hate must be held, innocent emphasis padding must go live. Self-cleaning.
// Run: node evasion-live-probe.mjs   (ADC; staging only)
import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

const app = initializeApp({ credential: applicationDefault(), projectId: "toskastaging" });
const db = getFirestore(app);

// [slug, text, expectedOutcome]  outcome: "held(<reason>)" | "live"
const CASES = [
  // index.js maps flagReason hate_speech -> pendingReason "abuse_hate"
  ["padslur", "you dirty spiccc", "held(abuse_hate)"],
  ["deleet", "you 9ook", "held(abuse_hate)"],
  ["emphasis", "im soooo tired of all this", "live"],
];

let failed = 0;
for (const [slug, text, expected] of CASES) {
  const ref = db.collection("posts").doc(`probe_evasion_${slug}_${process.pid}`);
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
  const ok = outcome === expected;
  if (!ok) failed++;
  console.log(`${ok ? "✓" : "✗ FAIL"} [${text}] => ${outcome} (expected ${expected})`);
  const snap = await ref.get();
  if (snap.exists) await ref.delete();
}
console.log(failed === 0 ? "PROBE PASS" : `PROBE FAIL (${failed} case(s))`);
process.exit(failed === 0 ? 0 : 1);
