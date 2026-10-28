// A5 phase 1 (2026-10-28 audit): the authorization fields — confirmedAdult / confirmedAdultAt and
// restricted / restrictedAt / restrictedUntil / restrictedBy — live in users/{uid}/private/data, which
// only the owner (read) and admins/server (write) can touch. The public users/{uid} doc no longer
// carries them, so another signed-in user can't learn a profile's restriction status or age
// attestation. Rules helpers hasConfirmedAdult() / notRestricted() read private/data.

const { initializeTestEnvironment, assertSucceeds, assertFails } = require("@firebase/rules-unit-testing");
const { deleteField, serverTimestamp } = require("firebase/firestore");
const fs = require("fs");
const path = require("path");

const PROJECT_ID = "toska-test";
const RULES_PATH = path.join(__dirname, "..", "firestore.rules");
let env;

// createdAt must be request.time for client creates (rules pin it); seeded docs use new Date().
const post = (authorId) => ({ authorId, authorHandle: `handle_${authorId}`, text: "hello there", createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, isRepost: false, moderationStatus: "pending_validation" });
const seededPost = (authorId) => ({ ...post(authorId), createdAt: new Date() });
async function seed({ privA = { confirmedAdult: true }, privB = { confirmedAdult: true } } = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const uid of ["alice", "bob", "modmin"]) await db.collection("users").doc(uid).set({ handle: `handle_${uid}`, followerCount: 0, followingCount: 0, totalLikes: 0, createdAt: new Date() });
    await db.collection("admins").doc("modmin").set({ role: "admin" });
    await db.doc("users/alice/private/data").set(privA);
    await db.doc("users/bob/private/data").set(privB);
    await db.doc("users/modmin/private/data").set({ confirmedAdult: true });
    await db.collection("posts").doc("live_alice").set({ ...seededPost("alice"), moderationStatus: "live" });
  });
}

describe("A5 phase 1: authorization fields in private/data (scoped hooks)", () => {
  before(async () => { env = await initializeTestEnvironment({ projectId: PROJECT_ID, firestore: { rules: fs.readFileSync(RULES_PATH, "utf8"), host: "localhost", port: 8080 } }); });
  after(async () => { if (env) await env.cleanup(); });
  beforeEach(async () => { await env.clearFirestore(); });

  const alice = () => env.authenticatedContext("alice").firestore();
  const bob = () => env.authenticatedContext("bob").firestore();
  const admin = () => env.authenticatedContext("modmin").firestore();
  const createPostDoc = (db, id) => db.collection("posts").doc(id).set(post("alice"));
  const createReplyDoc = (db) => db.collection("posts").doc("live_alice").collection("replies").doc("r1").set({ authorId: "bob", authorHandle: "handle_bob", text: "kind", likeCount: 0, createdAt: serverTimestamp(), moderationStatus: "pending_validation" });

  describe("owner cannot self-attest or self-unrestrict in private/data", () => {
    beforeEach(() => seed({ privA: { selectedMood: "numb" } }));
    it("DENIED: owner sets private/data.confirmedAdult", () => assertFails(alice().doc("users/alice/private/data").set({ confirmedAdult: true }, { merge: true })));
    it("DENIED: owner sets private/data.confirmedAdultAt", () => assertFails(alice().doc("users/alice/private/data").set({ confirmedAdultAt: new Date() }, { merge: true })));
    it("DENIED: owner sets private/data.restricted=false", () => assertFails(alice().doc("users/alice/private/data").set({ restricted: false }, { merge: true })));
    it("DENIED: owner sets private/data.restrictedUntil", () => assertFails(alice().doc("users/alice/private/data").set({ restrictedUntil: new Date() }, { merge: true })));
    it("DENIED: owner creates a fresh private/data carrying confirmedAdult", async () => { await env.withSecurityRulesDisabled(async (c) => c.firestore().doc("users/alice/private/data").delete()); await assertFails(alice().doc("users/alice/private/data").set({ pushEnabled: true, confirmedAdult: true })); });
    it("ALLOWED: owner writes prefs / mood / fcmToken as before", () => assertSucceeds(alice().doc("users/alice/private/data").set({ notifyLikes: false, pushEnabled: true, selectedMood: "numb", fcmToken: "tok" }, { merge: true })));
    it("ALLOWED: owner writes another private doc (not 'data') freely", () => assertSucceeds(alice().doc("users/alice/private/scratch").set({ anything: 1 })));
    it("ALLOWED: owner reads own private/data", () => assertSucceeds(alice().doc("users/alice/private/data").get()));
    it("DENIED: other user reads private/data", () => assertFails(bob().doc("users/alice/private/data").get()));
  });

  describe("admins restrict / unrestrict through private/data", () => {
    beforeEach(() => seed());
    it("ALLOWED: admin restricts (restricted, restrictedAt, restrictedBy == self)", () => assertSucceeds(admin().doc("users/alice/private/data").set({ restricted: true, restrictedAt: new Date(), restrictedBy: "modmin" }, { merge: true })));
    it("ALLOWED: admin unrestricts and clears restrictedUntil", async () => { await env.withSecurityRulesDisabled(async (c) => c.firestore().doc("users/alice/private/data").set({ restricted: true, restrictedUntil: new Date() }, { merge: true })); await assertSucceeds(admin().doc("users/alice/private/data").update({ restricted: false, restrictedAt: new Date(), restrictedBy: "modmin", restrictedUntil: deleteField() })); });
    it("DENIED: admin stamps restrictedBy as another admin", () => assertFails(admin().doc("users/alice/private/data").set({ restricted: true, restrictedAt: new Date(), restrictedBy: "someone_else" }, { merge: true })));
    it("DENIED: admin touches confirmedAdult in private/data", () => assertFails(admin().doc("users/alice/private/data").set({ confirmedAdult: false }, { merge: true })));
    it("DENIED: admin touches prefs in another user's private/data", () => assertFails(admin().doc("users/alice/private/data").set({ pushEnabled: false }, { merge: true })));
    it("DENIED: admin reads another user's private/data (no read leg)", () => assertFails(admin().doc("users/alice/private/data").get()));
    it("DENIED: non-admin writes restricted into another user's private/data", () => assertFails(bob().doc("users/alice/private/data").set({ restricted: true }, { merge: true })));
  });

  describe("public users/{uid} doc no longer accepts the fields and other users never see them", () => {
    beforeEach(() => seed());
    // Transition: build-102 iOS admin still writes the public doc; the leg stays and the
    // relocation shim moves the fields to private/data within seconds. Leg removal = phase 2.
    it("ALLOWED (transition): admin writes restricted onto the public user doc; shim relocates it", () => assertSucceeds(admin().collection("users").doc("alice").update({ restricted: true, restrictedAt: new Date(), restrictedBy: "modmin" })));
    it("DENIED: owner writes confirmedAdult onto the public user doc", () => assertFails(alice().collection("users").doc("alice").update({ confirmedAdult: true })));
    it("ALLOWED: other user reads the public doc (handle/counts only)", async () => { const s = await bob().collection("users").doc("alice").get(); const keys = Object.keys(s.data()); for (const f of ["confirmedAdult", "confirmedAdultAt", "restricted", "restrictedAt", "restrictedUntil", "restrictedBy"]) if (keys.includes(f)) throw new Error("public doc still carries " + f); });
  });

  describe("gates read private/data", () => {
    it("ALLOWED: post create when private/data.confirmedAdult == true", async () => { await seed(); await assertSucceeds(createPostDoc(alice(), "p1")); });
    it("DENIED: post create when private/data has no confirmedAdult", async () => { await seed({ privA: { pushEnabled: true } }); await assertFails(createPostDoc(alice(), "p2")); });
    it("DENIED: post create when private/data is MISSING entirely", async () => { await seed(); await env.withSecurityRulesDisabled(async (c) => c.firestore().doc("users/alice/private/data").delete()); await assertFails(createPostDoc(alice(), "p3")); });
    it("DENIED: post create when confirmedAdult sits only on the PUBLIC doc (legacy, not yet relocated)", async () => { await seed({ privA: { pushEnabled: true } }); await env.withSecurityRulesDisabled(async (c) => c.firestore().collection("users").doc("alice").set({ confirmedAdult: true }, { merge: true })); await assertFails(createPostDoc(alice(), "p4")); });
    it("ALLOWED: reply create when private/data.confirmedAdult == true", async () => { await seed(); await assertSucceeds(createReplyDoc(bob())); });
    it("DENIED: reply create without attestation", async () => { await seed({ privB: {} }); await assertFails(createReplyDoc(bob())); });
    it("DENIED: post create while private/data.restricted == true (no until)", async () => { await seed({ privA: { confirmedAdult: true, restricted: true } }); await assertFails(createPostDoc(alice(), "p5")); });
    it("DENIED: post create while restrictedUntil is in the future", async () => { await seed({ privA: { confirmedAdult: true, restricted: true, restrictedUntil: new Date(Date.now() + 3600e3) } }); await assertFails(createPostDoc(alice(), "p6")); });
    // canPublish() does not evaluate restrictedUntil (expression ceiling); clearExpiredRestrictions
    // (every 10 min) flips `restricted` to false after expiry. Until then create is still denied.
    it("DENIED: post create after restrictedUntil passed but before the sweeper cleared `restricted`", async () => { await seed({ privA: { confirmedAdult: true, restricted: true, restrictedUntil: new Date(Date.now() - 3600e3) } }); await assertFails(createPostDoc(alice(), "p7")); });
    it("ALLOWED: post create once the sweeper has set restricted:false", async () => { await seed({ privA: { confirmedAdult: true, restricted: false, restrictedBy: "system-expiry" } }); await assertSucceeds(createPostDoc(alice(), "p7b")); });
    it("ALLOWED: post EDIT after restrictedUntil passed (notRestricted keeps the time leg)", async () => { await seed({ privA: { confirmedAdult: true, restricted: true, restrictedUntil: new Date(Date.now() - 3600e3) } }); await assertSucceeds(alice().collection("posts").doc("live_alice").update({ text: "edit", editedAt: serverTimestamp() })); });
    it("ALLOWED: post create when the PUBLIC doc still says restricted but private/data does not (private is the source of truth)", async () => { await seed(); await env.withSecurityRulesDisabled(async (c) => c.firestore().collection("users").doc("alice").set({ restricted: true }, { merge: true })); await assertSucceeds(createPostDoc(alice(), "p8")); });
    it("DENIED: restricted author edits own post", async () => { await seed({ privA: { confirmedAdult: true, restricted: true } }); await assertFails(alice().collection("posts").doc("live_alice").update({ text: "edit", editedAt: serverTimestamp() })); });
    it("DENIED: restricted author replies", async () => { await seed({ privB: { confirmedAdult: true, restricted: true } }); await assertFails(createReplyDoc(bob())); });
    it("ALLOWED: restricted user can still delete own user doc? NO — self-delete stays blocked while restricted", async () => { await seed({ privA: { confirmedAdult: true, restricted: true } }); await assertFails(alice().collection("users").doc("alice").delete()); });
  });
});
