// PHASE 1 PROBE (2026-07-09) — follower/following handle byline spoof.
//
// Hypothesis: the followers/{followerId} create+update rules lock the schema
// to {handle, createdAt} but do NOT pin `handle` to the follower's real
// user-doc handle (unlike authorHandle/fromHandle/originalHandle, which prior
// passes pinned). FollowListView.loadUsers (ProfileView.swift:1564) renders
// doc.data()["handle"] straight from the follower doc, so a tampered client
// can plant an arbitrary/impersonating label into a victim's followers list.
//
// PASS-WHEN-IT-SHOULDN'T-1: mallory writes a follower doc into alice's tree
// with a handle spoofing a THIRD party. Rule currently ACCEPTS (the bug).
// After the fix (pin handle == caller's user-doc handle) this must be DENIED.

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

before(async () => {
  env = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules: fs.readFileSync(RULES_PATH, "utf8"), host: "localhost", port: 8080 },
  });
});
after(async () => { if (env) await env.cleanup(); });
beforeEach(async () => { await env.clearFirestore(); });

describe("PROBE: follower-doc handle byline spoof", () => {
  it("CONTROL: mallory can follow alice with her REAL handle (legit path unaffected)", async () => {
    await setUserDoc("alice");
    await setUserDoc("mallory");
    const m = env.authenticatedContext("mallory").firestore();
    await assertSucceeds(
      m.collection("users").doc("alice").collection("followers").doc("mallory")
        .set({ handle: "handle_mallory", createdAt: serverTimestamp() })
    );
  });

  it("SPOOF: mallory writes a follower doc into alice's tree with a THIRD party's handle", async () => {
    await setUserDoc("alice");
    await setUserDoc("mallory");
    await setUserDoc("victim");
    const m = env.authenticatedContext("mallory").firestore();
    // Alice's FollowListView renders this handle verbatim -> "handle_victim
    // followed you" while the row actually resolves to mallory's profile.
    // EXPECTED AFTER FIX: assertFails. WHILE BUGGED: assertSucceeds.
    await assertFails(
      m.collection("users").doc("alice").collection("followers").doc("mallory")
        .set({ handle: "handle_victim", createdAt: serverTimestamp() })
    );
  });

  it("SPOOF via UPDATE: mallory rewrites her follower-doc handle after the fact", async () => {
    await setUserDoc("alice");
    await setUserDoc("mallory");
    const m = env.authenticatedContext("mallory").firestore();
    await m.collection("users").doc("alice").collection("followers").doc("mallory")
      .set({ handle: "handle_mallory", createdAt: serverTimestamp() });
    await assertFails(
      m.collection("users").doc("alice").collection("followers").doc("mallory")
        .set({ handle: "handle_victim", createdAt: serverTimestamp() })
    );
  });
});
