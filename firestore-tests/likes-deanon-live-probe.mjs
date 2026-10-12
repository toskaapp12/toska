// LIVE STAGING probe — deployed like-read rules (de-anon fix 18be8bf).
// Staging ruleset (2026-10-03 release) is byte-identical to prod's
// (2026-09-29 release) and to local HEAD, verified via firebaserules API —
// so this staging client-level probe is evidence for prod behavior.
//
// Proves, as a REAL signed-in client:
//   1. list on posts/{id}/likes          → PERMISSION_DENIED  (enumeration dead)
//   2. list on .../replies/{r}/likes     → PERMISSION_DENIED  (reply-liker enumeration dead)
//   3. get OWN like doc (exists)         → ALLOWED            (unlike/dedup path intact)
//   4. get own like doc (nonexistent)    → ALLOWED, !exists   (like-transaction pre-read intact)
//   5. get ANOTHER user's like doc       → PERMISSION_DENIED  (targeted probe dead)
//   6. build-91 shape: unfiltered limit(500) list → DENIED even by the post author
// Self-cleaning.
import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword } from "firebase/auth";
import {
  getFirestore, doc, getDoc, getDocs, collection, query, limit,
} from "firebase/firestore";

const PROJECT_ID = "toskastaging";
const KEY = process.env.TOSKA_STAGING_WEB_API_KEY;
const APP = process.env.TOSKA_STAGING_APP_ID;
const SND = process.env.TOSKA_STAGING_SENDER_ID;
const EMAIL = process.env.TOSKA_STAGING_EMAIL;
const PW = process.env.TOSKA_STAGING_PW;
if (!KEY || !APP || !SND || !EMAIL || !PW) { console.error("missing env"); process.exit(1); }

admin.initializeApp({ projectId: PROJECT_ID });
const adminDb = admin.firestore();

const webApp = initializeApp({
  apiKey: KEY, authDomain: `${PROJECT_ID}.firebaseapp.com`,
  projectId: PROJECT_ID, appId: APP, messagingSenderId: SND,
});
const webAuth = getAuth(webApp);
const webDb = getFirestore(webApp);

const stamp = Date.now();
const postId = `probe_likerules_${stamp}`;
let failures = 0;
const ok = (m) => console.log(`✓ ${m}`);
const bad = (m) => { failures++; console.error(`✗ ${m}`); };

const expectDenied = async (name, fn) => {
  try { await fn(); bad(`${name}: ALLOWED (expected permission-denied)`); }
  catch (e) {
    if (e.code === "permission-denied") ok(`${name}: denied`);
    else bad(`${name}: unexpected error ${e.code}: ${e.message}`);
  }
};

try {
  const cred = await signInWithEmailAndPassword(webAuth, EMAIL, PW);
  const myUid = cred.user.uid;
  ok(`signed in as staging test user (${myUid.slice(0, 6)}…)`);

  // Seed via Admin SDK: a LIVE post authored by the test user, with the
  // test user's own like + a stranger's like, and a reply with a stranger like.
  const postRef = adminDb.collection("posts").doc(postId);
  await postRef.set({
    authorId: myUid, authorHandle: "probe_handle", text: "probe like rules",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    moderationStatus: "live", isShareable: false,
    likeCount: 2, replyCount: 1, repostCount: 0,
  });
  await postRef.collection("likes").doc(myUid).set({ createdAt: admin.firestore.FieldValue.serverTimestamp() });
  await postRef.collection("likes").doc(`stranger_${stamp}`).set({ createdAt: admin.firestore.FieldValue.serverTimestamp() });
  await postRef.collection("replies").doc("probe_reply").set({
    authorId: `stranger_${stamp}`, authorHandle: "stranger", text: "probe reply",
    createdAt: admin.firestore.FieldValue.serverTimestamp(), moderationStatus: "live", likeCount: 1,
  });
  await postRef.collection("replies").doc("probe_reply").collection("likes").doc(`stranger_${stamp}`)
    .set({ createdAt: admin.firestore.FieldValue.serverTimestamp() });
  ok("seeded live post + likes via Admin SDK");

  // 1. enumeration of post likes
  await expectDenied("list posts/{id}/likes", () =>
    getDocs(collection(webDb, "posts", postId, "likes")));
  // 6. exact build-91 delete-path query shape, by the POST AUTHOR
  await expectDenied("build-91 author limit(500) list", () =>
    getDocs(query(collection(webDb, "posts", postId, "likes"), limit(500))));
  // 2. enumeration of reply likes
  await expectDenied("list replies/{r}/likes", () =>
    getDocs(collection(webDb, "posts", postId, "replies", "probe_reply", "likes")));
  // 5. targeted stranger like-doc get
  await expectDenied("get stranger's like doc", () =>
    getDoc(doc(webDb, "posts", postId, "likes", `stranger_${stamp}`)));

  // 3. own like doc get (exists)
  try {
    const s = await getDoc(doc(webDb, "posts", postId, "likes", myUid));
    s.exists() ? ok("get OWN like doc: allowed, exists") : bad("own like doc get returned !exists");
  } catch (e) { bad(`own like doc get denied: ${e.code}`); }

  // 4. own like doc get on a post we did NOT like (nonexistent own doc)
  try {
    const s = await getDoc(doc(webDb, "posts", postId, "replies", "probe_reply", "likes", myUid));
    !s.exists() ? ok("get own NONEXISTENT reply-like doc: allowed, !exists (transaction pre-read intact)")
                : bad("nonexistent own reply-like doc reported exists");
  } catch (e) { bad(`own nonexistent reply-like get denied: ${e.code} (would break like transaction)`); }
} catch (e) {
  bad(`probe error: ${e.message}`);
} finally {
  try {
    const postRef = adminDb.collection("posts").doc(postId);
    for (const col of [
      postRef.collection("replies").doc("probe_reply").collection("likes"),
      postRef.collection("replies"), postRef.collection("likes"),
    ]) {
      const snap = await col.get();
      for (const d of snap.docs) await d.ref.delete();
    }
    await postRef.delete();
  } catch (e) { console.error("cleanup error:", e.message); }
  console.log(failures ? "RESULT: FAIL" : "RESULT: PASS");
  process.exit(failures ? 1 : 0);
}
