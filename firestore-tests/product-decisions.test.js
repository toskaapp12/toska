// Product decisions (owner, 2026-10-28, after the multi-user audit):
//   - the 18+ attestation gates likes, reply-likes, follows, saves and reports (not just publishing)
//   - a blocked user cannot SAVE the blocker's posts (nor a repost row of them); reporting stays allowed
//   - no replies on a held post (audit C6); reply text must be ≥ 2 characters after trimming (C12)

const { initializeTestEnvironment, assertSucceeds, assertFails } = require("@firebase/rules-unit-testing");
const { serverTimestamp } = require("firebase/firestore");
const fs = require("fs");
const path = require("path");

const PROJECT_ID = "toska-test";
const RULES_PATH = path.join(__dirname, "..", "firestore.rules");
let env;

const post = (authorId, status, extra = {}) => ({ authorId, authorHandle: `handle_${authorId}`, text: "hello there", createdAt: new Date(), likeCount: 0, repostCount: 0, replyCount: 0, isRepost: false, moderationStatus: status, ...extra });

async function seed() {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const uid of ["alice", "bob", "carol", "dave"]) await db.collection("users").doc(uid).set({ handle: `handle_${uid}`, followerCount: 0, followingCount: 0, totalLikes: 0, createdAt: new Date() });
    // alice, bob, dave attested; carol NOT
    for (const uid of ["alice", "bob", "dave"]) await db.doc(`users/${uid}/private/data`).set({ confirmedAdult: true });
    await db.doc("users/carol/private/data").set({ pushEnabled: true });
    await db.doc("users/alice/blocked/bob").set({ createdAt: new Date() }); // alice blocked bob
    await db.collection("posts").doc("live_alice").set(post("alice", "live"));
    await db.collection("posts").doc("held_alice").set(post("alice", "pending_review", { pendingReason: "pii", flagged: true }));
    await db.collection("posts").doc("pv_alice").set(post("alice", "pending_validation"));
    await db.collection("posts").doc("dave_repost_live_alice").set(post("dave", "live", { isRepost: true, originalPostId: "live_alice", originalAuthorId: "alice" }));
    await db.doc("posts/live_alice/replies/r1").set({ authorId: "alice", authorHandle: "handle_alice", text: "a reply", likeCount: 0, createdAt: new Date(), moderationStatus: "live" });
  });
}

describe("product decisions 2026-10-28: 18+ gate, blocked-save, held-post replies, 2-char replies (scoped hooks)", () => {
  before(async () => { env = await initializeTestEnvironment({ projectId: PROJECT_ID, firestore: { rules: fs.readFileSync(RULES_PATH, "utf8"), host: "localhost", port: 8080 } }); });
  after(async () => { if (env) await env.cleanup(); });
  beforeEach(async () => { await env.clearFirestore(); await seed(); });

  const as = (uid) => env.authenticatedContext(uid).firestore();
  const like = (db, uid, postId) => db.doc(`posts/${postId}/likes/${uid}`).set({ createdAt: serverTimestamp() });
  const likeReply = (db, uid) => db.doc(`posts/live_alice/replies/r1/likes/${uid}`).set({ createdAt: serverTimestamp() });
  const save = (db, uid, postId) => db.doc(`users/${uid}/saved/${postId}`).set({ createdAt: serverTimestamp(), postId });
  const follow = (db, uid, target) => db.doc(`users/${uid}/following/${target}`).set({ handle: `handle_${target}`, createdAt: serverTimestamp() });
  const followerRow = (db, uid, target) => db.doc(`users/${target}/followers/${uid}`).set({ handle: `handle_${uid}`, createdAt: serverTimestamp() });
  const report = (db, uid, postId, reportedUserId) => db.collection("reports").add({ reportedBy: uid, reason: "harassment", reasonLabel: "harassment", type: "post", status: "pending", createdAt: serverTimestamp(), postId, reportedUserId, reportedHandle: `handle_${reportedUserId}`, text: "snippet" });
  const reply = (db, uid, postId, text) => db.collection("posts").doc(postId).collection("replies").doc().set({ authorId: uid, authorHandle: `handle_${uid}`, text, likeCount: 0, createdAt: serverTimestamp(), moderationStatus: "pending_validation" });

  describe("18+ attestation gates every interaction", () => {
    it("DENIED: unattested user likes a post", () => assertFails(like(as("carol"), "carol", "live_alice")));
    it("DENIED: unattested user likes a reply", () => assertFails(likeReply(as("carol"), "carol")));
    it("DENIED: unattested user follows (following row)", () => assertFails(follow(as("carol"), "carol", "alice")));
    it("DENIED: unattested user follows (followers row on the target)", () => assertFails(followerRow(as("carol"), "carol", "alice")));
    it("DENIED: unattested user saves a post", () => assertFails(save(as("carol"), "carol", "live_alice")));
    it("DENIED: unattested user files a report", () => assertFails(report(as("carol"), "carol", "live_alice", "alice")));
    it("ALLOWED: attested user likes a post", () => assertSucceeds(like(as("dave"), "dave", "live_alice")));
    it("ALLOWED: attested user likes a reply", () => assertSucceeds(likeReply(as("dave"), "dave")));
    it("ALLOWED: attested user follows (both rows)", async () => { await assertSucceeds(follow(as("dave"), "dave", "alice")); await assertSucceeds(followerRow(as("dave"), "dave", "alice")); });
    it("ALLOWED: attested user saves a post", () => assertSucceeds(save(as("dave"), "dave", "live_alice")));
    it("ALLOWED: attested user files a report", () => assertSucceeds(report(as("dave"), "dave", "live_alice", "alice")));
    it("DENIED: attestation on the PUBLIC doc only does not count", async () => {
      await env.withSecurityRulesDisabled(async (c) => c.firestore().collection("users").doc("carol").set({ confirmedAdult: true }, { merge: true }));
      await assertFails(like(as("carol"), "carol", "live_alice"));
    });
  });

  describe("blocked users cannot save the blocker's posts; reporting stays allowed", () => {
    it("DENIED: bob (blocked by alice) saves alice's post", () => assertFails(save(as("bob"), "bob", "live_alice")));
    it("DENIED: bob saves dave's REPOST of alice's post (originalAuthorId pin)", () => assertFails(save(as("bob"), "bob", "dave_repost_live_alice")));
    it("ALLOWED: bob saves a post by someone who has not blocked him", async () => {
      await env.withSecurityRulesDisabled(async (c) => c.firestore().collection("posts").doc("live_dave").set(post("dave", "live")));
      await assertSucceeds(save(as("bob"), "bob", "live_dave"));
    });
    it("ALLOWED: bob still reports alice's post", () => assertSucceeds(report(as("bob"), "bob", "live_alice", "alice")));
    it("ALLOWED: unblocked dave saves alice's post", () => assertSucceeds(save(as("dave"), "dave", "live_alice")));
    it("DENIED (unchanged): bob likes alice's post", () => assertFails(like(as("bob"), "bob", "live_alice")));
  });

  describe("no replies on a held post; 2-character minimum", () => {
    it("ALLOWED: reply on a live post", () => assertSucceeds(reply(as("dave"), "dave", "live_alice", "ok")));
    it("DENIED: reply on a held (pending_review) post", () => assertFails(reply(as("dave"), "dave", "held_alice", "hello")));
    it("DENIED: the AUTHOR replies to their own held post", () => assertFails(reply(as("alice"), "alice", "held_alice", "hello")));
    it("DENIED: reply on a not-yet-validated (pending_validation) post", () => assertFails(reply(as("dave"), "dave", "pv_alice", "hello")));
    it("DENIED: reply on a missing post", () => assertFails(reply(as("dave"), "dave", "nope", "hello")));
    it("DENIED: 1-character reply", () => assertFails(reply(as("dave"), "dave", "live_alice", "a")));
    it("DENIED: whitespace-padded 1-character reply", () => assertFails(reply(as("dave"), "dave", "live_alice", "  a  ")));
    it("DENIED: whitespace-only reply", () => assertFails(reply(as("dave"), "dave", "live_alice", "   ")));
    it("ALLOWED: 2-character reply", () => assertSucceeds(reply(as("dave"), "dave", "live_alice", "ok")));
  });
});
