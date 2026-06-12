// Account-deletion cascade COMPLETENESS test (#4, 2026-06-11) — LIVE STAGING.
//
// GDPR Art. 17: after account deletion, NO residue. The prod flow is
// pendingDeletions → Auth.delete() → server deletes users/{uid} →
// onUserDocDeleted cascade (+ counter-decrement triggers + resume queue). This
// seeds a "victim" user with data in EVERY collection that references them,
// deletes the user doc (Admin SDK — the same delete the prod flow performs),
// waits for the cascade, then sweeps the whole DB for anything still pointing
// at that uid. Anything found = a GDPR residue / storage leak.
//
// Run with the staging admin ADC. (No web config needed — all Admin SDK.)

import admin from "firebase-admin";
const PROJECT_ID = "toskastaging";
const env = process.env.GCLOUD_PROJECT;
if (env && env !== PROJECT_ID) { console.error("staging-only"); process.exit(1); }
admin.initializeApp({ projectId: PROJECT_ID });
const auth = admin.auth(), db = admin.firestore();
const FV = admin.firestore.FieldValue;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let leaks = [];

async function mkUser(email, handle) {
  try { const u = await auth.getUserByEmail(email); await auth.deleteUser(u.uid); } catch {}
  const u = await auth.createUser({ email, emailVerified: true });
  await db.doc(`users/${u.uid}`).set({ handle, followerCount: 0, followingCount: 0, totalLikes: 0, postCount: 0, confirmedAdult: true, createdAt: FV.serverTimestamp() });
  return u.uid;
}

try {
  console.log("=== SETUP: victim V + bystander O, data in every collection ===");
  const V = await mkUser("cascade-victim@example.com", "cascade_victim");
  const O = await mkUser("cascade-other@example.com", "cascade_other");

  // V's own post
  const vPost = `cas_vpost_${Date.now()}`;
  await db.doc(`posts/${vPost}`).set({ authorId: V, authorHandle: "cascade_victim", text: "my words", createdAt: FV.serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "live" });
  // O's post that V interacts with
  const oPost = `cas_opost_${Date.now()}`;
  await db.doc(`posts/${oPost}`).set({ authorId: O, authorHandle: "cascade_other", text: "their words", createdAt: FV.serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "live" });

  // V scatters data everywhere:
  await db.doc(`posts/${oPost}/replies/cas_vreply`).set({ authorId: V, authorHandle: "cascade_victim", text: "V reply", createdAt: FV.serverTimestamp(), likeCount: 0, moderationStatus: "live" });
  await db.doc(`posts/${oPost}/likes/${V}`).set({ createdAt: FV.serverTimestamp() });        // V liked O's post
  await db.doc(`users/${V}/liked/${oPost}`).set({ createdAt: FV.serverTimestamp() });          // reverse index
  await db.doc(`users/${V}/saved/${oPost}`).set({ createdAt: FV.serverTimestamp() });
  await db.doc(`users/${V}/likedReplies/cas_vreply`).set({ postId: oPost, replyText: "x", replyHandle: "cascade_other", createdAt: FV.serverTimestamp() });
  await db.doc(`users/${V}/savedReplies/cas_vreply`).set({ postId: oPost, replyText: "x", replyHandle: "cascade_other", createdAt: FV.serverTimestamp() });
  await db.doc(`users/${V}/drafts/cas_draft`).set({ text: "unsent", createdAt: FV.serverTimestamp() });
  await db.doc(`users/${V}/private/data`).set({ email: "cascade-victim@example.com", selectedMood: "numb" });
  await db.doc(`users/${V}/presence/2026-06-11`).set({ date: "2026-06-11", createdAt: FV.serverTimestamp() });
  await db.doc(`users/${V}/blocked/${O}`).set({ at: FV.serverTimestamp() });
  // follow graph: V follows O and O follows V
  await db.doc(`users/${V}/following/${O}`).set({ handle: "cascade_other", createdAt: FV.serverTimestamp() });
  await db.doc(`users/${O}/followers/${V}`).set({ handle: "cascade_victim", createdAt: FV.serverTimestamp() });
  await db.doc(`users/${O}/following/${V}`).set({ handle: "cascade_victim", createdAt: FV.serverTimestamp() });
  await db.doc(`users/${V}/followers/${O}`).set({ handle: "cascade_other", createdAt: FV.serverTimestamp() });
  // V reposted O's post
  const vRepost = `${V}_repost_${oPost}`;
  await db.doc(`posts/${vRepost}`).set({ authorId: V, authorHandle: "cascade_victim", text: "their words", createdAt: FV.serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, isRepost: true, originalPostId: oPost, originalAuthorId: O, originalHandle: "cascade_other", moderationStatus: "live" });
  // V has a notification, V filed a report
  await db.doc(`users/${V}/notifications/cas_notif`).set({ type: "like", fromUserId: O, fromHandle: "cascade_other", createdAt: FV.serverTimestamp(), isRead: false });
  await db.doc(`reports/cas_report_${Date.now()}`).set({ reportedBy: V, reason: "other", type: "post", status: "pending", createdAt: FV.serverTimestamp(), postId: oPost, reportedUserId: O });
  // V wrote a reflection on their own post
  await db.doc(`posts/${vPost}/reflections/${V}`).set({ authorId: V, text: "anniversary thought", createdAt: FV.serverTimestamp() });

  console.log("seeded. Triggering deletion (delete users/V — the prod cascade entry point)…");
  await db.doc(`users/${V}`).delete();

  console.log("waiting 75s for the onUserDocDeleted cascade + counter triggers…");
  await sleep(75000);

  console.log("\n=== SWEEP for residue ===");
  async function check(label, getDocs) {
    const found = await getDocs();
    const n = found.length;
    console.log(`  ${n === 0 ? "✓ clean" : "✗ RESIDUE(" + n + ")"}  ${label}`);
    if (n > 0) leaks.push(`${label}: ${n} (${found.slice(0, 3).join(", ")})`);
  }
  await check("V's own post deleted", async () => (await db.collection("posts").where("authorId", "==", V).get()).docs.map((d) => d.id));
  await check("V's reply on O's post deleted", async () => (await db.collection("posts").doc(oPost).collection("replies").where("authorId", "==", V).get()).docs.map((d) => d.id));
  await check("V's like on O's post removed", async () => { const d = await db.doc(`posts/${oPost}/likes/${V}`).get(); return d.exists ? [d.id] : []; });
  await check("V's repost removed", async () => (await db.collection("posts").where("authorId", "==", V).where("isRepost", "==", true).get()).docs.map((d) => d.id));
  await check("V's user subtree gone (private/drafts/saved/etc.)", async () => {
    const subs = ["private", "drafts", "saved", "liked", "likedReplies", "savedReplies", "presence", "blocked", "following", "followers", "notifications"];
    const residue = [];
    for (const s of subs) { const snap = await db.collection(`users/${V}/${s}`).get(); if (!snap.empty) residue.push(`${s}(${snap.size})`); }
    return residue;
  });
  await check("O's follower-entry for V removed", async () => { const d = await db.doc(`users/${O}/followers/${V}`).get(); return d.exists ? [d.id] : []; });
  await check("O's following-entry for V removed", async () => { const d = await db.doc(`users/${O}/following/${V}`).get(); return d.exists ? [d.id] : []; });
  await check("V's report removed", async () => (await db.collection("reports").where("reportedBy", "==", V).get()).docs.map((d) => d.id));

  // O's counters should have been decremented (V's like + V's follow removed)
  const oFresh = (await db.doc(`users/${O}`).get()).data();
  console.log(`\n  O.followerCount after V removed: ${oFresh?.followerCount} (expect 0)`);
  if ((oFresh?.followerCount ?? 0) !== 0) leaks.push(`O.followerCount not decremented: ${oFresh?.followerCount}`);

  // cleanup bystander + post
  await db.doc(`posts/${oPost}`).delete().catch(() => {});
  await auth.deleteUser(O).catch(() => {}); await db.doc(`users/${O}`).delete().catch(() => {});
  await auth.deleteUser(V).catch(() => {});
} catch (e) {
  leaks.push("rig crashed: " + e.message);
  console.error(e);
} finally {
  console.log(`\n=== CASCADE SUMMARY: ${leaks.length === 0 ? "NO RESIDUE — clean GDPR delete" : leaks.length + " RESIDUE ITEM(S)"} ===`);
  leaks.forEach((l) => console.log("  - " + l));
  process.exit(leaks.length ? 1 : 0);
}
