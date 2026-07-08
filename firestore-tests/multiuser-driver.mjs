// Driver for the 5-simulator multi-user session (2026-06-11).
// While 5 real app instances (multi_user_1..5) sit on posts/multiuser_target_post,
// this signs in as the SAME five accounts via the web SDK and interacts:
//   • users 2-5 like the post (staggered)        → on-screen count must tick to 4
//   • all 5 post one clean reply each (staggered) → replies must appear live on every sim
//   • user 3 posts a PII reply                    → must be HELD; never visible on any sim
// Run after the sims are holding; screenshots are taken by the orchestrator.

import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword, connectAuthEmulator } from "firebase/auth";
import { getFirestore, doc, setDoc, serverTimestamp, connectFirestoreEmulator } from "firebase/firestore";

const PROJECT_ID = "toskastaging";
const POST_ID = "multiuser_target_post";
const WEB_API_KEY = process.env.TOSKA_STAGING_WEB_API_KEY;
const WEB_APP_ID = process.env.TOSKA_STAGING_APP_ID;
const WEB_SENDER_ID = process.env.TOSKA_STAGING_SENDER_ID;
if (!WEB_API_KEY || !WEB_APP_ID || !WEB_SENDER_ID) { console.error("missing staging web env vars"); process.exit(1); }

admin.initializeApp({ projectId: PROJECT_ID });
const adminDb = admin.firestore();

const REPLIES = [
  "user one, checking in",
  "user two — still awake too",
  "user three, you are not alone tonight",
  "user four sending something quiet",
  "user five, here with all of you",
];

const sessions = [];
for (let i = 1; i <= 5; i++) {
  const app = initializeApp({
    apiKey: WEB_API_KEY, authDomain: `${PROJECT_ID}.firebaseapp.com`,
    projectId: PROJECT_ID, appId: WEB_APP_ID, messagingSenderId: WEB_SENDER_ID,
  }, `drv${i}`);
  const auth = getAuth(app), db = getFirestore(app);
  // Web SDK doesn't auto-read emulator env vars (only firebase-admin does) —
  // without these, emulators:exec runs silently hit REAL staging. No-op live.
  if (process.env.FIREBASE_AUTH_EMULATOR_HOST) connectAuthEmulator(auth, `http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}`, { disableWarnings: true });
  if (process.env.FIRESTORE_EMULATOR_HOST) { const [h, p] = process.env.FIRESTORE_EMULATOR_HOST.split(":"); connectFirestoreEmulator(db, h, Number(p)); }
  const cred = await signInWithEmailAndPassword(auth, `toska-multi-${i}@example.com`, `MultiPass!${i}9`);
  sessions.push({ i, uid: cred.user.uid, handle: `multi_user_${i}`, db });
  console.log(`signed in multi_user_${i}`);
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

console.log("\n— likes from users 2-5 (staggered 2s) —");
for (const s of sessions.slice(1)) {
  await setDoc(doc(s.db, `posts/${POST_ID}/likes`, s.uid), { createdAt: serverTimestamp() });
  console.log(`liked by ${s.handle}`);
  await sleep(2000);
}

console.log("\n— one clean reply per user (staggered 3s) —");
for (const s of sessions) {
  await setDoc(doc(s.db, `posts/${POST_ID}/replies`, `multi_r_${s.i}`), {
    authorId: s.uid, authorHandle: s.handle, text: REPLIES[s.i - 1],
    createdAt: serverTimestamp(), likeCount: 0, moderationStatus: "pending_validation",
  });
  console.log(`reply by ${s.handle}`);
  await sleep(3000);
}

console.log("\n— PII reply from user 3 (must be HELD; never visible on any sim) —");
await setDoc(doc(sessions[2].db, `posts/${POST_ID}/replies`, "multi_r_pii"), {
  authorId: sessions[2].uid, authorHandle: sessions[2].handle,
  text: "her name is Sarah Johnson and she lives at 123 Main Street",
  createdAt: serverTimestamp(), likeCount: 0, moderationStatus: "pending_validation",
});

console.log("\nwaiting 20s for triggers to settle…");
await sleep(20000);

const post = await adminDb.doc(`posts/${POST_ID}`).get();
const replies = await adminDb.collection(`posts/${POST_ID}/replies`).get();
const live = replies.docs.filter(d => d.get("moderationStatus") === "live").map(d => d.id).sort();
const held = replies.docs.filter(d => d.get("moderationStatus") === "pending_review").map(d => d.id);
console.log(`likeCount=${post.get("likeCount")} replyCount=${post.get("replyCount")}`);
console.log(`live replies: ${live.join(", ")}`);
console.log(`held replies: ${held.join(", ")}`);
const ok = post.get("likeCount") === 4 && post.get("replyCount") === 5
  && live.length === 5 && held.includes("multi_r_pii");
console.log(ok ? "DRIVER BACKEND CHECKS: ALL GOOD" : "DRIVER BACKEND CHECKS: MISMATCH");
process.exit(ok ? 0 : 1);
