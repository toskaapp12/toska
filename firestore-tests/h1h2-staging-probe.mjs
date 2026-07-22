// Post-deploy probe for the 2026-07-22 HIGH fixes — LIVE STAGING ONLY.
//
// H1: a non-repost post create carrying `originalHandle` must be DENIED
//     by the deployed rules (impersonation byline spoof).
// H2: a spaced / homoglyph slur post must be HELD by the deployed
//     moderation function (never reach moderationStatus == "live").
//
// Run (same env as e2e-test.mjs):
//   TOSKA_STAGING_WEB_API_KEY=… TOSKA_STAGING_APP_ID=… TOSKA_STAGING_SENDER_ID=… \
//   node h1h2-staging-probe.mjs
// Prereq: gcloud ADC for the Admin SDK. Self-cleaning even on failure.

import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword } from "firebase/auth";
import { getFirestore, doc, setDoc, serverTimestamp } from "firebase/firestore";

const PROJECT_ID = "toskastaging";
const envProject = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
if (envProject && envProject !== PROJECT_ID) {
  console.error(`REFUSING TO RUN: GCLOUD_PROJECT="${envProject}" != ${PROJECT_ID}`);
  process.exit(1);
}
const KEY = process.env.TOSKA_STAGING_WEB_API_KEY;
const APP = process.env.TOSKA_STAGING_APP_ID;
const SND = process.env.TOSKA_STAGING_SENDER_ID;
if (!KEY || !APP || !SND) { console.error("missing staging web env vars"); process.exit(1); }

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
const EMAIL = `h1h2probe_${stamp}@example.com`;
const PW = "probe_pw_" + Math.random().toString(36).slice(2);
const HANDLE = `probe_${stamp.toString(36)}`;

let uid = null;
const createdPostIds = [];
let failures = 0;
const ok = (m) => console.log(`✓ ${m}`);
const bad = (m) => { failures++; console.error(`✗ ${m}`); };

function basePost(text) {
  return {
    authorId: uid, authorHandle: HANDLE, text,
    createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0,
  };
}

async function expectDenied(name, id, payload) {
  try {
    await setDoc(doc(webDb, "posts", id), payload);
    createdPostIds.push(id);
    bad(`${name} WAS ALLOWED (should be permission-denied)`);
  } catch (e) {
    if (e.code === "permission-denied") ok(`${name} correctly DENIED`);
    else bad(`${name} unexpected error: ${e.code || e.message}`);
  }
}

async function cleanup() {
  for (const id of createdPostIds) { try { await adminDb.doc(`posts/${id}`).delete(); } catch {} }
  if (uid) {
    try { await adminDb.doc(`users/${uid}`).delete(); } catch {}
    try { await adminAuth.deleteUser(uid); } catch {}
  }
}

try {
  const rec = await adminAuth.createUser({ email: EMAIL, password: PW, emailVerified: false });
  uid = rec.uid;
  await adminDb.doc(`users/${uid}`).set({
    handle: HANDLE, followerCount: 0, followingCount: 0, totalLikes: 0,
    allowSharing: true, showFollowerCount: false, hasCompletedOnboarding: true,
    acceptedPolicyVersion: 1, acceptedPolicyAt: admin.firestore.FieldValue.serverTimestamp(),
    confirmedAdult: true, confirmedAdultAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  await signInWithEmailAndPassword(webAuth, EMAIL, PW);
  ok(`signed in as throwaway user ${uid}`);

  // CONTROL: a clean normal post create must still be allowed.
  const controlId = `h1h2_control_${stamp}`;
  await setDoc(doc(webDb, "posts", controlId), basePost("probe control post — please ignore"));
  createdPostIds.push(controlId);
  ok("CONTROL: clean post create allowed");

  // H1: originalHandle on a non-repost (field omitted, and explicit false).
  await expectDenied("H1 spoof (isRepost omitted + originalHandle)", `h1_omit_${stamp}`,
    { ...basePost("innocent looking text"), originalHandle: "some_real_user" });
  await expectDenied("H1 spoof (isRepost=false + originalHandle)", `h1_false_${stamp}`,
    { ...basePost("innocent looking text"), isRepost: false, originalHandle: "some_real_user" });
  await expectDenied("H1 spoof (originalAuthorId smuggled)", `h1_oaid_${stamp}`,
    { ...basePost("innocent looking text"), originalAuthorId: "victim_uid_123" });

  // H2: evasion slurs must be HELD by the deployed moderation function.
  const h2Cases = [
    { id: `h2_spaced_${stamp}`, text: "you are all n i g g e r s", label: "spaced slur" },
    { id: `h2_homoglyph_${stamp}`, text: "what a nіgger", label: "homoglyph slur (Cyrillic і)" },
  ];
  for (const c of h2Cases) {
    await setDoc(doc(webDb, "posts", c.id), basePost(c.text));
    createdPostIds.push(c.id);
  }
  ok("H2 probe posts written; waiting for moderation function…");

  for (const c of h2Cases) {
    let status = null;
    for (let i = 0; i < 30; i++) {
      const snap = await adminDb.doc(`posts/${c.id}`).get();
      status = snap.exists ? snap.get("moderationStatus") : "(deleted)";
      if (status && status !== "pending_validation") break;
      await new Promise((r) => setTimeout(r, 2000));
    }
    if (status === "live") bad(`H2 ${c.label} went LIVE — evasion filter not effective`);
    else if (!status || status === "pending_validation") bad(`H2 ${c.label} never moderated (status=${status})`);
    else ok(`H2 ${c.label} held: moderationStatus=${status}`);
  }

  // Sanity: the clean control post should be allowed to go live.
  {
    let status = null;
    for (let i = 0; i < 30; i++) {
      const snap = await adminDb.doc(`posts/${controlId}`).get();
      status = snap.exists ? snap.get("moderationStatus") : "(deleted)";
      if (status && status !== "pending_validation") break;
      await new Promise((r) => setTimeout(r, 2000));
    }
    if (status === "live") ok("CONTROL post moderated to live (no false positive)");
    else bad(`CONTROL post did not go live (status=${status})`);
  }
} catch (e) {
  bad(`probe crashed: ${e.message || e}`);
} finally {
  await cleanup();
  console.log(failures === 0 ? "\n*** H1+H2 STAGING PROBE PASSED ***" : `\n*** PROBE FAILED (${failures}) ***`);
  process.exit(failures === 0 ? 0 : 1);
}
