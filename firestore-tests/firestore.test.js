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
const { serverTimestamp } = require("firebase/firestore");
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
  it("authenticated user can create their own user doc with valid handle", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
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

  it("rejects post create with text size > 2000", async () => {
    await setUserDoc("alice");
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("posts").doc("p1").set({
        authorId: "alice",
        authorHandle: "alice123",
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
        authorHandle: "alice123",
        text: "hello world",
        createdAt: new Date(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });
});

describe("Finding 1: conversation participants must be exactly 2", () => {
  it("allows 2-party conversation create", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("conversations").doc("c1").set({
        participants: ["alice", "bob"],
        messageCount: { alice: 0, bob: 0 },
        createdAt: new Date(),
      })
    );
  });

  it("rejects 3-party conversation create", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("conversations").doc("c1").set({
        participants: ["alice", "bob", "charlie"],
        messageCount: { alice: 0, bob: 0, charlie: 0 },
        createdAt: new Date(),
      })
    );
  });

  it("rejects 1-party (self-only) conversation create", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("conversations").doc("c1").set({
        participants: ["alice"],
        createdAt: new Date(),
      })
    );
  });

  it("rejects 2-party conversation where participants[0] == participants[1]", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("conversations").doc("c1").set({
        participants: ["alice", "alice"],
        createdAt: new Date(),
      })
    );
  });

  it("blocked user cannot send message in 2-party conversation", async () => {
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setBlock("bob", "alice"); // bob blocks alice
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("conversations").doc("c1").set({
        participants: ["alice", "bob"],
        messageCount: { alice: 0, bob: 0 },
        createdAt: new Date(),
      });
    });

    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("conversations").doc("c1").collection("messages").doc("m1").set({
        senderId: "alice",
        text: "hi",
        createdAt: new Date(),
        clientCountedV1: true,
      })
    );
  });

  it("blocked user cannot send message even in legacy 3-party conversation", async () => {
    // Belt-and-suspenders: even if a 3-party convo somehow exists (legacy
    // data, admin SDK write), the message-create rule's strict size==2
    // assertion blocks the write. Closes the original short-circuit gap.
    await setUserDoc("alice");
    await setUserDoc("bob");
    await setBlock("bob", "alice");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("conversations").doc("c1").set({
        participants: ["alice", "bob", "charlie"],
        messageCount: { alice: 0, bob: 0, charlie: 0 },
        createdAt: new Date(),
      });
    });

    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("conversations").doc("c1").collection("messages").doc("m1").set({
        senderId: "alice",
        text: "hi",
        createdAt: new Date(),
        clientCountedV1: true,
      })
    );
  });
});

describe("Finding 2: feelingCircles update can only add/remove caller", () => {
  it("allows joining a circle (adds caller)", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("feelingCircles").doc("fc1").set({
        tag: "lonely",
        participants: ["alice"],
        createdAt: new Date(),
      });
    });
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("feelingCircles").doc("fc1").update({
        participants: ["alice", "bob"],
      })
    );
  });

  it("allows leaving a circle (removes caller)", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("feelingCircles").doc("fc1").set({
        tag: "lonely",
        participants: ["alice", "bob"],
        createdAt: new Date(),
      });
    });
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("feelingCircles").doc("fc1").update({
        participants: ["alice"],
      })
    );
  });

  it("rejects force-add of another user without consent", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("feelingCircles").doc("fc1").set({
        tag: "lonely",
        participants: ["alice"],
        createdAt: new Date(),
      });
    });
    const a = env.authenticatedContext("alice").firestore();
    // alice tries to add bob and charlie without their consent
    await assertFails(
      a.collection("feelingCircles").doc("fc1").update({
        participants: ["alice", "bob", "charlie"],
      })
    );
  });

  it("second joiner can update participants only (matches iOS branched path)", async () => {
    // Mirrors the UPDATE branch of FeelingCircleView.joinCircle: when the
    // doc already exists, iOS issues an updateData with ONLY participants
    // (arrayUnion). The previous shape — a single setData(merge:true)
    // re-writing createdAt as serverTimestamp — was silently denied here
    // and joinCircle quietly logged + bailed for every Nth joiner.
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("feelingCircles").doc("fc1").set({
        tag: "lonely",
        date: "2026-05-04",
        participants: ["alice"],
        createdAt: new Date(2026, 4, 4, 12, 0),
        expiresAt: new Date(Date.now() + 12 * 60 * 60 * 1000),
      });
    });
    const { arrayUnion } = require("firebase/firestore");
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("feelingCircles").doc("fc1").update({
        participants: arrayUnion("bob"),
      })
    );
  });

  it("rejects evicting another participant", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("feelingCircles").doc("fc1").set({
        tag: "lonely",
        participants: ["alice", "bob", "charlie"],
        createdAt: new Date(),
      });
    });
    const a = env.authenticatedContext("alice").firestore();
    // alice tries to remove bob
    await assertFails(
      a.collection("feelingCircles").doc("fc1").update({
        participants: ["alice", "charlie"],
      })
    );
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
          createdAt: new Date(),
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
        authorHandle: "alice123",
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
        authorHandle: "alice123",
        text: "feeling lonely",
        createdAt: new Date(),
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
        authorHandle: "alice123",
        text: "hello",
        createdAt: new Date(),
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
    await assertSucceeds(
      b.collection("posts").doc("p1").collection("likes").doc("bob").set({
        createdAt: new Date(),
      })
    );
    await assertSucceeds(
      b.collection("users").doc("bob").collection("saved").doc("p1").set({
        createdAt: new Date(),
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
        authorHandle: "alice123",
        text: "hello",
        createdAt: new Date(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
      })
    );
  });
});

describe("conversations update is schema-locked to allow-listed fields", () => {
  async function seedConvo(extra = {}) {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("conversations").doc("c1").set({
        participants: ["alice", "bob"],
        messageCount: { alice: 0, bob: 0 },
        typing: { alice: false, bob: false },
        typingAt: {},
        lastRead: {},
        participantHandles: { alice: "alice", bob: "bob" },
        createdAt: new Date(),
        ...extra,
      });
    });
  }

  it("allows lastMessage + lastMessageAt + own messageCount slot bumped by 1", async () => {
    await seedConvo();
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("conversations").doc("c1").update({
        lastMessage: "hi",
        lastMessageAt: new Date(),
        "messageCount.alice": 1,
      })
    );
  });

  it("allows updating own typing slot", async () => {
    await seedConvo();
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("conversations").doc("c1").update({
        "typing.alice": true,
      })
    );
  });

  it("allows refreshing own participantHandles slot", async () => {
    await seedConvo();
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("conversations").doc("c1").update({
        "participantHandles.alice": "alice_new",
      })
    );
  });

  it("rejects writing the other peer's participantHandles slot", async () => {
    await seedConvo();
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("conversations").doc("c1").update({
        "participantHandles.bob": "spoofed",
      })
    );
  });

  it("rejects writing the other peer's typing slot", async () => {
    await seedConvo();
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("conversations").doc("c1").update({
        "typing.bob": true,
      })
    );
  });

  it("rejects writing the other peer's lastRead slot", async () => {
    await seedConvo();
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("conversations").doc("c1").update({
        "lastRead.bob": new Date(),
      })
    );
  });

  it("rejects messageCount jump of more than +1", async () => {
    await seedConvo();
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("conversations").doc("c1").update({
        "messageCount.alice": 5,
      })
    );
  });

  it("rejects writing arbitrary unlisted top-level fields", async () => {
    await seedConvo();
    const a = env.authenticatedContext("alice").firestore();
    // `flagged` would let a future trigger trust client-supplied moderation
    // state; the schema lock keeps it (and any other unlisted key) out.
    await assertFails(
      a.collection("conversations").doc("c1").update({
        flagged: false,
      })
    );
  });
});

describe("feelingCircles create is constrained to caller-only participants", () => {
  // serverTimestamp() resolves to request.time inside the rule evaluation,
  // matching the createdAt == request.time predicate.
  function tomorrowMidnight() {
    const d = new Date();
    d.setHours(0, 0, 0, 0);
    d.setDate(d.getDate() + 1);
    return d;
  }

  it("allows legitimate first-joiner create", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertSucceeds(
      a.collection("feelingCircles").doc("fc1").set({
        tag: "lonely",
        date: "2026-05-04",
        participants: ["alice"],
        createdAt: serverTimestamp(),
        expiresAt: tomorrowMidnight(),
      })
    );
  });

  it("rejects create with another user pre-seeded into participants", async () => {
    // The original wide-open create rule let a tampered client force-seed
    // victims into a circle's participants list at creation time, bypassing
    // the size-20 + own-uid-only enforcement on update.
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("feelingCircles").doc("fc1").set({
        tag: "lonely",
        date: "2026-05-04",
        participants: ["alice", "victim1", "victim2"],
        createdAt: serverTimestamp(),
        expiresAt: tomorrowMidnight(),
      })
    );
  });

  it("rejects create where the caller isn't the participant", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("feelingCircles").doc("fc1").set({
        tag: "lonely",
        date: "2026-05-04",
        participants: ["bob"],
        createdAt: serverTimestamp(),
        expiresAt: tomorrowMidnight(),
      })
    );
  });

  it("rejects create with expiresAt far in the future (defeats hourly cleanup)", async () => {
    const a = env.authenticatedContext("alice").firestore();
    const farFuture = new Date();
    farFuture.setDate(farFuture.getDate() + 7);
    await assertFails(
      a.collection("feelingCircles").doc("fc1").set({
        tag: "lonely",
        date: "2026-05-04",
        participants: ["alice"],
        createdAt: serverTimestamp(),
        expiresAt: farFuture,
      })
    );
  });

  it("rejects create with a scratch field outside the schema", async () => {
    const a = env.authenticatedContext("alice").firestore();
    await assertFails(
      a.collection("feelingCircles").doc("fc1").set({
        tag: "lonely",
        date: "2026-05-04",
        participants: ["alice"],
        createdAt: serverTimestamp(),
        expiresAt: tomorrowMidnight(),
        flagged: false,
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

  it("allows a legitimate reflection create", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertSucceeds(
      b.collection("posts").doc("p1").collection("reflections").doc("bob").set({
        authorId: "bob",
        text: "thinking about this again",
        createdAt: new Date(),
      })
    );
  });

  it("rejects reflection create with text > 500 chars", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p1").collection("reflections").doc("bob").set({
        authorId: "bob",
        text: "x".repeat(501),
        createdAt: new Date(),
      })
    );
  });

  it("rejects reflection create with extra unlisted field", async () => {
    const b = env.authenticatedContext("bob").firestore();
    await assertFails(
      b.collection("posts").doc("p1").collection("reflections").doc("bob").set({
        authorId: "bob",
        text: "ok",
        createdAt: new Date(),
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
