// Launch-day reseed (2026-09-15). Replaces every pre-launch post on prod with
// the content in seedLaunchContent.json. Admin SDK (rules bypassed), so
// shapes mirror the July seed exactly; Cloud Function triggers still fire on
// these writes (cascades on delete, counters on reply create).
//
//   node seedLaunchContent.js --delete   # remove ALL current posts (+cascade)
//   node seedLaunchContent.js --seed     # write posts + replies from the JSON
//   node seedLaunchContent.js --counters # set replyCount/totalLikes from source
//   node seedLaunchContent.js --verify   # read-only listing
//
// Run in that order with a minute between phases so triggers settle.
const admin = require("firebase-admin");
const fs = require("fs");
admin.initializeApp({ projectId: process.env.PROJECT || "toska-4ebf4" });
const db = admin.firestore();
const { Timestamp, FieldValue } = admin.firestore;
const C = JSON.parse(fs.readFileSync(__dirname + "/seedLaunchContent.json", "utf8"));
const ago = (h) => Timestamp.fromMillis(Date.now() - h * 3600e3);
const mode = process.argv[2];

async function del() {
  const posts = await db.collection("posts").get();
  console.log(`deleting ${posts.size} posts (cascades run server-side)`);
  for (const p of posts.docs) {
    // Replies first so the reply-delete triggers see a live parent.
    const replies = await p.ref.collection("replies").get();
    for (const r of replies.docs) await r.ref.delete();
    await p.ref.delete();
    console.log("  deleted", p.id);
  }
}

async function seed() {
  for (const p of C.posts) {
    const authorId = C.personas[p.handle];
    if (!authorId) throw new Error("unknown persona " + p.handle);
    const doc = {
      authorId, authorHandle: p.handle, text: p.text, tag: p.tag,
      createdAt: ago(p.hoursAgo),
      likeCount: p.likes, repostCount: 0, replyCount: 0,
      isRepost: false, isShareable: true, moderationStatus: "live",
    };
    if (p.featured) doc.webFeatured = true;
    await db.collection("posts").doc(p.id).set(doc);
    console.log("  post", p.id, p.handle, p.tag);
  }
  let n = 0;
  for (const r of C.replies) {
    const authorId = C.personas[r.handle];
    if (!authorId) throw new Error("unknown persona " + r.handle);
    n++;
    await db.collection("posts").doc(r.post).collection("replies").doc(`${r.post}_reply_${n}`).set({
      authorId, authorHandle: r.handle, text: r.text, likeCount: 0,
      createdAt: ago(r.hoursAgo), moderationStatus: "live",
    });
    console.log("  reply on", r.post, "by", r.handle);
  }
}

async function counters() {
  // replyCount = live replies actually present; totalLikes = sum(likeCount).
  const posts = await db.collection("posts").get();
  const sum = new Map();
  for (const p of posts.docs) {
    const d = p.data();
    const live = (await p.ref.collection("replies").where("moderationStatus", "==", "live").count().get()).data().count;
    if ((d.replyCount ?? 0) !== live) { await p.ref.update({ replyCount: live }); console.log("  replyCount", p.id, d.replyCount, "->", live); }
    if (d.authorId) sum.set(d.authorId, (sum.get(d.authorId) || 0) + (d.likeCount || 0));
  }
  const users = await db.collection("users").select("totalLikes", "handle").get();
  for (const u of users.docs) {
    const actual = sum.get(u.id) || 0, stored = u.data().totalLikes ?? 0;
    if (actual !== stored) { await u.ref.update({ totalLikes: actual }); console.log("  totalLikes", u.data().handle, stored, "->", actual); }
  }
}

async function verify() {
  const posts = await db.collection("posts").orderBy("createdAt", "desc").get();
  for (const p of posts.docs) {
    const d = p.data();
    console.log(p.id.padEnd(18), (d.authorHandle || "?").padEnd(16), d.tag.padEnd(14), "likes=" + d.likeCount, "replies=" + d.replyCount, d.webFeatured ? "FEATURED" : "", JSON.stringify(d.text.slice(0, 50)));
  }
  console.log("posts:", posts.size);
}

({ "--delete": del, "--seed": seed, "--counters": counters, "--verify": verify }[mode] || (() => { console.error("usage: --delete | --seed | --counters | --verify"); process.exit(1); }))()
  .then(() => process.exit(0)).catch((e) => { console.error("ERR", e.message); process.exit(1); });
