// onAllowSharingChanged probe — verifies sharing-consent revocation is
// RETROACTIVE (the privacy policy promises it): toggling users/{uid}
// .allowSharing backfills isShareable across the user's original posts
// (letters/whispers stay unshareable) and reposts of their posts.
// Run under the emulator (functions REQUIRED for the trigger):
//   PATH=/opt/homebrew/opt/openjdk@21/bin:$PATH firebase emulators:exec \
//     --only firestore,functions 'node firestore-tests/consent-backfill-probe.mjs' -P staging
import admin from "firebase-admin";
admin.initializeApp({ projectId: "toskastaging" });
const db = admin.firestore();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const u = "consent_u", get = async (id) => (await db.doc("posts/" + id).get()).data()?.isShareable;
const FV = admin.firestore.FieldValue;
// Full post shape — the emulator's moderation/audit triggers remove
// skeletal docs, so mirror what the app actually writes.
const base = { createdAt: FV.serverTimestamp(), moderationStatus: "live", likeCount: 0, replyCount: 0, repostCount: 0, text: "the quiet stays but so do i, somehow." };
await db.doc("users/" + u).set({ handle: "consent_h", allowSharing: true, followerCount: 0, followingCount: 0, totalLikes: 0, postCount: 2, confirmedAdult: true, createdAt: FV.serverTimestamp() });
await db.doc("posts/consent_p1").set({ ...base, authorId: u, authorHandle: "consent_h", isRepost: false, isShareable: true });
await db.doc("posts/consent_p2").set({ ...base, authorId: u, authorHandle: "consent_h", isRepost: false, isShareable: false, isLetter: true });
await db.doc("posts/consent_r1").set({ ...base, authorId: "consent_other", authorHandle: "other_h", isRepost: true, isShareable: true, originalAuthorId: u, originalPostId: "consent_p1", originalHandle: "consent_h" });
await sleep(2500); // let create-triggers settle before flipping the setting

await db.doc("users/" + u).update({ allowSharing: false });
await sleep(4000);
const offP1 = await get("consent_p1"), offR1 = await get("consent_r1");
console.log("after OFF: post=", offP1, "repost=", offR1);

await db.doc("users/" + u).update({ allowSharing: true });
await sleep(4000);
const onP1 = await get("consent_p1"), onP2 = await get("consent_p2"), onR1 = await get("consent_r1");
console.log("after ON: post=", onP1, "letter(stays off)=", onP2, "repost=", onR1);

const pass = offP1 === false && offR1 === false && onP1 === true && onP2 === false && onR1 === true;
console.log(pass ? "✓ CONSENT-BACKFILL PASS" : "✗ CONSENT-BACKFILL FAIL");
process.exit(pass ? 0 : 1);
