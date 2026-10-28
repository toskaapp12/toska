// A1 (2026-10-27 staging audit): held / crisis-held posts and replies must be readable ONLY by their
// author and admins. Before the fix, the posts/replies list rules allowed any query that did not
// constrain moderationStatus (where flagged==true, where pendingReason=="crisis", where authorId==X,
// a bare orderBy, a replies subcollection with no filter…), because moderationVisible() used
// data.get('moderationStatus','live') — an unconstrained field is "possibly absent", so the default
// made the clause satisfiable. These tests pin every shape found on staging.
//
// Run: cd firestore-tests && npm run test:rules   (or mocha this file under emulators:exec)

const { initializeTestEnvironment, assertSucceeds, assertFails } = require("@firebase/rules-unit-testing");
const fs = require("fs");
const path = require("path");

const PROJECT_ID = "toska-test";
const RULES_PATH = path.join(__dirname, "..", "firestore.rules");
let env;

const base = (authorId, extra = {}) => ({
  authorId, authorHandle: `handle_${authorId}`, text: "hello there", createdAt: new Date(),
  likeCount: 0, repostCount: 0, replyCount: 0, isRepost: false, tag: "longing", ...extra,
});

async function seed() {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const uid of ["alice", "bob", "modmin"]) {
      await db.collection("users").doc(uid).set({ handle: `handle_${uid}`, followerCount: 0, followingCount: 0, totalLikes: 0 });
      await db.doc(`users/${uid}/private/data`).set({ confirmedAdult: true }); // A5
    }
    await db.collection("admins").doc("modmin").set({ role: "admin" });
    await db.collection("posts").doc("live_alice").set(base("alice", { moderationStatus: "live" }));
    await db.collection("posts").doc("held_pii").set(base("alice", { moderationStatus: "pending_review", pendingReason: "pii", flagged: true, flagReason: "personal_information", text: "my ex Jessica Martinez" }));
    await db.collection("posts").doc("held_crisis").set(base("alice", { moderationStatus: "pending_review", pendingReason: "crisis", concerningContent: true, text: "i want to die tonight" }));
    await db.collection("posts").doc("pending_validation_alice").set(base("alice", { moderationStatus: "pending_validation" }));
    await db.collection("posts").doc("legacy_nostatus").set(base("alice"));
    await db.collection("posts").doc("held_bob").set(base("bob", { moderationStatus: "pending_review", pendingReason: "pii", flagged: true }));
    const replies = db.collection("posts").doc("live_alice").collection("replies");
    await replies.doc("r_live_bob").set({ authorId: "bob", authorHandle: "handle_bob", text: "kind words", createdAt: new Date(), likeCount: 0, moderationStatus: "live" });
    await replies.doc("r_held_carol").set({ authorId: "carol", authorHandle: "handle_carol", text: "call me 415 555 0199", createdAt: new Date(), likeCount: 0, moderationStatus: "pending_review", pendingReason: "pii" });
    await replies.doc("r_held_bob").set({ authorId: "bob", authorHandle: "handle_bob", text: "my ex Daniel Whitfield", createdAt: new Date(), likeCount: 0, moderationStatus: "pending_review", pendingReason: "pii" });
  });
}

describe("A1 held-content enumeration (scoped hooks — mocha root hooks are global across files)", () => {
before(async () => {
  env = await initializeTestEnvironment({ projectId: PROJECT_ID, firestore: { rules: fs.readFileSync(RULES_PATH, "utf8"), host: "localhost", port: 8080 } });
});
after(async () => { if (env) await env.cleanup(); });
beforeEach(async () => { await env.clearFirestore(); await seed(); });

const bob = () => env.authenticatedContext("bob").firestore();
const alice = () => env.authenticatedContext("alice").firestore();
const admin = () => env.authenticatedContext("modmin").firestore();
const anon = () => env.unauthenticatedContext().firestore();

describe("A1: held content enumeration — posts (list)", () => {
  it("DENIED: where flagged == true (no status filter)", () => assertFails(bob().collection("posts").where("flagged", "==", true).get()));
  it("DENIED: where concerningContent == true", () => assertFails(bob().collection("posts").where("concerningContent", "==", true).get()));
  it("DENIED: where pendingReason == 'crisis'", () => assertFails(bob().collection("posts").where("pendingReason", "==", "crisis").get()));
  it("DENIED: where pendingReason == 'pii'", () => assertFails(bob().collection("posts").where("pendingReason", "==", "pii").get()));
  it("DENIED: where authorId == <other user> with no status filter", () => assertFails(bob().collection("posts").where("authorId", "==", "alice").get()));
  it("DENIED: bare orderBy createdAt", () => assertFails(bob().collection("posts").orderBy("createdAt", "desc").limit(40).get()));
  it("DENIED: no filter at all", () => assertFails(bob().collection("posts").limit(10).get()));
  it("DENIED: where tag == 'longing' only", () => assertFails(bob().collection("posts").where("tag", "==", "longing").get()));
  it("DENIED: where moderationStatus == 'pending_review' (explicit non-live)", () => assertFails(bob().collection("posts").where("moderationStatus", "==", "pending_review").get()));
  it("DENIED: where moderationStatus in [pending_review, pending_validation]", () => assertFails(bob().collection("posts").where("moderationStatus", "in", ["pending_review", "pending_validation"]).get()));
  it("DENIED: where moderationStatus != 'live'", () => assertFails(bob().collection("posts").where("moderationStatus", "!=", "live").get()));
  it("DENIED: logged-out list of live posts", () => assertFails(anon().collection("posts").where("moderationStatus", "==", "live").get()));

  it("ALLOWED: where moderationStatus == 'live' (the feed query)", () => assertSucceeds(bob().collection("posts").where("moderationStatus", "==", "live").orderBy("createdAt", "desc").limit(60).get()));
  it("ALLOWED: live + authorId == other (other profile query)", () => assertSucceeds(bob().collection("posts").where("moderationStatus", "==", "live").where("authorId", "==", "alice").orderBy("createdAt", "desc").get()));
  it("ALLOWED: live + tag (explore)", () => assertSucceeds(bob().collection("posts").where("moderationStatus", "==", "live").where("tag", "==", "longing").where("isRepost", "==", false).get()));
  it("ALLOWED: own posts by authorId == me, any status (own profile incl. held)", () => assertSucceeds(bob().collection("posts").where("authorId", "==", "bob").orderBy("createdAt", "desc").get()));
  it("ALLOWED: own held posts by authorId == me AND status == pending_review", () => assertSucceeds(bob().collection("posts").where("authorId", "==", "bob").where("moderationStatus", "==", "pending_review").get()));
  it("ALLOWED: admin lists held posts (moderation queue)", () => assertSucceeds(admin().collection("posts").where("moderationStatus", "==", "pending_review").get()));
  it("ALLOWED: admin lists flagged posts", () => assertSucceeds(admin().collection("posts").where("flagged", "==", true).get()));
  it("ALLOWED: admin lists concerning posts (crisis queue)", () => assertSucceeds(admin().collection("posts").where("concerningContent", "==", true).get()));
});

describe("A1: held content — posts (get)", () => {
  it("DENIED: other user gets a held (pii) post", () => assertFails(bob().collection("posts").doc("held_pii").get()));
  it("DENIED: other user gets a crisis-held post", () => assertFails(bob().collection("posts").doc("held_crisis").get()));
  it("DENIED: other user gets a pending_validation post", () => assertFails(bob().collection("posts").doc("pending_validation_alice").get()));
  it("DENIED: other user gets a legacy post with NO moderationStatus (no default-to-live)", () => assertFails(bob().collection("posts").doc("legacy_nostatus").get()));
  it("ALLOWED: other user gets a live post", () => assertSucceeds(bob().collection("posts").doc("live_alice").get()));
  it("ALLOWED: author gets own held post", () => assertSucceeds(alice().collection("posts").doc("held_crisis").get()));
  it("ALLOWED: author gets own legacy no-status post", () => assertSucceeds(alice().collection("posts").doc("legacy_nostatus").get()));
  it("ALLOWED: admin gets a held post", () => assertSucceeds(admin().collection("posts").doc("held_pii").get()));
  it("ALLOWED: get of a missing post resolves (not-found, not permission-denied)", () => assertSucceeds(bob().collection("posts").doc("does_not_exist").get()));
});

describe("A1: held content enumeration — replies", () => {
  const replies = (db) => db.collection("posts").doc("live_alice").collection("replies");
  it("DENIED: replies with no status filter", () => assertFails(replies(bob()).limit(50).get()));
  it("DENIED: replies orderBy createdAt only", () => assertFails(replies(bob()).orderBy("createdAt", "desc").get()));
  it("DENIED: replies where pendingReason == 'pii'", () => assertFails(replies(bob()).where("pendingReason", "==", "pii").get()));
  it("DENIED: replies where authorId == <other> with no status", () => assertFails(replies(bob()).where("authorId", "==", "carol").get()));
  it("DENIED: other user gets a held reply", () => assertFails(replies(bob()).doc("r_held_carol").get()));
  it("DENIED: post author (alice) lists held replies of OTHERS on her own post without status filter", () => assertFails(replies(alice()).limit(50).get()));
  it("ALLOWED: replies where moderationStatus == 'live' (thread query)", () => assertSucceeds(replies(bob()).where("moderationStatus", "==", "live").orderBy("createdAt", "desc").get()));
  it("ALLOWED: own replies where authorId == me, any status (thread query B)", () => assertSucceeds(replies(bob()).where("authorId", "==", "bob").orderBy("createdAt", "asc").get()));
  it("ALLOWED: reply author gets own held reply", () => assertSucceeds(replies(bob()).doc("r_held_bob").get()));
  it("ALLOWED: other user gets a live reply", () => assertSucceeds(replies(bob()).doc("r_live_bob").get()));
  it("ALLOWED: admin lists all replies", () => assertSucceeds(replies(admin()).get()));
  it("ALLOWED: own replies across posts (collectionGroup authorId == me)", () => assertSucceeds(bob().collectionGroup("replies").where("authorId", "==", "bob").get()));
  it("DENIED: collectionGroup replies of another user", () => assertFails(bob().collectionGroup("replies").where("authorId", "==", "carol").get()));
  it("DENIED: collectionGroup replies where pendingReason == pii", () => assertFails(bob().collectionGroup("replies").where("pendingReason", "==", "pii").get()));
});
});
