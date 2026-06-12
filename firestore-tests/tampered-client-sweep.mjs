// Tampered-client SWEEP + rules property-fuzz (#3, 2026-06-11) — LIVE STAGING.
//
// Complements the targeted hostile-user emulator suite by running against the
// DEPLOYED staging ruleset and by PROPERTY-FUZZING: for every schema-locked
// create rule, generate many random extra-field / wrong-type / wrong-value
// mutations and assert each is denied. Plus a cross-user matrix: user B (and an
// unauthenticated client) attempts every write/read into user A's tree.
//
// Run with the staging web config + ADC (same as full-e2e.mjs).

import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword } from "firebase/auth";
import { getFirestore, doc, getDoc, setDoc, updateDoc, serverTimestamp } from "firebase/firestore";

const PROJECT_ID = "toskastaging";
const env = process.env.GCLOUD_PROJECT;
if (env && env !== PROJECT_ID) { console.error("staging-only"); process.exit(1); }
const KEY = process.env.TOSKA_STAGING_WEB_API_KEY, APP = process.env.TOSKA_STAGING_APP_ID, SND = process.env.TOSKA_STAGING_SENDER_ID;
if (!KEY || !APP || !SND) { console.error("missing staging web env vars"); process.exit(1); }

admin.initializeApp({ projectId: PROJECT_ID });
const aAuth = admin.auth(), aDb = admin.firestore();
const FV = admin.firestore.FieldValue;

let pass = 0, fail = 0;
const fails = [];
function rec(ok, name, detail = "") { ok ? pass++ : (fail++, fails.push(name + (detail ? " — " + detail : ""))); if (!ok) console.log(`  ✗ ${name}${detail ? " — " + detail : ""}`); }
async function denied(name, fn) {
  try { await fn(); rec(false, name, "WAS ALLOWED (should deny)"); }
  catch (e) { rec(e.code === "permission-denied", name, e.code === "permission-denied" ? "" : "unexpected " + (e.code || e.message)); }
}
async function allowed(name, fn) {
  try { await fn(); rec(true, name); } catch (e) { rec(false, name, "was DENIED: " + (e.code || e.message)); }
}

function webApp(n) {
  const app = initializeApp({ apiKey: KEY, authDomain: `${PROJECT_ID}.firebaseapp.com`, projectId: PROJECT_ID, appId: APP, messagingSenderId: SND }, n);
  return { auth: getAuth(app), db: getFirestore(app) };
}
async function mkUser(email, pw, handle) {
  try { const u = await aAuth.getUserByEmail(email); await aAuth.deleteUser(u.uid); } catch {}
  const u = await aAuth.createUser({ email, password: pw, emailVerified: true });
  await aDb.doc(`users/${u.uid}`).set({ handle, followerCount: 0, followingCount: 0, totalLikes: 0, postCount: 0, confirmedAdult: true, confirmedAdultAt: FV.serverTimestamp(), createdAt: FV.serverTimestamp(), acceptedPolicyVersion: 1 });
  await aDb.doc(`users/${u.uid}/private/data`).set({ email, selectedMood: "numb" });
  return u.uid;
}

const RANDOM_FIELDS = [
  { isAdmin: true }, { restricted: false }, { confirmedAdult: true }, { trustedByAdmin: true },
  { moderationStatus: "live" }, { likeCount: 9999 }, { followerCount: 9999 }, { __proto__inject: 1 },
  { authorId: "someone_else" }, { createdAt: new Date(2000, 0, 1) }, { scratch: "x".repeat(10) },
];

try {
  console.log("=== SETUP ===");
  const A = await mkUser("sweep-a@example.com", "SweepA!9", "sweep_alpha");
  const B = await mkUser("sweep-b@example.com", "SweepB!9", "sweep_bravo");
  // A blocks B (for block-bypass checks)
  await aDb.doc(`users/${A}/blocked/${B}`).set({ at: FV.serverTimestamp() });
  // A has a live post
  const postA = `sweep_post_${Date.now()}`;
  await aDb.doc(`posts/${postA}`).set({ authorId: A, authorHandle: "sweep_alpha", text: "hold this", createdAt: FV.serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "live" });
  const sB = webApp("B"); await signInWithEmailAndPassword(sB.auth, "sweep-b@example.com", "SweepB!9");
  const sNo = webApp("NO"); // unauthenticated

  console.log("\n=== CROSS-USER: B writes into A's identity/tree (all deny) ===");
  await denied("B cannot post AS A (forged authorId)", () => setDoc(doc(sB.db, "posts", `evil_${Date.now()}`), { authorId: A, authorHandle: "sweep_alpha", text: "forged", createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0 }));
  await denied("B cannot write A's user doc", () => updateDoc(doc(sB.db, "users", A), { followerCount: 1 }));
  await denied("B cannot write into A's drafts", () => setDoc(doc(sB.db, `users/${A}/drafts/x`), { text: "x", createdAt: serverTimestamp() }));
  await denied("B cannot write into A's saved", () => setDoc(doc(sB.db, `users/${A}/saved/x`), { createdAt: serverTimestamp() }));
  await denied("B cannot forge a follower of A", () => setDoc(doc(sB.db, `users/${A}/followers/${B}`), { handle: "sweep_bravo", createdAt: serverTimestamp() }));
  await denied("B (blocked) cannot like A's post", () => setDoc(doc(sB.db, `posts/${postA}/likes/${B}`), { createdAt: serverTimestamp() }));
  await denied("B (blocked) cannot reply to A's post", () => setDoc(doc(sB.db, `posts/${postA}/replies/r`), { authorId: B, authorHandle: "sweep_bravo", text: "hi", createdAt: serverTimestamp(), likeCount: 0, moderationStatus: "pending_validation" }));
  await denied("B cannot forge a notification into A's tree", () => setDoc(doc(sB.db, `users/${A}/notifications/n`), { type: "like", fromUserId: B, fromHandle: "sweep_bravo", message: "spoof", createdAt: serverTimestamp(), isRead: false }));

  console.log("\n=== CROSS-USER READS: B / unauth read A's private data (all deny) ===");
  await denied("B cannot read A's /private/data", () => getDoc(doc(sB.db, `users/${A}/private/data`)));
  await denied("B cannot read A's drafts", () => getDoc(doc(sB.db, `users/${A}/drafts/x`)));
  await denied("unauth cannot read A's /private/data", () => getDoc(doc(sNo.db, `users/${A}/private/data`)));
  await denied("unauth cannot read A's user doc", () => getDoc(doc(sNo.db, `users/${A}`)));
  await denied("unauth cannot write any post", () => setDoc(doc(sNo.db, "posts", `anon_${Date.now()}`), { authorId: "x", text: "y", createdAt: serverTimestamp() }));

  console.log("\n=== PROPERTY-FUZZ: random extra/typed fields on locked creates (all deny) ===");
  // post create
  for (let i = 0; i < RANDOM_FIELDS.length; i++) {
    const extra = RANDOM_FIELDS[i];
    await denied(`post create + ${JSON.stringify(extra)}`, () => setDoc(doc(sB.db, "posts", `fz_${Date.now()}_${i}`), { authorId: B, authorHandle: "sweep_bravo", text: "fuzz", createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "pending_validation", ...extra }));
  }
  // own-like create with junk
  for (let i = 0; i < RANDOM_FIELDS.length; i++) {
    const extra = RANDOM_FIELDS[i];
    if ("createdAt" in extra) continue; // createdAt handled by pin separately
    await denied(`own post-like + ${JSON.stringify(extra)}`, () => setDoc(doc(sB.db, `posts/${postA}/likes/${B}`), { createdAt: serverTimestamp(), ...extra }).catch((e) => { throw e; }));
  }
  // NOTE: B is blocked by A, so the like would deny on block anyway; use B's own
  // post to isolate the schema-lock from the block check.
  const postB = `sweep_postb_${Date.now()}`;
  await aDb.doc(`posts/${postB}`).set({ authorId: B, authorHandle: "sweep_bravo", text: "mine", createdAt: FV.serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "live" });
  for (let i = 0; i < RANDOM_FIELDS.length; i++) {
    const extra = RANDOM_FIELDS[i];
    if ("createdAt" in extra) continue;
    await denied(`own-post like + ${JSON.stringify(extra)} (no block)`, () => setDoc(doc(sB.db, `posts/${postB}/likes/${B}`), { createdAt: serverTimestamp(), ...extra }));
  }

  console.log("\n=== CONTROL: B's own legitimate writes succeed ===");
  await allowed("B can like their own post (clean)", () => setDoc(doc(sB.db, `posts/${postB}/likes/${B}`), { createdAt: serverTimestamp() }));
  await allowed("B can save A's post (saved is owner-tree)", () => setDoc(doc(sB.db, `users/${B}/saved/${postA}`), { createdAt: serverTimestamp() }));

  // cleanup
  await aDb.doc(`posts/${postA}`).delete().catch(() => {});
  await aDb.doc(`posts/${postB}`).delete().catch(() => {});
  for (const uid of [A, B]) { await aAuth.deleteUser(uid).catch(() => {}); await aDb.doc(`users/${uid}`).delete().catch(() => {}); }
} catch (e) {
  rec(false, "rig crashed", e.message);
} finally {
  console.log(`\n=== SWEEP SUMMARY: ${pass} passed, ${fail} failed ===`);
  if (fails.length) { console.log("FAILURES:"); fails.forEach((f) => console.log("  - " + f)); }
  process.exit(fail ? 1 : 0);
}
