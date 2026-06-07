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
//
// Slot conventions (referenced as authorIdx / fromIdx through the file):
//   0: soft_evening_42 — main interlocutor, sends DMs + replies
//   1: late_oak_88     — "a year out" voice, mostly posts wisdom
//   2: quiet_dawn_03   — exists to populate the demo's blocked-users list
//                        (so testing the Blocked Users settings page has
//                        a non-empty state). Demo blocks this user, so
//                        their content is filtered from demo's feed.
//   3: still_water_77  — follows demo (extra row in the followers list)
//   4: morning_glow_28 — demo follows them (extra row in the following list)
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
  {
    email: "appreview_buddy_quiet@toskaapp.com",
    handle: "quiet_dawn_03",
    breakupStage: "it just happened",
  },
  {
    email: "appreview_buddy_still@toskaapp.com",
    handle: "still_water_77",
    breakupStage: "months in",
  },
  {
    email: "appreview_buddy_morning@toskaapp.com",
    handle: "morning_glow_28",
    breakupStage: "they left",
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
    replyCount: 0,
    repostCount: 0,
  },
  {
    id: "demo_post_2",
    text: "i forgot how to be the version of me that existed before them. starting over from scratch is also kind of freeing.",
    tag: "rebuilding",
    likeCount: 12,
    replyCount: 1,
    repostCount: 0,
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
  // ---- variant posts: exercise the special-state rendering paths ----
  // Letter post — isLetter: true → renders with collapsed "letter"
  // preview + "read this letter..." link in FeedPostRow.
  {
    authorIdx: 0, // soft_evening_42
    id: "demo_buddy_letter_1",
    text: "dear future me,\n\nyou felt this — all of it. the ceiling stares at 3am, the songs that suddenly meant something, the silence in the passenger seat. you survived it. so when you read this and you're scared you'll never feel anything that big again — you will. you always do. it just doesn't always have to hurt.\n\nlove, you",
    tag: "longing",
    likeCount: 64,
    replyCount: 0,
    repostCount: 11,
    isLetter: true,
  },
  // Whisper post — isWhisper: true → renders with eye.slash icon in
  // the handle row (visual marker for ephemeral/quieter posts).
  {
    authorIdx: 1, // late_oak_88
    id: "demo_buddy_whisper_1",
    text: "i don't think they ever loved me back. and i'm just now letting that be okay.",
    tag: "acceptance",
    likeCount: 28,
    replyCount: 0,
    repostCount: 3,
    isWhisper: true,
  },
  // Midnight post — createdAt placed at ~2am yesterday so the
  // late-night moon-icon rendering picks it up.
  {
    authorIdx: 1, // late_oak_88
    id: "demo_buddy_midnight_1",
    text: "the 2am thoughts are just regular thoughts wearing a different shirt.",
    tag: "longing",
    likeCount: 91,
    replyCount: 0,
    repostCount: 12,
    createdAt: (() => { const d = new Date(); d.setDate(d.getDate() - 1); d.setHours(2, 0, 0, 0); return d; })(),
  },
  // GIF post — gifUrl set so the AsyncImage branch in FeedPostRow
  // renders the GIF inline. Uses a known stable Giphy URL; if the URL
  // ever 404s the row falls back to the "couldn't load gif" state
  // (also a valid path to demonstrate).
  {
    authorIdx: 0, // soft_evening_42
    id: "demo_buddy_gif_1",
    text: "this is exactly how it feels at 4pm on a tuesday",
    tag: "lonely",
    likeCount: 19,
    replyCount: 0,
    repostCount: 2,
    gifUrl: "https://media.giphy.com/media/3o7TKtnuHOHHUjR38Y/giphy.gif",
  },
];

// Sample notifications for the demo's inbox. Apple's reviewer opens the
// notifications tab and currently sees an empty state — these populate
// it with the kinds of events a normal user would have a few days in.
// fromIdx: 0 = soft_evening_42, 1 = late_oak_88, -1 = no actor (system /
// milestone). minutesAgo controls the createdAt offset so the inbox has
// a natural recency ordering. Notification ids are deterministic so re-
// running the seeder is idempotent.
const SAMPLE_NOTIFICATIONS = [
  // Recent activity at the top of the inbox.
  { id: "n_like_p1_soft", type: "like", fromIdx: 0, postId: "demo_post_1", isRead: false, minutesAgo: 35 },
  { id: "n_reply_p2_soft", type: "reply", fromIdx: 0, postId: "demo_post_2", isRead: false, minutesAgo: 90,
    message: "this. the version of you that comes back is different but real." },
  { id: "n_like_p2_late", type: "like", fromIdx: 1, postId: "demo_post_2", isRead: false, minutesAgo: 180 },
  { id: "n_follow_soft", type: "follow", fromIdx: 0, postId: "", isRead: false, minutesAgo: 240 },
  // Older + read — populate the "earlier" section of the inbox.
  { id: "n_save_p2_late", type: "save", fromIdx: 1, postId: "demo_post_2", isRead: true, minutesAgo: 600 },
  { id: "n_repost_p3_soft", type: "repost", fromIdx: 0, postId: "demo_post_3", isRead: true, minutesAgo: 900 },
  { id: "n_milestone_p2", type: "milestone", fromIdx: -1, postId: "demo_post_2", isRead: true, minutesAgo: 1320,
    message: "your post reached 10 felts" },
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

// Post writer — supports the optional flag fields the iOS feed row
// branches on (isLetter, isWhisper, gifUrl) and a custom createdAt so
// the seeded "midnight" post can be placed at a real late-night
// timestamp for the moon-icon rendering check. Falls back to server
// timestamp when no createdAt is provided so the existing post seeds
// don't change shape.
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
    createdAt: post.createdAt ? "<custom-timestamp>" : "<server-timestamp>",
  };
  if (post.isLetter) payload.isLetter = true;
  if (post.isWhisper) payload.isWhisper = true;
  if (post.gifUrl) payload.gifUrl = post.gifUrl;
  if (post.isShareable !== undefined) payload.isShareable = post.isShareable;
  plan("set", path, payload);
  if (!APPLY) return;
  const docData = {
    authorId: authorUid,
    authorHandle,
    text: post.text,
    tag: post.tag,
    likeCount: post.likeCount,
    replyCount: post.replyCount,
    repostCount: post.repostCount,
    createdAt: post.createdAt
      ? Timestamp.fromDate(post.createdAt)
      : FieldValue.serverTimestamp(),
  };
  if (post.isLetter) docData.isLetter = true;
  if (post.isWhisper) docData.isWhisper = true;
  if (post.gifUrl) docData.gifUrl = post.gifUrl;
  if (post.isShareable !== undefined) docData.isShareable = post.isShareable;
  await db.doc(path).set(docData);
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

// Writes a notification doc under the demo's inbox so the App Store
// reviewer sees a populated notifications tab on first open. Uses
// Admin SDK, so the rule's schema lockdown (which excludes the
// `message` field for client writes) doesn't apply — we can include
// the reply preview and milestone copy that the in-app renderer
// uses. `minutesAgo` becomes the createdAt offset so the inbox has
// a believable time ordering.
async function setNotification(recipientUid, notifId, type, fromUid, fromHandle, postId, isRead, minutesAgo, message) {
  const path = `users/${recipientUid}/notifications/${notifId}`;
  const data = {
    type,
    fromHandle,
    fromUserId: fromUid,
    postId: postId || "",
    isRead,
    createdAt: Timestamp.fromDate(new Date(Date.now() - minutesAgo * 60 * 1000)),
  };
  if (message) data.message = message;
  plan("set", path, { type, from: fromHandle, postId, isRead, minutesAgo });
  if (!APPLY) return;
  await db.doc(path).set(data);
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

// Generalized counter setter — once the additional follow-graph entries
// land (demo follows 3 buddies, 3 buddies follow demo), the per-user
// counts need to reflect the final graph. Use this AFTER all follow
// writes so the trigger-driven counter math doesn't get out of sync
// (Cloud Function increments would compound on top of the seed value
// only on the *first* run for newly-created docs; on re-runs, the
// triggers no-op since the follow docs already exist).
async function setFollowCounts(uid, { followerCount, followingCount }) {
  const payload = {};
  if (followerCount !== undefined) payload.followerCount = followerCount;
  if (followingCount !== undefined) payload.followingCount = followingCount;
  plan("update", `users/${uid}`, payload);
  if (!APPLY) return;
  await db.doc(`users/${uid}`).update(payload);
}

// Demo's own saved posts. Doc id is the postId; iOS reads the saved
// doc set just for IDs (createdAt drives ordering) and resolves text/
// handle/counts by fetching the actual post doc. Per firestore.rules
// the schema is open so any extra fields are tolerated.
async function setSavedPost(uid, postId, minutesAgo = 60) {
  const path = `users/${uid}/saved/${postId}`;
  plan("set", path, { createdAt: `<${minutesAgo}m ago>` });
  if (!APPLY) return;
  await db.doc(path).set({
    createdAt: Timestamp.fromDate(new Date(Date.now() - minutesAgo * 60 * 1000)),
  });
}

// Demo's own liked posts. Two-step: write the actual like doc (so the
// post's likeCount counter trigger fires, matching organic behavior)
// AND the reverse-index entry at users/{uid}/liked/{postId} that the
// Profile "liked" tab queries.
async function setLikedPost(uid, postId, minutesAgo = 60) {
  await setLike(postId, uid);
  const path = `users/${uid}/liked/${postId}`;
  plan("set", path, { createdAt: `<${minutesAgo}m ago>` });
  if (!APPLY) return;
  await db.doc(path).set({
    createdAt: Timestamp.fromDate(new Date(Date.now() - minutesAgo * 60 * 1000)),
  });
}

// Demo's own repost. Creates a top-level post doc with isRepost: true
// pointing at the original. Deterministic id matches the iOS write
// shape (PostInteractionManager.repost) — `{reposterUid}_repost_
// {originalPostId}` — so the FeedViewModel.fetchRepostedPostIds
// listener picks it up via the (authorId, isRepost) composite index.
// validatePost will accept the doc because text/originalPostId/
// originalAuthorId match the original.
async function setRepost(reposterUid, reposterHandle, original, originalAuthorUid, originalAuthorHandle, minutesAgo = 30) {
  const id = `${reposterUid}_repost_${original.id}`;
  const path = `posts/${id}`;
  const payload = {
    authorId: reposterUid,
    authorHandle: reposterHandle,
    text: original.text,
    tag: original.tag,
    likeCount: 0,
    repostCount: 0,
    replyCount: 0,
    isShareable: true,
    isRepost: true,
    originalPostId: original.id,
    originalAuthorId: originalAuthorUid,
    originalHandle: originalAuthorHandle,
    createdAt: `<${minutesAgo}m ago>`,
  };
  plan("set", path, payload);
  if (!APPLY) return;
  await db.doc(path).set({
    authorId: reposterUid,
    authorHandle: reposterHandle,
    text: original.text,
    tag: original.tag,
    likeCount: 0,
    repostCount: 0,
    replyCount: 0,
    isShareable: true,
    isRepost: true,
    originalPostId: original.id,
    originalAuthorId: originalAuthorUid,
    originalHandle: originalAuthorHandle,
    createdAt: Timestamp.fromDate(new Date(Date.now() - minutesAgo * 60 * 1000)),
  });
}

// Demo's drafts. Schema per firestore.rules:488 — text + createdAt
// (required) + optional updatedAt. Doc id is arbitrary; iOS lists by
// createdAt desc.
async function setDraft(uid, draftId, text, minutesAgo = 120) {
  const path = `users/${uid}/drafts/${draftId}`;
  plan("set", path, { text: text.slice(0, 40) + "...", createdAt: `<${minutesAgo}m ago>` });
  if (!APPLY) return;
  await db.doc(path).set({
    text,
    createdAt: Timestamp.fromDate(new Date(Date.now() - minutesAgo * 60 * 1000)),
  });
}

// Demo's saved replies. Doc id is the replyId; the doc carries a
// save-time snapshot of {postId, replyText, replyHandle, createdAt}
// per ProfileView.loadSavedReplies, so the row renders without a
// per-reply lookup.
async function setSavedReply(uid, replyId, postId, replyText, replyHandle, minutesAgo = 90) {
  const path = `users/${uid}/savedReplies/${replyId}`;
  plan("set", path, { postId, replyHandle, createdAt: `<${minutesAgo}m ago>` });
  if (!APPLY) return;
  await db.doc(path).set({
    postId,
    replyText,
    replyHandle,
    createdAt: Timestamp.fromDate(new Date(Date.now() - minutesAgo * 60 * 1000)),
  });
}

// Demo's liked replies. Same shape as saved replies. Note: this is
// only the reverse-index entry; the actual like doc at
// posts/{postId}/replies/{replyId}/likes/{uid} also needs to be
// written for the reply's likeCount to bump.
async function setLikedReply(uid, replyId, postId, replyText, replyHandle, minutesAgo = 90) {
  const likePath = `posts/${postId}/replies/${replyId}/likes/${uid}`;
  plan("set", likePath, { createdAt: "<server-timestamp>" });
  const path = `users/${uid}/likedReplies/${replyId}`;
  plan("set", path, { postId, replyHandle, createdAt: `<${minutesAgo}m ago>` });
  if (!APPLY) return;
  await db.doc(likePath).set({ createdAt: FieldValue.serverTimestamp() });
  await db.doc(path).set({
    postId,
    replyText,
    replyHandle,
    createdAt: Timestamp.fromDate(new Date(Date.now() - minutesAgo * 60 * 1000)),
  });
}

// Demo's blocked-users list — populates the Settings → Blocked Users
// page. Per BlockedUsersListView, the doc carries handle + blockedAt;
// doc id is the blocked user's uid (also referenced by
// BlockedUsersCache to filter content).
async function setBlocked(blockerUid, blockedUid, blockedHandle, minutesAgo = 240) {
  const path = `users/${blockerUid}/blocked/${blockedUid}`;
  plan("set", path, { handle: blockedHandle, blockedAt: `<${minutesAgo}m ago>` });
  if (!APPLY) return;
  await db.doc(path).set({
    handle: blockedHandle,
    blockedAt: Timestamp.fromDate(new Date(Date.now() - minutesAgo * 60 * 1000)),
  });
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

  // Seed sample notifications into the demo's inbox so the reviewer's
  // notifications tab opens populated (likes/reply/follow/save/repost/
  // milestone). fromIdx -1 means a system-generated notification (only
  // used for milestone), no fromUserId or fromHandle resolves.
  for (const notif of SAMPLE_NOTIFICATIONS) {
    const fromUid = notif.fromIdx === -1 ? "" : buddyUids[notif.fromIdx];
    const fromHandle = notif.fromIdx === -1 ? "toska" : BUDDIES[notif.fromIdx].handle;
    await setNotification(
      demoUid,
      notif.id,
      notif.type,
      fromUid,
      fromHandle,
      notif.postId,
      notif.isRead,
      notif.minutesAgo,
      notif.message
    );
  }

  // ---------- follow graph ----------
  // Slot conventions (BUDDIES array):
  //   0: soft_evening_42  — mutual with demo (interlocutor)
  //   1: late_oak_88      — demo follows (so following list has 2)
  //   2: quiet_dawn_03    — blocked by demo (no follow either way)
  //   3: still_water_77   — follows demo (so followers list has 2)
  //   4: morning_glow_28  — demo follows them too (so following has 3)
  const lateUid    = buddyUids[1];
  const quietUid   = buddyUids[2];
  const stillUid   = buddyUids[3];
  const morningUid = buddyUids[4];

  // Demo follows soft, late, morning. Total following = 3.
  await setFollow(demoUid, softUid);
  await setFollow(demoUid, lateUid);
  await setFollow(demoUid, morningUid);
  // Soft + still follow demo. Total followers = 2.
  await setFollow(softUid, demoUid);
  await setFollow(stillUid, demoUid);

  // Counter writes — set to the final graph state directly. On a first
  // run the follow-trigger increments would land too, but on re-runs
  // (the common case once the seed has been applied once) the triggers
  // no-op since the follow docs already exist. Setting the final state
  // explicitly here keeps both paths converging on the same values.
  await setFollowCounts(demoUid,    { followerCount: 2, followingCount: 3 });
  await setFollowCounts(softUid,    { followerCount: 1, followingCount: 1 });
  await setFollowCounts(lateUid,    { followerCount: 1, followingCount: 0 });
  await setFollowCounts(morningUid, { followerCount: 1, followingCount: 0 });
  await setFollowCounts(stillUid,   { followerCount: 0, followingCount: 1 });

  // ---------- demo's engagement state ----------
  // Saved posts — demo saved two buddy posts so the Profile "saved"
  // tab has content to render.
  await setSavedPost(demoUid, "demo_buddy_late_post_1", 30);
  await setSavedPost(demoUid, "demo_buddy_letter_1",    180);

  // Liked posts — demo liked two buddy posts (writes the actual like
  // doc on each so the post's likeCount trigger fires).
  await setLikedPost(demoUid, "demo_buddy_soft_post_1", 45);
  await setLikedPost(demoUid, "demo_buddy_midnight_1",  20);

  // Demo's repost — reposts soft's first post. Picks up in the feed
  // with the "@appreview_demo reposted" provenance row (since FeedView
  // now passes originalHandle to FeedPostRow).
  const softFirstPost = BUDDY_POSTS.find(p => p.id === "demo_buddy_soft_post_1");
  await setRepost(demoUid, DEMO_HANDLE, softFirstPost, softUid, BUDDIES[0].handle, 60);

  // Drafts — two saved drafts so the Drafts list isn't empty when the
  // user taps Settings → Drafts.
  await setDraft(demoUid, "draft_1",
    "i keep thinking about the last thing i didn't say. maybe i should write it here.",
    180);
  await setDraft(demoUid, "draft_2",
    "today felt different. not better. just different. i want to remember that.",
    420);

  // Saved + liked replies — demo saved and liked one of soft's replies
  // from the seeded reply set. Picks up in the Profile saved/liked
  // tabs via ReplyEngagementRow.
  await setSavedReply(demoUid,
    "demo_buddy_late_post_1_reply_3",  // a soft reply on late_oak's anniversary post
    "demo_buddy_late_post_1",
    "the unimaginable-in-month-one part is what i needed.",
    "soft_evening_42",
    120);
  await setLikedReply(demoUid,
    "demo_buddy_soft_post_1_reply_2",
    "demo_buddy_soft_post_1",
    "yeah. and the days you forget you're carrying it at all count too.",
    "late_oak_88",
    240);

  // Blocked — demo blocks quiet_dawn_03 so the Settings → Blocked Users
  // page has a row to look at. quiet has no posts in the seed so the
  // block doesn't visibly remove any feed content (avoids surprising
  // the reviewer when posts vanish).
  await setBlocked(demoUid, quietUid, BUDDIES[2].handle, 480);

  // DMs were cut (2026-06-03). No conversation is seeded for the demo account;
  // the conversations/messages collections are denied in firestore.rules.

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
