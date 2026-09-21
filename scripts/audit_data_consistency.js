// READ-ONLY data-consistency probe (2026-09-21 audit). Sweeps the live
// database for the orphan/drift classes the daily detectCounterDrift job
// does NOT cover. Writes nothing.
//
//   node scripts/audit_data_consistency.js <projectId>
//
// Checks:
//   A. post counters: likeCount / replyCount(live) / repostCount vs actual
//      subcollection + query counts (newest 100 non-repost posts)
//   B. orphaned reposts: isRepost docs whose original post is gone
//   C. dangling user refs: users/*/liked + saved entries whose post is gone
//   D. follow symmetry: A.following(B) without B.followers(A) + count drift
//   E. notifications pointing at deleted posts (sample)
const admin = require("../functions/node_modules/firebase-admin");
const project = process.argv[2];
if (!project) { console.error("usage: node audit_data_consistency.js <projectId>"); process.exit(1); }
admin.initializeApp({ projectId: project });
const db = admin.firestore();

let issues = 0;
const flag = (msg) => { issues++; console.log("✗", msg); };

(async () => {
  // ---- A: post counters --------------------------------------------------
  const posts = await db.collection("posts")
    .orderBy("createdAt", "desc").limit(150).get();
  const nonReposts = posts.docs.filter((d) => d.data().isRepost !== true).slice(0, 100);
  let counterChecked = 0;
  for (const p of nonReposts) {
    const d = p.data();
    // Skip the freshest posts — in-flight trigger increments look like drift.
    if (d.createdAt?.toMillis && Date.now() - d.createdAt.toMillis() < 10 * 60e3) continue;
    counterChecked++;
    const [likes, liveReplies, reposts] = await Promise.all([
      p.ref.collection("likes").count().get(),
      p.ref.collection("replies").where("moderationStatus", "==", "live").count().get(),
      db.collection("posts").where("isRepost", "==", true)
        .where("originalPostId", "==", p.id).count().get(),
    ]);
    const want = { likeCount: likes.data().count, replyCount: liveReplies.data().count, repostCount: reposts.data().count };
    for (const [k, actual] of Object.entries(want)) {
      const stored = d[k] ?? 0;
      if (stored !== actual) flag(`post ${p.id}: ${k} stored=${stored} actual=${actual}`);
    }
  }
  console.log(`A: counters checked on ${counterChecked} posts`);

  // ---- B: orphaned reposts ------------------------------------------------
  const repostDocs = await db.collection("posts")
    .where("isRepost", "==", true).limit(300).get();
  for (const r of repostDocs.docs) {
    const origId = r.data().originalPostId;
    if (!origId) { flag(`repost ${r.id}: no originalPostId`); continue; }
    const orig = await db.collection("posts").doc(origId).get();
    if (!orig.exists) flag(`repost ${r.id}: original ${origId} is GONE (orphan)`);
  }
  console.log(`B: ${repostDocs.size} reposts checked for orphaned originals`);

  // ---- C + D + E: per-user sweeps ----------------------------------------
  const users = await db.collection("users").limit(25).get();
  let danglingChecked = 0, symChecked = 0, notifChecked = 0;
  for (const u of users.docs) {
    for (const sub of ["liked", "saved"]) {
      const refs = await u.ref.collection(sub).limit(50).get();
      for (const r of refs.docs) {
        danglingChecked++;
        const post = await db.collection("posts").doc(r.id).get();
        if (!post.exists) flag(`users/${u.id}/${sub}/${r.id}: post is GONE (dangling ref)`);
      }
    }
    const following = await u.ref.collection("following").limit(50).get();
    for (const f of following.docs) {
      symChecked++;
      const mirror = await db.collection("users").doc(f.id)
        .collection("followers").doc(u.id).get();
      if (!mirror.exists) flag(`follow asymmetry: ${u.id} follows ${f.id} but no mirror follower doc`);
    }
    const storedFollowing = u.data().followingCount ?? 0;
    const actualFollowing = (await u.ref.collection("following").count().get()).data().count;
    if (storedFollowing !== actualFollowing)
      flag(`users/${u.id}: followingCount stored=${storedFollowing} actual=${actualFollowing}`);
    const storedFollowers = u.data().followerCount ?? 0;
    const actualFollowers = (await u.ref.collection("followers").count().get()).data().count;
    if (storedFollowers !== actualFollowers)
      flag(`users/${u.id}: followerCount stored=${storedFollowers} actual=${actualFollowers}`);
    const notifs = await u.ref.collection("notifications")
      .orderBy("createdAt", "desc").limit(25).get();
    for (const n of notifs.docs) {
      const pid = n.data().postId;
      if (!pid) continue;
      notifChecked++;
      const post = await db.collection("posts").doc(pid).get();
      if (!post.exists) flag(`users/${u.id}/notifications/${n.id}: post ${pid} is GONE`);
    }
  }
  console.log(`C: ${danglingChecked} liked/saved refs checked`);
  console.log(`D: ${symChecked} follow edges checked + counts on ${users.size} users`);
  console.log(`E: ${notifChecked} notifications checked`);

  console.log(issues === 0
    ? `\n✓ ${project}: NO consistency issues found`
    : `\n${issues} issue(s) found on ${project}`);
  process.exit(issues === 0 ? 0 : 2);
})().catch((e) => { console.error(e.message); process.exit(1); });
