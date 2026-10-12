// LIVE PROD probe — onPostDeletedCleanupSubtree under firebase-admin 14.
//
// Build-91→92 review (2026-10-07): PostDetailView no longer enumerates or
// deletes post likes client-side (de-anon fix 18be8bf); post deletion now
// relies ENTIRELY on the deployed onPostDeletedCleanupSubtree trigger.
// The functions runtime was bumped firebase-admin 13→14 / functions 7.2→7.4
// and deployed 2026-10-03 — this probe proves the trigger still drains the
// subtree (likes, replies, reply-likes) in prod after the bump.
//
// Entirely synthetic uids/doc ids; post is held_for_review (never visible
// to non-admins); self-cleaning on every exit path.
import admin from "firebase-admin";

const PROJECT_ID = "toska-4ebf4";
admin.initializeApp({ projectId: PROJECT_ID });
const db = admin.firestore();

const stamp = Date.now();
const postId = `probe_cleanup_${stamp}`;
const authorUid = `probe_uid_${stamp}`;
const postRef = db.collection("posts").doc(postId);

let failures = 0;
const ok = (m) => console.log(`✓ ${m}`);
const bad = (m) => { failures++; console.error(`✗ ${m}`); };

async function residue() {
  const [likes, replies] = await Promise.all([
    postRef.collection("likes").get(),
    postRef.collection("replies").get(),
  ]);
  let replyLikes = 0;
  for (const r of replies.docs) {
    replyLikes += (await r.ref.collection("likes").get()).size;
  }
  return { likes: likes.size, replies: replies.size, replyLikes };
}

async function hardCleanup() {
  // Belt and braces regardless of trigger outcome.
  const subtrees = [
    postRef.collection("replies").doc("probe_reply_1").collection("likes"),
    postRef.collection("replies"),
    postRef.collection("likes"),
    postRef.collection("reflections"),
  ];
  for (const col of subtrees) {
    const snap = await col.get();
    for (const d of snap.docs) await d.ref.delete();
  }
  await postRef.delete();
  // Synthetic author's notification/user residue from like/reply triggers.
  const userRef = db.collection("users").doc(authorUid);
  const notifs = await userRef.collection("notifications").get();
  for (const d of notifs.docs) await d.ref.delete();
  await userRef.delete();
}

try {
  // 1. Seed post + subtree.
  await postRef.set({
    authorId: authorUid, authorHandle: "probe_handle", text: "probe cleanup check",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    moderationStatus: "held_for_review", isShareable: false,
    likeCount: 0, replyCount: 0, repostCount: 0,
  });
  await postRef.collection("likes").doc("probe_liker_a").set({ createdAt: admin.firestore.FieldValue.serverTimestamp() });
  await postRef.collection("likes").doc("probe_liker_b").set({ createdAt: admin.firestore.FieldValue.serverTimestamp() });
  const replyRef = postRef.collection("replies").doc("probe_reply_1");
  await replyRef.set({
    authorId: authorUid, authorHandle: "probe_handle", text: "probe reply",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    moderationStatus: "held_for_review", likeCount: 0,
  });
  await replyRef.collection("likes").doc("probe_liker_c").set({ createdAt: admin.firestore.FieldValue.serverTimestamp() });
  const before = await residue();
  if (before.likes === 2 && before.replies === 1 && before.replyLikes === 1) {
    ok(`seeded subtree (likes=2, replies=1, replyLikes=1)`);
  } else {
    bad(`seed mismatch: ${JSON.stringify(before)}`);
  }

  // 2. Delete the post doc — exactly what PostDetailView now does last.
  await postRef.delete();
  ok("post doc deleted; waiting for onPostDeletedCleanupSubtree…");

  // 3. Poll up to 120s for the trigger to drain the subtree.
  let drained = null;
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    await new Promise(r => setTimeout(r, 3000));
    const r = await residue();
    process.stdout.write(`  …likes=${r.likes} replies=${r.replies} replyLikes=${r.replyLikes}\n`);
    if (r.likes === 0 && r.replies === 0 && r.replyLikes === 0) { drained = Date.now(); break; }
  }
  if (drained) ok(`subtree fully drained by trigger (admin-14 prod) in ${(120_000 - (deadline - drained)) / 1000}s`);
  else bad("subtree NOT drained within 120s — trigger regression or dead-letter; check function logs");
} catch (e) {
  bad(`probe error: ${e.message}`);
} finally {
  await hardCleanup().catch(e => console.error("cleanup error:", e.message));
  console.log(failures ? "RESULT: FAIL" : "RESULT: PASS");
  process.exit(failures ? 1 : 0);
}
