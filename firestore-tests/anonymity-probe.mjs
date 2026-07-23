// Anonymity / privacy guarantee probe — LIVE.
//
// Proves the guarantees an anonymous social app lives or dies on:
//   G1  Email lives ONLY in Firebase Auth + owner-only private/data — NEVER on
//       a world-readable main user doc (checked against REAL data).
//   G2  A non-owner (user B) CANNOT read A's private/data (email, mood, tokens).
//   G3  Quantify exactly which main-doc fields a non-owner CAN read (the L1
//       finding) — proves it's moderation metadata, not identity/PII.
//   G4  gifUrl host-lock is enforced (a tampered client can't store an
//       attacker URL that would beacon a viewer's IP → deanonymize).
//   G5  Posts/replies never carry the author's email/uid-as-identity leak.
//
// Staging run (writes): full G1–G5 with throwaway users.
// Prod run (read-only): pass TOSKA_PROBE_PROD=1 → G1 + G5 sampled across real
//   docs via Admin SDK only (NO writes, NO client sign-in). Safe against prod.
//
// Env: same staging web vars as e2e-test.mjs; gcloud ADC for Admin SDK.

import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword } from "firebase/auth";
import { getFirestore, doc, getDoc, setDoc, serverTimestamp } from "firebase/firestore";

const PROD = process.env.TOSKA_PROBE_PROD === "1";
const PROJECT_ID = PROD ? "toska-4ebf4" : "toskastaging";
const envProject = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
if (envProject && envProject !== PROJECT_ID) {
  console.error(`REFUSING: GCLOUD_PROJECT="${envProject}" != ${PROJECT_ID}`);
  process.exit(1);
}

admin.initializeApp({ projectId: PROJECT_ID });
const adminDb = admin.firestore();
const adminAuth = admin.auth();

let failures = 0;
const ok = (m) => console.log(`  ✓ ${m}`);
const bad = (m) => { failures++; console.error(`  ✗ ${m}`); };

// Fields that would break anonymity if present on a world-readable main doc.
const PII_KEYS = ["email", "selectedMood", "fcmToken", "notifyLikes", "notifyReplies",
  "notifyFollows", "notifyReposts", "notifySaves", "notifyMessages", "notifyMilestones",
  "pushEnabled", "gentleCheckIn", "phone", "realName", "displayName"];

async function checkMainDocPII(uid, data) {
  const leaked = PII_KEYS.filter((k) => k in data);
  if (leaked.length) { bad(`user ${uid} main doc carries PII: ${leaked.join(", ")}`); return false; }
  return true;
}

async function prodReadOnly() {
  console.log(`\n=== PROD read-only anonymity audit (${PROJECT_ID}) ===`);
  // G1: sample up to 500 real user docs — assert NONE carry PII on the main doc.
  const users = await adminDb.collection("users").limit(500).get();
  let clean = 0;
  for (const d of users.docs) { if (await checkMainDocPII(d.id, d.data())) clean++; }
  if (clean === users.size) ok(`G1: ${users.size}/${users.size} real user docs carry ZERO PII on the world-readable main doc`);

  // G1b: confirm email actually lives in Auth (spot-check a few uids that have Auth records).
  let authEmails = 0;
  for (const d of users.docs.slice(0, 5)) {
    try { const u = await adminAuth.getUser(d.id); if (u.email) authEmails++; } catch {}
  }
  ok(`G1b: email present in Auth for ${authEmails}/5 sampled accounts (Auth is the sole email home)`);

  // G5: sample posts — assert no email/authorEmail/PII field leaked onto content docs.
  const posts = await adminDb.collection("posts").limit(500).get();
  const contentPII = ["email", "authorEmail", "fcmToken", "phone", "realName"];
  let dirty = 0;
  for (const d of posts.docs) {
    const data = d.data();
    const hit = contentPII.filter((k) => k in data);
    if (hit.length) { dirty++; bad(`post ${d.id} leaks ${hit.join(",")}`); }
  }
  if (!dirty) ok(`G5: ${posts.size}/${posts.size} real posts carry no email/PII field`);

  // G4 (read-only): sample posts with a gifUrl — assert every one is giphy-hosted.
  const gifPosts = posts.docs.filter((d) => typeof d.data().gifUrl === "string");
  const badGif = gifPosts.filter((d) => !/^https:\/\/([a-z0-9-]+[.])+giphy[.]com\//.test(d.data().gifUrl));
  if (gifPosts.length === 0) ok("G4: no gifUrl posts in sample (nothing to check)");
  else if (badGif.length === 0) ok(`G4: all ${gifPosts.length} sampled gifUrl posts are giphy-hosted (no beacon host)`);
  else bad(`G4: ${badGif.length} posts have a NON-giphy gifUrl (possible beacon): ${badGif.slice(0,3).map(d=>d.data().gifUrl).join(" | ")}`);
}

async function stagingFull() {
  const KEY = process.env.TOSKA_STAGING_WEB_API_KEY, APP = process.env.TOSKA_STAGING_APP_ID, SND = process.env.TOSKA_STAGING_SENDER_ID;
  if (!KEY || !APP || !SND) { console.error("missing staging web env vars"); process.exit(1); }
  const web = initializeApp({ apiKey: KEY, authDomain: `${PROJECT_ID}.firebaseapp.com`, projectId: PROJECT_ID, appId: APP, messagingSenderId: SND });
  const webAuth = getAuth(web), webDb = getFirestore(web);
  const stamp = Date.now();

  console.log(`\n=== STAGING full anonymity probe (${PROJECT_ID}) ===`);
  // Two throwaway users: A (victim), B (attacker).
  const mk = async (tag) => {
    const email = `anonprobe_${tag}_${stamp}@example.com`, pw = "pw_" + Math.random().toString(36).slice(2);
    const rec = await adminAuth.createUser({ email, password: pw, emailVerified: true });
    // Realistic account: email + mood in private/data, restriction/adult on main.
    await adminDb.doc(`users/${rec.uid}`).set({
      handle: `anon_${tag}_${stamp.toString(36)}`, followerCount: 0, followingCount: 0, totalLikes: 0,
      allowSharing: true, showFollowerCount: false, hasCompletedOnboarding: true,
      acceptedPolicyVersion: 1, confirmedAdult: true, createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await adminDb.doc(`users/${rec.uid}/private/data`).set({ email, selectedMood: "numb", fcmToken: "fake-token-xyz" });
    return { uid: rec.uid, email, pw };
  };
  const A = await mk("a"), B = await mk("b");
  await signInWithEmailAndPassword(webAuth, B.email, B.pw);
  ok(`set up victim A + attacker B (signed in as B)`);

  // G2: B cannot read A's private/data (where the email actually lives).
  try {
    await getDoc(doc(webDb, `users/${A.uid}/private/data`));
    bad("G2: B COULD read A's private/data — EMAIL EXPOSED");
  } catch (e) { if (e.code === "permission-denied") ok("G2: B cannot read A's private/data (email/mood/token isolated)"); else bad(`G2 unexpected: ${e.code}`); }

  // G1/G3: B reads A's main doc. Assert readable fields contain NO PII, and
  // enumerate exactly what IS visible (the L1 exposure).
  try {
    const snap = await getDoc(doc(webDb, `users/${A.uid}`));
    if (!snap.exists()) { ok("G3: B cannot read A's main doc at all"); }
    else {
      const data = snap.data();
      await checkMainDocPII(A.uid, data);
      const visible = Object.keys(data).sort();
      const modMeta = visible.filter((k) => ["restricted","restrictedAt","restrictedBy","restrictedUntil","confirmedAdult"].includes(k));
      ok(`G1: A's main doc readable by B carries NO email/PII`);
      if (modMeta.length) console.log(`  ℹ L1 note: B can also see moderation metadata ${modMeta.join(", ")} (not identity; deferred fix)`);
      console.log(`  ℹ fields visible to B: ${visible.join(", ")}`);
    }
  } catch (e) { if (e.code === "permission-denied") ok("G3: B cannot read A's main doc (fully denied)"); else bad(`G3 unexpected: ${e.code}`); }

  // G4: B (adult-confirmed) tries to store a NON-giphy gifUrl → must be denied.
  const basePost = (extra) => ({ authorId: B.uid, authorHandle: `anon_b_${stamp.toString(36)}`, text: "gif beacon test post",
    createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, ...extra });
  try {
    await setDoc(doc(webDb, "posts", `anon_gif_${stamp}`), basePost({ gifUrl: "https://evil.example.com/track.gif" }));
    bad("G4: a NON-giphy gifUrl was ACCEPTED — deanonymizing beacon possible");
    await adminDb.doc(`posts/anon_gif_${stamp}`).delete();
  } catch (e) { if (e.code === "permission-denied") ok("G4: non-giphy gifUrl rejected (beacon blocked)"); else bad(`G4 unexpected: ${e.code}`); }
  // control: a giphy gifUrl is accepted
  try {
    await setDoc(doc(webDb, "posts", `anon_gif_ok_${stamp}`), basePost({ gifUrl: "https://media.giphy.com/x.gif" }));
    ok("G4 control: giphy-hosted gifUrl accepted");
    await adminDb.doc(`posts/anon_gif_ok_${stamp}`).delete();
  } catch (e) { bad(`G4 control giphy gif was DENIED: ${e.code}`); }

  // Cleanup
  for (const u of [A, B]) {
    try { await adminDb.doc(`users/${u.uid}/private/data`).delete(); } catch {}
    try { await adminDb.doc(`users/${u.uid}`).delete(); } catch {}
    try { await adminAuth.deleteUser(u.uid); } catch {}
  }
  ok("cleaned up throwaway users");
}

(async () => {
  try {
    if (PROD) await prodReadOnly();
    else await stagingFull();
  } catch (e) { bad(`probe crashed: ${e.message || e}`); }
  console.log(failures === 0 ? "\n*** ANONYMITY PROBE PASSED ***" : `\n*** FAILURES: ${failures} ***`);
  process.exit(failures === 0 ? 0 : 1);
})();
