// Emulator-backed unit tests for the Cloud Functions Admin-SDK logic that the
// 2026-06-08 audit remediation changed:
//   - M-1   reply pending-review hold      (setReplyPendingReview / setReplyLive)
//   - F-2   like cleanup on deletion       (cleanupLikesForUid)
//   - F-1   counter dedup idempotency      (claimedTransaction)
//   - F-5   rate limiting                  (checkRateLimit, incl. failClosed window)
//   - cascade helper termination           (cleanupRepliesForUid)
//
// Run with:
//   cd functions-tests && npm install && npm test
//
// The npm script wraps this in `firebase emulators:exec --only firestore`, which
// sets FIRESTORE_EMULATOR_HOST + GCLOUD_PROJECT. Requiring ../functions/index.js
// then points the Admin SDK at the emulator; we reuse that module's db + helpers
// via its __test export so there's a single firebase-admin instance.

const assert = require("assert");

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error("FIRESTORE_EMULATOR_HOST not set — run via `npm test` (firebase emulators:exec).");
}
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "toska-test";

const fns = require("../functions/index.js");
const { __test } = fns;
const { db, FieldValue, setReplyPendingReview, setReplyLive, cleanupLikesForUid,
        cleanupRepliesForUid, claimedTransaction, checkRateLimit,
        isPostExplicitCrisis, isPostConcerning, computePostFlagReason,
        computeReplyFlagReason } = __test;

const PROJECT_ID = process.env.GCLOUD_PROJECT;

async function clearFirestore() {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const res = await fetch(
    `http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`,
    { method: "DELETE" }
  );
  if (!res.ok && res.status !== 200) {
    throw new Error(`clearFirestore failed: ${res.status}`);
  }
}

function replyRef(postId, replyId) {
  return db.collection("posts").doc(postId).collection("replies").doc(replyId);
}

beforeEach(async () => { await clearFirestore(); });

// ─────────────────────────────────────────────────────────────────────
// M-1: setReplyPendingReview — recoverable hold
// ─────────────────────────────────────────────────────────────────────
describe("M-1 setReplyPendingReview", () => {
  it("holds a clean reply: sets pending_review + reason + timestamp, returns true", async () => {
    const ref = replyRef("p", "r");
    await ref.set({ authorId: "u", text: "I miss Sarah Johnson", createdAt: FieldValue.serverTimestamp() });
    const changed = await setReplyPendingReview(ref, "pii");
    assert.strictEqual(changed, true);
    const snap = await ref.get();
    assert.strictEqual(snap.get("moderationStatus"), "pending_review");
    assert.strictEqual(snap.get("pendingReason"), "pii");
    assert.ok(snap.get("pendingDetectedAt"), "pendingDetectedAt should be set");
  });

  it("is idempotent: a second call on an already-held reply is a no-op (returns false)", async () => {
    const ref = replyRef("p", "r");
    await ref.set({ authorId: "u", text: "x", moderationStatus: "pending_review", pendingReason: "pii" });
    const changed = await setReplyPendingReview(ref, "abuse_link");
    assert.strictEqual(changed, false);
    const snap = await ref.get();
    assert.strictEqual(snap.get("pendingReason"), "pii", "first reason must win");
  });

  it("returns false for a missing reply", async () => {
    const changed = await setReplyPendingReview(replyRef("p", "ghost"), "pii");
    assert.strictEqual(changed, false);
  });
});

// ─────────────────────────────────────────────────────────────────────
// M-1: setReplyLive — promote clean reply, never override a hold
// ─────────────────────────────────────────────────────────────────────
describe("M-1 setReplyLive", () => {
  it("promotes a field-less (clean) reply to live", async () => {
    const ref = replyRef("p", "r");
    await ref.set({ authorId: "u", text: "stay strong", createdAt: FieldValue.serverTimestamp() });
    await setReplyLive(ref);
    assert.strictEqual((await ref.get()).get("moderationStatus"), "live");
  });

  it("does NOT override a concurrent pending_review hold", async () => {
    const ref = replyRef("p", "r");
    await ref.set({ authorId: "u", text: "x", moderationStatus: "pending_review", pendingReason: "pii" });
    await setReplyLive(ref);
    assert.strictEqual((await ref.get()).get("moderationStatus"), "pending_review");
  });

  it("is a no-op on an already-live reply", async () => {
    const ref = replyRef("p", "r");
    await ref.set({ authorId: "u", text: "x", moderationStatus: "live" });
    await setReplyLive(ref);
    assert.strictEqual((await ref.get()).get("moderationStatus"), "live");
  });
});

// ─────────────────────────────────────────────────────────────────────
// F-2: cleanupLikesForUid — likes on OTHER users' content + the indices
// ─────────────────────────────────────────────────────────────────────
describe("F-2 cleanupLikesForUid", () => {
  it("deletes the user's like docs on others' posts/replies AND the reverse indices", async () => {
    const uid = "u";
    // Reverse indices the user maintains.
    await db.collection("users").doc(uid).collection("liked").doc("postA").set({ createdAt: new Date() });
    await db.collection("users").doc(uid).collection("liked").doc("postB").set({ createdAt: new Date() });
    await db.collection("users").doc(uid).collection("likedReplies").doc("replyX")
      .set({ postId: "postP", createdAt: new Date() });
    // The actual like docs on third-party content (keyed by the liker's uid).
    await db.collection("posts").doc("postA").collection("likes").doc(uid).set({ createdAt: new Date() });
    await db.collection("posts").doc("postB").collection("likes").doc(uid).set({ createdAt: new Date() });
    await db.collection("posts").doc("postP").collection("replies").doc("replyX")
      .collection("likes").doc(uid).set({ createdAt: new Date() });

    const res = await cleanupLikesForUid(uid, 50);
    assert.strictEqual(res.capHit, false);

    for (const p of ["postA", "postB"]) {
      assert.strictEqual((await db.collection("posts").doc(p).collection("likes").doc(uid).get()).exists, false,
        `like on ${p} should be gone`);
    }
    assert.strictEqual(
      (await db.collection("posts").doc("postP").collection("replies").doc("replyX").collection("likes").doc(uid).get()).exists,
      false, "reply-like should be gone");
    assert.strictEqual((await db.collection("users").doc(uid).collection("liked").get()).empty, true, "liked index drained");
    assert.strictEqual((await db.collection("users").doc(uid).collection("likedReplies").get()).empty, true, "likedReplies index drained");
  });

  it("reports capHit when the index exceeds the per-pass budget", async () => {
    const uid = "u";
    const batch = db.batch();
    for (let i = 0; i < 300; i++) {
      batch.set(db.collection("users").doc(uid).collection("liked").doc(`post${i}`), { createdAt: new Date() });
    }
    await batch.commit();
    // maxIterations=1 → one 250-doc page → capHit (300 > 250).
    const res = await cleanupLikesForUid(uid, 1);
    assert.strictEqual(res.capHit, true);
  });
});

// ─────────────────────────────────────────────────────────────────────
// F-1: claimedTransaction — atomic dedup, idempotent under redelivery
// ─────────────────────────────────────────────────────────────────────
describe("F-1 claimedTransaction", () => {
  it("applies the write once, then skips a redelivered (same eventId+subKey) event", async () => {
    const counter = db.collection("posts").doc("p");
    await counter.set({ replyCount: 0 });
    const apply = (eventId) => claimedTransaction(eventId, "replyCount", async (tx) => {
      const snap = await tx.get(counter);
      if (!snap.exists) return;
      tx.update(counter, { replyCount: FieldValue.increment(1) });
    });
    await apply("evt-1");
    await apply("evt-1"); // redelivery — must be skipped by the claim
    assert.strictEqual((await counter.get()).get("replyCount"), 1, "redelivery must not double-count");
  });

  it("rolls back the claim and re-throws when the transaction fn throws (so Eventarc retries)", async () => {
    let threw = false;
    try {
      await claimedTransaction("evt-err", "k", async () => { throw new Error("boom"); });
    } catch (e) { threw = true; }
    assert.strictEqual(threw, true, "must re-throw for redelivery");
    // Claim doc must NOT exist (rolled back), so a retry can re-run.
    const claim = await db.collection("processedTriggerEvents").doc("evt-err_k").get();
    assert.strictEqual(claim.exists, false, "claim must not be set on failure");
  });

  it("independent subKeys both apply (paired-write counters don't block each other)", async () => {
    const a = db.collection("posts").doc("a"); const b = db.collection("users").doc("b");
    await a.set({ c: 0 }); await b.set({ c: 0 });
    await claimedTransaction("evt-2", "post", async (tx) => { tx.update(a, { c: FieldValue.increment(1) }); });
    await claimedTransaction("evt-2", "user", async (tx) => { tx.update(b, { c: FieldValue.increment(1) }); });
    assert.strictEqual((await a.get()).get("c"), 1);
    assert.strictEqual((await b.get()).get("c"), 1);
  });
});

// ─────────────────────────────────────────────────────────────────────
// F-5: checkRateLimit — sliding window allow/deny
// ─────────────────────────────────────────────────────────────────────
describe("F-5 checkRateLimit", () => {
  it("allows up to the max within the window, then denies", async () => {
    const uid = "rl-user";
    assert.strictEqual(await checkRateLimit(uid, "giphyProxy", 2, 60), true);
    assert.strictEqual(await checkRateLimit(uid, "giphyProxy", 2, 60), true);
    assert.strictEqual(await checkRateLimit(uid, "giphyProxy", 2, 60), false, "3rd call over max=2 denied");
  });

  it("throws on an unknown (non-allowlisted) endpoint", async () => {
    let threw = false;
    try { await checkRateLimit("u", "totally-unknown", 5, 60); } catch (e) { threw = true; }
    assert.strictEqual(threw, true);
  });
});

// ─────────────────────────────────────────────────────────────────────
// Deletion cascade helper: cleanupRepliesForUid (collectionGroup, capHit)
// ─────────────────────────────────────────────────────────────────────
describe("cascade cleanupRepliesForUid", () => {
  it("deletes the user's replies across posts and terminates (capHit false)", async () => {
    const uid = "author";
    await replyRef("p1", "r1").set({ authorId: uid, text: "a", createdAt: new Date() });
    await replyRef("p2", "r2").set({ authorId: uid, text: "b", createdAt: new Date() });
    await replyRef("p1", "other").set({ authorId: "someone-else", text: "c", createdAt: new Date() });

    const res = await cleanupRepliesForUid(uid, 50);
    assert.strictEqual(res.capHit, false);
    assert.strictEqual((await replyRef("p1", "r1").get()).exists, false);
    assert.strictEqual((await replyRef("p2", "r2").get()).exists, false);
    assert.strictEqual((await replyRef("p1", "other").get()).exists, true, "other users' replies untouched");
  });
});

// ─────────────────────────────────────────────────────────────────────
// #1: Crisis / abuse classifiers (index.js) — safety-critical, were untested.
// Pure functions, no Firestore. isPostExplicitCrisis → holds AND pages admins;
// isPostConcerning → holds (no page); computePost/ReplyFlagReason → abuse/PII.
// ─────────────────────────────────────────────────────────────────────
describe("#1 crisis detection — isPostExplicitCrisis (pages admins)", () => {
  const mustPage = [
    "i want to kill myself",
    "i feel so suicidal lately",
    "i keep thinking about ending my life",
    "honestly i just want to die",
    "i've been cutting myself again",
    "i want to k1ll myself",            // leetspeak evasion
    "i feel s u i c i d a l",           // spaced-letter evasion
  ];
  mustPage.forEach((t) => it(`flags: ${JSON.stringify(t)}`, () => {
    assert.strictEqual(isPostExplicitCrisis(t), true);
  }));

  const mustNotPage = [
    "this breakup is killing me",       // idiom, not self-harm
    "i could die of embarrassment",     // idiom
    "i'm so done with him",             // venting
    "i can't do this anymore",          // soft distress, not EXPLICIT (still concerning)
    "we broke up and i'm finally okay",
  ];
  mustNotPage.forEach((t) => it(`does NOT page: ${JSON.stringify(t)}`, () => {
    assert.strictEqual(isPostExplicitCrisis(t), false);
  }));
});

describe("#1 crisis detection — isPostConcerning (holds, no page)", () => {
  ["i can't go on", "nobody would miss me", "there's no point in living",
   "i want to kill myself" /* explicit ⊂ concerning */
  ].forEach((t) => it(`holds: ${JSON.stringify(t)}`, () => {
    assert.strictEqual(isPostConcerning(t), true);
  }));

  ["had coffee with a friend today", "we broke up last month and i'm okay now"
  ].forEach((t) => it(`does NOT hold: ${JSON.stringify(t)}`, () => {
    assert.strictEqual(isPostConcerning(t), false);
  }));

  it("explicit crisis is a subset of concerning (invariant)", () => {
    const t = "i want to kill myself";
    assert.ok(isPostExplicitCrisis(t) && isPostConcerning(t));
  });
});

describe("#1 abuse mapping — computePostFlagReason", () => {
  const cases = [
    ["you stupid f@ggot",            "hate_speech"],
    ["i will kill you for this",     "targeted_threat"],
    ["just kys already",             "harassment"],
    ["dm me to send nudes",          "sexual_content"],
    ["buy bitcoin now, limited time","spam_or_commercial"],
    ["my number is 5551234567",      "personal_information"],
    ["i miss the way things were between us", null],
  ];
  cases.forEach(([t, reason]) => it(`${JSON.stringify(t)} → ${reason}`, () => {
    assert.strictEqual(computePostFlagReason(t), reason);
  }));
});

describe("#1 abuse mapping — computeReplyFlagReason (post/reply asymmetry source)", () => {
  it("hate on a reply → 'hate_speech' (caller hard-deletes)", () => {
    assert.strictEqual(computeReplyFlagReason("you f@ggot"), "hate_speech");
  });
  it("PII on a reply → 'personal_information' (caller now HOLDS, M-1)", () => {
    assert.strictEqual(computeReplyFlagReason("my ex Sarah Johnson did this"), "personal_information");
  });
  it("clean reply → null", () => {
    assert.strictEqual(computeReplyFlagReason("i'm so sorry you're going through this"), null);
  });
});

// ─────────────────────────────────────────────────────────────────────
// #2: Trigger-level orchestration — the handlers route correctly end-to-end.
// v2 functions expose .run(cloudEvent); we pass { id, data: <snapshot>, params }.
// ─────────────────────────────────────────────────────────────────────
async function snapOf(path) { return db.doc(path).get(); }

describe("#2 trigger orchestration — validateReply (M-1)", () => {
  it("clean reply → promoted to live", async () => {
    await replyRef("p", "r").set({ authorId: "u", text: "i'm so sorry, stay strong", createdAt: new Date() });
    await fns.validateReply.run({ id: "e1", data: await snapOf("posts/p/replies/r"), params: { postId: "p", replyId: "r" } });
    assert.strictEqual((await replyRef("p", "r").get()).get("moderationStatus"), "live");
  });

  it("PII reply → HELD (pending_review), NOT deleted", async () => {
    await replyRef("p", "r2").set({ authorId: "u", text: "my ex Sarah Johnson did this to me", createdAt: new Date() });
    await fns.validateReply.run({ id: "e2", data: await snapOf("posts/p/replies/r2"), params: { postId: "p", replyId: "r2" } });
    const snap = await replyRef("p", "r2").get();
    assert.strictEqual(snap.exists, true, "reply must NOT be deleted (M-1 recoverable hold)");
    assert.strictEqual(snap.get("moderationStatus"), "pending_review");
    assert.strictEqual(snap.get("pendingReason"), "pii");
  }).timeout(8000); // moderationDeleteJitter sleeps 1.5–3s on the PII path

  it("blank reply → hard-deleted", async () => {
    await replyRef("p", "r3").set({ authorId: "u", text: "   ", createdAt: new Date() });
    await fns.validateReply.run({ id: "e3", data: await snapOf("posts/p/replies/r3"), params: { postId: "p", replyId: "r3" } });
    assert.strictEqual((await replyRef("p", "r3").get()).exists, false);
  });
});

describe("#2 trigger orchestration — validatePost", () => {
  it("clean post → promoted to live", async () => {
    await db.doc("posts/pc").set({ authorId: "u", text: "i keep replaying our last conversation", likeCount: 0, repostCount: 0, replyCount: 0, createdAt: new Date() });
    await fns.validatePost.run({ id: "e4", data: await snapOf("posts/pc"), params: { postId: "pc" } });
    assert.strictEqual((await db.doc("posts/pc").get()).get("moderationStatus"), "live");
  });

  it("PII post → HELD (pending_review), NOT deleted", async () => {
    await db.doc("posts/pp").set({ authorId: "u", text: "call my ex at 5551234567", likeCount: 0, repostCount: 0, replyCount: 0, createdAt: new Date() });
    await fns.validatePost.run({ id: "e5", data: await snapOf("posts/pp"), params: { postId: "pp" } });
    const snap = await db.doc("posts/pp").get();
    assert.strictEqual(snap.exists, true);
    assert.strictEqual(snap.get("moderationStatus"), "pending_review");
    assert.strictEqual(snap.get("pendingReason"), "pii");
  }).timeout(8000);
});

// ─────────────────────────────────────────────────────────────────────
// #3: Counter-trigger guards — a reply-repost must bump ONLY the reply's
// repostCount, never the parent post's (the originalReplyId exclusion).
// ─────────────────────────────────────────────────────────────────────
describe("#3 counter guards — reply-repost does not double-count", () => {
  it("reply-repost increments reply.repostCount but NOT origPost.repostCount", async () => {
    await db.doc("posts/origPost").set({ authorId: "A", text: "orig", isRepost: false, repostCount: 0, likeCount: 0, replyCount: 0, createdAt: new Date() });
    await db.doc("posts/origPost/replies/origReply").set({ authorId: "B", text: "a reply", repostCount: 0, likeCount: 0, createdAt: new Date() });
    await db.doc("posts/repost1").set({ authorId: "C", text: "a reply", isRepost: true, originalPostId: "origPost", originalReplyId: "origReply", originalAuthorId: "B", repostCount: 0, likeCount: 0, replyCount: 0, createdAt: new Date() });
    const ev = { id: "rr1", data: await snapOf("posts/repost1"), params: { postId: "repost1" } };

    await fns.onReplyRepostCreatedUpdateCount.run(ev);
    await fns.onRepostCreatedUpdateCount.run(ev); // must early-return on originalReplyId guard

    assert.strictEqual((await db.doc("posts/origPost/replies/origReply").get()).get("repostCount"), 1, "reply counter +1");
    assert.strictEqual((await db.doc("posts/origPost").get()).get("repostCount"), 0, "parent post counter untouched");
  });
});

// ─────────────────────────────────────────────────────────────────────
// #4: Deletion-cascade completeness — onUserDocDeleted erases the user's
// data across every collection (posts, replies/likes on others, follow
// edges, notifications authored, reposts, drafts), incl. the F-2 like cleanup.
// ─────────────────────────────────────────────────────────────────────
describe("#4 deletion cascade — onUserDocDeleted completeness", () => {
  it("erases the user's data across all surfaces", async () => {
    const uid = "victim";
    await db.doc(`users/${uid}`).set({ handle: "victim", confirmedAdult: true });
    // own post
    await db.doc("posts/own").set({ authorId: uid, text: "mine", isRepost: false, createdAt: new Date() });
    // reply on someone else's post
    await db.doc("posts/foreign/replies/myreply").set({ authorId: uid, text: "hi", createdAt: new Date() });
    // like on someone else's post (+ reverse index)
    await db.doc(`users/${uid}/liked/foreign`).set({ createdAt: new Date() });
    await db.doc("posts/foreign/likes/" + uid).set({ createdAt: new Date() });
    // follow edge (both mirrors)
    await db.doc(`users/${uid}/following/peer`).set({ handle: "peer", createdAt: new Date() });
    await db.doc(`users/peer/followers/${uid}`).set({ handle: "victim", createdAt: new Date() });
    // notification authored by uid in someone else's inbox
    await db.doc(`users/peer/notifications/n1`).set({ fromUserId: uid, type: "follow", isRead: false, createdAt: new Date() });
    // repost authored by uid of someone else's post
    await db.doc("posts/myrepost").set({ authorId: uid, isRepost: true, originalAuthorId: "peer", originalPostId: "x", text: "y", createdAt: new Date() });
    // draft
    await db.doc(`users/${uid}/drafts/d1`).set({ text: "draft", createdAt: new Date() });

    await fns.onUserDocDeleted.run({ data: await snapOf(`users/${uid}`), params: { userId: uid } });

    const gone = async (p) => assert.strictEqual((await db.doc(p).get()).exists, false, `${p} should be erased`);
    await gone("posts/own");
    await gone("posts/foreign/replies/myreply");
    await gone("posts/foreign/likes/" + uid);
    await gone(`users/${uid}/liked/foreign`);
    await gone(`users/${uid}/following/peer`);
    await gone(`users/peer/followers/${uid}`);
    await gone(`users/peer/notifications/n1`);
    await gone("posts/myrepost");
    await gone(`users/${uid}/drafts/d1`);
  }).timeout(15000);
});

// ─────────────────────────────────────────────────────────────────────
// M-1 leak regression: enrichReplyNotification must NOT backfill a held
// reply's (possibly-PII) text into the post author's notification preview.
// ─────────────────────────────────────────────────────────────────────
describe("M-1 enrichReplyNotification — no held-reply text leak", () => {
  async function runEnrich(userId, notifId) {
    return fns.enrichReplyNotification.run({
      data: await db.doc(`users/${userId}/notifications/${notifId}`).get(),
      params: { userId, notifId },
    });
  }

  it("does NOT set message when the backing reply is held (pending_review)", async () => {
    await db.doc("users/author/notifications/reply_p_actor")
      .set({ type: "reply", fromUserId: "actor", postId: "p", isRead: false, createdAt: new Date() });
    await replyRef("p", "r").set({
      authorId: "actor", text: "my ex Sarah Johnson did this", createdAt: new Date(),
      moderationStatus: "pending_review", pendingReason: "pii",
    });
    await runEnrich("author", "reply_p_actor");
    const snap = await db.doc("users/author/notifications/reply_p_actor").get();
    assert.strictEqual(snap.get("message"), undefined, "held reply text must not leak into the preview");
  });

  it("DOES backfill message for a normal (live) reply", async () => {
    await db.doc("users/author/notifications/reply_p_actor2")
      .set({ type: "reply", fromUserId: "actor", postId: "p2", isRead: false, createdAt: new Date() });
    await replyRef("p2", "r").set({
      authorId: "actor", text: "i'm here for you", createdAt: new Date(), moderationStatus: "live",
    });
    await runEnrich("author", "reply_p_actor2");
    const snap = await db.doc("users/author/notifications/reply_p_actor2").get();
    assert.strictEqual(snap.get("message"), "i'm here for you");
  });
});

// ─────────────────────────────────────────────────────────────────────
// #1 (edge fix): replyCount tracks VISIBLE replies, not all replies.
// ─────────────────────────────────────────────────────────────────────
describe("#1 replyCount visibility tracking", () => {
  const change = (b, a) => ({ before: { data: () => b }, after: { data: () => a } });

  it("holding a reply (visible->hidden) decrements replyCount", async () => {
    await db.doc("posts/p").set({ replyCount: 3 });
    await fns.onReplyVisibilityCountAdjust.run({ id: "v1", data: change({}, { moderationStatus: "pending_review" }), params: { postId: "p", replyId: "r" } });
    assert.strictEqual((await db.doc("posts/p").get()).get("replyCount"), 2);
  });
  it("approving a held reply (hidden->visible) increments replyCount", async () => {
    await db.doc("posts/p").set({ replyCount: 2 });
    await fns.onReplyVisibilityCountAdjust.run({ id: "v2", data: change({ moderationStatus: "pending_review" }, { moderationStatus: "live" }), params: { postId: "p", replyId: "r" } });
    assert.strictEqual((await db.doc("posts/p").get()).get("replyCount"), 3);
  });
  it("a text edit with no visibility change does NOT touch replyCount", async () => {
    await db.doc("posts/p").set({ replyCount: 5 });
    await fns.onReplyVisibilityCountAdjust.run({ id: "v3", data: change({ moderationStatus: "live", text: "a" }, { moderationStatus: "live", text: "b" }), params: { postId: "p", replyId: "r" } });
    assert.strictEqual((await db.doc("posts/p").get()).get("replyCount"), 5);
  });
  it("field-less -> live (clean promote) does NOT touch replyCount", async () => {
    await db.doc("posts/p").set({ replyCount: 5 });
    await fns.onReplyVisibilityCountAdjust.run({ id: "v4", data: change({}, { moderationStatus: "live" }), params: { postId: "p", replyId: "r" } });
    assert.strictEqual((await db.doc("posts/p").get()).get("replyCount"), 5);
  });
  it("deleting an already-HELD reply does NOT decrement (was never counted)", async () => {
    await db.doc("posts/p").set({ replyCount: 4 });
    await fns.onReplyDeletedUpdateCount.run({ id: "d1", data: { data: () => ({ moderationStatus: "pending_review" }) }, params: { postId: "p", replyId: "r" } });
    assert.strictEqual((await db.doc("posts/p").get()).get("replyCount"), 4);
  });
  it("deleting a LIVE reply DOES decrement", async () => {
    await db.doc("posts/p").set({ replyCount: 4 });
    await fns.onReplyDeletedUpdateCount.run({ id: "d2", data: { data: () => ({ moderationStatus: "live" }) }, params: { postId: "p", replyId: "r" } });
    assert.strictEqual((await db.doc("posts/p").get()).get("replyCount"), 3);
  });
});

// #2 (edge fix): a link-bearing reply is held with pendingReason "abuse_link",
// a name reply with "pii".
describe("#2 reply hold reason: link vs name", () => {
  it("link reply → held with pendingReason 'abuse_link'", async () => {
    await replyRef("p", "rl").set({ authorId: "u", text: "find his profile at www.evilsite.com", createdAt: new Date() });
    await fns.validateReply.run({ id: "lr1", data: await db.doc("posts/p/replies/rl").get(), params: { postId: "p", replyId: "rl" } });
    const s = await replyRef("p", "rl").get();
    assert.strictEqual(s.get("moderationStatus"), "pending_review");
    assert.strictEqual(s.get("pendingReason"), "abuse_link");
  }).timeout(8000);
  it("name reply → held with pendingReason 'pii'", async () => {
    await replyRef("p", "rn").set({ authorId: "u", text: "my ex Sarah Johnson did this", createdAt: new Date() });
    await fns.validateReply.run({ id: "nr1", data: await db.doc("posts/p/replies/rn").get(), params: { postId: "p", replyId: "rn" } });
    const s = await replyRef("p", "rn").get();
    assert.strictEqual(s.get("pendingReason"), "pii");
  }).timeout(8000);
});
