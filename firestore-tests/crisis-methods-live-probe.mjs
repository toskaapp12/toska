// LIVE-STAGING probe: verify the DEPLOYED pipeline enforces the 2026-07-28
// crisis-list extension (system-review A.5 #3) with correct TIER semantics:
//   explicit method language -> held + concerningContent + PAGE path
//   soft method language     -> held + concerningContent, NOT paged
//   idiom/goodbye-letter controls -> live, untouched
// Paging leaves a claim doc (processedTriggerEvents/crisisAlert_<postId>) only
// after a SUCCESSFUL FCM send, so on staging that check is INFORMATIONAL (a
// missing staging admin token is a pre-existing env condition, not a list
// regression). Self-cleaning. Run: node crisis-methods-live-probe.mjs (ADC)
import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

const app = initializeApp({ credential: applicationDefault(), projectId: "toskastaging" });
const db = getFirestore(app);

// [slug, text, expected]  expected: "held" | "live"; pageExpected only checked
// informationally for the explicit case.
const CASES = [
  ["explicit", "i want to slit my wrists", "held", { explicit: true }],
  ["soft", "keep thinking about a noose", "held", { explicit: false }],
  ["idiom", "gun to my head i couldnt say why we broke up", "live", {}],
  ["goodbyeletter", "wrote a goodbye letter to my ex today", "live", {}],
];

let failed = 0;
for (const [slug, text, expected, opts] of CASES) {
  const ref = db.collection("posts").doc(`probe_crisismethod_${slug}_${process.pid}`);
  const claimRef = db.collection("processedTriggerEvents").doc(`crisisAlert_${ref.id}`);
  await ref.set({
    authorId: "probe-nonexistent-uid",
    text,
    createdAt: FieldValue.serverTimestamp(),
    likeCount: 0, repostCount: 0, replyCount: 0,
    moderationStatus: "pending_validation",
  });
  let outcome = "timeout";
  let concerning = null;
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const snap = await ref.get();
    if (!snap.exists) { outcome = "deleted"; break; }
    const d = snap.data();
    if (d.moderationStatus === "pending_review") {
      outcome = "held"; concerning = d.concerningContent === true; break;
    }
    if (d.moderationStatus === "live") { outcome = "live"; break; }
  }
  let ok = outcome === expected;
  if (ok && expected === "held" && concerning !== true) ok = false;
  if (!ok) failed++;
  let pageNote = "";
  if (opts.explicit !== undefined) {
    // Give the alert trigger a moment, then check the page-claim doc.
    await new Promise((r) => setTimeout(r, 5000));
    const claimed = (await claimRef.get()).exists;
    if (opts.explicit) {
      pageNote = claimed
        ? " [paged: claim doc present]"
        : " [page claim ABSENT — check staging admin FCM token / function logs]";
    } else if (claimed) {
      ok = false; failed++;
      pageNote = " [FAIL: soft tier PAGED — claim doc present]";
    } else {
      pageNote = " [not paged, correct]";
    }
  }
  console.log(`${ok ? "✓" : "✗ FAIL"} [${text}] => ${outcome}${expected === "held" ? ` concerning=${concerning}` : ""}${pageNote}`);
  const snap = await ref.get();
  if (snap.exists) await ref.delete();
  const claim = await claimRef.get();
  if (claim.exists) await claimRef.delete();
}
console.log(failed === 0 ? "PROBE PASS" : `PROBE FAIL (${failed} case(s))`);
process.exit(failed === 0 ? 0 : 1);
