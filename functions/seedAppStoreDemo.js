// Seed an App Store review demo account + a small buddy ecosystem so every
// feature in the app has something real to interact with.
//
// What this seeds (in order):
//   1. demo account (Auth user + user doc + private/data)
//      - email:  appreview@toskaapp.com  (override with --email)
//      - handle: appreview_demo
//      - fully onboarded: confirmedAdult=true, acceptedPolicyVersion=1,
//        hasCompletedOnboarding=true, breakupStage="months in"
//   2. two buddy accounts so the demo isn't alone in an empty feed:
//      - soft_evening_42  (stage "still in it")
//      - late_oak_88      (stage "a year or more")
//   3. content:
//      - 3 posts authored by demo (likeCount/replyCount/repostCount pre-set
//        so a reviewer can see real numbers)
//      - 2 posts by soft_evening_42, 1 post by late_oak_88
//      - soft_evening_42 likes one demo post and replies to another
//      - demo follows soft_evening_42 (so demo's feed has a follow signal)
//      - soft_evening_42 follows demo (so demo has 1 follower)
//      - one DM conversation between demo and soft_evening_42 with 2 messages
//
// The script is idempotent in this sense:
//   - if the auth user for an email already exists, we re-use it (no recreate)
//   - if a user doc / post / conversation with our deterministic id already
//     exists, we overwrite it with merge-set semantics — the seeded state
//     converges on every run
//
// Safety:
//   - default mode is dry-run (prints every planned write, performs none)
//   - --apply must be passed explicitly to commit
//   - the script refuses to run unless GCLOUD_PROJECT is set explicitly,
//     matching the convention in scrubLegacyPII.js — never let auto-detection
//     pick the wrong project
//   - if you pass --project=prod-only-please-no the script also bails (no
//     attempt to short-circuit GCLOUD_PROJECT validation)
//
// Usage:
//   cd functions
//   GCLOUD_PROJECT=toskastaging node seedAppStoreDemo.js                    # dry run
//   GCLOUD_PROJECT=toskastaging node seedAppStoreDemo.js --apply            # writes
//   GCLOUD_PROJECT=toskastaging node seedAppStoreDemo.js --apply \
//       --email=demo@example.com                                            # custom email
//   GCLOUD_PROJECT=toskastaging node seedAppStoreDemo.js --apply \
//       --password='your-own-strong-password'                               # supply password
//
// Requires that ADC credentials (or GOOGLE_APPLICATION_CREDENTIALS env var)
// point at a service account with Firestore + Auth admin write access on the
// target project.

const admin = require("firebase-admin");
const crypto = require("crypto");

// ---------- arg parsing ----------

const APPLY = process.argv.includes("--apply");

function argValue(name) {
  const arg = process.argv.find(a => a.startsWith(`--${name}=`));
  return arg ? arg.split("=").slice(1).join("=") : null;
}

const EMAIL_OVERRIDE = argValue("email");
const PASSWORD_OVERRIDE = argValue("password");

// ---------- project guard ----------

if (!process.env.GCLOUD_PROJECT) {
  console.error(
    "Refusing to run without GCLOUD_PROJECT explicitly set.\n" +
    "Run as:\n" +
    "  GCLOUD_PROJECT=toskastaging node seedAppStoreDemo.js [--apply]"
  );
  process.exit(1);
}
const PROJECT = process.env.GCLOUD_PROJECT;

// Belt-and-suspenders: a typo'd GCLOUD_PROJECT pointed at prod by accident
// would seed prod with throwaway demo content. Require explicit confirmation
// on prod.
if (PROJECT === "toska-4ebf4" && !process.argv.includes("--yes-this-is-prod")) {
  console.error(
    "GCLOUD_PROJECT=toska-4ebf4 (prod). Refusing without --yes-this-is-prod.\n" +
    "Demo content lands in real production. If you really mean it:\n" +
    "  GCLOUD_PROJECT=toska-4ebf4 node seedAppStoreDemo.js --apply --yes-this-is-prod"
  );
  process.exit(1);
}

admin.initializeApp();
const db = admin.firestore();
const auth = admin.auth();
const { FieldValue, Timestamp } = admin.firestore;

// ---------- credentials ----------

const DEMO_EMAIL = EMAIL_OVERRIDE || "appreview@toskaapp.com";
const DEMO_HANDLE = "appreview_demo";

// 24-char URL-safe random password, printed once at the end so the operator
// can paste it into 1Password / App Store Connect. If the user supplies
// --password=…, use that instead so they keep control.
function generatePassword() {
  return crypto.randomBytes(18).toString("base64url"); // 24 chars
}
const DEMO_PASSWORD = PASSWORD_OVERRIDE || generatePassword();

// Buddy accounts (no need to pass these to a reviewer — they exist only so
// the demo's feed / DMs / follow lists aren't empty). Their passwords are
// throwaway; nobody signs in as them.
const BUDDIES = [
  {
    email: "appreview_buddy_soft@toskaapp.com",
    handle: "soft_evening_42",
    breakupStage: "still in it",
  },
  {
    email: "appreview_buddy_late@toskaapp.com",
    handle: "late_oak_88",
    breakupStage: "a year or more",
  },
];

// ---------- planned writes ledger (for dry-run printing) ----------

const planned = [];
function plan(action, path, payload) {
  planned.push({ action, path, payload });
}

// ---------- seeded post text (kept on-brand: vulnerable, anonymous,
// no PII patterns the moderation pipeline would catch) ----------

const DEMO_POSTS = [
  {
    id: "demo_post_1",
    text: "the silence in the kitchen at night is the loudest thing now.",
    tag: "lonely",
    likeCount: 7,
    replyCount: 1,
    repostCount: 0,
  },
  {
    id: "demo_post_2",
    text: "i forgot how to be the version of me that existed before them. starting over from scratch is also kind of freeing.",
    tag: "rebuilding",
    likeCount: 12,
    replyCount: 0,
    repostCount: 1,
  },
  {
    id: "demo_post_3",
    text: "today i made it to noon without crying. that's a win.",
    tag: "small_wins",
    likeCount: 4,
    replyCount: 0,
    repostCount: 0,
  },
];

const BUDDY_POSTS = [
  {
    authorIdx: 0, // soft_evening_42
    id: "demo_buddy_soft_post_1",
    text: "everyone says it gets easier. it doesn't. you just get used to carrying it.",
    tag: "honesty",
    likeCount: 23,
    replyCount: 2,
    repostCount: 4,
  },
  {
    authorIdx: 0,
    id: "demo_buddy_soft_post_2",
    text: "found one of their hoodies in the back of my closet. immediately spiraled. then made tea. small acts of survival.",
    tag: "lonely",
    likeCount: 8,
    replyCount: 1,
    repostCount: 0,
  },
  {
    authorIdx: 1, // late_oak_88
    id: "demo_buddy_late_post_1",
    text: "a year out. i don't think about them every day anymore. that itself was unimaginable in month one.",
    tag: "rebuilding",
    likeCount: 31,
    replyCount: 5,
    repostCount: 7,
  },
];

// Replies backing the BUDDY_POSTS replyCount values above. Without these,
// the post detail view shows "X replies" in the header but renders the
// "be the first to reply" empty state — looks broken to anyone (Apple
// reviewer included) tapping into a buddy post. authorIdx -1 means the
// demo user; 0 = soft_evening_42; 1 = late_oak_88. Counts on each
// BUDDY_POSTS entry MUST equal the number of replies aimed at that post
// id below — otherwise the header re-introduces the same drift.
const BUDDY_REPLIES = [
  // demo_buddy_soft_post_1 (replyCount: 2)
  {
    postId: "demo_buddy_soft_post_1",
    id: "demo_buddy_soft_post_1_reply_1",
    authorIdx: -1, // demo
    text: "this hits. some days carrying it is lighter than others.",
  },
  {
    postId: "demo_buddy_soft_post_1",
    id: "demo_buddy_soft_post_1_reply_2",
    authorIdx: 1, // late_oak_88
    text: "yeah. and the days you forget you're carrying it at all count too.",
  },
  // demo_buddy_soft_post_2 (replyCount: 1)
  {
    postId: "demo_buddy_soft_post_2",
    id: "demo_buddy_soft_post_2_reply_1",
    authorIdx: -1, // demo
    text: "the small acts count more than people realize. tea counts.",
  },
  // demo_buddy_late_post_1 (replyCount: 5)
  {
    postId: "demo_buddy_late_post_1",
    id: "demo_buddy_late_post_1_reply_1",
    authorIdx: 0, // soft_evening_42
    text: "needed to hear this today. one year feels impossible from where i am.",
  },
  {
    postId: "demo_buddy_late_post_1",
    id: "demo_buddy_late_post_1_reply_2",
    authorIdx: -1, // demo
    text: "saving this so i can come back to it on a hard week.",
  },
  {
    postId: "demo_buddy_late_post_1",
    id: "demo_buddy_late_post_1_reply_3",
    authorIdx: 0,
    text: "the unimaginable-in-month-one part is what i needed.",
  },
  {
    postId: "demo_buddy_late_post_1",
    id: "demo_buddy_late_post_1_reply_4",
    authorIdx: -1,
    text: "this is the kind of post i open the app for.",
  },
  {
    postId: "demo_buddy_late_post_1",
    id: "demo_buddy_late_post_1_reply_5",
    authorIdx: 0,
    text: "sending you something gentle from earlier in it.",
  },
];

// ---------- helpers ----------

// Returns { uid, created }. `created` is true only when this run actually
// minted the auth user — used by the credentials-print block at the end so
// we never claim the supplied password is live when we silently reused an
// existing account from a prior run (the prior password is the live one
// and we don't have it).
async function ensureAuthUser(email, password, displayName) {
  let user;
  try {
    user = await auth.getUserByEmail(email);
    plan("auth.reuse", `auth/${email}`, { uid: user.uid });
    return { uid: user.uid, created: false };
  } catch (err) {
    if (err.code !== "auth/user-not-found") throw err;
  }
  if (!APPLY) {
    plan("auth.create", `auth/${email}`, { displayName, password: "<redacted>" });
    return { uid: `<dry-run-uid-for-${email}>`, created: true };
  }
  const created = await auth.createUser({
    email,
    password,
    displayName,
    emailVerified: true,
  });
  plan("auth.create", `auth/${email}`, { uid: created.uid, displayName });
  return { uid: created.uid, created: true };
}

async function setUserDoc(uid, handle, breakupStage) {
  const userPath = `users/${uid}`;
  const privatePath = `users/${uid}/private/data`;
  plan("set", userPath, {
    handle,
    confirmedAdult: true,
    confirmedAdultAt: "<server-timestamp>",
    acceptedPolicyVersion: 1,
    acceptedPolicyAt: "<server-timestamp>",
    hasCompletedOnboarding: true,
    followerCount: 0,
    followingCount: 0,
    totalLikes: 0,
    allowSharing: true,
    showFollowerCount: false,
    createdAt: "<server-timestamp>",
  });
  plan("set", privatePath, {
    breakupStage,
    pushEnabled: true,
  });
  if (!APPLY) return;
  await db.doc(userPath).set({
    handle,
    confirmedAdult: true,
    confirmedAdultAt: FieldValue.serverTimestamp(),
    acceptedPolicyVersion: 1,
    acceptedPolicyAt: FieldValue.serverTimestamp(),
    hasCompletedOnboarding: true,
    followerCount: 0,
    followingCount: 0,
    totalLikes: 0,
    allowSharing: true,
    showFollowerCount: false,
    createdAt: FieldValue.serverTimestamp(),
  }, { merge: true });
  await db.doc(privatePath).set({
    breakupStage,
    pushEnabled: true,
  }, { merge: true });
}

async function setPost(authorUid, authorHandle, post) {
  const path = `posts/${post.id}`;
  const payload = {
    authorId: authorUid,
    authorHandle,
    text: post.text,
    tag: post.tag,
    likeCount: post.likeCount,
    replyCount: post.replyCount,
    repostCount: post.repostCount,
    createdAt: "<server-timestamp>",
  };
  plan("set", path, payload);
  if (!APPLY) return;
  await db.doc(path).set({
    authorId: authorUid,
    authorHandle,
    text: post.text,
    tag: post.tag,
    likeCount: post.likeCount,
    replyCount: post.replyCount,
    repostCount: post.repostCount,
    createdAt: FieldValue.serverTimestamp(),
  });
}

async function setLike(postId, likerUid) {
  const path = `posts/${postId}/likes/${likerUid}`;
  plan("set", path, { createdAt: "<server-timestamp>" });
  if (!APPLY) return;
  await db.doc(path).set({ createdAt: FieldValue.serverTimestamp() });
}

async function setReply(postId, replyId, authorUid, authorHandle, text) {
  const path = `posts/${postId}/replies/${replyId}`;
  plan("set", path, { authorId: authorUid, authorHandle, text });
  if (!APPLY) return;
  await db.doc(path).set({
    authorId: authorUid,
    authorHandle,
    text,
    likeCount: 0,
    createdAt: FieldValue.serverTimestamp(),
  });
}

async function setFollow(followerUid, followingUid) {
  const followingPath = `users/${followerUid}/following/${followingUid}`;
  const followerPath = `users/${followingUid}/followers/${followerUid}`;
  plan("set", followingPath, { createdAt: "<server-timestamp>" });
  plan("set", followerPath, { createdAt: "<server-timestamp>" });
  if (!APPLY) return;
  await db.doc(followingPath).set({ createdAt: FieldValue.serverTimestamp() });
  await db.doc(followerPath).set({ createdAt: FieldValue.serverTimestamp() });
}

async function bumpFollowCounts(demoUid, buddyUid) {
  // Mirror the counter-trigger end state directly so the demo's profile shows
  // followerCount=1 and followingCount=1 immediately, without depending on
  // trigger latency on staging.
  plan("update", `users/${demoUid}`, { followerCount: 1, followingCount: 1 });
  plan("update", `users/${buddyUid}`, { followerCount: 1, followingCount: 1 });
  if (!APPLY) return;
  await db.doc(`users/${demoUid}`).update({ followerCount: 1, followingCount: 1 });
  await db.doc(`users/${buddyUid}`).update({ followerCount: 1, followingCount: 1 });
}

async function setConversation(demoUid, demoHandle, buddyUid, buddyHandle) {
  // Deterministic convo id, lower uid first so both clients land on the same
  // doc regardless of who initiated. Matches OtherProfileView.startConversation
  // pattern.
  const ids = [demoUid, buddyUid].sort();
  const convoId = `${ids[0]}_${ids[1]}`;
  const convoPath = `conversations/${convoId}`;
  const messages = [
    { id: "m1", senderId: buddyUid, text: "hey. i saw your post earlier. it landed." },
    { id: "m2", senderId: demoUid, text: "thank you. some days the words just need to leave." },
  ];

  plan("set", convoPath, {
    participants: [demoUid, buddyUid],
    participantHandles: { [demoUid]: demoHandle, [buddyUid]: buddyHandle },
    messageCount: { [demoUid]: 1, [buddyUid]: 1 },
    typing: { [demoUid]: false, [buddyUid]: false },
    typingAt: {},
    lastRead: {},
    lastMessage: messages[messages.length - 1].text,
    lastMessageAt: "<server-timestamp>",
    createdAt: "<server-timestamp>",
  });
  for (const m of messages) {
    plan("set", `${convoPath}/messages/${m.id}`, {
      senderId: m.senderId,
      text: m.text,
      clientCountedV1: true,
      createdAt: "<server-timestamp>",
    });
  }
  if (!APPLY) return;
  await db.doc(convoPath).set({
    participants: [demoUid, buddyUid],
    participantHandles: { [demoUid]: demoHandle, [buddyUid]: buddyHandle },
    messageCount: { [demoUid]: 1, [buddyUid]: 1 },
    typing: { [demoUid]: false, [buddyUid]: false },
    typingAt: {},
    lastRead: {},
    lastMessage: messages[messages.length - 1].text,
    lastMessageAt: FieldValue.serverTimestamp(),
    createdAt: FieldValue.serverTimestamp(),
  });
  for (const m of messages) {
    await db.doc(`${convoPath}/messages/${m.id}`).set({
      senderId: m.senderId,
      text: m.text,
      clientCountedV1: true,
      createdAt: FieldValue.serverTimestamp(),
    });
  }
}

// ---------- main ----------

(async () => {
  console.log(`Project:   ${PROJECT}`);
  console.log(`Mode:      ${APPLY ? "APPLY (writes will land)" : "DRY RUN (no writes)"}`);
  console.log(`Demo email: ${DEMO_EMAIL}`);
  console.log("");

  const { uid: demoUid, created: demoCreated } = await ensureAuthUser(DEMO_EMAIL, DEMO_PASSWORD, DEMO_HANDLE);
  await setUserDoc(demoUid, DEMO_HANDLE, "months in");

  const buddyUids = [];
  const buddyCreds = [];
  for (const buddy of BUDDIES) {
    const password = generatePassword();
    const { uid, created } = await ensureAuthUser(buddy.email, password, buddy.handle);
    await setUserDoc(uid, buddy.handle, buddy.breakupStage);
    buddyUids.push(uid);
    buddyCreds.push({ email: buddy.email, handle: buddy.handle, uid, password, created });
  }
  const softUid = buddyUids[0];

  for (const post of DEMO_POSTS) {
    await setPost(demoUid, DEMO_HANDLE, post);
  }
  for (const post of BUDDY_POSTS) {
    const authorUid = buddyUids[post.authorIdx];
    const authorHandle = BUDDIES[post.authorIdx].handle;
    await setPost(authorUid, authorHandle, post);
  }

  // soft_evening_42 likes demo_post_1 and replies to demo_post_2.
  await setLike("demo_post_1", softUid);
  await setReply(
    "demo_post_2",
    "demo_reply_soft_1",
    softUid,
    BUDDIES[0].handle,
    "this. the version of you that comes back is different but real."
  );

  // Back the BUDDY_POSTS replyCount values with actual reply docs. Without
  // these, tapping a buddy post in the demo account shows the empty-state
  // ("be the first to reply") under a header that promises N replies.
  // authorIdx -1 = demo (so the demo user appears in the threaded view),
  // 0 = soft_evening_42, 1 = late_oak_88.
  for (const reply of BUDDY_REPLIES) {
    const authorUid = reply.authorIdx === -1 ? demoUid : buddyUids[reply.authorIdx];
    const authorHandle = reply.authorIdx === -1 ? DEMO_HANDLE : BUDDIES[reply.authorIdx].handle;
    await setReply(reply.postId, reply.id, authorUid, authorHandle, reply.text);
  }

  // mutual follow between demo and soft.
  await setFollow(demoUid, softUid);
  await setFollow(softUid, demoUid);
  await bumpFollowCounts(demoUid, softUid);

  await setConversation(demoUid, DEMO_HANDLE, softUid, BUDDIES[0].handle);

  // ---------- print summary ----------

  console.log("---- planned writes ----");
  for (const p of planned) {
    console.log(`  [${p.action}] ${p.path}`);
  }
  console.log(`  total: ${planned.length}`);
  console.log("");

  if (APPLY) {
    console.log("---- credentials ----");
    console.log(`  demo (paste into App Store Connect → App Review → Demo Account):`);
    console.log(`    email:    ${DEMO_EMAIL}`);
    if (demoCreated) {
      console.log(`    password: ${DEMO_PASSWORD}`);
    } else {
      console.log(`    password: <unchanged — account existed before this run, password was NOT reset>`);
      console.log(`              if you don't have it, use Firebase console → Auth → reset.`);
    }
    console.log(`    handle:   ${DEMO_HANDLE}`);
    console.log(`    uid:      ${demoUid}`);

    for (const c of buddyCreds) {
      console.log("");
      console.log(`  buddy ${c.handle}:`);
      console.log(`    email:    ${c.email}`);
      if (c.created) {
        console.log(`    password: ${c.password}`);
      } else {
        console.log(`    password: <unchanged — account existed before this run, password was NOT reset>`);
      }
      console.log(`    uid:      ${c.uid}`);
    }

    console.log("");
    console.log("Save these to 1Password now — newly-minted passwords are shown ONCE.");
  } else {
    console.log("Dry run complete. Re-run with --apply to commit.");
  }

  process.exit(0);
})().catch((err) => {
  console.error("seedAppStoreDemo failed:", err);
  process.exit(1);
});
