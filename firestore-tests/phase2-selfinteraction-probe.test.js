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
// This probe proves the RULES half: self-like + self-repost CREATE both
// succeed today. If we decide to close the gap at the rules layer, these
// should flip to assertFails.

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
  it("SELF-LIKE: alice can like her OWN post (rules permit → totalLikes self-inflation)", async () => {
    await setUserDoc("alice");
    await setPost("p1", "alice");
    const a = env.authenticatedContext("alice").firestore();
    // SELF-LIKE stays ALLOWED by design (2026-07-09): the web like button is
    // active on own posts, so a rules block would break a working UI action.
    // totalLikes self-inflation deferred pending a product call — see §12 F-P2-1.
    await assertSucceeds(
      a.collection("posts").doc("p1").collection("likes").doc("alice")
        .set({ createdAt: serverTimestamp() })
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
