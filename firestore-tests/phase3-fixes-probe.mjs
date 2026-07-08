// Phase-3 fix probe (2026-07-08 audit) — exercises the new trigger behavior:
//   A. moderation hold on an original CASCADES to repost copies (+ release)
//   B. text edit on an original FANS OUT to repost copies
//   C. webFeatured is cleared when a featured post's text is edited
//   D. totalLikes settles when a post doc is deleted before its likes drain
//   E. reply-notification preview: backfilled only after promotion to live,
//      scrubbed when the reply is later held
//   F. validatePost deletes a repost of a whisper (ephemeral) original
//   G. consent re-enable leaves reposts-of-letters unshareable
// Run under the emulator (functions REQUIRED):
//   PATH=/opt/homebrew/opt/openjdk@21/bin:$PATH firebase emulators:exec \
//     --only firestore,auth,functions 'node firestore-tests/phase3-fixes-probe.mjs' -P staging
import admin from "firebase-admin";
admin.initializeApp({ projectId: "toskastaging" });
const db = admin.firestore();
const FV = admin.firestore.FieldValue;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const post = (id) => db.doc("posts/" + id);
const data = async (ref) => (await ref.get()).data();

let failures = 0;
const check = (label, cond, detail) => {
  console.log((cond ? "  ✓ " : "  ✗ ") + label + (cond ? "" : `  [${detail}]`));
  if (!cond) failures++;
};

// Full post shape — the emulator's moderation/audit triggers remove skeletal
// docs, so mirror what the app actually writes (see consent-backfill-probe).
const CLEAN = "the quiet stays but so do i, somehow.";
const CLEAN2 = "some mornings the coffee is just coffee again.";
const base = { createdAt: FV.serverTimestamp(), moderationStatus: "live", likeCount: 0, replyCount: 0, repostCount: 0, text: CLEAN };
const mkUser = (uid, handle) => db.doc("users/" + uid).set({
  handle, allowSharing: true, followerCount: 0, followingCount: 0,
  totalLikes: 0, postCount: 1, confirmedAdult: true, createdAt: FV.serverTimestamp(),
});

// Poll until a doc satisfies `pred` (or fail after ~20s). Fixed sleeps are
// not enough here: a cold functions emulator can take >10s on the FIRST
// validatePost invocation, and if that lands after a later probe step (e.g.
// holding the original) validatePost correctly deletes the repost copy —
// a probe-order artifact, not a product bug.
const settle = async (ref, pred, label) => {
  for (let i = 0; i < 40; i++) {
    const d = (await ref.get()).data();
    if (pred(d)) return d;
    await sleep(500);
  }
  console.log(`  ! settle timeout: ${label}`);
  return (await ref.get()).data();
};

// ---------- A + B + C: cascade / fan-out / webFeatured ----------
console.log("A/B/C — hold cascade, edit fan-out, webFeatured clear");
await mkUser("p3_author", "p3_author_h");
await mkUser("p3_reposter", "p3_reposter_h");
// Create at pending_validation (what the real client writes) so the settle
// on "live" PROVES validatePost finished — a doc created "live" would settle
// instantly while validatePost is still in flight.
await post("p3_orig").set({ ...base, moderationStatus: "pending_validation", authorId: "p3_author", authorHandle: "p3_author_h", isRepost: false, isShareable: true, webFeatured: true });
await settle(post("p3_orig"), (d) => d?.moderationStatus === "live", "original validated live");
await post("p3_copy").set({ ...base, moderationStatus: "pending_validation", authorId: "p3_reposter", authorHandle: "p3_reposter_h", isRepost: true, isShareable: true, originalAuthorId: "p3_author", originalPostId: "p3_orig", originalHandle: "p3_author_h" });
await settle(post("p3_copy"), (d) => d?.moderationStatus === "live", "copy validated live");

// hold the original (same write shape setPendingReview/admin approve produce)
await post("p3_orig").update({ moderationStatus: "pending_review", pendingReason: "reported", pendingDetectedAt: FV.serverTimestamp() });
await sleep(3500);
let copy = await data(post("p3_copy"));
check("hold cascades to repost copy", copy?.moderationStatus === "pending_review", `copy status=${copy?.moderationStatus}`);

// release (admin approve shape: status back to live)
await post("p3_orig").update({ moderationStatus: "live" });
await sleep(3500);
copy = await data(post("p3_copy"));
check("release cascades to repost copy", copy?.moderationStatus === "live", `copy status=${copy?.moderationStatus}`);

// edit the original's text — copy text follows, webFeatured clears
await post("p3_orig").update({ text: CLEAN2, editedAt: FV.serverTimestamp() });
await sleep(4500); // fan-out + copy's own re-moderation pass
copy = await data(post("p3_copy"));
const orig = await data(post("p3_orig"));
check("edit fans out to repost copy", copy?.text === CLEAN2, `copy text=${JSON.stringify(copy?.text)}`);
check("copy stays live after clean-edit re-moderation", (copy?.moderationStatus ?? "live") === "live", `status=${copy?.moderationStatus}`);
check("webFeatured cleared on edit", orig?.webFeatured === undefined, `webFeatured=${orig?.webFeatured}`);

// ---------- D: totalLikes settle on direct post delete ----------
console.log("D — totalLikes parity on admin-style direct delete");
await mkUser("p3_liked", "p3_liked_h");
await post("p3_pop").set({ ...base, authorId: "p3_liked", authorHandle: "p3_liked_h", isRepost: false, isShareable: true });
await sleep(2500);
for (const liker of ["p3_l1", "p3_l2", "p3_l3"]) {
  await post("p3_pop").collection("likes").doc(liker).set({ createdAt: FV.serverTimestamp() });
}
await sleep(4000); // like triggers: likeCount + author totalLikes
let likedUser = await data(db.doc("users/p3_liked"));
check("likes settle to totalLikes=3", likedUser?.totalLikes === 3, `totalLikes=${likedUser?.totalLikes}`);
await post("p3_pop").delete(); // admin dashboard path: doc deleted, likes NOT drained first
await sleep(5000); // onPostDeletedAdjustTotalLikes + subtree cleanup
likedUser = await data(db.doc("users/p3_liked"));
check("totalLikes settles to 0 after direct delete", likedUser?.totalLikes === 0, `totalLikes=${likedUser?.totalLikes}`);

// ---------- E: reply-notification preview lifecycle ----------
console.log("E — notif preview: backfill on live, scrub on hold");
await mkUser("p3_op", "p3_op_h");
await mkUser("p3_replier", "p3_replier_h");
await post("p3_thread").set({ ...base, authorId: "p3_op", authorHandle: "p3_op_h", isRepost: false, isShareable: true });
await sleep(2500);
const REPLY_TEXT = "i kept the playlist but i skip our song every time.";
await post("p3_thread").collection("replies").doc("p3_r1").set({
  authorId: "p3_replier", authorHandle: "p3_replier_h", text: REPLY_TEXT,
  createdAt: FV.serverTimestamp(), likeCount: 0, moderationStatus: "pending_validation",
});
await db.doc("users/p3_op/notifications/p3_n1").set({
  type: "reply", fromUserId: "p3_replier", postId: "p3_thread",
  createdAt: FV.serverTimestamp(), read: false,
});
await sleep(5000); // enrich defers (pending_validation) → validateReply promotes → setReplyLive backfills
let notif = await data(db.doc("users/p3_op/notifications/p3_n1"));
check("preview backfilled after promotion", typeof notif?.message === "string" && notif.message.length > 0, `message=${JSON.stringify(notif?.message)}`);

// edit the reply into PII → onReplyUpdated holds it → scrub
await post("p3_thread").collection("replies").doc("p3_r1").update({ text: "call me at 555-123-4567 tonight", editedAt: FV.serverTimestamp() });
await sleep(4500);
const heldReply = await data(post("p3_thread").collection("replies").doc("p3_r1"));
notif = await data(db.doc("users/p3_op/notifications/p3_n1"));
check("PII edit holds the reply", heldReply?.moderationStatus === "pending_review", `status=${heldReply?.moderationStatus}`);
check("hold scrubs the notification preview", notif?.message === undefined, `message=${JSON.stringify(notif?.message)}`);

// ---------- F: validatePost deletes whisper reposts ----------
console.log("F — whisper repost rejected server-side");
await mkUser("p3_whisperer", "p3_whisperer_h");
const expiresAt = admin.firestore.Timestamp.fromMillis(Date.now() + 3600e3);
await post("p3_wh").set({ ...base, authorId: "p3_whisperer", authorHandle: "p3_whisperer_h", isRepost: false, isShareable: false, isWhisper: true, expiresAt });
await sleep(2500);
await post("p3_wh_copy").set({ ...base, authorId: "p3_reposter", authorHandle: "p3_reposter_h", isRepost: true, isShareable: false, originalAuthorId: "p3_whisperer", originalPostId: "p3_wh", moderationStatus: "pending_validation" });
await sleep(4000);
const whCopy = await post("p3_wh_copy").get();
check("whisper repost deleted by validatePost", !whCopy.exists, `exists=${whCopy.exists} status=${whCopy.data()?.moderationStatus}`);

// ---------- G: re-enable leaves reposts-of-letters unshareable ----------
console.log("G — consent re-enable skips reposts of letters");
await mkUser("p3_letters", "p3_letters_h");
await post("p3_letter").set({ ...base, authorId: "p3_letters", authorHandle: "p3_letters_h", isRepost: false, isShareable: false, isLetter: true });
await post("p3_letter_copy").set({ ...base, authorId: "p3_reposter", authorHandle: "p3_reposter_h", isRepost: true, isShareable: false, originalAuthorId: "p3_letters", originalPostId: "p3_letter", originalHandle: "p3_letters_h" });
await sleep(3000);
await db.doc("users/p3_letters").update({ allowSharing: false });
await sleep(4000);
await db.doc("users/p3_letters").update({ allowSharing: true });
await sleep(4000);
const letterCopy = await data(post("p3_letter_copy"));
check("repost-of-letter stays unshareable on re-enable", letterCopy?.isShareable === false, `isShareable=${letterCopy?.isShareable}`);

console.log(failures === 0 ? "✓ PHASE3-FIXES PASS" : `✗ PHASE3-FIXES FAIL (${failures})`);
process.exit(failures === 0 ? 0 : 1);
