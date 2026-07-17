// auditReplyModeration + auditUserRestriction scrub probe (2026-07-17).
// Runs against DEPLOYED staging (ADC, not the emulator) to prove:
//   1. A reply going live with pendingApprovedBy (web admin approve shape)
//      gets a reply.approve adminAuditLog entry AND the stamp scrubbed.
//   2. Re-restricting an already-restricted user (restricted unchanged)
//      still gets restrictedBy scrubbed (the hoisted-scrub fix).
// Usage: node firestore-tests/audit-reply-scrub-probe.mjs
import admin from "firebase-admin";
admin.initializeApp({ projectId: "toskastaging" });
const db = admin.firestore();
const FV = admin.firestore.FieldValue;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const U = "auditprobe_u", P = "auditprobe_p", R = "auditprobe_r";
const postShape = {
  createdAt: FV.serverTimestamp(), moderationStatus: "live",
  likeCount: 0, replyCount: 0, repostCount: 0,
  authorId: U, authorHandle: "auditprobe_h",
  text: "some doors close so quietly you only hear it later.",
};

// Poll until pred(data) or timeout; returns final data.
async function waitFor(ref, pred, label, timeoutMs = 60000) {
  const start = Date.now();
  for (;;) {
    const d = (await ref.get()).data();
    if (pred(d)) return d;
    if (Date.now() - start > timeoutMs) throw new Error(`TIMEOUT waiting for ${label}: ${JSON.stringify(d)}`);
    await sleep(3000);
  }
}

let failed = false;
const check = (ok, label) => { console.log(`${ok ? "PASS" : "FAIL"}: ${label}`); if (!ok) failed = true; };

// --- setup ---
await db.doc(`users/${U}`).set({
  handle: "auditprobe_h", followerCount: 0, followingCount: 0, totalLikes: 0,
  postCount: 1, confirmedAdult: true, createdAt: FV.serverTimestamp(),
});
await db.doc(`posts/${P}`).set(postShape);
await db.doc(`posts/${P}/replies/${R}`).set({
  authorId: U, authorHandle: "auditprobe_h", createdAt: FV.serverTimestamp(),
  likeCount: 0, moderationStatus: "pending_review", pendingReason: "pii",
  pendingDetectedAt: FV.serverTimestamp(), text: "you can reach me any time, i mean it.",
});
await sleep(5000); // let create-triggers settle

// --- 1: simulate web admin approvePendingReply ---
const replyRef = db.doc(`posts/${P}/replies/${R}`);
await replyRef.update({
  moderationStatus: "live",
  pendingApprovedAt: FV.serverTimestamp(), pendingApprovedBy: "probe_admin",
  pendingReason: FV.delete(), pendingDetectedAt: FV.delete(),
});
const reply = await waitFor(replyRef, (d) => d && d.pendingApprovedBy == null, "reply stamp scrub");
check(reply.pendingApprovedBy == null, "pendingApprovedBy scrubbed off live reply");
check(reply.moderationStatus === "live", "reply still live after scrub");
await sleep(2000);
const audit = await db.collection("adminAuditLog")
  .where("action", "==", "reply.approve")
  .where("targetId", "==", `${P}/${R}`).get();
check(!audit.empty, "reply.approve adminAuditLog entry written");
check(audit.docs.every((d) => d.data().adminUid === "probe_admin"), "audit entry attributes probe_admin");

// --- 2: re-restrict with restricted unchanged ---
const userRef = db.doc(`users/${U}`);
await userRef.update({ restricted: true, restrictedAt: FV.serverTimestamp(), restrictedBy: "probe_admin" });
await waitFor(userRef, (d) => d && d.restrictedBy == null, "first restrictedBy scrub");
await userRef.update({ restricted: true, restrictedAt: FV.serverTimestamp(), restrictedBy: "probe_admin_2" });
const user = await waitFor(userRef, (d) => d && d.restrictedBy == null, "re-restrict restrictedBy scrub");
check(user.restrictedBy == null, "restrictedBy scrubbed on re-restrict (restricted unchanged)");
check(user.restricted === true, "restricted flag survives scrub");

// --- cleanup ---
await replyRef.delete();
await db.doc(`posts/${P}`).delete();
await userRef.delete();
for (const d of audit.docs) await d.ref.delete();
console.log(failed ? "PROBE FAILED" : "PROBE PASSED — cleanup done");
process.exit(failed ? 1 : 0);
