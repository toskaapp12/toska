// Full-app-test backend layer (STAGING). Exercises the deployed Cloud Functions
// end-to-end with throwaway accounts A/B, records outcomes, cleans up after.
// Covers: moderation enforcement (validatePost), counter triggers, crisis path.
// Run from functions/:  GOOGLE_CLOUD_PROJECT=toskastaging node ../firestore-tests/fulltest-backend-probe.mjs
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

initializeApp({ projectId: "toskastaging" });
const db = getFirestore();
const run = Date.now().toString(36);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const A = `ft_a_${run}`, B = `ft_b_${run}`;
const created = { posts: [], users: [A, B], misc: [] };
const log = [];
const rec = (section, name, verdict, detail) => { log.push({ section, name, verdict, detail }); console.log(`[${section}] ${verdict}  ${name}${detail ? " — " + detail : ""}`); };

async function mkUser(uid) {
  await db.collection("users").doc(uid).set({ handle: `handle_${uid}`, confirmedAdult: true, allowSharing: false, followerCount: 0, followingCount: 0, totalLikes: 0 });
}
async function mkPost(id, authorId, text, extra = {}) {
  await db.collection("posts").doc(id).set({
    authorId, authorHandle: `handle_${authorId}`, text, moderationStatus: "pending_validation",
    isRepost: false, likeCount: 0, replyCount: 0, repostCount: 0, createdAt: FieldValue.serverTimestamp(), ...extra,
  });
  created.posts.push(id);
}
const getPost = async (id) => (await db.collection("posts").doc(id).get()).data();

try {
  await mkUser(A); await mkUser(B);

  // ---------- 4. Moderation enforcement (validatePost) ----------
  const cases = [
    ["clean",  "today was hard but i am slowly feeling a little lighter than i did before", "live"],
    ["name",   "Sarah broke up with me last week and i cannot stop crying about it", "held"],
    ["phone",  "call me 555-123-4567 if you ever want to talk about it", "held"],
    ["email",  "you can reach me at someone@example.com whenever you want", "held"],
    ["link",   "i found example.com really helpful for getting through this", "held"],
    ["crisis", "i want to kill myself tonight i cannot do this anymore", "pending_review"],
  ];
  const ids = {};
  for (const [kind, text] of cases) { const id = `ftpost_${kind}_${run}`; ids[kind] = id; await mkPost(id, A, text); }
  console.log("moderation posts created; waiting 12s for validatePost…");
  await sleep(12000);
  for (const [kind, , expect] of cases) {
    const d = await getPost(ids[kind]);
    const ms = d?.moderationStatus ?? "(deleted/missing)";
    const reason = d?.pendingReason || d?.flagReason || d?.concerningContent || "";
    // clean must be live; everything else must NOT be plain "live"
    const ok = kind === "clean" ? ms === "live" : (ms !== "live");
    rec("4-moderation", `${kind} → ${ms}${reason ? " ("+reason+")" : ""}`, ok ? "PASS" : "FAIL", `expected ~${expect}`);
  }
  // crisis alert dedup claim present?
  const claim = await db.collection("processedTriggerEvents").doc(`crisisAlert_${ids.crisis}`).get();
  rec("4-moderation", "crisis alert path fired (processedTriggerEvents/crisisAlert_<id>)", claim.exists ? "PASS" : "FAIL", claim.exists ? "claim doc present" : "no claim doc");
  if (claim.exists) created.misc.push(["processedTriggerEvents", `crisisAlert_${ids.crisis}`]);

  // ---------- 7. Counter triggers ----------
  const P = `ftcnt_${run}`; await mkPost(P, B, "a calm clean post for counter testing only nothing here");
  await sleep(6000); // let it promote to live
  // like
  await db.collection("posts").doc(P).collection("likes").doc(A).set({ createdAt: FieldValue.serverTimestamp(), userId: A });
  await sleep(5000);
  let after = await getPost(P); const likeUp = after.likeCount;
  await db.collection("posts").doc(P).collection("likes").doc(A).delete();
  await sleep(5000);
  after = await getPost(P); const likeDown = after.likeCount;
  rec("7-counters", `felt: ${0}→${likeUp}→${likeDown}`, (likeUp === 1 && likeDown === 0) ? "PASS" : "FAIL");
  // reply
  const R = `ftreply_${run}`;
  await db.collection("posts").doc(P).collection("replies").doc(R).set({ authorId: A, authorHandle: `handle_${A}`, text: "a gentle reply for counting", moderationStatus: "pending_validation", likeCount: 0, createdAt: FieldValue.serverTimestamp() });
  await sleep(7000);
  after = await getPost(P);
  rec("7-counters", `reply count → ${after.replyCount}`, after.replyCount === 1 ? "PASS" : "FAIL");
  // repost
  const RP = `${A}_repost_${P}`;
  await db.collection("posts").doc(RP).set({ authorId: A, authorHandle: `handle_${A}`, text: after.text, isRepost: true, originalPostId: P, originalAuthorId: B, moderationStatus: "pending_validation", likeCount: 0, replyCount: 0, repostCount: 0, createdAt: FieldValue.serverTimestamp() });
  created.posts.push(RP);
  await sleep(6000);
  after = await getPost(P); const repUp = after.repostCount;
  await db.collection("posts").doc(RP).delete();
  await sleep(5000);
  after = await getPost(P); const repDown = after.repostCount;
  rec("7-counters", `repost: 0→${repUp}→${repDown}`, (repUp === 1 && repDown === 0) ? "PASS" : "FAIL");
} catch (e) {
  rec("probe", "harness error", "FAIL", e.message);
} finally {
  for (const id of created.posts) {
    const reps = await db.collection("posts").doc(id).collection("replies").listDocuments().catch(() => []);
    for (const r of reps) await r.delete().catch(() => {});
    const lks = await db.collection("posts").doc(id).collection("likes").listDocuments().catch(() => []);
    for (const l of lks) await l.delete().catch(() => {});
    await db.collection("posts").doc(id).delete().catch(() => {});
  }
  for (const [c, d] of created.misc) await db.collection(c).doc(d).delete().catch(() => {});
  for (const u of created.users) await db.collection("users").doc(u).delete().catch(() => {});
  console.log("cleaned up.");
}
const fails = log.filter((l) => l.verdict === "FAIL");
console.log(`\n${log.length - fails.length}/${log.length} PASS`);
