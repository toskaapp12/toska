// Hostile-user rules tests (forensic audit 2026-06-08).
//
// Adversary model: a logged-in user with a tampered/jailbroken client
// making direct Firestore SDK calls. Each test asserts the rule layer
// prevents (or, where a finding exists, FAILS to prevent) an abuse.
//
// Run with the same harness as firestore.test.js:
//   firebase emulators:exec --only firestore,auth --project=toska-test \
//     'npx mocha --timeout 15000 hostile-user.test.js'

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

async function seedUser(uid, fields = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().collection("users").doc(uid).set({
      handle: `handle_${uid}`,
      followerCount: 0, followingCount: 0, totalLikes: 0,
      confirmedAdult: true,
      ...fields,
    });
  });
}
async function seedPost(postId, authorId, extra = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().collection("posts").doc(postId).set({
      authorId, authorHandle: `handle_${authorId}`, text: "hello",
      createdAt: new Date(), likeCount: 0, repostCount: 0, replyCount: 0,
      moderationStatus: "live", ...extra,
    });
  });
}
async function seedRaw(pathSegs, data) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    let ref = ctx.firestore();
    for (let i = 0; i < pathSegs.length; i += 2) {
      ref = ref.collection(pathSegs[i]).doc(pathSegs[i + 1]);
    }
    await ref.set(data);
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

// ─────────────────────────────────────────────────────────────────────
// FINDING CANDIDATE: post author-update has a field DENYLIST but no
// hasOnly() schema lock (unlike post-create). The denylist omits the
// moderation audit-attribution fields deletedBy / unflaggedBy /
// crisisReviewedBy, which auditPostModeration / auditPostDeletion key on.
// ─────────────────────────────────────────────────────────────────────
describe("R-1 FIXED: post author cannot inject audit-attribution / arbitrary fields on own post", () => {
  it("author CANNOT write unflaggedBy onto own post (hasOnly lock blocks audit forgery)", async () => {
    await seedUser("attacker");
    await seedPost("p1", "attacker");
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(
      db.collection("posts").doc("p1").update({ text: "hello", unflaggedBy: "some_admin_uid" })
    );
  });

  it("author CANNOT write deletedBy onto own post", async () => {
    await seedUser("attacker");
    await seedPost("p2", "attacker");
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(
      db.collection("posts").doc("p2").update({ text: "hello", deletedBy: "victim_admin_uid" })
    );
  });

  it("author CANNOT inject an arbitrary scratch field", async () => {
    await seedUser("attacker");
    await seedPost("p3", "attacker");
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(
      db.collection("posts").doc("p3").update({ text: "hello", trustedByAdmin: true })
    );
  });

  it("author CAN still edit text + editedAt (legit edit path preserved)", async () => {
    await seedUser("attacker");
    await seedPost("p3b", "attacker");
    const db = env.authenticatedContext("attacker").firestore();
    await assertSucceeds(
      db.collection("posts").doc("p3b").update({ text: "edited text", editedAt: serverTimestamp() })
    );
  });

  it("CONTROL: author still CANNOT flip moderationStatus to live (denylist holds)", async () => {
    await seedUser("attacker");
    await seedPost("p4", "attacker", { moderationStatus: "pending_review" });
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(
      db.collection("posts").doc("p4").update({ text: "hello", moderationStatus: "live" })
    );
  });
});

// ─────────────────────────────────────────────────────────────────────
// §3-F (g)/(h): privileged collections + self-escalation
// ─────────────────────────────────────────────────────────────────────
describe("§3-F privileged reads + self-escalation are denied", () => {
  it("(g) non-admin cannot read reports", async () => {
    await seedRaw(["reports", "r1"], { reportedBy: "x", status: "pending", createdAt: new Date() });
    const db = env.authenticatedContext("nobody").firestore();
    await assertFails(db.collection("reports").doc("r1").get());
  });
  it("(g) non-admin cannot read another user's admins doc", async () => {
    await seedRaw(["admins", "realadmin"], { role: "admin" });
    const db = env.authenticatedContext("nobody").firestore();
    await assertFails(db.collection("admins").doc("realadmin").get());
  });
  it("(g) non-admin cannot read adminAuditLog", async () => {
    await seedRaw(["adminAuditLog", "e1"], { action: "x" });
    const db = env.authenticatedContext("nobody").firestore();
    await assertFails(db.collection("adminAuditLog").doc("e1").get());
  });
  it("(g) nobody can read processedTriggerEvents", async () => {
    await seedRaw(["processedTriggerEvents", "ev1"], { expiresAt: new Date() });
    const db = env.authenticatedContext("nobody").firestore();
    await assertFails(db.collection("processedTriggerEvents").doc("ev1").get());
  });
  it("(h) cannot self-grant admin", async () => {
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("admins").doc("attacker").set({ role: "admin" }));
  });
  it("(h) cannot self-unrestrict via own user doc", async () => {
    await seedUser("attacker", { restricted: true });
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("users").doc("attacker").update({ restricted: false }));
  });
  it("(d) cannot inflate own followerCount", async () => {
    await seedUser("attacker");
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("users").doc("attacker").update({ followerCount: 999999 }));
  });
  it("(h) cannot self-confirm-adult on own user doc update", async () => {
    await seedUser("attacker", { confirmedAdult: false });
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("users").doc("attacker").update({ confirmedAdult: true }));
  });
  it("G-2: an ACTIVELY-restricted user cannot delete their own user doc to escape restriction", async () => {
    // notRestricted() short-circuits true on its !exists leg; a client delete
    // of users/{uid} would let a repeat-offender drop the doc, recreate, and
    // post again. The legit account-deletion path never deletes this doc from
    // the client (Auth.delete() → Admin-SDK cascade), so this delete is denied
    // while a restriction is active.
    await seedUser("attacker", {
      restricted: true,
      restrictedUntil: new Date(Date.now() + 48 * 3600 * 1000), // 48h out
    });
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("users").doc("attacker").delete());
  });
  it("G-2 control: an UNrestricted user can still delete their own user doc", async () => {
    await seedUser("normal");
    const db = env.authenticatedContext("normal").firestore();
    await assertSucceeds(db.collection("users").doc("normal").delete());
  });
  it("G-2 control: a user whose restriction has EXPIRED can delete their own doc", async () => {
    await seedUser("expired", {
      restricted: true,
      restrictedUntil: new Date(Date.now() - 3600 * 1000), // expired 1h ago
    });
    const db = env.authenticatedContext("expired").firestore();
    await assertSucceeds(db.collection("users").doc("expired").delete());
  });
});

// ─────────────────────────────────────────────────────────────────────
// §3-F (i) byline forgery, (b) social-graph enumeration
// ─────────────────────────────────────────────────────────────────────
describe("§3-F byline forgery + social-graph enumeration", () => {
  it("(i) post create with spoofed authorHandle is denied", async () => {
    await seedUser("attacker", { handle: "handle_attacker" });
    await seedUser("victim", { handle: "victim_handle" });
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(
      db.collection("posts").doc("forged").set({
        authorId: "attacker", authorHandle: "victim_handle", text: "I said this",
        createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0,
        moderationStatus: "pending_validation",
      })
    );
  });
  it("(i) post create with correct authorHandle succeeds", async () => {
    await seedUser("attacker", { handle: "handle_attacker" });
    const db = env.authenticatedContext("attacker").firestore();
    await assertSucceeds(
      db.collection("posts").doc("ok").set({
        authorId: "attacker", authorHandle: "handle_attacker", text: "mine",
        createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0,
        moderationStatus: "pending_validation",
      })
    );
  });
  it("(b) cannot read another user's following list", async () => {
    await seedRaw(["users", "victim", "following", "someone"], { handle: "x", createdAt: new Date() });
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("users").doc("victim").collection("following").doc("someone").get());
  });
  it("(b) cannot read another user's followers list", async () => {
    await seedRaw(["users", "victim", "followers", "someone"], { handle: "x", createdAt: new Date() });
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("users").doc("victim").collection("followers").doc("someone").get());
  });
  it("(a) cannot read another user's private subcollection (PII)", async () => {
    await seedRaw(["users", "victim", "private", "data"], { email: "v@x.com", selectedMood: "sad" });
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("users").doc("victim").collection("private").doc("data").get());
  });
});

// ─────────────────────────────────────────────────────────────────────
// §3-F (j) cut collections, server-only collections
// ─────────────────────────────────────────────────────────────────────
describe("§3-F cut + server-only collections deny client writes", () => {
  it("(j) cannot write to cut conversations", async () => {
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("conversations").doc("c1").set({ x: 1 }));
  });
  it("(j) cannot write to cut feelingCircles", async () => {
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("feelingCircles").doc("f1").set({ x: 1 }));
  });
  it("(j) cannot write to cut finalPosts", async () => {
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("finalPosts").doc("p1").set({ x: 1 }));
  });
  it("cannot write meta/tagCounts", async () => {
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("meta").doc("tagCounts").set({ heartbreak: 9999 }));
  });
  it("cannot write dailyMoment", async () => {
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("dailyMoment").doc("2026-06-08").set({ text: "x" }));
  });
});

// ─────────────────────────────────────────────────────────────────────
// §3-F collection-group replies leak check (held-post inheritance)
// ─────────────────────────────────────────────────────────────────────
describe("§3-F collection-group replies are own-author-only", () => {
  it("cannot read another user's reply via collectionGroup gate (own-author only)", async () => {
    // A reply authored by 'victim' under a held post. The collection-group
    // rule allows read only if resource.data.authorId == auth.uid.
    await seedPost("held", "victim", { moderationStatus: "pending_review" });
    await seedRaw(["posts", "held", "replies", "rep1"], {
      authorId: "victim", text: "secret reply", createdAt: new Date(), likeCount: 0,
    });
    const db = env.authenticatedContext("attacker").firestore();
    // Direct get on the held post's reply: postVisibleToCaller(held) is false
    // for attacker (not author, not live, not admin) -> denied.
    await assertFails(db.collection("posts").doc("held").collection("replies").doc("rep1").get());
  });
});

// ─────────────────────────────────────────────────────────────────────
// M-1: reply pending_review hold — visibility + anti-self-approve
// ─────────────────────────────────────────────────────────────────────
async function seedReplyDoc(postId, replyId, authorId, extra = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().collection("posts").doc(postId)
      .collection("replies").doc(replyId)
      .set({ authorId, text: "a reply", createdAt: new Date(), likeCount: 0, ...extra });
  });
}
async function seedAdmin(uid) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().collection("admins").doc(uid).set({ role: "admin" });
  });
}

describe("M-1: held reply (moderationStatus pending_review) visibility", () => {
  it("a live reply is readable by a third party", async () => {
    await seedPost("p", "author");
    await seedReplyDoc("p", "r1", "replyauthor", { moderationStatus: "live" });
    const db = env.authenticatedContext("third").firestore();
    await assertSucceeds(db.collection("posts").doc("p").collection("replies").doc("r1").get());
  });
  it("a legacy reply (no moderationStatus) is readable by a third party", async () => {
    await seedPost("p", "author");
    await seedReplyDoc("p", "r1b", "replyauthor");
    const db = env.authenticatedContext("third").firestore();
    await assertSucceeds(db.collection("posts").doc("p").collection("replies").doc("r1b").get());
  });
  it("a held reply is NOT readable by a third party", async () => {
    await seedPost("p", "author");
    await seedReplyDoc("p", "r2", "replyauthor", { moderationStatus: "pending_review", pendingReason: "pii" });
    const db = env.authenticatedContext("third").firestore();
    await assertFails(db.collection("posts").doc("p").collection("replies").doc("r2").get());
  });
  it("a held reply IS readable by its own author", async () => {
    await seedPost("p", "author");
    await seedReplyDoc("p", "r3", "replyauthor", { moderationStatus: "pending_review", pendingReason: "pii" });
    const db = env.authenticatedContext("replyauthor").firestore();
    await assertSucceeds(db.collection("posts").doc("p").collection("replies").doc("r3").get());
  });
  it("the author's own-held query (authorId==me, pending_review) is allowed", async () => {
    await seedPost("p", "author");
    await seedReplyDoc("p", "r4", "replyauthor", { moderationStatus: "pending_review", pendingReason: "pii" });
    const db = env.authenticatedContext("replyauthor").firestore();
    await assertSucceeds(
      db.collection("posts").doc("p").collection("replies")
        .where("authorId", "==", "replyauthor")
        .where("moderationStatus", "==", "pending_review").get()
    );
  });
  it("admin can read held replies via collectionGroup", async () => {
    await seedAdmin("adm");
    await seedPost("p", "author");
    await seedReplyDoc("p", "r5", "replyauthor", { moderationStatus: "pending_review", pendingReason: "pii" });
    const db = env.authenticatedContext("adm").firestore();
    await assertSucceeds(
      db.collectionGroup("replies").where("moderationStatus", "==", "pending_review").get()
    );
  });
});

describe("M-1: reply hold anti-self-approve + admin approve", () => {
  it("reply author CANNOT self-approve (set moderationStatus live)", async () => {
    await seedPost("p", "author");
    await seedReplyDoc("p", "r6", "replyauthor", { moderationStatus: "pending_review", pendingReason: "pii" });
    const db = env.authenticatedContext("replyauthor").firestore();
    await assertFails(
      db.collection("posts").doc("p").collection("replies").doc("r6")
        .update({ text: "a reply", moderationStatus: "live" })
    );
  });
  it("reply author CAN still edit their own text", async () => {
    await seedPost("p", "author");
    await seedReplyDoc("p", "r7", "replyauthor", { moderationStatus: "live" });
    const db = env.authenticatedContext("replyauthor").firestore();
    await assertSucceeds(
      db.collection("posts").doc("p").collection("replies").doc("r7")
        .update({ text: "edited reply", editedAt: serverTimestamp() })
    );
  });
  it("admin CAN approve a held reply (set moderationStatus live)", async () => {
    await seedAdmin("adm");
    await seedPost("p", "author");
    await seedReplyDoc("p", "r8", "replyauthor", { moderationStatus: "pending_review", pendingReason: "pii" });
    const db = env.authenticatedContext("adm").firestore();
    await assertSucceeds(
      db.collection("posts").doc("p").collection("replies").doc("r8")
        .update({ moderationStatus: "live", pendingApprovedBy: "adm" })
    );
  });
});

// ─────────────────────────────────────────────────────────────────────
// M-1 edge/security: a tampered client must NOT be able to self-stamp a
// reply's moderationStatus (which would bypass validateReply's PII hold),
// and must not enumerate others' replies via collectionGroup.
// ─────────────────────────────────────────────────────────────────────
describe("M-1 edge: reply create cannot self-set moderationStatus", () => {
  async function setupPostAndUser() {
    await seedUser("attacker", { handle: "handle_attacker" });
    await seedPost("p", "victimauthor");
  }
  const validReply = (extra = {}) => ({
    authorId: "attacker", authorHandle: "handle_attacker",
    text: "my ex Sarah Johnson did this", likeCount: 0, createdAt: serverTimestamp(), ...extra,
  });

  it("CONTROL: a valid reply (no moderationStatus) is accepted", async () => {
    await setupPostAndUser();
    const db = env.authenticatedContext("attacker").firestore();
    await assertSucceeds(db.collection("posts").doc("p").collection("replies").doc("r0").set(validReply()));
  });
  it("T-2: reply create with moderationStatus='pending_validation' is ACCEPTED (start-hidden)", async () => {
    // The client now writes pending_validation at create so a PII reply is never
    // third-party-readable in the pre-validateReply window. The read rule treats
    // != 'live' as hidden to non-authors; setReplyLive promotes clean ones.
    await setupPostAndUser();
    const db = env.authenticatedContext("attacker").firestore();
    await assertSucceeds(db.collection("posts").doc("p").collection("replies").doc("rpv").set(validReply({ moderationStatus: "pending_validation" })));
  });
  it("reply create with moderationStatus='live' is DENIED (hasOnly blocks the PII-bypass)", async () => {
    await setupPostAndUser();
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("posts").doc("p").collection("replies").doc("r1").set(validReply({ moderationStatus: "live" })));
  });
  it("reply create with moderationStatus='pending_review' is DENIED too", async () => {
    await setupPostAndUser();
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("posts").doc("p").collection("replies").doc("r2").set(validReply({ moderationStatus: "pending_review" })));
  });
  it("reply create with pendingReason/flagged injected is DENIED", async () => {
    await setupPostAndUser();
    const db = env.authenticatedContext("attacker").firestore();
    await assertFails(db.collection("posts").doc("p").collection("replies").doc("r3").set(validReply({ flagged: false })));
  });
});

describe("M-1 edge: non-author cannot enumerate others' replies via collectionGroup", () => {
  it("collectionGroup('replies') filtered to a VICTIM's authorId is denied for a non-admin", async () => {
    await seedPost("p", "victimauthor");
    await seedReplyDoc("p", "vr", "victimauthor", { moderationStatus: "pending_review", pendingReason: "pii" });
    const db = env.authenticatedContext("snoop").firestore();
    const { collectionGroup, query, where, getDocs } = require("firebase/firestore");
    await assertFails(getDocs(query(collectionGroup(db, "replies"), where("authorId", "==", "victimauthor"))));
  });
});

// ─────────────────────────────────────────────────────────────────────
// T-10 (2026-06-11): the post-like create rule now has a schema lock
// (hasOnly(['createdAt']) + createdAt == request.time), mirroring the reply-
// like sibling. A tampered client must not be able to scribble arbitrary
// fields onto a like doc.
// ─────────────────────────────────────────────────────────────────────
describe("T-10: post-like create is schema-locked", () => {
  it("CONTROL: a clean like (only server createdAt) is accepted", async () => {
    await seedUser("liker");
    await seedPost("p", "author");
    const db = env.authenticatedContext("liker").firestore();
    await assertSucceeds(
      db.collection("posts").doc("p").collection("likes").doc("liker").set({ createdAt: serverTimestamp() })
    );
  });
  it("a like with an injected scratch field is DENIED (hasOnly)", async () => {
    await seedUser("liker");
    await seedPost("p", "author");
    const db = env.authenticatedContext("liker").firestore();
    await assertFails(
      db.collection("posts").doc("p").collection("likes").doc("liker").set({ createdAt: serverTimestamp(), trustedByAdmin: true })
    );
  });
});

// ─────────────────────────────────────────────────────────────────────
// #3a: cannot repost a HELD reply.  #3b: held reply's likers are hidden.
// ─────────────────────────────────────────────────────────────────────
describe("#3a reply-repost is denied for a held reply", () => {
  const REPLY_TEXT = "the original reply text";
  async function setup(modStatus) {
    await seedUser("reposter", { handle: "handle_reposter" });
    await seedPost("op", "origauthor");
    await seedReplyDoc("op", "orr", "ra", { text: REPLY_TEXT, moderationStatus: modStatus });
  }
  const repost = () => ({
    authorId: "reposter", authorHandle: "handle_reposter", text: REPLY_TEXT,
    createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0,
    isRepost: true, originalPostId: "op", originalReplyId: "orr", originalAuthorId: "ra",
  });
  it("CONTROL: reposting a LIVE reply is allowed", async () => {
    await setup("live");
    const db = env.authenticatedContext("reposter").firestore();
    await assertSucceeds(db.collection("posts").doc("reposter_repost_x").set(repost()));
  });
  it("reposting a HELD (pending_review) reply is DENIED", async () => {
    await setup("pending_review");
    const db = env.authenticatedContext("reposter").firestore();
    await assertFails(db.collection("posts").doc("reposter_repost_y").set(repost()));
  });
});

describe("#3b held reply's liker list is gated on the reply's moderationStatus", () => {
  async function setupLike(modStatus) {
    await seedPost("p", "postauthor"); // live post
    await seedReplyDoc("p", "r", "replyauthor", { moderationStatus: modStatus });
    await seedRaw(["posts", "p", "replies", "r", "likes", "liker1"], { createdAt: new Date() });
  }
  it("CONTROL: a third party CAN read likers of a LIVE reply", async () => {
    await setupLike("live");
    const db = env.authenticatedContext("third").firestore();
    await assertSucceeds(db.collection("posts").doc("p").collection("replies").doc("r").collection("likes").doc("liker1").get());
  });
  it("a third party CANNOT read likers of a HELD reply", async () => {
    await setupLike("pending_review");
    const db = env.authenticatedContext("third").firestore();
    await assertFails(db.collection("posts").doc("p").collection("replies").doc("r").collection("likes").doc("liker1").get());
  });
  it("the reply author CAN read likers of their own held reply", async () => {
    await setupLike("pending_review");
    const db = env.authenticatedContext("replyauthor").firestore();
    await assertSucceeds(db.collection("posts").doc("p").collection("replies").doc("r").collection("likes").doc("liker1").get());
  });
});

describe("N-1 FIXED: reply author cannot spoof authorHandle / inject fields via update", () => {
  beforeEach(async () => {
    await env.clearFirestore();
    await seedUser("postauthor");
    await seedUser("replyauthor", { handle: "handle_replyauthor" });
    await seedUser("victim", { handle: "handle_victim" });
    await seedPost("p", "postauthor"); // live post
    await seedReplyDoc("p", "r1", "replyauthor", {
      authorHandle: "handle_replyauthor", moderationStatus: "live",
    });
  });

  it("CONTROL: the reply author CAN make a text-only edit", async () => {
    const db = env.authenticatedContext("replyauthor").firestore();
    await assertSucceeds(
      db.collection("posts").doc("p").collection("replies").doc("r1")
        .update({ text: "edited reply", editedAt: serverTimestamp() })
    );
  });

  it("DENIED: reply author cannot re-write authorHandle to a victim's handle (byline spoof)", async () => {
    const db = env.authenticatedContext("replyauthor").firestore();
    await assertFails(
      db.collection("posts").doc("p").collection("replies").doc("r1")
        .update({ text: "edited reply", authorHandle: "handle_victim" })
    );
  });

  it("DENIED: reply author cannot inject an arbitrary scratch field via update (R-1 class)", async () => {
    const db = env.authenticatedContext("replyauthor").firestore();
    await assertFails(
      db.collection("posts").doc("p").collection("replies").doc("r1")
        .update({ text: "edited reply", trustedByAdmin: true })
    );
  });
});
