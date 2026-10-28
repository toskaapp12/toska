// DE-ANONYMIZATION RED TEAM (pentest, 2026-09-29).
//
// Adversary goal: given a post/reply, recover the REAL identity behind the
// anonymous handle — email, uid→handle linkage, device token, or any field
// that narrows who wrote it. Every `assertFails` here is an attack that MUST
// be denied; every asserted-absent field is data the attacker must never see.
//
// Runs on the emulator against the real firestore.rules.
const {
  initializeTestEnvironment, assertFails, assertSucceeds,
} = require("@firebase/rules-unit-testing");
const fs = require("fs");
const { serverTimestamp } = require("firebase/firestore");

const PROJECT_ID = "toska-deanon-redteam";
const RULES = fs.readFileSync(require("path").join(__dirname, "..", "firestore.rules"), "utf8");
let env;

// Victim (the anonymous author we're trying to unmask) and attacker.
const VICTIM = "victim_uid", ATTACKER = "attacker_uid";

before(async () => {
  env = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules: RULES, host: "localhost", port: 8080 },
  });
});
after(async () => { if (env) await env.cleanup(); });
beforeEach(async () => {
  await env.clearFirestore();
  // Seed a realistic victim: public user doc (handle only) + PRIVATE data
  // (email, fcmToken, prefs) + a live post.
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.collection("users").doc(VICTIM).set({
      handle: "quiet_moon_882", followerCount: 3, followingCount: 1,
      totalLikes: 12, allowSharing: true, createdAt: new Date(),
    });
    await db.collection("users").doc(VICTIM).collection("private").doc("data").set({
      email: "realname@gmail.com", fcmToken: "device-token-abc123",
      breakupStage: "they left", restricted: false,
    });
    await db.collection("users").doc(ATTACKER).set({
      handle: "attacker_h", createdAt: new Date(),
    });
    // Realistic attacker: fully onboarded (publishing surfaces gate on
    // confirmedAdult, and the allow-assertions below must fail only on the
    // contract under test, never on an unrelated missing-field denial).
    // A5 phase 1: the attestation lives in private/data.
    await db.doc(`users/${ATTACKER}/private/data`).set({ confirmedAdult: true });
    await db.collection("posts").doc("vpost").set({
      authorId: VICTIM, authorHandle: "quiet_moon_882", text: "i still check your location",
      likeCount: 5, replyCount: 0, repostCount: 0, isRepost: false,
      moderationStatus: "live", createdAt: new Date(),
    });
  });
});

const asAttacker = () => env.authenticatedContext(ATTACKER).firestore();
const asAnon = () => env.unauthenticatedContext().firestore();

describe("DE-ANON RED TEAM: private account data", () => {
  it("attacker CANNOT read victim's private/data (email, fcmToken)", async () => {
    await assertFails(asAttacker().collection("users").doc(VICTIM).collection("private").doc("data").get());
  });
  it("unauthenticated CANNOT read victim's private/data", async () => {
    await assertFails(asAnon().collection("users").doc(VICTIM).collection("private").doc("data").get());
  });
  it("attacker reading victim's PUBLIC user doc gets no PII fields", async () => {
    const snap = await assertSucceeds(asAttacker().collection("users").doc(VICTIM).get());
    const d = snap.data() || {};
    for (const leak of ["email", "fcmToken", "breakupStage", "restricted", "restrictedUntil"]) {
      if (leak in d) throw new Error(`PUBLIC user doc leaks '${leak}'`);
    }
  });
});

describe("DE-ANON RED TEAM: engagement-list harvesting", () => {
  // Knowing WHO liked a post is a de-anon vector (cross-reference likers).
  it("attacker CANNOT enumerate a post's likes subcollection", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("posts").doc("vpost").collection("likes").doc("someone").set({ createdAt: new Date() });
    });
    await assertFails(asAttacker().collection("posts").doc("vpost").collection("likes").get());
  });
  it("attacker CANNOT read victim's followers list", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("users").doc(VICTIM).collection("followers").doc("f1").set({ createdAt: new Date() });
    });
    await assertFails(asAttacker().collection("users").doc(VICTIM).collection("followers").get());
  });
  it("attacker CANNOT read victim's following list", async () => {
    await assertFails(asAttacker().collection("users").doc(VICTIM).collection("following").get());
  });
  it("attacker CANNOT read victim's liked / saved history", async () => {
    await assertFails(asAttacker().collection("users").doc(VICTIM).collection("liked").get());
    await assertFails(asAttacker().collection("users").doc(VICTIM).collection("saved").get());
  });
});

describe("DE-ANON RED TEAM: identity infrastructure", () => {
  it("attacker CANNOT read the bannedIdentities HMAC table", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("bannedIdentities").doc("h1").set({ kind: "email" });
    });
    await assertFails(asAttacker().collection("bannedIdentities").doc("h1").get());
  });
  it("attacker CANNOT read moderation/crisis queues (carry uids)", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("crisisReplyQueue").doc("c1").set({ authorId: VICTIM, createdAt: new Date() });
      await ctx.firestore().collection("reports").doc("r1").set({ reportedBy: ATTACKER, reportedUserId: VICTIM, status: "pending", createdAt: new Date() });
    });
    await assertFails(asAttacker().collection("crisisReplyQueue").doc("c1").get());
    await assertFails(asAttacker().collection("reports").doc("r1").get());
  });
  it("attacker CANNOT read the admins collection to find privileged uids", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("admins").doc("someadmin").set({ role: "admin" });
    });
    await assertFails(asAttacker().collection("admins").doc("someadmin").get());
  });
});

describe("DE-ANON RED TEAM: privilege + tamper", () => {
  it("attacker CANNOT make themselves admin", async () => {
    await assertFails(asAttacker().collection("admins").doc(ATTACKER).set({ role: "admin" }));
  });
  it("attacker CANNOT write victim's private data to exfiltrate later", async () => {
    await assertFails(asAttacker().collection("users").doc(VICTIM).collection("private").doc("data").set({ email: "x" }));
  });
  it("attacker CANNOT overwrite a post's authorId to reassign authorship", async () => {
    await assertFails(asAttacker().collection("posts").doc("vpost").update({ authorId: ATTACKER }));
  });
  it("attacker CANNOT flip the kill switch (config write)", async () => {
    await assertFails(asAttacker().collection("config").doc("clientPolicy").set({ minBuild: 999 }));
  });
});

// ── 2026-10-07 fix-round contracts ──
describe("DE-ANON RED TEAM: 2026-10-07 tightenings", () => {
  it("attacker CANNOT point-get the handles registry (keyspace enumeration)", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("handles").doc("quiet_moon_882").set({ uid: VICTIM });
    });
    await assertFails(asAttacker().collection("handles").doc("quiet_moon_882").get());
  });

  it("attacker CANNOT squat the victim's deterministic repost slot", async () => {
    // Repost doc under an id embedding the VICTIM's uid — frames the victim
    // as the reposter and permanently blocks their real repost (create would
    // collide with a doc they can't delete).
    await assertFails(asAttacker().collection("posts").doc(`${VICTIM}_repost_vpost`).set({
      authorId: ATTACKER, text: "i still check your location",
      isRepost: true, originalPostId: "vpost", originalAuthorId: VICTIM,
      likeCount: 0, replyCount: 0, repostCount: 0,
      moderationStatus: "pending_validation", createdAt: serverTimestamp(),
      isShareable: true,
    }));
  });

  it("notification create is NOT an authorship oracle for held posts", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("posts").doc("heldpost").set({
        authorId: VICTIM, authorHandle: "quiet_moon_882", text: "held",
        likeCount: 0, replyCount: 0, repostCount: 0, isRepost: false,
        moderationStatus: "pending_review", createdAt: new Date(),
      });
      // Attacker even owns a like doc on it (seeded as if pre-hold).
      await ctx.firestore().collection("posts").doc("heldpost")
        .collection("likes").doc(ATTACKER).set({ createdAt: new Date() });
    });
    // The verdict of this create was the oracle: allowed == "VICTIM authored
    // heldpost". Must now be denied because the post is not live.
    await assertFails(asAttacker().collection("users").doc(VICTIM)
      .collection("notifications").doc(`like_heldpost_${ATTACKER}`).set({
        type: "like", postId: "heldpost", fromUserId: ATTACKER,
        createdAt: serverTimestamp(),
      }));
  });

  it("post create REQUIRES moderationStatus=pending_validation (start-hidden is enforced)", async () => {
    const base = {
      authorId: ATTACKER, text: "hello world",
      likeCount: 0, replyCount: 0, repostCount: 0,
      createdAt: serverTimestamp(),
    };
    // Omitted field would default-read "live" pre-moderation — denied.
    await assertFails(asAttacker().collection("posts").doc("np1").set(base));
    await assertFails(asAttacker().collection("posts").doc("np2").set({
      ...base, moderationStatus: "live",
    }));
    await assertSucceeds(asAttacker().collection("posts").doc("np3").set({
      ...base, moderationStatus: "pending_validation",
    }));
  });

  it("reply create REQUIRES moderationStatus=pending_validation", async () => {
    const base = {
      authorId: ATTACKER, text: "a reply",
      createdAt: serverTimestamp(),
    };
    await assertFails(asAttacker().collection("posts").doc("vpost")
      .collection("replies").doc("nr1").set(base));
    await assertSucceeds(asAttacker().collection("posts").doc("vpost")
      .collection("replies").doc("nr2").set({
        ...base, moderationStatus: "pending_validation",
      }));
  });

  it("promptDate rides the create (validatePost strips malformed values server-side)", async () => {
    // The clause was moved OUT of rules — the posts create rule runs at
    // Firestore's 1000-expression cap and the extra expressions tipped valid
    // creates into "unable to evaluate" denials. validatePost now strips any
    // promptDate that isn't exactly yyyy-MM-dd (triggers don't run in the
    // rules emulator, so only the create verdicts are asserted here).
    const base = {
      authorId: ATTACKER, text: "prompt response",
      likeCount: 0, replyCount: 0, repostCount: 0,
      createdAt: serverTimestamp(), moderationStatus: "pending_validation",
    };
    await assertSucceeds(asAttacker().collection("posts").doc("pd3").set({
      ...base, promptDate: "2026-10-07",
    }));
  });
});

// ── TEST-01 (2026-10-23): logged-out WRITE denial, every writable path ──
// SEC-02 proves structurally that all write rules require auth; this pins it
// behaviorally. Every attempt below must fail for an unauthenticated client.
describe("TEST-01: unauthenticated writes are denied everywhere", () => {
  const attempts = (db) => ({
    "users create": () => db.collection("users").doc("anonU").set({ handle: "anon_h", createdAt: new Date() }),
    "users update": () => db.collection("users").doc(VICTIM).update({ handle: "stolen" }),
    "handles create": () => db.collection("handles").doc("anon_h").set({ uid: "anonU" }),
    "posts create": () => db.collection("posts").doc("anonP").set({ authorId: "anonU", text: "hi", createdAt: new Date(), likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "pending_validation" }),
    "posts update": () => db.collection("posts").doc("vpost").update({ text: "defaced" }),
    "posts delete": () => db.collection("posts").doc("vpost").delete(),
    "replies create": () => db.collection("posts").doc("vpost").collection("replies").doc("r").set({ authorId: "anonU", text: "x", createdAt: new Date(), moderationStatus: "pending_validation" }),
    "post likes create": () => db.collection("posts").doc("vpost").collection("likes").doc("anonU").set({ createdAt: new Date() }),
    "reflections create": () => db.collection("posts").doc("vpost").collection("reflections").doc("anonU").set({ authorId: "anonU", text: "x", createdAt: new Date() }),
    "following create": () => db.collection("users").doc(VICTIM).collection("following").doc("x").set({ handle: "h", createdAt: new Date() }),
    "followers create": () => db.collection("users").doc(VICTIM).collection("followers").doc("x").set({ handle: "h", createdAt: new Date() }),
    "notifications create": () => db.collection("users").doc(VICTIM).collection("notifications").doc("n").set({ type: "like", postId: "vpost", createdAt: new Date(), isRead: false }),
    "saved create": () => db.collection("users").doc(VICTIM).collection("saved").doc("vpost").set({ createdAt: new Date() }),
    "liked create": () => db.collection("users").doc(VICTIM).collection("liked").doc("vpost").set({ createdAt: new Date() }),
    "savedReplies create": () => db.collection("users").doc(VICTIM).collection("savedReplies").doc("r").set({ createdAt: new Date() }),
    "likedReplies create": () => db.collection("users").doc(VICTIM).collection("likedReplies").doc("r").set({ createdAt: new Date() }),
    "blocked create": () => db.collection("users").doc(VICTIM).collection("blocked").doc("x").set({ createdAt: new Date() }),
    "presence write": () => db.collection("users").doc(VICTIM).collection("presence").doc("state").set({ online: true }),
    "private write": () => db.collection("users").doc(VICTIM).collection("private").doc("data").set({ email: "x" }),
    "drafts create": () => db.collection("users").doc(VICTIM).collection("drafts").doc("d").set({ text: "x", updatedAt: new Date() }),
    "reports create": () => db.collection("reports").doc("rp").set({ reportedBy: "anonU", reason: "spam", type: "post", status: "pending", createdAt: new Date(), postId: "vpost" }),
    "pendingDeletions create": () => db.collection("pendingDeletions").doc("anonU").set({ requestedAt: new Date() }),
    "crisisReplyQueue update": () => db.collection("crisisReplyQueue").doc("c").set({ reviewed: true }),
    "admins create": () => db.collection("admins").doc("anonU").set({ role: "admin" }),
    "config write": () => db.collection("config").doc("clientPolicy").set({ minBuild: 999 }),
    "meta write": () => db.collection("meta").doc("tagCounts").set({ hacked: 1 }),
  });
  it("denies all 26 unauthenticated write shapes", async () => {
    const db = asAnon();
    for (const [label, fn] of Object.entries(attempts(db))) {
      await assertFails(fn()).catch((e) => { throw new Error(`${label}: ${e.message}`); });
    }
  });
});
