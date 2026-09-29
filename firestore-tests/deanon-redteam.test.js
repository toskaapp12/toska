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
