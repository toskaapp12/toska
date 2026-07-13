// PHASE 2 PROBE (2026-07-09) — self-interaction counter inflation.
//
// Self-FOLLOW is blocked at the rules layer (following/followers require
// followedId != userId; tested in firestore.test.js). But self-LIKE and
// self-REPOST have no such guard: the likes/repost create rules never compare
// the actor to the post author. Downstream, onLikeCreatedUpdateCounts
// (index.js:1395) increments the author's totalLikes and
// onRepostCreatedUpdateCount (index.js:1666) increments the post's repostCount
// with NO liker!=author / reposter!=author check — while the NOTIFICATION path
// DOES guard self (index.js:2039). So a tampered client can self-like/self-
// repost its own posts to inflate its own vanity counters (totalLikes is shown
// as social proof on OtherProfileView).
//
// 2026-07-13 product call: self-like is now ALSO blocked at the rules layer
// (create-only — deleting a legacy self-like stays allowed, and the post
// author keeps delete rights over likes on their post). Both clients had
// the affordance removed first (web likeBtn.disabled + toggleLike own_post
// guard; iOS toggleLike/toggleReplyLike guards). This probe pins the full
// closed state: self-like DENIED (post + reply), self-repost DENIED,
// cross-user like ALLOWED, legacy self-like delete ALLOWED.

const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require("@firebase/rules-unit-testing");
const { serverTimestamp } = require("firebase/firestore");
const fs = require("fs");
const path = require("path");

const PROJECT_ID = "toska-test";
const RULES_PATH = path.join(__dirname, "..", "firestore.rules");
let env;

async function setUserDoc(uid, fields = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().collection("users").doc(uid).set({
      handle: `handle_${uid}`,
      followerCount: 0, followingCount: 0, totalLikes: 0, confirmedAdult: true,
      ...fields,
    });
  });
}
async function setPost(postId, authorId, extra = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().collection("posts").doc(postId).set({
      authorId, authorHandle: `handle_${authorId}`, text: "my own words",
      createdAt: new Date(), likeCount: 0, repostCount: 0, replyCount: 0,
      moderationStatus: "live", ...extra,
    });
  });
}

before(async () => {
  env = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules: fs.readFileSync(RULES_PATH, "utf8"), host: "localhost", port: 8080 },
  });
});
after(async () => { if (env) await env.cleanup(); });
beforeEach(async () => { await env.clearFirestore(); });

describe("PROBE: self-interaction counter inflation (rules half)", () => {
  it("SELF-LIKE: alice CANNOT like her OWN post (rules now deny — F-P2-1 closed 2026-07-13)", async () => {
    await setUserDoc("alice");
    await setPost("p1", "alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").collection("likes").doc("alice")
        .set({ createdAt: serverTimestamp() })
    );
  });

  it("CROSS-LIKE: bob can still like alice's post (guard must not overreach)", async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("posts").doc("p1").collection("likes").doc("bob")
        .set({ createdAt: serverTimestamp() })
    );
  });

  it("LEGACY SELF-LIKE: alice can still DELETE a pre-existing self-like (create-only block)", async () => {
    await setUserDoc("alice");
    await setPost("p1", "alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("posts").doc("p1")
        .collection("likes").doc("alice").set({ createdAt: new Date() });
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("posts").doc("p1").collection("likes").doc("alice").delete()
    );
  });

  it("SELF-REPLY-LIKE: alice CANNOT like her OWN reply; bob CAN (reply-author guard)", async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("posts").doc("p1")
        .collection("replies").doc("r1").set({
          authorId: "alice", authorHandle: "handle_alice", text: "my reply",
          createdAt: new Date(), likeCount: 0, moderationStatus: "live",
        });
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").collection("replies").doc("r1")
        .collection("likes").doc("alice").set({ createdAt: serverTimestamp() })
    );
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("posts").doc("p1").collection("replies").doc("r1")
        .collection("likes").doc("bob").set({ createdAt: serverTimestamp() })
    );
  });

  it("SELF-REPOST: alice CANNOT repost her OWN post (rules now deny — F-P2-1 fix)", async () => {
    await setUserDoc("alice");
    await setPost("p1", "alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("alice_repost_p1").set({
        authorId: "alice", authorHandle: "handle_alice",
        text: "my own words", createdAt: serverTimestamp(),
        likeCount: 0, repostCount: 0, replyCount: 0,
        isRepost: true, originalPostId: "p1", originalAuthorId: "alice",
      })
    );
  });
});
