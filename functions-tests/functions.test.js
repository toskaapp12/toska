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
const { db, FieldValue, Timestamp, setReplyPendingReview, setReplyLive, cleanupLikesForUid,
        cleanupRepliesForUid, clearPostSubtree, claimedTransaction, checkRateLimit,
        pruneNotificationsOlderThan,
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
// MED-1 fix: pruneOldNotifications — 90-day inbox retention (privacy policy)
// ─────────────────────────────────────────────────────────────────────
describe("MED-1 pruneNotificationsOlderThan", () => {
  it("deletes notifications older than the cutoff, keeps recent ones, across users (collectionGroup)", async () => {
    const old = Timestamp.fromDate(new Date(Date.now() - 100 * 24 * 60 * 60 * 1000)); // 100d
    const recent = Timestamp.fromDate(new Date(Date.now() - 10 * 24 * 60 * 60 * 1000)); // 10d
    await db.collection("users").doc("alice").collection("notifications").doc("n_old")
      .set({ type: "like", fromUserId: "x", createdAt: old });
    await db.collection("users").doc("alice").collection("notifications").doc("n_new")
      .set({ type: "like", fromUserId: "x", createdAt: recent });
    await db.collection("users").doc("bob").collection("notifications").doc("n_old2")
      .set({ type: "reply", fromUserId: "y", message: "old preview", createdAt: old });

    const cutoff = Timestamp.fromDate(new Date(Date.now() - 90 * 24 * 60 * 60 * 1000));
    const { totalDeleted } = await pruneNotificationsOlderThan(cutoff);

    assert.strictEqual(totalDeleted, 2, "both old notifications (across both users) pruned");
    assert.strictEqual((await db.collection("users").doc("alice").collection("notifications").doc("n_old").get()).exists, false, "alice old gone");
    assert.strictEqual((await db.collection("users").doc("bob").collection("notifications").doc("n_old2").get()).exists, false, "bob old gone (with its message preview)");
    assert.strictEqual((await db.collection("users").doc("alice").collection("notifications").doc("n_new").get()).exists, true, "recent kept");
  });

  it("is a no-op when nothing is older than the cutoff", async () => {
    await db.collection("users").doc("alice").collection("notifications").doc("n1")
      .set({ type: "like", fromUserId: "x", createdAt: Timestamp.now() });
    const cutoff = Timestamp.fromDate(new Date(Date.now() - 90 * 24 * 60 * 60 * 1000));
    const { totalDeleted } = await pruneNotificationsOlderThan(cutoff);
    assert.strictEqual(totalDeleted, 0);
    assert.strictEqual((await db.collection("users").doc("alice").collection("notifications").doc("n1").get()).exists, true);
  });
});

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

// N-2 (2026-06-09 re-review): a single-post delete must drain the post's own
// subtree — replies (+ their nested likes), post likes, reflections — or held
// pending_review PII replies orphan under a deleted parent.
describe("N-2 clearPostSubtree", () => {
  it("deletes replies (+ their likes), post likes, and reflections; terminates", async () => {
    const postRef = db.collection("posts").doc("p1");
    // A held PII reply (the GDPR-sensitive case) + a live reply with a liker.
    await replyRef("p1", "held").set({
      authorId: "u1", text: "my ex Sarah Johnson", createdAt: new Date(),
      moderationStatus: "pending_review", pendingReason: "pii",
    });
    await replyRef("p1", "live").set({
      authorId: "u2", text: "hang in there", createdAt: new Date(), moderationStatus: "live",
    });
    await replyRef("p1", "live").collection("likes").doc("liker").set({ createdAt: new Date() });
    await postRef.collection("likes").doc("u3").set({ createdAt: new Date() });
    await postRef.collection("reflections").doc("ref1").set({ authorId: "p1author", text: "r", createdAt: new Date() });

    const capHit = await clearPostSubtree("p1", 20);

    assert.strictEqual(capHit, false);
    assert.strictEqual((await replyRef("p1", "held").get()).exists, false, "held PII reply must be gone");
    assert.strictEqual((await replyRef("p1", "live").get()).exists, false);
    assert.strictEqual((await replyRef("p1", "live").collection("likes").doc("liker").get()).exists, false, "reply's nested likes must be gone");
    assert.strictEqual((await postRef.collection("likes").doc("u3").get()).exists, false);
    assert.strictEqual((await postRef.collection("reflections").doc("ref1").get()).exists, false);
  });

  it("is idempotent / safe on an already-empty subtree (capHit false)", async () => {
    const capHit = await clearPostSubtree("nonexistent", 20);
    assert.strictEqual(capHit, false);
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
    "i want to k1ll myself",            // leetspeak evasion (1→i)
    "i want to ki11 myself",            // 1→l leet (the actual bug string)
    "i want to k!ll myself",            // !→i leet
    "i want to ki|| myself",            // |→l leet
    "i think about su1c1de a lot",      // 1→i inside a word
    "thinking about su!c!de tonight",   // !→i inside a word
    "i feel s u i c i d a l",           // spaced-letter evasion
    // 2026-07-01: mixed-position ambiguous glyphs — one "1" in an i-position
    // AND one in an l-position defeated the old uniform i-form/l-form pair.
    "i want to k1ll myse1f",
    "im su1cida1",
    "im ѕuicidal",                      // Cyrillic ѕ (U+0455) confusable
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
    "1 more day of this and then i'm free!",  // benign digit/! — must not FP from the leet expansion
    "he broke my heart!!! i hate this",       // benign ! run — must not FP
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
    // 2026-07-01: the MOD_THREAT narrowing to single fixed strings dropped
    // determiner/possessive phrasings — these published live with no hold.
    ["im going to burn down your house", "targeted_threat"],
    ["ill shoot up her school",          "targeted_threat"],
    // ...while the venting false-positives the narrowing targeted must stay null
    ["my whole life is burning down",    null],
    ["i always blow up at him",          null],
  ];
  cases.forEach(([t, reason]) => it(`${JSON.stringify(t)} → ${reason}`, () => {
    assert.strictEqual(computePostFlagReason(t), reason);
  }));

  // N-13 (2026-06-10 re-review): the M-2 year/number-list phone false-positive
  // fix lived only in moderation.js, but validatePost reaches the phone check
  // through computePostFlagReason → containsPII → hasPhoneNumber, which counted
  // total digits and false-positived year/score lists as "personal_information".
  // A list of independent short numbers must NOT read as a phone; a real phone
  // (contiguous 10+ run, or 10+ digits in <=4 groups) and crisis lines must.
  const n13 = [
    ["we dated in 2019 2020 2021 2022 2023, then it ended", null],   // 5-element year list — FP
    ["scores were 21 19 23 17 25 across the season",        null],   // 5-element number list — FP
    ["scores 123 456 789 012",                              null],   // 4-element list — FP (1st-pass miss)
    ["win 100 200 300 400 lottery",                         null],
    ["it happened in 2019",                                 null],
    ["text 1-800-273-8255 if you're struggling",            null],   // crisis line, not personal
    ["call me at 555 123 4567",                "personal_information"], // NANP, still caught
    ["my number is 555-123-4567",              "personal_information"],
    ["my number is 5551234567",                "personal_information"], // bare 10-digit run
    ["reach me at +44 20 7946 0958",           "personal_information"], // intl +CC
    ["call +33 6 12 34 56 78 anytime",         "personal_information"], // intl many-group (regression guard)
  ];
  n13.forEach(([t, reason]) => it(`N-13: ${JSON.stringify(t)} → ${reason}`, () => {
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
  it("threat+harassment text → same (more severe) category as posts", () => {
    const t = "kys, i will kill you";
    assert.strictEqual(computeReplyFlagReason(t), "targeted_threat");
    assert.strictEqual(computeReplyFlagReason(t), computePostFlagReason(t));
  });
});

// ─────────────────────────────────────────────────────────────────────
// #2: Trigger-level orchestration — the handlers route correctly end-to-end.
// v2 functions expose .run(cloudEvent); we pass { id, data: <snapshot>, params }.
// ─────────────────────────────────────────────────────────────────────
async function snapOf(path) { return db.doc(path).get(); }

// 2026-07-01: crisis text introduced by EDIT. Soft-concerning phrases are used
// so the explicit-crisis paging branch (FCM, unmockable here) stays cold —
// the durable-queue writes are the behavior under test.
describe("crisis on edit — onPostUpdated / onReplyUpdated", () => {
  const change = (b, a) => ({ before: { data: () => b }, after: { data: () => a } });

  it("post edit with new crisis text clears crisisReviewedAt (resurfaces in queue)", async () => {
    await db.doc("posts/pce").set({
      authorId: "u", text: "i cant go on anymore", moderationStatus: "live",
      concerningContent: true, crisisReviewedAt: new Date(),
    });
    await fns.onPostUpdated.run({
      id: "ce1",
      data: change(
        { text: "old reviewed text" },
        (await snapOf("posts/pce")).data()
      ),
      params: { postId: "pce" },
    });
    const snap = await db.doc("posts/pce").get();
    assert.strictEqual(snap.get("concerningContent"), true);
    assert.strictEqual(snap.get("crisisReviewedAt"), undefined,
      "reviewed stamp covers the OLD text; new crisis text must re-enter the unreviewed queue");
  });

  it("reply edited into crisis text re-enters the crisisReplyQueue unreviewed (C-1: no on-doc marker)", async () => {
    // C-1 (2026-07-17): crisis replies stay LIVE and UNMARKED — the crisis
    // marker lives in the admin-only crisisReplyQueue, and the reviewed:false
    // merge IS the resurfacing semantics the old crisisReviewedAt-delete
    // provided.
    await db.doc("posts/pce/replies/rce").set({
      authorId: "u", text: "i cant do this anymore", moderationStatus: "live",
    });
    await db.doc("crisisReplyQueue/pce_rce").set({
      postId: "pce", replyId: "rce", reviewed: true, detectedAt: new Date(),
    });
    await fns.onReplyUpdated.run({
      id: "ce2",
      data: change(
        { text: "totally fine reply" },
        (await snapOf("posts/pce/replies/rce")).data()
      ),
      params: { postId: "pce", replyId: "rce" },
    });
    const snap = await db.doc("posts/pce/replies/rce").get();
    assert.strictEqual(snap.get("concerningContent"), undefined,
      "crisis marker must NOT land on the world-readable reply doc");
    const queue = await db.doc("crisisReplyQueue/pce_rce").get();
    assert.strictEqual(queue.get("reviewed"), false,
      "already-reviewed entry must re-enter the unreviewed queue on a crisis edit");
  });

  it("reply edit on a deleted reply is a no-op (no ghost doc)", async () => {
    await fns.onReplyUpdated.run({
      id: "ce3",
      data: change({ text: "old" }, { text: "i cant go on anymore" }),
      params: { postId: "pce", replyId: "ghost-edit" },
    });
    assert.strictEqual((await db.doc("posts/pce/replies/ghost-edit").get()).exists, false);
  });
});

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
    // The blank-reply guard only decrements replies that were countable at
    // create (real text + authorId) — mirror a real deleted reply's data.
    await db.doc("posts/p").set({ replyCount: 4 });
    await fns.onReplyDeletedUpdateCount.run({ id: "d2", data: { data: () => ({ moderationStatus: "live", text: "a real reply", authorId: "u" }) }, params: { postId: "p", replyId: "r" } });
    assert.strictEqual((await db.doc("posts/p").get()).get("replyCount"), 3);
  });
});

// N-16: deleting a reply must clean up any reply-reposts (top-level posts with
// originalReplyId pointing at it), which previously orphaned with a dangling id.
describe("N-16 — reply delete cleans up reply-reposts", () => {
  it("removes reposts of the deleted reply, leaves reposts of other replies", async () => {
    await db.doc("posts/op16").set({ authorId: "A", text: "orig", isRepost: false, repostCount: 0, likeCount: 0, replyCount: 0, createdAt: new Date() });
    await db.doc("posts/rr16a").set({ authorId: "C", text: "a reply", isRepost: true, originalReplyId: "r16", originalPostId: "op16", originalAuthorId: "B", repostCount: 0, likeCount: 0, replyCount: 0, createdAt: new Date() });
    await db.doc("posts/rr16b").set({ authorId: "D", text: "a reply", isRepost: true, originalReplyId: "r16", originalPostId: "op16", originalAuthorId: "B", repostCount: 0, likeCount: 0, replyCount: 0, createdAt: new Date() });
    await db.doc("posts/keep16").set({ authorId: "E", text: "x", isRepost: true, originalReplyId: "OTHER", originalPostId: "op16", repostCount: 0, likeCount: 0, replyCount: 0, createdAt: new Date() });
    await fns.onReplyDeletedCleanupReposts.run({ id: "rr16", data: { data: () => ({}) }, params: { postId: "op16", replyId: "r16" } });
    assert.strictEqual((await db.doc("posts/rr16a").get()).exists, false);
    assert.strictEqual((await db.doc("posts/rr16b").get()).exists, false);
    assert.strictEqual((await db.doc("posts/keep16").get()).exists, true, "reposts of a different reply untouched");
  }).timeout(8000);
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

// M3 (2026-07-22 deep audit): fanOutToRepostCopies is paginated (PAGE=300,
// cursor on __name__) instead of one unbounded get(). Verify it still touches
// EVERY matching copy across multiple pages, respects shouldUpdate, and skips
// reply-reposts on a post-level fan-out.
describe("M3 fanOutToRepostCopies pagination", () => {
  it("updates all copies across >2 pages, honors filters", async () => {
    const N = 650; // 3 pages at PAGE=300
    let batch = db.batch(), inBatch = 0;
    for (let i = 0; i < N; i++) {
      batch.set(db.doc(`posts/m3copy${String(i).padStart(4, "0")}`), {
        authorId: `u${i}`, text: "copy", isRepost: true, originalPostId: "m3orig",
        moderationStatus: "live", repostCount: 0, likeCount: 0, replyCount: 0, createdAt: new Date(),
      });
      if (++inBatch === 400) { await batch.commit(); batch = db.batch(); inBatch = 0; }
    }
    // One already-held copy (shouldUpdate must skip it) and one reply-repost
    // (post-level fan-out must skip it even though originalPostId matches).
    batch.set(db.doc("posts/m3held"), {
      authorId: "uh", text: "copy", isRepost: true, originalPostId: "m3orig",
      moderationStatus: "pending_review", repostCount: 0, likeCount: 0, replyCount: 0, createdAt: new Date(),
    });
    batch.set(db.doc("posts/m3replyrepost"), {
      authorId: "ur", text: "reply copy", isRepost: true, originalPostId: "m3orig", originalReplyId: "someReply",
      moderationStatus: "live", repostCount: 0, likeCount: 0, replyCount: 0, createdAt: new Date(),
    });
    await batch.commit();

    const n = await fns.__test.fanOutToRepostCopies({
      originalPostId: "m3orig",
      shouldUpdate: (d) => (d.moderationStatus || "live") === "live",
      update: { moderationStatus: "pending_review", pendingReason: "original_held" },
    });
    assert.strictEqual(n, N, `should update exactly the ${N} live post-copies`);

    const still = await db.collection("posts")
      .where("originalPostId", "==", "m3orig")
      .where("moderationStatus", "==", "live").get();
    // Only the reply-repost may remain live.
    assert.strictEqual(still.size, 1);
    assert.strictEqual(still.docs[0].id, "m3replyrepost");
    const held = await db.doc("posts/m3held").get();
    assert.strictEqual(held.get("pendingReason"), undefined, "already-held copy untouched");
  }).timeout(60000);
});

// ─────────────────────────────────────────────────────────────────────
// A.5 #9 (2026-07-28): mirrorModerationState — dual-write of moderation /
// adult-gate state to private/data + the restrictedUsers admin index.
// ─────────────────────────────────────────────────────────────────────
describe("mirrorModerationState — private mirror + restrictedUsers index", () => {
  const change = (b, a) => ({
    before: { exists: b !== null, data: () => b || {} },
    after:  { exists: a !== null, data: () => a || {} },
  });
  const run = (uid, b, a, id) =>
    fns.mirrorModerationState.run({ id, data: change(b, a), params: { userId: uid } });

  it("restrict: mirrors fields to private/data and creates the index row", async () => {
    const until = new Date(Date.now() + 48 * 3600e3);
    await run("mm1",
      { handle: "mm1", restricted: false, confirmedAdult: true },
      { handle: "mm1", restricted: true, restrictedAt: new Date(), restrictedUntil: until, restrictedBy: "system", confirmedAdult: true },
      "mm-e1");
    const priv = await db.doc("users/mm1/private/data").get();
    assert.strictEqual(priv.get("restricted"), true);
    assert.strictEqual(priv.get("restrictedBy"), "system");
    assert.strictEqual(priv.get("confirmedAdult"), true);
    const row = await db.doc("restrictedUsers/mm1").get();
    assert.strictEqual(row.exists, true);
    assert.strictEqual(row.get("handle"), "mm1");
    assert.strictEqual(row.get("restrictedBy"), "system");
  });

  it("restrictedBy scrub event does NOT erase the private copy (change-guard skips)", async () => {
    const base = { handle: "mm1", restricted: true, confirmedAdult: true };
    // Self-contained: restrict first (writes restrictedBy to private), then
    // replay the auditUserRestriction scrub event (restrictedBy deleted from
    // the main doc, nothing else changed).
    await run("mm1", { handle: "mm1", restricted: false }, { ...base, restrictedBy: "system" }, "mm-e2a");
    await run("mm1", { ...base, restrictedBy: "system" }, { ...base }, "mm-e2");
    const priv = await db.doc("users/mm1/private/data").get();
    assert.strictEqual(priv.get("restrictedBy"), "system", "scrub must not clear private attribution");
    assert.strictEqual((await db.doc("restrictedUsers/mm1").get()).exists, true);
  });

  it("unrestrict: mirror updates and the index row is removed", async () => {
    await run("mm1",
      { handle: "mm1", restricted: true, confirmedAdult: true },
      { handle: "mm1", restricted: false, restrictedAt: new Date(), confirmedAdult: true },
      "mm-e3");
    const priv = await db.doc("users/mm1/private/data").get();
    assert.strictEqual(priv.get("restricted"), false);
    assert.strictEqual((await db.doc("restrictedUsers/mm1").get()).exists, false);
  });

  it("confirmAdult write is mirrored", async () => {
    await run("mm2", { handle: "mm2" }, { handle: "mm2", confirmedAdult: true, confirmedAdultAt: new Date() }, "mm-e4");
    const priv = await db.doc("users/mm2/private/data").get();
    assert.strictEqual(priv.get("confirmedAdult"), true);
    assert.ok(priv.get("confirmedAdultAt"));
    assert.strictEqual((await db.doc("restrictedUsers/mm2").get()).exists, false, "no index row for unrestricted user");
  });

  it("counter-bump update is a no-op (change-guard)", async () => {
    await db.doc("users/mm2/private/data").set({ marker: "untouched" }, { merge: true });
    await run("mm2",
      { handle: "mm2", confirmedAdult: true, postCount: 1 },
      { handle: "mm2", confirmedAdult: true, postCount: 2 },
      "mm-e5");
    const priv = await db.doc("users/mm2/private/data").get();
    assert.strictEqual(priv.get("marker"), "untouched");
  });

  it("user-doc delete removes the index row", async () => {
    await db.doc("restrictedUsers/mm3").set({ handle: "mm3" });
    await run("mm3", { handle: "mm3", restricted: true }, null, "mm-e6");
    assert.strictEqual((await db.doc("restrictedUsers/mm3").get()).exists, false);
  });
});

// ─────────────────────────────────────────────────────────────────────
// Block-re-signup (2026-07-29): identity hashing + blockBannedSignups.
// ─────────────────────────────────────────────────────────────────────
describe("block-re-signup — bannedIdentities helpers + blocking function", () => {
  const { identityHash, extractIdentities } = require("../functions/bannedIdentities");
  const PEPPER = "test-pepper";
  before(() => { process.env.BANNED_ID_PEPPER = PEPPER; });

  it("extractIdentities: email + provider uids, normalized + deduped", () => {
    const ids = extractIdentities({
      email: " Bad.Actor@Example.com ",
      providerData: [
        { providerId: "google.com", uid: "g-123", email: "bad.actor@example.com" },
        { providerId: "apple.com", uid: "a-456", email: "relay@privaterelay.appleid.com" },
        { providerId: "password", uid: "bad.actor@example.com" },
      ],
    });
    assert.deepStrictEqual(ids, [
      { kind: "email", value: "bad.actor@example.com" },
      { kind: "google.com", value: "g-123" },
      { kind: "apple.com", value: "a-456" },
      { kind: "email", value: "relay@privaterelay.appleid.com" },
    ]);
  });

  it("identityHash is stable, keyed, and non-reversing", () => {
    const h = identityHash(PEPPER, "email", "x@y.z");
    assert.strictEqual(h, identityHash(PEPPER, "email", "x@y.z"));
    assert.notStrictEqual(h, identityHash("other-pepper", "email", "x@y.z"));
    assert.notStrictEqual(h, identityHash(PEPPER, "google.com", "x@y.z"));
    assert.ok(/^[a-f0-9]{64}$/.test(h));
    assert.ok(!h.includes("x@y.z"));
  });

  it("blockBannedSignups rejects a banned email and allows a clean one", async () => {
    await db.collection("bannedIdentities").doc(identityHash(PEPPER, "email", "banned@example.com"))
      .set({ kind: "email" });
    let rejected = null;
    try {
      await fns.blockBannedSignups.run({ data: { email: "banned@example.com", providerData: [] } });
    } catch (e) { rejected = e; }
    assert.ok(rejected, "banned email must be rejected");
    assert.match(String(rejected.message || rejected), /account cannot be created/);
    // clean signup passes
    await fns.blockBannedSignups.run({ data: { email: "fresh@example.com", providerData: [] } });
  });

  it("blockBannedSignups rejects a banned Google uid even with a NEW email", async () => {
    await db.collection("bannedIdentities").doc(identityHash(PEPPER, "google.com", "g-banned"))
      .set({ kind: "google.com" });
    let rejected = null;
    try {
      await fns.blockBannedSignups.run({ data: {
        email: "totally-new@example.com",
        providerData: [{ providerId: "google.com", uid: "g-banned" }],
      } });
    } catch (e) { rejected = e; }
    assert.ok(rejected, "banned provider uid must be rejected regardless of email");
  });

  it("blockBannedSignups is a no-op for empty event data (fail-open shape)", async () => {
    await fns.blockBannedSignups.run({ data: null });
    await fns.blockBannedSignups.run({ data: { providerData: [] } });
  });
});
