// PHASE 4 PROBE (2026-07-09) — admin-gate is rules-backed, not client-only.
//
// The admin dashboard (docs/admin.html) gates its UI on an admins/{uid} doc,
// but the guide's HIGH-or-not question is: do the RULES also enforce it, so a
// non-admin hitting the API directly can't perform admin writes? Also verify
// the CONTROL: a real admin's writes (the exact shapes admin.html issues)
// actually PASS the rules — otherwise the dashboard is silently broken.

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

async function seed(collPath, id, data) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().collection(collPath).doc(id).set(data);
  });
}
async function seedUser(uid, fields = {}) {
  await seed("users", uid, {
    handle: `handle_${uid}`, followerCount: 0, followingCount: 0,
    totalLikes: 0, confirmedAdult: true, ...fields,
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

// Common fixture: a victim user, a victim post, a pending report.
async function fixture() {
  await seedUser("victim");
  await seed("posts", "vp", {
    authorId: "victim", authorHandle: "handle_victim", text: "victim words",
    createdAt: new Date(), likeCount: 0, repostCount: 0, replyCount: 0,
    moderationStatus: "pending_review",
  });
  await seed("reports", "r1", {
    reportedBy: "someone", type: "post", postId: "vp",
    status: "pending", createdAt: new Date(),
  });
}

describe("PROBE: admin gate is rules-backed (non-admin DENIED)", () => {
  it("non-admin CANNOT restrict another user", async () => {
    await fixture(); await seedUser("mallory");
    const m = env.authenticatedContext("mallory").firestore();
    await assertFails(m.collection("users").doc("victim").update({
      restricted: true, restrictedAt: serverTimestamp(), restrictedBy: "mallory",
    }));
  });
  it("non-admin CANNOT flip another user's post to live (approve)", async () => {
    await fixture(); await seedUser("mallory");
    const m = env.authenticatedContext("mallory").firestore();
    await assertFails(m.collection("posts").doc("vp").update({ moderationStatus: "live" }));
  });
  it("non-admin CANNOT delete another user's post", async () => {
    await fixture(); await seedUser("mallory");
    const m = env.authenticatedContext("mallory").firestore();
    await assertFails(m.collection("posts").doc("vp").delete());
  });
  it("non-admin CANNOT resolve a report", async () => {
    await fixture(); await seedUser("mallory");
    const m = env.authenticatedContext("mallory").firestore();
    await assertFails(m.collection("reports").doc("r1").update({
      status: "resolved", reviewedBy: "mallory", reviewedAt: serverTimestamp(), action: "post_deleted",
    }));
  });
  it("non-admin CANNOT even READ the report queue", async () => {
    await fixture(); await seedUser("mallory");
    const m = env.authenticatedContext("mallory").firestore();
    await assertFails(m.collection("reports").doc("r1").get());
  });
});

describe("PROBE CONTROL: a real admin's dashboard writes PASS the rules", () => {
  // Seed the admins/{uid} doc the isAdmin() rule reads.
  async function makeAdmin(uid) { await seed("admins", uid, { role: "admin" }); }

  it("admin CAN approve (flip post to live)", async () => {
    await fixture(); await makeAdmin("boss");
    const a = env.authenticatedContext("boss").firestore();
    await assertSucceeds(a.collection("posts").doc("vp").update({ moderationStatus: "live" }));
  });
  it("admin CAN restrict a user (restrictedBy == self)", async () => {
    await fixture(); await makeAdmin("boss");
    const a = env.authenticatedContext("boss").firestore();
    await assertSucceeds(a.collection("users").doc("victim").update({
      restricted: true, restrictedAt: serverTimestamp(), restrictedBy: "boss",
    }));
  });
  it("admin CAN resolve a report (reviewedBy == self)", async () => {
    await fixture(); await makeAdmin("boss");
    const a = env.authenticatedContext("boss").firestore();
    await assertSucceeds(a.collection("reports").doc("r1").update({
      status: "resolved", reviewedBy: "boss", reviewedAt: serverTimestamp(), action: "post_deleted",
    }));
  });
  it("admin CANNOT frame another admin (restrictedBy != self is denied)", async () => {
    await fixture(); await makeAdmin("boss");
    const a = env.authenticatedContext("boss").firestore();
    await assertFails(a.collection("users").doc("victim").update({
      restricted: true, restrictedAt: serverTimestamp(), restrictedBy: "otheradmin",
    }));
  });
});
