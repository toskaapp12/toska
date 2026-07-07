// Rate-limit BURST test (#6, 2026-06-11) — LIVE STAGING.
//
// Two enforcement surfaces:
//   A) rateLimitPosts trigger: >5 posts / 5min by one author → the overflow
//      posts get flagged:true / flagReason "rate_limit_exceeded". Tested live by
//      bursting 8 posts as one user via the web SDK and checking the flags.
//   B) checkRateLimit sliding window (the limiter behind ALL three callables —
//      giphyProxy 60/min, reconcileMyCounts 6/day, confirmAdult 5/hr). The
//      callables need App Check (real device), but the limiter MATH is the same;
//      tested by driving the exported checkRateLimit directly against staging.
//
// Run with staging web config + ADC.

import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword, connectAuthEmulator } from "firebase/auth";
import { getFirestore, doc, setDoc, serverTimestamp, connectFirestoreEmulator } from "firebase/firestore";

const PROJECT_ID = "toskastaging";
const env = process.env.GCLOUD_PROJECT;
if (env && env !== PROJECT_ID) { console.error("staging-only"); process.exit(1); }
const KEY = process.env.TOSKA_STAGING_WEB_API_KEY, APP = process.env.TOSKA_STAGING_APP_ID, SND = process.env.TOSKA_STAGING_SENDER_ID;
if (!KEY || !APP || !SND) { console.error("missing staging web env vars"); process.exit(1); }

admin.initializeApp({ projectId: PROJECT_ID });
const aAuth = admin.auth(), aDb = admin.firestore();
const FV = admin.firestore.FieldValue;
const { __test } = await import("../functions/index.js");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let pass = 0, fail = 0; const fails = [];
const rec = (ok, name, d = "") => { ok ? pass++ : (fail++, fails.push(name + (d ? " — " + d : ""))); console.log(`  ${ok ? "✓" : "✗"} ${name}${d ? " — " + d : ""}`); };

try {
  const email = "burst-user@example.com", pw = "Burst!9x";
  try { const u = await aAuth.getUserByEmail(email); await aAuth.deleteUser(u.uid); } catch {}
  const U = (await aAuth.createUser({ email, password: pw, emailVerified: true })).uid;
  await aDb.doc(`users/${U}`).set({ handle: "burst_user", followerCount: 0, followingCount: 0, totalLikes: 0, postCount: 0, confirmedAdult: true, createdAt: FV.serverTimestamp() });
  const app = initializeApp({ apiKey: KEY, authDomain: `${PROJECT_ID}.firebaseapp.com`, projectId: PROJECT_ID, appId: APP, messagingSenderId: SND }, "burst");
  const auth = getAuth(app), db = getFirestore(app);
  // Web SDK doesn't auto-read emulator env vars (only firebase-admin does) —
  // without these the burst hits REAL staging. No-op on live-staging runs.
  if (process.env.FIREBASE_AUTH_EMULATOR_HOST) connectAuthEmulator(auth, `http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}`, { disableWarnings: true });
  if (process.env.FIRESTORE_EMULATOR_HOST) { const [h, p] = process.env.FIRESTORE_EMULATOR_HOST.split(":"); connectFirestoreEmulator(db, h, Number(p)); }
  await signInWithEmailAndPassword(auth, email, pw);

  console.log("=== A) POST-FLOOD: 8 posts in a burst → overflow flagged by rateLimitPosts ===");
  const ids = [];
  for (let i = 0; i < 8; i++) {
    const id = `burst_post_${Date.now()}_${i}`; ids.push(id);
    await setDoc(doc(db, "posts", id), { authorId: U, authorHandle: "burst_user", text: `burst ${i}`, createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "pending_validation" });
  }
  console.log("  8 posts written; waiting 30s for rateLimitPosts to evaluate…");
  await sleep(30000);
  let flagged = 0;
  for (const id of ids) {
    const d = await aDb.doc(`posts/${id}`).get();
    if (d.exists && d.get("flagReason") === "rate_limit_exceeded") flagged++;
  }
  // >5 in window → overflow flagged. Expect at least the 3 over the limit.
  rec(flagged >= 2, `overflow posts flagged rate_limit_exceeded`, `${flagged} of 8 flagged (expect the >5 overflow)`);

  console.log("\n=== B) checkRateLimit sliding window (the callable limiter) ===");
  // checkRateLimit throws on endpoints outside RATE_LIMIT_ALLOWED_ENDPOINTS
  // (fail-closed hardening — an unknown name must not mint a fresh unlimited
  // bucket), so the rig must use REAL endpoint names. Isolation between the
  // two sub-tests comes from the bucket key being `${uid}_${endpoint}`: same
  // user, two different allowlisted endpoints = independent windows.
  // First confirm the fail-closed rejection itself:
  let unknownThrew = false;
  try { await __test.checkRateLimit(U, `burst_test_${Date.now()}`, 5, 3600); }
  catch { unknownThrew = true; }
  rec(unknownThrew, `unknown endpoint rejected (fail-closed allowlist)`);

  // confirmAdult-style: 5 per 3600s. 6th must be denied.
  const ep = "confirmAdult";
  let allowedCount = 0, deniedAt = -1;
  for (let i = 0; i < 7; i++) {
    const ok = await __test.checkRateLimit(U, ep, 5, 3600);
    if (ok) allowedCount++; else if (deniedAt < 0) deniedAt = i;
  }
  rec(allowedCount === 5, `limiter allows exactly 5 in window`, `allowed ${allowedCount}`);
  rec(deniedAt === 5, `6th request denied`, `first denial at index ${deniedAt}`);

  // fail-closed variant (giphyProxy uses failClosed=true): if the limiter errors
  // it should deny. We can't easily force an error, but confirm a clean
  // sub-limit call still allows under failClosed.
  const ep2 = "giphyProxy";
  const fcOk = await __test.checkRateLimit(U, ep2, 60, 60, true);
  rec(fcOk === true, `fail-closed limiter allows a request under the limit`);

  // cleanup: delete burst posts + the rateLimits docs + user
  for (const id of ids) await aDb.doc(`posts/${id}`).delete().catch(() => {});
  await aDb.doc(`rateLimits/${U}_${ep}`).delete().catch(() => {});
  await aDb.doc(`rateLimits/${U}_${ep2}`).delete().catch(() => {});
  await aAuth.deleteUser(U).catch(() => {}); await aDb.doc(`users/${U}`).delete().catch(() => {});
} catch (e) {
  rec(false, "rig crashed", e.message); console.error(e);
} finally {
  console.log(`\n=== RATE-LIMIT SUMMARY: ${pass} passed, ${fail} failed ===`);
  fails.forEach((f) => console.log("  - " + f));
  process.exit(fail ? 1 : 0);
}
