// SIGNUP-RACE probe — live STAGING. 2026-10-22 sweep follow-up.
//
// The 10-12 fix round removed every handle-availability pre-read (handles
// gets are admin-only now); the batched users+handles CREATE is the sole
// collision arbiter. This probe races that arbiter: N simultaneous signups
// ALL trying to claim the SAME handle first, falling back per the client
// retry contract (fresh candidate per attempt). Proves under real
// contention: exactly ONE account wins a contested handle, every loser
// lands on a different handle (no duplicate handles, no failed signups),
// and the registry ends 1:1 with user docs. Self-cleaning.
//
// Run (same env as concurrency-test.mjs): node signup-race-probe.mjs
import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, createUserWithEmailAndPassword } from "firebase/auth";
import { getFirestore, doc, writeBatch, serverTimestamp } from "firebase/firestore";

const PROJECT_ID = "toskastaging";
const N = 6;
const KEY = process.env.TOSKA_STAGING_WEB_API_KEY;
const APP = process.env.TOSKA_STAGING_APP_ID;
const SND = process.env.TOSKA_STAGING_SENDER_ID;
if (!KEY || !APP || !SND) { console.error("missing staging env"); process.exit(1); }

admin.initializeApp({ projectId: PROJECT_ID });
const adminDb = admin.firestore();
const adminAuth = admin.auth();

const stamp = Date.now();
const CONTESTED = `race_handle_${stamp}`;
let failures = 0;
const ok = (m) => console.log(`✓ ${m}`);
const bad = (m) => { failures++; console.error(`✗ ${m}`); };

// Mirror of the client claim loop (ContentModeration.commitUserDocClaimingHandle /
// web claimHandleAndCreateUserDoc): batch create, on failure retry with a
// fresh candidate. Attempt 1 for EVERY user is the SAME contested handle.
async function signupAndClaim(i) {
  const app = initializeApp({
    apiKey: KEY, authDomain: `${PROJECT_ID}.firebaseapp.com`,
    projectId: PROJECT_ID, appId: APP, messagingSenderId: SND,
  }, `racer${i}`);
  const cred = await createUserWithEmailAndPassword(getAuth(app),
    `race_${stamp}_${i}@example.com`, `race_pw_${stamp}_${i}`);
  const uid = cred.user.uid;
  const db = getFirestore(app);
  const candidates = [CONTESTED, `race_fb_${stamp}_${i}_a`, `race_fb_${stamp}_${i}_b`];
  for (const handle of candidates) {
    const batch = writeBatch(db);
    batch.set(doc(db, "users", uid), {
      handle,
      followerCount: 0, followingCount: 0, totalLikes: 0,
      allowSharing: true, showFollowerCount: false,
      hasCompletedOnboarding: false,
      createdAt: serverTimestamp(),
    });
    batch.set(doc(db, "handles", handle.toLowerCase()), { uid });
    try {
      await batch.commit();
      return { uid, handle, attempts: candidates.indexOf(handle) + 1 };
    } catch { /* claimed by a racer — next candidate */ }
  }
  return { uid, handle: null, attempts: candidates.length };
}

try {
  // Fire all N signups at once — maximal contention on the shared candidate.
  const results = await Promise.all(Array.from({ length: N }, (_, i) => signupAndClaim(i)));

  const winners = results.filter((r) => r.handle === CONTESTED);
  const losersUnclaimed = results.filter((r) => r.handle === null);
  if (winners.length === 1) ok(`contested handle won by exactly ONE of ${N} racers (uid ${winners[0].uid.slice(0, 6)}…)`);
  else bad(`contested handle winners: ${winners.length} (expected exactly 1)`);
  if (losersUnclaimed.length === 0) ok("every losing racer settled on a fallback handle (no failed signups)");
  else bad(`${losersUnclaimed.length} racers ended with NO handle`);

  const handles = results.map((r) => r.handle).filter(Boolean);
  if (new Set(handles).size === handles.length) ok("no duplicate handles across racers");
  else bad(`duplicate handles: ${handles.join(", ")}`);

  // Registry truth: each claimed handle's row must point at its claimant,
  // and each user doc's handle must have a matching row (1:1).
  let mismatches = 0;
  for (const r of results) {
    if (!r.handle) continue;
    const row = await adminDb.collection("handles").doc(r.handle.toLowerCase()).get();
    const userDoc = await adminDb.collection("users").doc(r.uid).get();
    if (row.data()?.uid !== r.uid) { mismatches++; console.error(`  registry row ${r.handle} → ${row.data()?.uid}, expected ${r.uid}`); }
    if (userDoc.data()?.handle !== r.handle) { mismatches++; console.error(`  user doc ${r.uid.slice(0, 6)} handle ${userDoc.data()?.handle}, expected ${r.handle}`); }
  }
  if (mismatches === 0) ok("registry ↔ user docs 1:1 consistent");
  else bad(`${mismatches} registry/user-doc mismatches`);

  const retried = results.filter((r) => r.attempts > 1).length;
  console.log(`  (retry pressure: ${retried}/${N} racers needed fallback attempts)`);
} catch (e) {
  bad(`probe error: ${e.message}`);
} finally {
  // Cleanup: delete auth users via Admin SDK — but delete the USER DOCS
  // ourselves too rather than relying on cascade timing, then sweep handles.
  try {
    const list = await adminAuth.listUsers(1000);
    const mine = list.users.filter((u) => u.email?.startsWith(`race_${stamp}_`));
    for (const u of mine) {
      await adminDb.collection("users").doc(u.uid).delete().catch(() => {});
      await adminAuth.deleteUser(u.uid).catch(() => {});
    }
    const reg = await adminDb.collection("handles")
      .where("uid", "in", mine.map((u) => u.uid).slice(0, 10)).get()
      .catch(() => ({ docs: [] }));
    for (const d of reg.docs) await d.ref.delete().catch(() => {});
    // Belt and braces for the deterministic names:
    await adminDb.collection("handles").doc(CONTESTED.toLowerCase()).delete().catch(() => {});
    console.log(`  (cleaned ${mine.length} racer accounts)`);
  } catch (e) { console.error("cleanup error:", e.message); }
  console.log(failures ? "RESULT: FAIL" : "RESULT: PASS");
  process.exit(failures ? 1 : 0);
}
