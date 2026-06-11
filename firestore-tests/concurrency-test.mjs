// CONCURRENCY test rig against live STAGING (toskastaging).
//
// Spins up SIX real accounts signed in simultaneously via the client SDK and
// drives contended, overlapping writes at shared targets — the races a single-
// user rig can't produce:
//
//   • 6 users LIKE the same post at once          → likeCount settles at 6
//   • 6 users UNLIKE at once                      → settles back to 0
//   • 6 users REPLY at once (start-hidden, T-2)   → all promoted live; replyCount = 6
//   • 3 users post PII replies at once            → all HELD; replyCount unchanged
//   • 5 users REPOST the same post at once        → repostCount = 5
//   • 5 users FOLLOW the same user at once        → followerCount = 5; unfollow → 0
//   • like/unlike churn (5 rapid cycles) racing other users' likes → exact settle
//
// What this proves: the claimedTransaction counter triggers are idempotent and
// drift-free under real contention (concurrent invocations + Eventarc retries),
// the moderation pipeline keeps up under burst load, and no legitimate client
// op gets a spurious permission-denied when six sessions overlap.
//
// RUN (same env as full-e2e.mjs — staging web config + ADC):
//   cd firestore-tests && node concurrency-test.mjs
// Cleans up its accounts and posts afterward (best-effort).

import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword } from "firebase/auth";
import {
  getFirestore, doc, setDoc, deleteDoc, serverTimestamp,
} from "firebase/firestore";

const PROJECT_ID = "toskastaging";
const N = 6;

const envProject = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
if (envProject && envProject !== PROJECT_ID) {
  console.error(`REFUSING: GCLOUD_PROJECT="${envProject}" — this script is staging-only.`);
  process.exit(1);
}
const WEB_API_KEY = process.env.TOSKA_STAGING_WEB_API_KEY;
const WEB_APP_ID = process.env.TOSKA_STAGING_APP_ID;
const WEB_SENDER_ID = process.env.TOSKA_STAGING_SENDER_ID;
if (!WEB_API_KEY || !WEB_APP_ID || !WEB_SENDER_ID) {
  console.error("missing staging web env vars");
  process.exit(1);
}

admin.initializeApp({ projectId: PROJECT_ID });
const adminAuth = admin.auth();
const adminDb = admin.firestore();
const FV = admin.firestore.FieldValue;

const results = [];
function rec(ok, name, detail = "") {
  results.push({ ok, name, detail });
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? "  — " + detail : ""}`);
}

// Settle-poll: counters converge via triggers + contention retries; be patient.
async function settle(name, predicate, timeoutMs = 90000, every = 2000) {
  const start = Date.now();
  let last;
  while (Date.now() - start < timeoutMs) {
    try { last = await predicate(); if (last === true) { rec(true, name); return; } } catch {}
    await new Promise(r => setTimeout(r, every));
  }
  rec(false, name, `timed out after ${timeoutMs}ms (last=${JSON.stringify(last)})`);
}

// Run the same op as every user CONCURRENTLY; any rejection is a finding.
async function allUsers(name, users, fn) {
  const settled = await Promise.allSettled(users.map((u, i) => fn(u, i)));
  const errs = settled.filter(s => s.status === "rejected")
    .map(s => s.reason?.code || s.reason?.message);
  rec(errs.length === 0, name, errs.length ? `${errs.length} rejected: ${errs.slice(0, 3).join(", ")}` : "");
}

const users = []; // {uid, handle, db}
const trash = { posts: [], uids: [] };

try {
  console.log(`=== SETUP: ${N} fresh concurrent staging accounts ===`);
  for (let i = 1; i <= N; i++) {
    const email = `toska-conc-${i}@example.com`, pw = `ToskaConc!${i}9`, handle = `conc_tester_${i}`;
    try { const u = await adminAuth.getUserByEmail(email); await adminAuth.deleteUser(u.uid); } catch {}
    const u = await adminAuth.createUser({ email, password: pw, emailVerified: true });
    await adminDb.doc(`users/${u.uid}`).set({
      handle, followerCount: 0, followingCount: 0, totalLikes: 0, postCount: 0,
      allowSharing: true, showFollowerCount: true, hasCompletedOnboarding: true,
      acceptedPolicyVersion: 1, acceptedPolicyAt: FV.serverTimestamp(),
      confirmedAdult: true, confirmedAdultAt: FV.serverTimestamp(), createdAt: FV.serverTimestamp(),
    });
    const app = initializeApp({
      apiKey: WEB_API_KEY, authDomain: `${PROJECT_ID}.firebaseapp.com`,
      projectId: PROJECT_ID, appId: WEB_APP_ID, messagingSenderId: WEB_SENDER_ID,
    }, `conc${i}`);
    await signInWithEmailAndPassword(getAuth(app), email, pw);
    users.push({ uid: u.uid, handle, db: getFirestore(app) });
    trash.uids.push(u.uid);
  }
  console.log(`${N} users signed in concurrently\n`);

  const owner = users[0];
  const peers = users.slice(1); // 5 users

  // Target post by user 1 (start-hidden → live)
  const postId = `conc_${Date.now()}_target`;
  trash.posts.push(postId);
  await setDoc(doc(owner.db, "posts", postId), {
    authorId: owner.uid, authorHandle: owner.handle, text: "hold this for me",
    createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0,
    tag: "numb", moderationStatus: "pending_validation",
  });
  await settle("target post promoted → live",
    async () => (await adminDb.doc(`posts/${postId}`).get()).get("moderationStatus") === "live");

  console.log("\n=== PHASE 1: 6 concurrent likes on one post ===");
  await allUsers("all 6 like simultaneously (no rejections)", users,
    (u) => setDoc(doc(u.db, `posts/${postId}/likes`, u.uid), { createdAt: serverTimestamp() }));
  await settle("likeCount settles at exactly 6",
    async () => { const v = (await adminDb.doc(`posts/${postId}`).get()).get("likeCount"); return v === 6 ? true : v; });
  await settle("author totalLikes settles at exactly 6",
    async () => { const v = (await adminDb.doc(`users/${owner.uid}`).get()).get("totalLikes"); return v === 6 ? true : v; });

  console.log("\n=== PHASE 2: 6 concurrent unlikes ===");
  await allUsers("all 6 unlike simultaneously (no rejections)", users,
    (u) => deleteDoc(doc(u.db, `posts/${postId}/likes`, u.uid)));
  await settle("likeCount settles back to exactly 0",
    async () => { const v = (await adminDb.doc(`posts/${postId}`).get()).get("likeCount"); return v === 0 ? true : v; });
  await settle("author totalLikes settles back to exactly 0",
    async () => { const v = (await adminDb.doc(`users/${owner.uid}`).get()).get("totalLikes"); return v === 0 ? true : v; });

  console.log("\n=== PHASE 3: 6 concurrent clean replies (T-2 start-hidden) ===");
  await allUsers("all 6 reply simultaneously (no rejections)", users,
    (u, i) => setDoc(doc(u.db, `posts/${postId}/replies`, `conc_r_${i}_${Date.now()}`), {
      authorId: u.uid, authorHandle: u.handle, text: `still standing, ${i} breaths later`,
      createdAt: serverTimestamp(), likeCount: 0, moderationStatus: "pending_validation",
    }));
  await settle("all 6 replies promoted → live; replyCount settles at exactly 6",
    async () => {
      const v = (await adminDb.doc(`posts/${postId}`).get()).get("replyCount");
      return v === 6 ? true : v;
    });

  console.log("\n=== PHASE 4: 3 concurrent PII replies (burst moderation) ===");
  await allUsers("3 users post PII replies simultaneously (writes accepted)", users.slice(0, 3),
    (u, i) => setDoc(doc(u.db, `posts/${postId}/replies`, `conc_pii_${i}_${Date.now()}`), {
      authorId: u.uid, authorHandle: u.handle, text: "my ex Sarah Johnson did this too",
      createdAt: serverTimestamp(), likeCount: 0, moderationStatus: "pending_validation",
    }));
  await settle("all 3 PII replies HELD at pending_review (none leaked live)",
    async () => {
      const snap = await adminDb.collection(`posts/${postId}/replies`).get();
      const held = snap.docs.filter(d => d.id.startsWith("conc_pii_") && d.get("moderationStatus") === "pending_review").length;
      const leaked = snap.docs.filter(d => d.id.startsWith("conc_pii_") && d.get("moderationStatus") === "live").length;
      return (held === 3 && leaked === 0) ? true : { held, leaked };
    });
  await settle("replyCount still exactly 6 (held replies never counted)",
    async () => { const v = (await adminDb.doc(`posts/${postId}`).get()).get("replyCount"); return v === 6 ? true : v; });

  console.log("\n=== PHASE 5: 5 concurrent reposts of one post ===");
  await allUsers("5 peers repost simultaneously (no rejections)", peers, (u) => {
    const rid = `${u.uid}_repost_${postId}`;
    trash.posts.push(rid);
    return setDoc(doc(u.db, "posts", rid), {
      authorId: u.uid, authorHandle: u.handle, text: "hold this for me",
      createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, isRepost: true,
      originalPostId: postId, originalAuthorId: owner.uid, originalHandle: owner.handle,
      moderationStatus: "pending_validation",
    });
  });
  await settle("repostCount settles at exactly 5",
    async () => { const v = (await adminDb.doc(`posts/${postId}`).get()).get("repostCount"); return v === 5 ? true : v; });

  console.log("\n=== PHASE 6: 5 concurrent follows of one user ===");
  await allUsers("5 peers follow user 1 simultaneously (no rejections)", peers, async (u) => {
    await setDoc(doc(u.db, `users/${u.uid}/following`, owner.uid), { handle: owner.handle, createdAt: serverTimestamp() });
    await setDoc(doc(u.db, `users/${owner.uid}/followers`, u.uid), { handle: u.handle, createdAt: serverTimestamp() });
  });
  await settle("followerCount settles at exactly 5",
    async () => { const v = (await adminDb.doc(`users/${owner.uid}`).get()).get("followerCount"); return v === 5 ? true : v; });
  await allUsers("5 peers unfollow simultaneously (no rejections)", peers, async (u) => {
    await deleteDoc(doc(u.db, `users/${owner.uid}/followers`, u.uid));
    await deleteDoc(doc(u.db, `users/${u.uid}/following`, owner.uid));
  });
  await settle("followerCount settles back to exactly 0",
    async () => { const v = (await adminDb.doc(`users/${owner.uid}`).get()).get("followerCount"); return v === 0 ? true : v; });

  console.log("\n=== PHASE 7: like/unlike churn racing steady likes ===");
  // users 3-6 like and HOLD; user 2 churns like→unlike 5 times. Final = 4.
  const holders = users.slice(2);
  const churner = users[1];
  await Promise.all([
    allUsers("4 holders like (no rejections)", holders,
      (u) => setDoc(doc(u.db, `posts/${postId}/likes`, u.uid), { createdAt: serverTimestamp() })),
    (async () => {
      for (let i = 0; i < 5; i++) {
        await setDoc(doc(churner.db, `posts/${postId}/likes`, churner.uid), { createdAt: serverTimestamp() });
        await deleteDoc(doc(churner.db, `posts/${postId}/likes`, churner.uid));
      }
      rec(true, "churner completed 5 like/unlike cycles");
    })(),
  ]);
  await settle("likeCount settles at exactly 4 (holders only; churn fully cancelled)",
    async () => { const v = (await adminDb.doc(`posts/${postId}`).get()).get("likeCount"); return v === 4 ? true : v; });

  console.log("\n=== GROUND TRUTH: counters vs actual documents ===");
  {
    const likes = await adminDb.collection(`posts/${postId}/likes`).get();
    const replies = await adminDb.collection(`posts/${postId}/replies`).get();
    const liveReplies = replies.docs.filter(d => d.get("moderationStatus") === "live").length;
    const post = await adminDb.doc(`posts/${postId}`).get();
    rec(post.get("likeCount") === likes.size, "likeCount == #like docs", `${post.get("likeCount")} vs ${likes.size}`);
    rec(post.get("replyCount") === liveReplies, "replyCount == #live reply docs", `${post.get("replyCount")} vs ${liveReplies}`);
  }
} catch (e) {
  rec(false, "rig crashed", e.message);
} finally {
  console.log("\nCleaning up…");
  try {
    for (const pid of trash.posts) await adminDb.doc(`posts/${pid}`).delete().catch(() => {});
    for (const uid of trash.uids) {
      await adminAuth.deleteUser(uid).catch(() => {});
      await adminDb.doc(`users/${uid}`).delete().catch(() => {});
    }
  } catch {}
  const pass = results.filter(r => r.ok).length, fail = results.length - pass;
  console.log(`\n=== CONCURRENCY SUMMARY: ${pass}/${results.length} passed, ${fail} failed ===`);
  process.exit(fail ? 1 : 0);
}
