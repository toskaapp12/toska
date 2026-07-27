// Phase-1 (rules) live-staging adversarial probe — TOSKA_FULL_AUDIT_2026-07-24.
// Targets the §5 churn list against the DEPLOYED staging rules:
//   1. handles get/list split + registry immutability
//   2. users-create getAfter registry binding
//   3. posts admin stamp-then-delete path (deletedBy pin)
//   4. pendingDeletions create/cancel/delete lifecycle
//   5. ephemeral-flag type confusion (isWhisper non-bool bypasses expiresAt gate)
// plus unauth + admin-surface spot checks.
//
// LIVE STAGING ONLY. Self-cleaning even on failure (verified residue sweep).
// Run:
//   TOSKA_STAGING_WEB_API_KEY=… TOSKA_STAGING_APP_ID=… TOSKA_STAGING_SENDER_ID=… \
//   TOSKA_STAGING_EMAIL_A=… TOSKA_STAGING_PASSWORD_A=… \
//   TOSKA_STAGING_EMAIL_B=… TOSKA_STAGING_PASSWORD_B=… \
//   node phase1-audit-probe-20260724.mjs
// Prereq: gcloud ADC for the Admin SDK.

import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import {
  getAuth, signInWithEmailAndPassword, createUserWithEmailAndPassword, signOut,
} from "firebase/auth";
import {
  getFirestore, doc, getDoc, getDocs, setDoc, updateDoc, deleteDoc,
  collection, query, limit, writeBatch, serverTimestamp, Timestamp,
} from "firebase/firestore";

const PROJECT_ID = "toskastaging";
const envProject = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
if (envProject && envProject !== PROJECT_ID) {
  console.error(`REFUSING TO RUN: GCLOUD_PROJECT="${envProject}" != ${PROJECT_ID}`);
  process.exit(1);
}
const need = (k) => {
  const v = process.env[k];
  if (!v) { console.error(`missing env ${k}`); process.exit(1); }
  return v;
};
const KEY = need("TOSKA_STAGING_WEB_API_KEY");
const APP = need("TOSKA_STAGING_APP_ID");
const SND = need("TOSKA_STAGING_SENDER_ID");
const EMAIL_A = need("TOSKA_STAGING_EMAIL_A"), PW_A = need("TOSKA_STAGING_PASSWORD_A");
const EMAIL_B = need("TOSKA_STAGING_EMAIL_B"), PW_B = need("TOSKA_STAGING_PASSWORD_B");

admin.initializeApp({ projectId: PROJECT_ID });
const adminAuth = admin.auth();
const adminDb = admin.firestore();

const webApp = initializeApp({
  apiKey: KEY, authDomain: `${PROJECT_ID}.firebaseapp.com`,
  projectId: PROJECT_ID, appId: APP, messagingSenderId: SND,
});
const webAuth = getAuth(webApp);
const webDb = getFirestore(webApp);

const stamp = Date.now();
const T_EMAIL = `p1probe_t_${stamp}@example.com`;
const T2_EMAIL = `p1probe_t2_${stamp}@example.com`;
const T_PW = "probe_pw_" + Math.random().toString(36).slice(2);
const T_HANDLE = `p1t_${stamp.toString(36)}`;
const T2_HANDLE = `p1t2_${stamp.toString(36)}`;

let tUid = null, t2Uid = null;
const createdPostIds = [];
let failures = 0;
const ok = (m) => console.log(`✓ ${m}`);
const bad = (m) => { failures++; console.error(`✗ ${m}`); };

async function expectDenied(name, fn) {
  try {
    await fn();
    bad(`${name} WAS ALLOWED (expected permission-denied)`);
    return true; // it landed
  } catch (e) {
    if (e.code === "permission-denied") ok(`DENIED as expected: ${name}`);
    else bad(`${name}: unexpected error ${e.code || e.message}`);
    return false;
  }
}
async function expectAllowed(name, fn) {
  try { await fn(); ok(`ALLOWED as expected: ${name}`); return true; }
  catch (e) { bad(`${name}: DENIED/error ${e.code || e.message}`); return false; }
}

async function cleanup() {
  console.log("--- cleanup ---");
  for (const id of createdPostIds) { try { await adminDb.doc(`posts/${id}`).delete(); } catch {} }
  for (const uid of [tUid, t2Uid]) {
    if (!uid) continue;
    try { await adminDb.doc(`pendingDeletions/${uid}`).delete(); } catch {}
    try { await adminDb.doc(`users/${uid}`).delete(); } catch {}
    try { await adminAuth.deleteUser(uid); } catch {}
  }
  for (const h of [T_HANDLE, T2_HANDLE]) {
    try { await adminDb.doc(`handles/${h}`).delete(); } catch {}
  }
  // residue verification
  let residue = 0;
  for (const id of createdPostIds) {
    if ((await adminDb.doc(`posts/${id}`).get()).exists) { residue++; console.error(`RESIDUE: posts/${id}`); }
  }
  for (const uid of [tUid, t2Uid]) {
    if (!uid) continue;
    if ((await adminDb.doc(`users/${uid}`).get()).exists) { residue++; console.error(`RESIDUE: users/${uid}`); }
    if ((await adminDb.doc(`pendingDeletions/${uid}`).get()).exists) { residue++; console.error(`RESIDUE: pendingDeletions/${uid}`); }
  }
  for (const h of [T_HANDLE, T2_HANDLE]) {
    if ((await adminDb.doc(`handles/${h}`).get()).exists) { residue++; console.error(`RESIDUE: handles/${h}`); }
  }
  console.log(residue === 0 ? "cleanup: ZERO residue" : `cleanup: ${residue} residue docs (see above)`);
}

function basePost(uid, handle, text) {
  return {
    authorId: uid, authorHandle: handle, text,
    createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0,
  };
}

try {
  // ---------- unauth probes (before any sign-in) ----------
  await expectDenied("unauth read of posts/wt_fixture_firstlight",
    () => getDoc(doc(webDb, "posts", "wt_fixture_firstlight")));
  await expectDenied("unauth get of a handles row",
    () => getDoc(doc(webDb, "handles", "anyhandle")));

  // ---------- throwaway T (admin-seeded, confirmedAdult, has registry row) ----------
  const rec = await adminAuth.createUser({ email: T_EMAIL, password: T_PW });
  tUid = rec.uid;
  await adminDb.doc(`users/${tUid}`).set({
    handle: T_HANDLE, followerCount: 0, followingCount: 0, totalLikes: 0,
    allowSharing: true, showFollowerCount: false, hasCompletedOnboarding: true,
    acceptedPolicyVersion: 3, acceptedPolicyAt: admin.firestore.FieldValue.serverTimestamp(),
    confirmedAdult: true, confirmedAdultAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  await adminDb.doc(`handles/${T_HANDLE}`).set({ uid: tUid });
  await signInWithEmailAndPassword(webAuth, T_EMAIL, T_PW);
  ok(`signed in as throwaway T ${tUid}`);

  // ---------- 1. handles: get allowed / list denied / immutable ----------
  await expectAllowed("authed handles point-get (own row)",
    () => getDoc(doc(webDb, "handles", T_HANDLE)));
  await expectDenied("authed handles LIST (registry enumeration)",
    () => getDocs(query(collection(webDb, "handles"), limit(5))));
  await expectDenied("handles row delete by its owner (allow delete: false)",
    () => deleteDoc(doc(webDb, "handles", T_HANDLE)));
  await expectDenied("handles squat: claim a row not matching own user-doc handle",
    () => setDoc(doc(webDb, "handles", `squat_${stamp.toString(36)}`), { uid: tUid }));

  // ---------- 5. posts create + ephemeral type confusion ----------
  const controlId = `p1_control_${stamp}`;
  if (await expectAllowed("control clean post create (notRestricted+confirmedAdult pass)",
    () => setDoc(doc(webDb, "posts", controlId), basePost(tUid, T_HANDLE, "phase1 probe control post — ignore"))))
    createdPostIds.push(controlId);

  await expectDenied("isWhisper=true WITHOUT expiresAt (ephemeral gate, genuine bool)",
    () => setDoc(doc(webDb, "posts", `p1_wtrue_${stamp}`),
      { ...basePost(tUid, T_HANDLE, "whisper gate probe"), isWhisper: true }));

  const confId = `p1_wstr_${stamp}`;
  const landed = await (async () => {
    try {
      await setDoc(doc(webDb, "posts", confId),
        { ...basePost(tUid, T_HANDLE, "whisper type-confusion probe"), isWhisper: "x" });
      createdPostIds.push(confId);
      return true;
    } catch (e) { return false; }
  })();
  if (landed) bad(`FINDING CONFIRMED LIVE: isWhisper:"x" (non-bool) accepted WITHOUT expiresAt — type-confusion bypass of the ephemeral gate`);
  else ok(`isWhisper non-bool rejected (no type-confusion gap)`);

  // second post for the stamp/delete tests
  const stampPostId = `p1_stamp_${stamp}`;
  await setDoc(doc(webDb, "posts", stampPostId), basePost(tUid, T_HANDLE, "phase1 stamp-then-delete target — ignore"));
  createdPostIds.push(stampPostId);

  // ---------- 4. pendingDeletions lifecycle (on throwaway T only) ----------
  await expectDenied("pendingDeletions create with CLIENT timestamp (requestedAt pin)",
    () => setDoc(doc(webDb, "pendingDeletions", tUid), { uid: tUid, requestedAt: Timestamp.now() }));
  await expectAllowed("pendingDeletions create with serverTimestamp",
    () => setDoc(doc(webDb, "pendingDeletions", tUid), { uid: tUid, requestedAt: serverTimestamp() }));
  await expectDenied("pendingDeletions read-back by owner (allow read: false)",
    () => getDoc(doc(webDb, "pendingDeletions", tUid)));
  await expectDenied("pendingDeletions update touching uid (affectedKeys lock)",
    () => updateDoc(doc(webDb, "pendingDeletions", tUid), { uid: "someone_else" }));
  await expectAllowed("pendingDeletions cancel (cancelled/cancelledAt)",
    () => updateDoc(doc(webDb, "pendingDeletions", tUid), { cancelled: true, cancelledAt: serverTimestamp() }));
  await expectAllowed("pendingDeletions owner delete (restart-deletion path)",
    () => deleteDoc(doc(webDb, "pendingDeletions", tUid)));

  // ---------- 2. users-create registry binding (fresh web-signup T2) ----------
  await signOut(webAuth);
  const cred = await createUserWithEmailAndPassword(webAuth, T2_EMAIL, T_PW);
  t2Uid = cred.user.uid;
  ok(`created web-signup throwaway T2 ${t2Uid}`);
  const t2Doc = {
    handle: T2_HANDLE, followerCount: 0, followingCount: 0, totalLikes: 0,
    allowSharing: true, showFollowerCount: false, createdAt: serverTimestamp(),
  };
  await expectDenied("users create WITHOUT handles registry row in batch (getAfter binding)",
    () => setDoc(doc(webDb, "users", t2Uid), t2Doc));
  await expectDenied("users create with MISMATCHED registry row (claims other id)",
    () => {
      const b = writeBatch(webDb);
      b.set(doc(webDb, "users", t2Uid), t2Doc);
      b.set(doc(webDb, "handles", `wrong_${stamp.toString(36)}`), { uid: t2Uid });
      return b.commit();
    });
  await expectDenied("users create seeding followerCount=999999 (S-1)",
    () => {
      const b = writeBatch(webDb);
      b.set(doc(webDb, "users", t2Uid), { ...t2Doc, followerCount: 999999 });
      b.set(doc(webDb, "handles", T2_HANDLE), { uid: t2Uid });
      return b.commit();
    });
  await expectDenied("users create smuggling confirmedAdult=true (server-owned)",
    () => {
      const b = writeBatch(webDb);
      b.set(doc(webDb, "users", t2Uid), { ...t2Doc, confirmedAdult: true });
      b.set(doc(webDb, "handles", T2_HANDLE), { uid: t2Uid });
      return b.commit();
    });
  await expectAllowed("users create WITH matching registry row batch (legit signup shape)",
    () => {
      const b = writeBatch(webDb);
      b.set(doc(webDb, "users", t2Uid), t2Doc);
      b.set(doc(webDb, "handles", T2_HANDLE), { uid: t2Uid });
      return b.commit();
    });
  // handle immutability post-create
  await expectDenied("users update swapping handle (immutable)",
    () => updateDoc(doc(webDb, "users", t2Uid), { handle: "stolen_handle" }));
  await expectDenied("users update self-setting restricted:false (server-owned)",
    () => updateDoc(doc(webDb, "users", t2Uid), { restricted: false }));

  // T2 reads T's surfaces
  await expectAllowed("other-user read of T's public user doc (PII-clean projection)",
    () => getDoc(doc(webDb, "users", tUid)));
  await expectDenied("other-user read of T's private/data",
    () => getDoc(doc(webDb, "users", tUid, "private", "data")));
  await expectDenied("non-admin LIST of reports",
    () => getDocs(query(collection(webDb, "reports"), limit(3))));
  await expectDenied("non-admin LIST of adminAuditLog",
    () => getDocs(query(collection(webDb, "adminAuditLog"), limit(3))));
  await expectDenied("non-admin read of another user's admins/{uid} doc",
    () => getDoc(doc(webDb, "admins", tUid)));

  // ---------- 3. admin stamp-then-delete (accounts B then A) ----------
  await signOut(webAuth);
  await signInWithEmailAndPassword(webAuth, EMAIL_B, PW_B);
  ok("signed in as staging non-admin B");
  await expectDenied("non-admin B stamps deletedBy on T's post",
    () => updateDoc(doc(webDb, "posts", stampPostId), { deletedBy: webAuth.currentUser.uid }));
  await expectDenied("non-admin B deletes T's post",
    () => deleteDoc(doc(webDb, "posts", stampPostId)));

  await signOut(webAuth);
  await signInWithEmailAndPassword(webAuth, EMAIL_A, PW_A);
  const aUid = webAuth.currentUser.uid;
  ok(`signed in as staging admin A ${aUid}`);
  await expectDenied("admin A stamps deletedBy=OTHER uid (attribution pin)",
    () => updateDoc(doc(webDb, "posts", stampPostId), { deletedBy: "some_other_admin_uid" }));
  await expectAllowed("admin A stamps deletedBy=self on T's post",
    () => updateDoc(doc(webDb, "posts", stampPostId), { deletedBy: aUid, deletedAt: serverTimestamp() }));
  await expectAllowed("admin A deletes T's post (inline admin delete path)",
    () => deleteDoc(doc(webDb, "posts", stampPostId)));
  await expectAllowed("admin A lists adminAuditLog",
    () => getDocs(query(collection(webDb, "adminAuditLog"), limit(1))));
  await signOut(webAuth);
} catch (e) {
  bad(`probe aborted: ${e.stack || e.message}`);
} finally {
  await cleanup();
}
console.log(failures === 0 ? "\nALL PHASE-1 PROBES PASSED" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
