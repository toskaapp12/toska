// Rules unit tests for firestore.rules.
//
// Run with:
//   cd firestore-tests && npm install && npm test
//
// The script boots a local Firestore + Auth emulator, runs the test suite,
// and tears the emulator down. No production data touched. The --project
// flag uses a fixed test project ID ("toska-test") so emulator state is
// fully isolated from real Firebase.
//
// Each test exercises a single rule clause via assertSucceeds /
// assertFails. The five findings closed by the 2026-04-29 audit are each
// pinned by a regression test below — adding one similar block per future
// rule change is the convention.

const assert = require("assert");
const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require("@firebase/rules-unit-testing");
const { serverTimestamp, deleteField } = require("firebase/firestore");
const fs = require("fs");
const path = require("path");

const PROJECT_ID = "toska-test";
const RULES_PATH = path.join(__dirname, "..", "firestore.rules");

let env;

async function setUserDoc(uid, fields = {}) {
  // Default helper seeds confirmedAdult=true so tests focused on other
  // rules don't have to repeat the field. Adult-gate tests pass an
  // explicit fields = { confirmedAdult: false } to exercise the new
  // hasConfirmedAdult() check.
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx
      .firestore()
      .collection("users")
      .doc(uid)
      .set({
        handle: `handle_${uid}`,
        followerCount: 0,
        followingCount: 0,
        totalLikes: 0,
        confirmedAdult: true,
        ...fields,
      });
  });
}

async function setBlock(blocker, blocked) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx
      .firestore()
      .collection("users")
      .doc(blocker)
      .collection("blocked")
      .doc(blocked)
      .set({ createdAt: new Date() });
  });
}

async function setPost(postId, authorId, extra = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx
      .firestore()
      .collection("posts")
      .doc(postId)
      .set({
        authorId,
        authorHandle: `handle_${authorId}`,
        text: "hello",
        createdAt: new Date(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        ...extra,
      });
  });
}

async function setSave(userId, postId) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx
      .firestore()
      .collection("users")
      .doc(userId)
      .collection("saved")
      .doc(postId)
      .set({ createdAt: new Date() });
  });
}

before(async () => {
  env = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: fs.readFileSync(RULES_PATH, "utf8"),
      host: "localhost",
      port: 8080,
    },
  });
});

after(async () => {
  if (env) await env.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
});

describe("baseline sanity", () => {
  it("authenticated user can create their own user doc with valid handle (batched with registry row)", async () => {
    const a = env.authenticatedContext("alice").firestore();
    // 2026-07-01: signup must claim handles/{handle.lower()} in the same
    // batch — see the "handle uniqueness registry" tests below.
    const batch = a.batch();
    batch.set(a.collection("users").doc("alice"), {
      handle: "alice123",
      followerCount: 0,
      followingCount: 0,
      totalLikes: 0,
      createdAt: new Date(),
    });
    batch.set(a.collection("handles").doc("alice123"), { uid: "alice" });
    await assertSucceeds(batch.commit());
  });

  it("rejects user doc create WITHOUT the registry row (pre-registry client shape)", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").set({
        handle: "alice123",
        followerCount: 0,
        followingCount: 0,
        totalLikes: 0,
        createdAt: new Date(),
      })
    );
  });

  it("rejects user doc with handle containing markup characters", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").set({
        handle: "<svg onload=alert(1)>",
        followerCount: 0,
        followingCount: 0,
        totalLikes: 0,
        createdAt: new Date(),
      })
    );
  });

  // 2026-07-01: handle uniqueness registry. The authorHandle/originalHandle/
  // fromHandle pins all verify against the caller's OWN user doc, which is
  // meaningless if two user docs can carry the same handle — a tampered
  // client could sign up with a verbatim copy of a victim's handle and
  // publish under their byline. The registry (handles/{handle.lower()},
  // claimed in the signup batch) is what makes those pins real.
  describe("handle uniqueness registry", () => {
    async function seedRegistryRow(handleLower, uid) {
      await env.withSecurityRulesDisabled(async (ctx) => {
        await ctx.firestore().collection("handles").doc(handleLower).set({ uid });
      });
    }

    function signupBatch(db, uid, handle, registryId = null) {
      const batch = db.batch();
      batch.set(db.collection("users").doc(uid), {
        handle,
        followerCount: 0,
        followingCount: 0,
        totalLikes: 0,
        createdAt: new Date(),
      });
      batch.set(db.collection("handles").doc(registryId ?? handle.toLowerCase()), { uid });
      return batch;
    }

    it("DENIED: signing up with a handle already registered to another user (impersonation)", async () => {
      await seedRegistryRow("victim_handle_42", "victim");
      const m = env.authenticatedContext("mallory").firestore();
      await assertFails(signupBatch(m, "mallory", "victim_handle_42").commit());
    });

    it("DENIED: case-variant of a taken handle maps to the same registry row", async () => {
      await seedRegistryRow("victim_handle_42", "victim");
      const m = env.authenticatedContext("mallory").firestore();
      await assertFails(signupBatch(m, "mallory", "Victim_Handle_42").commit());
    });

    it("DENIED: registry row claiming an id that doesn't match the user doc's handle (squat)", async () => {
      const m = env.authenticatedContext("mallory").firestore();
      await assertFails(signupBatch(m, "mallory", "mallory_own_1", "someone_elses_handle").commit());
    });

    it("DENIED: registry row with uid pointing at another user", async () => {
      const m = env.authenticatedContext("mallory").firestore();
      const batch = m.batch();
      batch.set(m.collection("users").doc("mallory"), {
        handle: "mallory_own_1", followerCount: 0, followingCount: 0, totalLikes: 0, createdAt: new Date(),
      });
      batch.set(m.collection("handles").doc("mallory_own_1"), { uid: "victim" });
      await assertFails(batch.commit());
    });

    it("DENIED: owner update changing handle (immutable post-create; bypasses the registry)", async () => {
      await setUserDoc("mallory", { handle: "mallory_own_1" });
      const m = env.authenticatedContext("mallory").firestore();
      await assertFails(
        m.collection("users").doc("mallory").update({ handle: "victim_handle_42" })
      );
    });

    it("NO client may delete a registry row — not even the owner", async () => {
      // The rule moved to `allow delete: if false` (self-release let a user
      // free their own handle while still carrying it → duplicate-handle
      // sockpuppets; the Admin-SDK deletion cascade releases rows instead).
      // This test previously asserted owner-release and went stale.
      await seedRegistryRow("alice123", "alice");
      const a = env.authenticatedContext("alice").firestore();
      const m = env.authenticatedContext("mallory").firestore();
      await assertFails(m.collection("handles").doc("alice123").delete());
      await assertFails(a.collection("handles").doc("alice123").delete());
    });

    it("registry rows are readable by any authenticated user (availability pre-check)", async () => {
      await seedRegistryRow("alice123", "alice");
      const m = env.authenticatedContext("mallory").firestore();
      await assertSucceeds(m.collection("handles").doc("alice123").get());
    });
  });

  // S-1 (2026-06-16): the create path must reject a forged non-zero counter.
  // The update rule already forbids changing counters; without this lock a
  // tampered client could SEED followerCount=999999 at signup to forge
  // follower-count social proof (OtherProfileView reads these directly).
  it("rejects user doc create with a forged non-zero followerCount", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").set({
        handle: "alice123",
        followerCount: 999999,
        followingCount: 0,
        totalLikes: 0,
        createdAt: new Date(),
      })
    );
  });

  it("rejects user doc create that pre-seeds a restriction field", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").set({
        handle: "alice123",
        followerCount: 0,
        followingCount: 0,
        totalLikes: 0,
        restricted: false,
        createdAt: new Date(),
      })
    );
  });

  it("rejects post create with text size > 2000", async () => {
    await setUserDoc("alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        authorHandle: "handle_alice",
        text: "x".repeat(2001),
        createdAt: new Date(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });

  it("allows post create with valid shape", async () => {
    await setUserDoc("alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        authorHandle: "handle_alice",
        text: "hello world",
        // createdAt is pinned to request.time on the server. A client-side
        // `new Date()` does not equal request.time once the write reaches
        // the emulator, so the rule rejects it. Every happy-path post create
        // test in this file must use serverTimestamp().
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });
});

describe("post create: expiresAt bounded to the near future (audit 2026-07-17)", () => {
  // expiresAt is computed from the DEVICE clock (whisper +1h, midnight ≤
  // ~24h+DST). The rule bounds it to request.time + 26h so a skewed clock or
  // tampered client can't mint an "ephemeral" post that never expires.
  beforeEach(async () => { await setUserDoc("alice"); });

  function whisperWith(expiresAt) {
    const a = env.authenticatedContext("alice").firestore();
    const data = {
      authorId: "alice",
      authorHandle: "handle_alice",
      text: "hello world",
      createdAt: serverTimestamp(),
      likeCount: 0,
      repostCount: 0,
      replyCount: 0,
      isWhisper: true,
    };
    if (expiresAt !== undefined) data.expiresAt = expiresAt;
    return a.collection("posts").doc("p_exp").set(data);
  }

  it("allows a whisper expiring in 1h", async () => {
    await assertSucceeds(whisperWith(new Date(Date.now() + 3600 * 1000)));
  });
  it("allows a midnight-style expiry ~24h out", async () => {
    await assertSucceeds(whisperWith(new Date(Date.now() + 24 * 3600 * 1000)));
  });
  it("rejects expiresAt in the far future (never-expiring 'ephemeral' post)", async () => {
    await assertFails(whisperWith(new Date("3000-01-01T00:00:00Z")));
  });
  it("rejects expiresAt just past the 26h bound", async () => {
    await assertFails(whisperWith(new Date(Date.now() + 27 * 3600 * 1000)));
  });
  it("rejects a non-timestamp expiresAt", async () => {
    await assertFails(whisperWith("3000-01-01"));
  });
});

describe("post create: client moderationStatus is start-hidden only (audit 2026-06-01)", () => {
  // Clients may start a post hidden ("pending_validation") so it's invisible
  // until validatePost promotes it to "live", but can NEVER self-publish as
  // "live" or self-assign the moderation hold "pending_review".
  beforeEach(async () => { await setUserDoc("alice"); });

  function postWith(modStatus) {
    const a = env.authenticatedContext("alice").firestore();
    const data = {
      authorId: "alice",
      authorHandle: "handle_alice",
      text: "hello world",
      createdAt: serverTimestamp(),
      likeCount: 0,
      repostCount: 0,
      replyCount: 0,
    };
    if (modStatus !== undefined) data.moderationStatus = modStatus;
    return a.collection("posts").doc("p1").set(data);
  }

  it("allows omitting moderationStatus (old clients)", async () => {
    await assertSucceeds(postWith(undefined));
  });
  it("allows moderationStatus = pending_validation (new clients, start hidden)", async () => {
    await assertSucceeds(postWith("pending_validation"));
  });
  it("rejects a client self-publishing as live", async () => {
    await assertFails(postWith("live"));
  });
  it("rejects a client self-assigning the moderation hold", async () => {
    await assertFails(postWith("pending_review"));
  });
});

describe("Finding 3: blocked user cannot create save notification", () => {
  it("rejects save notification when post author has blocked the actor", async () => {
    await setUserDoc("alice"); // post author
    await setUserDoc("bob"); // blocked user
    await setPost("p1", "alice");
    await setSave("bob", "p1"); // bob saved alice's post
    await setBlock("alice", "bob"); // alice blocks bob

    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users")
        .doc("alice")
        .collection("notifications")
        .doc("save_p1_bob")
        .set({
          type: "save",
          fromUserId: "bob",
          postId: "p1",
          isRead: false,
          createdAt: new Date(),
        })
    );
  });

  it("allows save notification when actor is not blocked", async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    await setSave("bob", "p1");

    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("users")
        .doc("alice")
        .collection("notifications")
        .doc("save_p1_bob")
        .set({
          type: "save",
          fromUserId: "bob",
          postId: "p1",
          isRead: false,
          createdAt: serverTimestamp(),
        })
    );
  });

  it("rejects message notification when recipient has blocked the actor", async () => {
    // Defense-in-depth coverage of the 'message' branch added in finding 3.
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setBlock("alice", "bob"); // alice blocks bob
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("conversations").doc("c1").set({
        participants: ["alice", "bob"],
        createdAt: new Date(),
      });
    });

    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users")
        .doc("alice")
        .collection("notifications")
        .doc("msg_c1_bob")
        .set({
          type: "message",
          fromUserId: "bob",
          conversationId: "c1",
          isRead: false,
          createdAt: new Date(),
        })
    );
  });
});

// 8b9923c: in-app fromHandle spoofing close. The push-payload handle is
// re-resolved server-side by sendPushNotification, but the in-app render
// trusted whatever fromHandle the client wrote. The new rule pins
// fromHandle (when present) to the caller's actual handle on their user
// doc. setUserDoc seeds handle=`handle_${uid}` so tests can assert match
// vs. mismatch deterministically.
describe("fromHandle is pinned to caller's actual handle on notification create", () => {
  it("allows notification create when fromHandle matches caller's handle", async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("posts").doc("p1")
        .collection("likes").doc("bob")
        .set({ createdAt: new Date() });
    });

    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("users").doc("alice")
        .collection("notifications").doc("like_p1_bob")
        .set({
          type: "like",
          fromUserId: "bob",
          fromHandle: "handle_bob", // matches setUserDoc default
          postId: "p1",
          isRead: false,
          createdAt: serverTimestamp(),
        })
    );
  });

  it("rejects notification create when fromHandle is spoofed to another user's handle", async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("posts").doc("p1")
        .collection("likes").doc("bob")
        .set({ createdAt: new Date() });
    });

    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users").doc("alice")
        .collection("notifications").doc("like_p1_bob")
        .set({
          type: "like",
          fromUserId: "bob",
          fromHandle: "handle_alice", // spoofed — bob's real handle is handle_bob
          postId: "p1",
          isRead: false,
          createdAt: new Date(),
        })
    );
  });

  it("rejects notification create with a fully fabricated fromHandle string", async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("posts").doc("p1")
        .collection("likes").doc("bob")
        .set({ createdAt: new Date() });
    });

    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users").doc("alice")
        .collection("notifications").doc("like_p1_bob")
        .set({
          type: "like",
          fromUserId: "bob",
          fromHandle: "@victim_lookalike",
          postId: "p1",
          isRead: false,
          createdAt: new Date(),
        })
    );
  });

  it("allows notification create when fromHandle is omitted entirely", async () => {
    // Defense-in-depth: omission is the legitimate code path for callers
    // that don't render an in-app handle. The rule clause is gated on
    // 'fromHandle' in keys() so absent is accepted.
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("posts").doc("p1")
        .collection("likes").doc("bob")
        .set({ createdAt: new Date() });
    });

    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("users").doc("alice")
        .collection("notifications").doc("like_p1_bob")
        .set({
          type: "like",
          fromUserId: "bob",
          postId: "p1",
          isRead: false,
          createdAt: serverTimestamp(),
        })
    );
  });
});

describe("Finding 4: reports text capped at 4000 chars", () => {
  // The reports create rule pins createdAt to request.time, so tests must
  // use serverTimestamp() — a client-side new Date() never matches the
  // emulator's evaluation time exactly and would always fail.
  it("allows report with normal-sized text", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("reports").add({
        reportedBy: "alice",
        reason: "harassment",
        reasonLabel: "harassment",
        type: "post",
        status: "pending",
        createdAt: serverTimestamp(),
        postId: "p1",
        reportedUserId: "bob",
        reportedHandle: "bob123",
        text: "post content snippet",
      })
    );
  });

  it("rejects report with text > 4000 chars", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("reports").add({
        reportedBy: "alice",
        reason: "harassment",
        reasonLabel: "harassment",
        type: "post",
        status: "pending",
        createdAt: serverTimestamp(),
        postId: "p1",
        reportedUserId: "bob",
        reportedHandle: "bob123",
        text: "x".repeat(4001),
      })
    );
  });

  it("rejects report with reportedBy spoofed to a different uid", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("reports").add({
        reportedBy: "bob", // spoofed
        reason: "harassment",
        type: "post",
        status: "pending",
        createdAt: serverTimestamp(),
      })
    );
  });
});

describe("Finding 7: server-side confirmedAdult gate on publishing surfaces", () => {
  it("rejects post create when confirmedAdult is missing", async () => {
    await setUserDoc("alice", { confirmedAdult: false });
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        authorHandle: "handle_alice",
        text: "hello",
        createdAt: new Date(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });

  it("rejects reply create when confirmedAdult is missing", async () => {
    await setUserDoc("alice");                          // post author, confirmed
    await setUserDoc("bob", { confirmedAdult: false }); // replier, NOT confirmed
    await setPost("p1", "alice");

    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p1").collection("replies").add({
        authorId: "bob",
        text: "reply text",
        createdAt: new Date(),
      })
    );
  });

  it("rejects DM message create when confirmedAdult is missing", async () => {
    await setUserDoc("alice");
    await setUserDoc("bob", { confirmedAdult: false });
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("conversations").doc("c1").set({
        participants: ["alice", "bob"],
        messageCount: { alice: 0, bob: 0 },
        createdAt: new Date(),
      });
    });

    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("conversations").doc("c1").collection("messages").doc("m1").set({
        senderId: "bob",
        text: "hi",
        createdAt: new Date(),
        clientCountedV1: true,
      })
    );
  });

  it("rejects circle message create when confirmedAdult is missing", async () => {
    await setUserDoc("alice", { confirmedAdult: false });
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("feelingCircles").doc("fc1").set({
        tag: "lonely",
        participants: ["alice"],
        createdAt: new Date(),
      });
    });

    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("feelingCircles").doc("fc1").collection("messages").add({
        authorId: "alice",
        authorHandle: "handle_alice",
        text: "feeling lonely",
        createdAt: serverTimestamp(),
      })
    );
  });

  it("allows post create when confirmedAdult is true", async () => {
    // Belt-and-suspenders: confirms the gate isn't blocking legitimate users.
    // setUserDoc seeds confirmedAdult=true by default, so this is the
    // happy-path counterpart to the rejection tests above.
    await setUserDoc("alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        authorHandle: "handle_alice",
        text: "hello",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });

  it("allows likes/saves/follows even when confirmedAdult is false", async () => {
    // The gate is publishing-only — consumption + relationship actions
    // don't need it. A user who hasn't accepted the adult terms can still
    // browse + like, just can't publish content.
    await setUserDoc("alice");
    await setUserDoc("bob", { confirmedAdult: false });
    await setPost("p1", "alice");

    const b = env.authenticatedContext("bob").firestore();
    // Must use serverTimestamp() — the post-like create rule pins
    // createdAt == request.time (T-10 schema lock), like every other like/save
    // write in this file and the real client (PostInteractionManager).
    await assertSucceeds(
      b.collection("posts").doc("p1").collection("likes").doc("bob").set({
        createdAt: serverTimestamp(),
      })
    );
    await assertSucceeds(
      b.collection("users").doc("bob").collection("saved").doc("p1").set({
        createdAt: serverTimestamp(),
      })
    );
  });
});

describe("regression: prior audit fixes (2026-04-26)", () => {
  it("rejects post update that touches `flagged`", async () => {
    await setUserDoc("alice");
    await setPost("p1", "alice", { flagged: true, flagReason: "hate_speech" });

    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").update({
        text: "edited",
        flagged: false, // attempt to unflag own moderated post
      })
    );
  });

  it("rejects writing fcmToken to main user doc", async () => {
    await setUserDoc("alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").update({
        fcmToken: "fake-token",
      })
    );
  });

  // confirmedAdult / confirmedAdultAt are now server-only fields, written
  // only by the confirmAdult Cloud Function via Admin SDK. firestore.rules
  // refuses both create-time and update-time client writes so a tampered
  // client can't shortcut the iOS age gate by setting the field directly.
  it("rejects user doc create that includes confirmedAdult", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").set({
        handle: "alice123",
        followerCount: 0,
        followingCount: 0,
        totalLikes: 0,
        createdAt: new Date(),
        confirmedAdult: true,
      })
    );
  });

  it("rejects user doc create that includes confirmedAdultAt", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").set({
        handle: "alice123",
        followerCount: 0,
        followingCount: 0,
        totalLikes: 0,
        createdAt: new Date(),
        confirmedAdultAt: new Date(),
      })
    );
  });

  it("rejects user doc update that sets confirmedAdult", async () => {
    await setUserDoc("alice", { confirmedAdult: false });
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").update({
        confirmedAdult: true,
      })
    );
  });

  it("rejects user doc update that flips confirmedAdult false", async () => {
    // setUserDoc seeds confirmedAdult: true via the rules-disabled helper —
    // verify the owner can't undo that via a direct update either.
    await setUserDoc("alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").update({
        confirmedAdult: false,
      })
    );
  });

  it("rejects post create from a server-restricted user", async () => {
    // Set restricted=true with no expiry — admin restriction
    await setUserDoc("alice", {
      restricted: true,
      restrictedAt: new Date(),
      restrictedBy: "system",
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        authorHandle: "handle_alice",
        text: "hello",
        createdAt: new Date(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });
});

describe("reflections subcollection is reflection-author-or-post-author scoped", () => {
  beforeEach(async () => {
    // alice owns post p1; bob is an unrelated third party.
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setUserDoc("carol");
    await setPost("p1", "alice");
  });

  async function seedReflection(reflectionAuthor) {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("posts").doc("p1")
        .collection("reflections").doc(reflectionAuthor)
        .set({
          authorId: reflectionAuthor,
          text: "looking back at this",
          createdAt: new Date(),
        });
    });
  }

  it("allows the reflection author to read their own reflection", async () => {
    await seedReflection("bob");
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("posts").doc("p1").collection("reflections").doc("bob").get()
    );
  });

  it("allows the post author to read reflections under their post", async () => {
    // Required by PostDetailView.swift:809 cleanup loop before deleting
    // the parent post.
    await seedReflection("bob");
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("posts").doc("p1").collection("reflections").doc("bob").get()
    );
  });

  it("rejects an unrelated user from reading someone else's reflection", async () => {
    // Was previously open to any auth user — privacy leak.
    await seedReflection("bob");
    const c = env.authenticatedContext("carol").firestore();
    await assertFails(
      c.collection("posts").doc("p1").collection("reflections").doc("bob").get()
    );
  });

  it("allows a legitimate reflection create by the post author", async () => {
    // Reflections are AnniversaryCardView's own-post anniversary thoughts.
    // The rule restricts create to the post author so a tampered client
    // can't spam reflections into another user's post — alice owns p1
    // (per the beforeEach), so alice writing a reflection on p1 is the
    // legitimate happy path.
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("posts").doc("p1").collection("reflections").doc("alice").set({
        authorId: "alice",
        text: "thinking about this again",
        createdAt: serverTimestamp(),
      })
    );
  });

  it("rejects reflection create when caller is not the post author", async () => {
    // The rule fix: previously any auth user could write a reflection
    // on anyone's post (read was post-author-or-reflection-author scoped,
    // but write was wide open). Bob writing a reflection under alice's
    // post is exactly the harassment vector this closes.
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p1").collection("reflections").doc("bob").set({
        authorId: "bob",
        text: "thinking about this again",
        createdAt: serverTimestamp(),
      })
    );
  });

  it("rejects reflection create with text > 500 chars", async () => {
    // Use alice (post author) so we test the length check in isolation
    // rather than the post-author check.
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").collection("reflections").doc("alice").set({
        authorId: "alice",
        text: "x".repeat(501),
        createdAt: serverTimestamp(),
      })
    );
  });

  it("rejects reflection create with extra unlisted field", async () => {
    // Use alice (post author) so the post-author check passes and the
    // hasOnly schema lockdown is the rule that does the rejection.
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").collection("reflections").doc("alice").set({
        authorId: "alice",
        text: "ok",
        createdAt: serverTimestamp(),
        flagged: false,
      })
    );
  });

  it("allows the post author to delete a reflection under their post", async () => {
    // PostDetailView's pre-delete-post cleanup needs this; previously
    // the rule denied it and the try? swallowed the failure.
    await seedReflection("bob");
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("posts").doc("p1").collection("reflections").doc("bob").delete()
    );
  });
});

describe("drafts subcollection — owner-only rehearsal space", () => {
  it("allows owner to create a draft with valid shape", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("users").doc("alice").collection("drafts").doc("d1").set({
        text: "the thing i havent said yet",
        createdAt: serverTimestamp(),
      })
    );
  });

  it("rejects another user reading someone else's drafts", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("users").doc("alice").collection("drafts").doc("d1")
        .set({ text: "private", createdAt: new Date() });
    });
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users").doc("alice").collection("drafts").doc("d1").get()
    );
  });

  it("rejects draft create with text > 2000 chars", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").collection("drafts").doc("d1").set({
        text: "x".repeat(2001),
        createdAt: serverTimestamp(),
      })
    );
  });

  it("rejects draft create with extra unlisted field", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").collection("drafts").doc("d1").set({
        text: "ok",
        createdAt: serverTimestamp(),
        flagged: false,
      })
    );
  });

  it("allows owner to update text + updatedAt", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("users").doc("alice").collection("drafts").doc("d1")
        .set({ text: "first draft", createdAt: new Date() });
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("users").doc("alice").collection("drafts").doc("d1").update({
        text: "revised",
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("allows owner to delete their own draft", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("users").doc("alice").collection("drafts").doc("d1")
        .set({ text: "anything", createdAt: new Date() });
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("users").doc("alice").collection("drafts").doc("d1").delete()
    );
  });
});

// =====================================================================
// security audit fixes — Tier A
//
// The describe blocks below pin every rule branch added or tightened in
// the security-audit Tier A pass. Each test exercises one concrete vector
// from the audit so a future rule edit that re-opens the gap fails CI
// with a named, recognizable test rather than a generic "rules changed."
// =====================================================================

describe("user doc read: block-aware + legacy-PII guard (audit P0/P1)", () => {
  it("allows a non-owner to read a clean post-migration profile", async () => {
    // Baseline: setUserDoc seeds only public fields (handle, *Count,
    // confirmedAdult), so the noLegacyPIIVisible() guard passes and a
    // non-blocked authenticated user can load the public projection.
    await setUserDoc("alice");
    await setUserDoc("bob");
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(b.collection("users").doc("alice").get());
  });

  it("rejects a blocked user from reading the blocker's profile", async () => {
    // Block-aware delivery vector: without this, bob can still load
    // OtherProfileView for alice after she blocked him, observing handle/
    // follower counts to fuel a sock-puppet attack.
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setBlock("alice", "bob");
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(b.collection("users").doc("alice").get());
  });

  it("still allows the owner to read their own profile when blocked-by-flag is set", async () => {
    // Owner branch must keep working — alice's ProfileView depends on
    // reading her own user doc and the block exists() check is meant
    // for non-owners only.
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setBlock("alice", "bob");
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(a.collection("users").doc("alice").get());
  });

  it("rejects a non-owner read when legacy PII (email) is still on the main doc", async () => {
    // P0: pre-migration accounts that still carry email on the main user
    // doc must not leak it to other authenticated users. Whole-doc deny
    // is the only granularity rules support — OtherProfileView shows
    // "loading…" until functions/scrubLegacyPII.js scrubs the field.
    await setUserDoc("alice", { email: "alice@example.com" });
    await setUserDoc("bob");
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(b.collection("users").doc("alice").get());
  });

  it("rejects a non-owner read when legacy notify* prefs are still on the main doc", async () => {
    // Belt-and-suspenders: a different legacy field should also block.
    await setUserDoc("alice", { notifyLikes: true });
    await setUserDoc("bob");
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(b.collection("users").doc("alice").get());
  });

  it("still allows the owner to read their own profile even when legacy PII is present", async () => {
    // Pre-migration owner can still load their own settings — that's
    // how the SettingsView scrub path opportunistically deletes legacy
    // fields on save.
    await setUserDoc("alice", { email: "alice@example.com" });
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(a.collection("users").doc("alice").get());
  });
});

describe("notification create: schema lockdown (audit P1)", () => {
  it("rejects notification create with extra unlisted field", async () => {
    // Without keys().hasOnly, a tampered client could attach
    // `flagged: false` or `trustedByAdmin: true` and let a future
    // trigger trust the value.
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("posts").doc("p1")
        .collection("likes").doc("bob")
        .set({ createdAt: new Date() });
    });
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users").doc("alice")
        .collection("notifications").doc("like_p1_bob")
        .set({
          type: "like",
          fromUserId: "bob",
          postId: "p1",
          isRead: false,
          createdAt: serverTimestamp(),
          flagged: false,
        })
    );
  });

  it("rejects notification create with isRead == true (no pre-read decoy)", async () => {
    // A "pre-read" notification doc would hide itself from the recipient's
    // unread badge while still firing sendPushNotification — useful for
    // a stalker probing a victim's device without leaving in-app
    // breadcrumbs.
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("posts").doc("p1")
        .collection("likes").doc("bob")
        .set({ createdAt: new Date() });
    });
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users").doc("alice")
        .collection("notifications").doc("like_p1_bob")
        .set({
          type: "like",
          fromUserId: "bob",
          postId: "p1",
          isRead: true,
          createdAt: serverTimestamp(),
        })
    );
  });

  it("rejects notification create with backdated createdAt", async () => {
    // request.time pin: notification createdAt must equal server time so
    // a tampered client can't predate a notification (e.g., to land
    // before sendPushNotification's badge-count query).
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("posts").doc("p1")
        .collection("likes").doc("bob")
        .set({ createdAt: new Date() });
    });
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users").doc("alice")
        .collection("notifications").doc("like_p1_bob")
        .set({
          type: "like",
          fromUserId: "bob",
          postId: "p1",
          isRead: false,
          createdAt: new Date("2025-01-01"),
        })
    );
  });

  it("rejects notification create missing isRead", async () => {
    // hasAll requires isRead. Skipping it would let a client write a
    // notification doc whose unread state is undefined-ish (and the
    // recipient's badge query treats undefined as "never read").
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("posts").doc("p1")
        .collection("likes").doc("bob")
        .set({ createdAt: new Date() });
    });
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users").doc("alice")
        .collection("notifications").doc("like_p1_bob")
        .set({
          type: "like",
          fromUserId: "bob",
          postId: "p1",
          createdAt: serverTimestamp(),
        })
    );
  });
});

describe("post create: createdAt pinned to request.time (audit P2)", () => {
  it("rejects post create with backdated createdAt", async () => {
    await setUserDoc("alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        authorHandle: "handle_alice",
        text: "hello",
        createdAt: new Date("2025-01-01"),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });
});

describe("reply create: schema lockdown + createdAt pin (audit P2)", () => {
  beforeEach(async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
  });

  it("allows a legitimate reply create with valid shape", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("posts").doc("p1").collection("replies").doc("r1").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "responding",
        createdAt: serverTimestamp(),
        likeCount: 0,
        parentPostText: "hello",
        parentPostHandle: "handle_alice",
      })
    );
  });

  it("rejects reply create with extra unlisted field", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p1").collection("replies").doc("r1").set({
        authorId: "bob",
        text: "responding",
        createdAt: serverTimestamp(),
        flagged: false,
      })
    );
  });

  it("rejects reply create with backdated createdAt", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p1").collection("replies").doc("r1").set({
        authorId: "bob",
        text: "responding",
        createdAt: new Date("2025-01-01"),
      })
    );
  });

  it("rejects reply create with pre-inflated likeCount", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p1").collection("replies").doc("r1").set({
        authorId: "bob",
        text: "responding",
        createdAt: serverTimestamp(),
        likeCount: 999,
      })
    );
  });
});

describe("conversation message create: createdAt pinned (audit P2)", () => {
  beforeEach(async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("conversations").doc("c1").set({
        participants: ["alice", "bob"],
        messageCount: { alice: 0, bob: 0 },
        createdAt: new Date(),
      });
    });
  });

  it("rejects message create with backdated createdAt", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("conversations").doc("c1")
        .collection("messages").doc("m1")
        .set({
          senderId: "alice",
          text: "hi",
          createdAt: new Date("2025-01-01"),
          clientCountedV1: true,
        })
    );
  });
});

// =====================================================================
// pre-existing coverage gaps — Tier A baseline (audit P3 #27)
// Pins rule branches that were live-but-untested before this audit.
// =====================================================================

describe("private subcollection: owner-only", () => {
  beforeEach(async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
  });

  it("allows the owner to write their private/data doc", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("users").doc("alice")
        .collection("private").doc("data")
        .set({ email: "alice@example.com", selectedMood: "ok" })
    );
  });

  it("rejects another user from reading someone else's private data", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("users").doc("alice")
        .collection("private").doc("data")
        .set({ email: "alice@example.com", fcmToken: "abc123" });
    });
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users").doc("alice")
        .collection("private").doc("data").get()
    );
  });

  it("rejects another user from writing into someone else's private subcollection", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users").doc("alice")
        .collection("private").doc("data")
        .set({ email: "attacker@example.com" })
    );
  });
});

describe("post delete: author or admin only", () => {
  it("allows the post author to delete their own post", async () => {
    await setUserDoc("alice");
    await setPost("p1", "alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(a.collection("posts").doc("p1").delete());
  });

  it("rejects an unrelated user from deleting someone else's post", async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(b.collection("posts").doc("p1").delete());
  });
});

describe("reply update + delete", () => {
  beforeEach(async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("posts").doc("p1")
        .collection("replies").doc("r1")
        .set({
          authorId: "bob",
          text: "original",
          createdAt: new Date(),
          likeCount: 0,
        });
    });
  });

  it("allows reply author to update their own text", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("posts").doc("p1")
        .collection("replies").doc("r1")
        .update({ text: "edited" })
    );
  });

  it("rejects another user from updating someone else's reply", async () => {
    await setUserDoc("carol");
    const c = env.authenticatedContext("carol").firestore();
    await assertFails(
      c.collection("posts").doc("p1")
        .collection("replies").doc("r1")
        .update({ text: "tampered" })
    );
  });

  it("rejects reply update that exceeds the 500-char cap", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p1")
        .collection("replies").doc("r1")
        .update({ text: "x".repeat(501) })
    );
  });

  it("allows reply author to delete their own reply", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("posts").doc("p1")
        .collection("replies").doc("r1").delete()
    );
  });

  it("allows post author to delete a reply on their post (moderation cleanup)", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("posts").doc("p1")
        .collection("replies").doc("r1").delete()
    );
  });

  it("rejects an unrelated user from deleting someone else's reply", async () => {
    await setUserDoc("carol");
    const c = env.authenticatedContext("carol").firestore();
    await assertFails(
      c.collection("posts").doc("p1")
        .collection("replies").doc("r1").delete()
    );
  });
});

describe("follow mirrors: create + delete", () => {
  beforeEach(async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
  });

  it("allows alice to add herself to bob's followers (and to her own following)", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("users").doc("bob")
        .collection("followers").doc("alice")
        .set({ createdAt: serverTimestamp() })
    );
    await assertSucceeds(
      a.collection("users").doc("alice")
        .collection("following").doc("bob")
        .set({ createdAt: serverTimestamp() })
    );
  });

  it("rejects self-follow on /following/", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice")
        .collection("following").doc("alice")
        .set({ createdAt: serverTimestamp() })
    );
  });

  it("rejects self-follow on /followers/", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice")
        .collection("followers").doc("alice")
        .set({ createdAt: serverTimestamp() })
    );
  });

  it("rejects a blocked user from creating a follower mirror doc", async () => {
    await setBlock("bob", "alice"); // bob blocks alice
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("bob")
        .collection("followers").doc("alice")
        .set({ createdAt: serverTimestamp() })
    );
  });

  it("allows alice to remove her own follower entry under bob", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("users").doc("bob")
        .collection("followers").doc("alice")
        .set({ createdAt: new Date() });
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("users").doc("bob")
        .collection("followers").doc("alice").delete()
    );
  });

  // 2026-06-01 audit: follower/following docs are schema-locked to
  // { handle, createdAt } so a follower can't smuggle arbitrary fields into
  // a doc that lives under the target's user document.
  // Handle must be the follower's REAL user-doc handle (2026-07-09 pin);
  // setUserDoc seeds handle_${uid}, so alice's follower doc carries handle_alice.
  it("allows a follower create carrying the legit { handle, createdAt }", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("users").doc("bob")
        .collection("followers").doc("alice")
        .set({ handle: "handle_alice", createdAt: serverTimestamp() })
    );
  });

  it("rejects a follower create with an extra side-channel field", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("bob")
        .collection("followers").doc("alice")
        .set({ handle: "handle_alice", createdAt: serverTimestamp(), injected: "x" })
    );
  });

  it("rejects a follower UPDATE that injects a side-channel field", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore()
        .collection("users").doc("bob")
        .collection("followers").doc("alice")
        .set({ handle: "handle_alice", createdAt: new Date() });
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("bob")
        .collection("followers").doc("alice")
        .update({ injected: "x" })
    );
  });

  it("rejects a following create with an extra side-channel field", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice")
        .collection("following").doc("bob")
        .set({ handle: "handle_bob", createdAt: serverTimestamp(), injected: "x" })
    );
  });
});

describe("notRestricted(): time-expiry leg", () => {
  it("allows a post create when restrictedUntil is in the past", async () => {
    // System auto-restrictions set restrictedUntil = now + 48h. Once
    // that timestamp is in the past, notRestricted() returns true again
    // even if `restricted: true` is still on the doc — the time-expiry
    // leg of the predicate. Without this branch, expired auto-restrictions
    // would persist forever (admin-set restrictions intentionally have
    // no expiry).
    await setUserDoc("alice", {
      restricted: true,
      restrictedUntil: new Date(Date.now() - 60 * 1000), // 1 minute ago
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        authorHandle: "handle_alice",
        text: "back online",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });

  it("rejects a post create when restrictedUntil is still in the future", async () => {
    await setUserDoc("alice", {
      restricted: true,
      restrictedUntil: new Date(Date.now() + 60 * 60 * 1000), // 1h ahead
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        authorHandle: "handle_alice",
        text: "still under restriction",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });
});

describe("like create: blocked by post author", () => {
  it("rejects a like from a user the post author has blocked", async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    await setBlock("alice", "bob"); // alice blocked bob
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p1")
        .collection("likes").doc("bob")
        .set({ createdAt: serverTimestamp() })
    );
  });

  it("allows a like from a non-blocked user", async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("posts").doc("p1")
        .collection("likes").doc("bob")
        .set({ createdAt: serverTimestamp() })
    );
  });
});

describe("legacy PII immutability: reject re-introduction on update", () => {
  // legacyPIIFieldsImmutable() permits deletes (so SettingsView can scrub)
  // and unchanged values (so updates on pre-migration docs don't fail
  // wholesale), but rejects any add/modify of the field set. Each test
  // covers a different field so a future reordering of the predicate
  // chain doesn't silently drop a check.
  beforeEach(async () => {
    await setUserDoc("alice");
  });

  it("rejects re-introducing email via update", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").update({
        email: "alice@example.com",
      })
    );
  });

  it("rejects re-introducing selectedMood via update", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").update({
        selectedMood: "still in it",
      })
    );
  });

  it("rejects re-introducing notifyLikes via update", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").update({
        notifyLikes: true,
      })
    );
  });

  it("rejects re-introducing pushEnabled via update", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").update({
        pushEnabled: false,
      })
    );
  });
});

describe("repost create: rule-layer forgery check (audit P2)", () => {
  // Closes the visibility window where validatePost (Cloud Function) used
  // to delete forged reposts only after the doc was created and briefly
  // queryable. Rules now reject the create entirely if originalAuthorId
  // or text don't match the original post.
  beforeEach(async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setUserDoc("carol");
    await setPost("p_orig", "alice", { text: "alice's words" });
  });

  it("allows a faithful repost", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("posts").doc("p_repost").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "alice's words",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "p_orig",
        originalAuthorId: "alice",
        originalHandle: "handle_alice",
      })
    );
  });

  it("rejects a repost with a forged originalAuthorId", async () => {
    // Attacker tries to attribute alice's real text to carol's byline.
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p_repost").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "alice's words",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "p_orig",
        originalAuthorId: "carol",
        originalHandle: "handle_carol",
      })
    );
  });

  it("rejects a repost with text that doesn't match the original", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p_repost").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "fabricated quote",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "p_orig",
        originalAuthorId: "alice",
        originalHandle: "handle_alice",
      })
    );
  });

  it("rejects a repost pointing at a non-existent original", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p_repost").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "alice's words",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "does_not_exist",
        originalAuthorId: "alice",
        originalHandle: "handle_alice",
      })
    );
  });

  it("rejects reposting a repost", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("posts").doc("p_first_repost").set({
        authorId: "carol",
        authorHandle: "handle_carol",
        text: "alice's words",
        createdAt: new Date(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "p_orig",
        originalAuthorId: "alice",
      });
    });
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p_repost").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "alice's words",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "p_first_repost",
        originalAuthorId: "carol",
        originalHandle: "handle_carol",
      })
    );
  });

  it("rejects repost when original author has blocked the reposter", async () => {
    await setBlock("alice", "bob");
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p_repost").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "alice's words",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "p_orig",
        originalAuthorId: "alice",
        originalHandle: "handle_alice",
      })
    );
  });

  it("rejects a repost with a forged originalHandle (real text + author, spoofed byline)", async () => {
    // Closes the byline-spoof gap left by the prior fix. text and
    // originalAuthorId both match alice's real post, but originalHandle is
    // set to carol's handle. Without the user-doc handle pin the repost
    // would render as "originally by @carol" while quoting alice's words —
    // a misattribution shape that escapes the text/authorId equality
    // checks.
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p_repost").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "alice's words",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "p_orig",
        originalAuthorId: "alice",
        originalHandle: "handle_carol",
      })
    );
  });

  it("allows a repost with originalHandle omitted entirely", async () => {
    // Omission is the legitimate fallback for clients that don't render
    // an "originally by" byline. The pin is gated on 'originalHandle' in
    // keys() so absent is accepted.
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("posts").doc("p_repost").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "alice's words",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "p_orig",
        originalAuthorId: "alice",
      })
    );
  });

  // 2026-06-01 audit: reply-reposts (originalReplyId set) are now verified at
  // the rule layer against the ORIGINAL REPLY, same as post-reposts. setReply
  // seeds posts/p_orig/replies/r1 authored by alice with text "a reply".
  it("allows a faithful reply-repost", async () => {
    await setReply("p_orig", "r1", "alice");
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("posts").doc("p_repost").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "a reply",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "p_orig",
        originalReplyId: "r1",
        originalAuthorId: "alice",
        originalHandle: "handle_alice",
      })
    );
  });

  it("rejects a reply-repost with a forged originalAuthorId", async () => {
    await setReply("p_orig", "r1", "alice"); // reply really authored by alice
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p_repost").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "a reply",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "p_orig",
        originalReplyId: "r1",
        originalAuthorId: "carol", // forged byline
        originalHandle: "handle_carol",
      })
    );
  });

  it("rejects a reply-repost with text that doesn't match the original reply", async () => {
    await setReply("p_orig", "r1", "alice");
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p_repost").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "fabricated reply quote",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "p_orig",
        originalReplyId: "r1",
        originalAuthorId: "alice",
        originalHandle: "handle_alice",
      })
    );
  });

  it("rejects a reply-repost pointing at a non-existent reply", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p_repost").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "a reply",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        isRepost: true,
        originalPostId: "p_orig",
        originalReplyId: "does_not_exist",
        originalAuthorId: "alice",
        originalHandle: "handle_alice",
      })
    );
  });
});

describe("notification create: message field is server-only (audit P1 2026-05-08)", () => {
  // The reply-type notification rule does not require an actual reply doc
  // to exist, only that postId points at a post owned by the recipient.
  // Combined with a previously client-writable `message` field, that let
  // any authenticated user plant a free-text payload into any victim's
  // NotificationsView (rendered as `"@handle replied: \"...\""`),
  // bypassing validateReply moderation. The fix drops `message` from the
  // schema lockdown; enrichReplyNotification (Cloud Function) backfills
  // the field from the actual reply doc via Admin SDK.
  beforeEach(async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("p1", "alice");
  });

  it("rejects notification create with a client-supplied message field", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users").doc("alice")
        .collection("notifications").doc("reply_p1_bob")
        .set({
          type: "reply",
          fromUserId: "bob",
          fromHandle: "handle_bob",
          message: "alex from school knows you are @victim_handle",
          postId: "p1",
          isRead: false,
          createdAt: serverTimestamp(),
        })
    );
  });

  it("allows reply notification create when message field is omitted", async () => {
    // The legitimate iOS write path no longer includes `message`. The Cloud
    // Function backfill populates it post-create via Admin SDK.
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("users").doc("alice")
        .collection("notifications").doc("reply_p1_bob")
        .set({
          type: "reply",
          fromUserId: "bob",
          fromHandle: "handle_bob",
          postId: "p1",
          isRead: false,
          createdAt: serverTimestamp(),
        })
    );
  });

  it("rejects message-type notification create with a client-supplied message field", async () => {
    // Defense-in-depth: even though message-type notifications never
    // rendered the `message` field in NotificationsView, the schema
    // lockdown now uniformly rejects the field across all types. Closes
    // the future-trigger-trusts-the-field shape generally.
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("conversations").doc("c1").set({
        participants: ["alice", "bob"],
        createdAt: new Date(),
      });
    });
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users").doc("alice")
        .collection("notifications").doc("message_c1_bob")
        .set({
          type: "message",
          fromUserId: "bob",
          fromHandle: "handle_bob",
          message: "anything",
          conversationId: "c1",
          isRead: false,
          createdAt: serverTimestamp(),
        })
    );
  });
});

describe("authorHandle pin (post + reply): byline must match user-doc handle", () => {
  // Closes the byline-spoof gap on top-level publishing surfaces. Without
  // these pins, a user could write their own post / reply with a spoofed
  // authorHandle ("@victim_handle"), and every reader's feed / thread UI
  // would render the content under that misattributed byline. authorId
  // stays correct (rule pins it to auth.uid) so backend traces resolve to
  // the real actor — but the in-app render is what determines the social
  // shape.
  beforeEach(async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
  });

  it("rejects post create with authorHandle spoofed to another user's handle", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        authorHandle: "handle_bob", // spoofed
        text: "hello",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });

  it("rejects post create with a fully fabricated authorHandle", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        authorHandle: "@victim_lookalike",
        text: "hello",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });

  it("allows post create when authorHandle matches caller's user-doc handle", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        authorHandle: "handle_alice",
        text: "hello",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });

  it("allows post create when authorHandle is omitted entirely", async () => {
    // Omission is the legitimate fallback — the pin is gated on the field
    // being present in keys().
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        text: "hello",
        createdAt: serverTimestamp(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });

  it("rejects reply create with authorHandle spoofed to another user's handle", async () => {
    await setPost("p1", "alice");
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p1").collection("replies").doc("r1").set({
        authorId: "bob",
        authorHandle: "handle_alice", // spoofed
        text: "responding",
        createdAt: serverTimestamp(),
      })
    );
  });

  it("allows reply create when authorHandle matches caller's user-doc handle", async () => {
    await setPost("p1", "alice");
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("posts").doc("p1").collection("replies").doc("r1").set({
        authorId: "bob",
        authorHandle: "handle_bob",
        text: "responding",
        createdAt: serverTimestamp(),
      })
    );
  });
});

// 2026-06-01 audit — pending-review subcollections must inherit the parent
// post's visibility. Before the fix, replies/likes under a held
// (moderationStatus != 'live') post were readable by any authed user, which
// leaked the held post's content (replies snapshot parentPostText) and its
// engager list. postVisibleToCaller() (firestore.rules:18) now gates these.
async function setAdmin(uid) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().collection("admins").doc(uid).set({ role: "admin" });
  });
}

describe("C-1 (2026-07-17): admin go-live must scrub moderation markers", () => {
  // A live post doc is readable by every authenticated client, so an admin
  // update that transitions moderationStatus to "live" must not leave
  // crisis/moderation metadata (concerningContent / flagged / flagReason /
  // pendingReason) on the resulting doc.
  beforeEach(async () => {
    await setUserDoc("alice");
    await setAdmin("mod");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("posts").doc("held1").set({
        authorId: "alice", authorHandle: "handle_alice", text: "held words",
        createdAt: new Date(), likeCount: 0, repostCount: 0, replyCount: 0,
        moderationStatus: "pending_review", pendingReason: "crisis",
        concerningContent: true, flagged: true, flagReason: "self_harm",
      });
    });
  });

  it("DENIED: admin sets live while concerningContent stays true", async () => {
    const m = env.authenticatedContext("mod").firestore();
    await assertFails(m.collection("posts").doc("held1").update({
      moderationStatus: "live",
    }));
  });

  it("allows admin go-live when the full marker set is cleared", async () => {
    const m = env.authenticatedContext("mod").firestore();
    await assertSucceeds(m.collection("posts").doc("held1").update({
      moderationStatus: "live",
      concerningContent: deleteField(), flagged: deleteField(),
      flagReason: deleteField(), pendingReason: deleteField(),
    }));
  });

  it("allows a marker-neutral admin update on a live+flagged doc (delete stamp)", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("posts").doc("liveflagged").set({
        authorId: "alice", authorHandle: "handle_alice", text: "flagged words",
        createdAt: new Date(), likeCount: 0, repostCount: 0, replyCount: 0,
        moderationStatus: "live", flagged: true, flagReason: "spam",
      });
    });
    const m = env.authenticatedContext("mod").firestore();
    await assertSucceeds(m.collection("posts").doc("liveflagged").update({
      deletedBy: "mod", deletedAt: serverTimestamp(),
    }));
  });
});

describe("C-1 (2026-07-17): crisisReplyQueue is admin-only", () => {
  beforeEach(async () => {
    await setUserDoc("alice");
    await setAdmin("mod");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("crisisReplyQueue").doc("p1_r1").set({
        postId: "p1", replyId: "r1", reviewed: false, detectedAt: new Date(),
      });
    });
  });

  it("DENIED: non-admin cannot read a queue entry", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(a.collection("crisisReplyQueue").doc("p1_r1").get());
  });
  it("DENIED: non-admin cannot list the queue", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(a.collection("crisisReplyQueue").where("reviewed", "==", false).get());
  });
  it("allows admin read", async () => {
    const m = env.authenticatedContext("mod").firestore();
    await assertSucceeds(m.collection("crisisReplyQueue").doc("p1_r1").get());
  });
  it("allows admin to mark reviewed", async () => {
    const m = env.authenticatedContext("mod").firestore();
    await assertSucceeds(m.collection("crisisReplyQueue").doc("p1_r1").update({
      reviewed: true, reviewedAt: serverTimestamp(), reviewedBy: "mod",
    }));
  });
  it("DENIED: admin update cannot repoint the entry at another reply", async () => {
    const m = env.authenticatedContext("mod").firestore();
    await assertFails(m.collection("crisisReplyQueue").doc("p1_r1").update({
      reviewed: true, replyId: "someone_elses_reply",
    }));
  });
  it("DENIED: non-admin cannot create or update queue entries", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(a.collection("crisisReplyQueue").doc("x").set({
      postId: "p", replyId: "r", reviewed: false,
    }));
    await assertFails(a.collection("crisisReplyQueue").doc("p1_r1").update({ reviewed: true }));
  });
});

async function setReply(postId, replyId, authorId) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx
      .firestore()
      .collection("posts").doc(postId)
      .collection("replies").doc(replyId)
      .set({
        authorId,
        text: "a reply",
        parentPostText: "the held parent post body",
        createdAt: new Date(),
        likeCount: 0,
      });
  });
}

async function setLike(postId, likeUserId) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx
      .firestore()
      .collection("posts").doc(postId)
      .collection("likes").doc(likeUserId)
      .set({ createdAt: new Date() });
  });
}

describe("pending-review: post subcollections inherit parent visibility", () => {
  // alice authors a post that the moderation system has HELD.
  beforeEach(async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setPost("held", "alice", { moderationStatus: "pending_review" });
    await setPost("live", "alice", { moderationStatus: "live" });
    await setReply("held", "r1", "carol");
    await setReply("live", "r1", "carol");
    await setLike("held", "dave");
    await setLike("live", "dave");
  });

  it("blocks a non-author from reading replies on a held post", async () => {
    const bob = env.authenticatedContext("bob").firestore();
    await assertFails(
      bob.collection("posts").doc("held").collection("replies").doc("r1").get()
    );
  });

  it("lets the post author read replies on their own held post", async () => {
    const alice = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      alice.collection("posts").doc("held").collection("replies").doc("r1").get()
    );
  });

  it("lets an admin read replies on a held post", async () => {
    await setAdmin("mod");
    const mod = env.authenticatedContext("mod").firestore();
    await assertSucceeds(
      mod.collection("posts").doc("held").collection("replies").doc("r1").get()
    );
  });

  it("still lets any authed user read replies on a live post", async () => {
    const bob = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      bob.collection("posts").doc("live").collection("replies").doc("r1").get()
    );
  });

  it("defaults a post with no moderationStatus field to live (legacy)", async () => {
    await setPost("legacy", "alice"); // no moderationStatus
    await setReply("legacy", "r1", "carol");
    const bob = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      bob.collection("posts").doc("legacy").collection("replies").doc("r1").get()
    );
  });

  it("blocks a non-author from enumerating likers on a held post", async () => {
    const bob = env.authenticatedContext("bob").firestore();
    await assertFails(
      bob.collection("posts").doc("held").collection("likes").doc("dave").get()
    );
  });

  it("still lets any authed user read likes on a live post", async () => {
    const bob = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      bob.collection("posts").doc("live").collection("likes").doc("dave").get()
    );
  });

  // The collection-group catch-all (firestore.rules /{path=**}/replies) is
  // ORed with the per-post rule, so it must not re-open the leak.
  it("collectionGroup: a user can read their OWN replies (powers ProfileView)", async () => {
    await setReply("held", "mine", "bob"); // bob's own reply under a held post
    const bob = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      bob.collectionGroup("replies").where("authorId", "==", "bob").get()
    );
  });

  it("collectionGroup: a user CANNOT read another user's replies", async () => {
    // carol authored held/r1; bob querying carol's replies is denied — this
    // is the OtherProfileView path that was intentionally closed.
    const bob = env.authenticatedContext("bob").firestore();
    await assertFails(
      bob.collectionGroup("replies").where("authorId", "==", "carol").get()
    );
  });

  it("collectionGroup: an unfiltered replies dump is denied", async () => {
    const bob = env.authenticatedContext("bob").firestore();
    await assertFails(bob.collectionGroup("replies").get());
  });
});

// ============================================================
// Cut features denied entirely (DMs + FeelingCircle), 2026-06-03.
// conversations/messages and feelingCircles/messages reject all client
// reads and writes. Only the Admin SDK (cleanup/cascade) touches leftovers.
// Replaces the prior feature-tests that asserted these writes SUCCEED.
// ============================================================
describe("cut features: conversations + feelingCircles fully denied", () => {
  it("rejects conversation create", async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("conversations").doc("alice_bob").set({
        participants: ["alice", "bob"],
        createdAt: new Date(),
      })
    );
  });

  it("rejects conversation read", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("conversations").doc("c1").set({
        participants: ["alice", "bob"],
      });
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(a.collection("conversations").doc("c1").get());
  });

  it("rejects conversation message create", async () => {
    await setUserDoc("alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("conversations").doc("c1").set({
        participants: ["alice", "bob"],
      });
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("conversations").doc("c1").collection("messages").doc("m1").set({
        senderId: "alice", text: "hi", clientCountedV1: true, createdAt: new Date(),
      })
    );
  });

  it("rejects feelingCircle create", async () => {
    await setUserDoc("alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("feelingCircles").doc("fc1").set({
        tag: "lonely", participants: ["alice"],
        createdAt: new Date(), expiresAt: new Date(Date.now() + 3600 * 1000),
      })
    );
  });

  it("rejects feelingCircle read", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("feelingCircles").doc("fc1").set({ participants: ["alice"] });
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(a.collection("feelingCircles").doc("fc1").get());
  });

  it("rejects feelingCircle message create", async () => {
    await setUserDoc("alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("feelingCircles").doc("fc1").set({ participants: ["alice"] });
    });
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("feelingCircles").doc("fc1").collection("messages").add({
        authorId: "alice", authorHandle: "handle_alice", text: "hi", createdAt: new Date(),
      })
    );
  });
});

// ============================================================
// SEC-1: aggregate counters on the user doc are server-owned. A client
// must not forge followerCount/followingCount/totalLikes/postCount on its
// own user doc (OtherProfileView reads these -> forged value = fake
// follower-count social proof). Only the Cloud Functions (Admin SDK) write them.
// ============================================================
describe("user doc: aggregate counters are server-owned (SEC-1)", () => {
  it("rejects owner forging followerCount on own user doc", async () => {
    await setUserDoc("alice", { followerCount: 0 });
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(a.collection("users").doc("alice").update({ followerCount: 999999 }));
  });

  it("rejects owner forging followingCount / totalLikes", async () => {
    // postCount was removed 2026-06-30 (unused + unmaintained), so it's no
    // longer a locked server-owned counter — only followerCount/followingCount/
    // totalLikes remain locked.
    await setUserDoc("alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(a.collection("users").doc("alice").update({ followingCount: 500 }));
    await assertFails(a.collection("users").doc("alice").update({ totalLikes: 12345 }));
  });

  it("still allows owner to update a normal field (allowSharing)", async () => {
    await setUserDoc("alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(a.collection("users").doc("alice").update({ allowSharing: false }));
  });
});

// Web-phase-1 finding (2026-07-09): the shared `allow create, delete` on
// users/{uid}/blocked evaluated request.resource.data on DELETE, where
// request.resource doesn't exist — so every client unblock (iOS
// BlockedUsersCache.unblock, web) was denied since S-2 (2026-06-16). The rule
// is now split; these pin both halves.
describe("blocked subcollection: unblock works, S-2 create pin holds", () => {
  it("allows the owner to delete their own block entry (unblock)", async () => {
    await setUserDoc("alice");
    await setBlock("alice", "bob");
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("users").doc("alice").collection("blocked").doc("bob").delete());
  });

  it("rejects a non-owner deleting someone else's block entry", async () => {
    await setUserDoc("alice");
    await setBlock("alice", "bob");
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("users").doc("alice").collection("blocked").doc("bob").delete());
  });

  it("still allows create with blockedUid == doc id", async () => {
    await setUserDoc("alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("users").doc("alice").collection("blocked").doc("bob")
        .set({ blockedAt: new Date(), blockedUid: "bob", handle: "handle_bob" }));
  });

  it("still rejects create with a tampered blockedUid (S-2)", async () => {
    await setUserDoc("alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("users").doc("alice").collection("blocked").doc("bob")
        .set({ blockedAt: new Date(), blockedUid: "victim" }));
  });
});
