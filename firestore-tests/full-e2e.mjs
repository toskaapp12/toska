// FULL end-to-end test rig against live STAGING (toskastaging).
//
// Creates two real accounts (A = primary tester, B = peer) and exercises the
// whole stack the way the app does — rules + Cloud Function triggers +
// moderation, and how they work TOGETHER — with positive flows AND adversarial
// security negatives. Every check is recorded and the run prints a pass/fail
// summary at the end (it does NOT abort on the first failure).
//
// By default it LEAVES account A populated and persistent so you can sign into
// it on the simulator (Debug build → staging) and see every feature with real
// content. Pass --clean to delete both accounts + their data afterward.
//
// WHAT IT PROVES (functionality + security, together):
//   • Post create (clean) → validatePost promotes it to moderationStatus=live
//   • Reply create (clean) → live;  reply with PII ("my ex Sarah Johnson")
//     → HELD at pending_review by validateReply (the M-1 recoverable hold)
//   • Counters: like → likeCount++/totalLikes++, reply → replyCount++,
//     follow → follower/followingCount++, repost → repostCount++ (triggers)
//   • A held reply does NOT inflate the post's replyCount (onReplyVisibility…)
//   • Block: a blocked user can't like or reply to the blocker
//   • Adversarial DENIES: post-as-someone-else, self-set confirmedAdult,
//     inflate own counters, self-unrestrict, read someone's /private, forge a
//     notification, self-publish moderationStatus=live, N-1 reply-update
//     byline spoof, read admins/adminAuditLog
//
// WHAT IT DOES NOT COVER (needs a real device): the 3 App-Check-enforced
// callables (confirmAdult / giphyProxy / reconcileMyCounts). The Admin SDK sets
// confirmedAdult directly here (mimicking the callable) so A/B can post.
//
// RUN:
//   cd firestore-tests
//   GCLOUD_PROJECT=toskastaging \
//   TOSKA_STAGING_WEB_API_KEY="AIza…" \
//   TOSKA_STAGING_APP_ID="1:…:ios:…" \
//   TOSKA_STAGING_SENDER_ID="…" \
//   node full-e2e.mjs            # leaves account A; add --clean to tear down
//
// Prereqs: `gcloud auth application-default login` (Admin SDK ADC) + the three
// staging Web-config env vars (pull them from toska/GoogleService-Info-Staging.plist).

import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword, signOut, connectAuthEmulator } from "firebase/auth";
import {
  getFirestore, doc, getDoc, setDoc, updateDoc, deleteDoc,
  collection, serverTimestamp,
  connectFirestoreEmulator,
} from "firebase/firestore";

const PROJECT_ID = "toskastaging";
const KEEP = !process.argv.includes("--clean");

// Refuse to run anywhere but staging.
const envProject = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
if (envProject && envProject !== PROJECT_ID) {
  console.error(`REFUSING: GCLOUD_PROJECT="${envProject}" — this script is staging-only.`);
  process.exit(1);
}
const WEB_API_KEY = process.env.TOSKA_STAGING_WEB_API_KEY;
const WEB_APP_ID = process.env.TOSKA_STAGING_APP_ID;
const WEB_SENDER_ID = process.env.TOSKA_STAGING_SENDER_ID;
if (!WEB_API_KEY || !WEB_APP_ID || !WEB_SENDER_ID) {
  console.error("Missing TOSKA_STAGING_WEB_API_KEY / _APP_ID / _SENDER_ID env vars.");
  process.exit(1);
}

const ACCT = {
  A: { email: "toska-tester-a@example.com", pw: "ToskaTest!A1", handle: "tester_alpha" },
  B: { email: "toska-tester-b@example.com", pw: "ToskaTest!B2", handle: "tester_bravo" },
};

admin.initializeApp({ projectId: PROJECT_ID });
const adminAuth = admin.auth();
const adminDb = admin.firestore();
const FV = admin.firestore.FieldValue;

function webApp(name) {
  const app = initializeApp({
    apiKey: WEB_API_KEY, authDomain: `${PROJECT_ID}.firebaseapp.com`,
    projectId: PROJECT_ID, appId: WEB_APP_ID, messagingSenderId: WEB_SENDER_ID,
  }, name);
  const auth = getAuth(app), db = getFirestore(app);
  // Web SDK doesn't auto-read emulator env vars (only firebase-admin does) —
  // without these, emulators:exec runs silently hit REAL staging. No-op live.
  if (process.env.FIREBASE_AUTH_EMULATOR_HOST) connectAuthEmulator(auth, `http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}`, { disableWarnings: true });
  if (process.env.FIRESTORE_EMULATOR_HOST) { const [h, p] = process.env.FIRESTORE_EMULATOR_HOST.split(":"); connectFirestoreEmulator(db, h, Number(p)); }
  return { auth, db };
}

// ---- result tracking ----
const results = [];
function rec(ok, name, detail = "") {
  results.push({ ok, name, detail });
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? "  — " + detail : ""}`);
}
// positive: expect the promise to resolve
async function expectOk(name, fn) {
  try { await fn(); rec(true, name); } catch (e) { rec(false, name, e.code || e.message); }
}
// negative: expect a permission-denied
async function expectDenied(name, fn) {
  try { await fn(); rec(false, name, "WRITE/READ WAS ALLOWED (should be denied)"); }
  catch (e) { rec(e.code === "permission-denied", name, e.code === "permission-denied" ? "" : e.code || e.message); }
}
// informational probe: reports allowed/denied without counting as pass/fail
async function probe(name, fn) {
  try { await fn(); console.log(`• ${name}: ALLOWED (known low gap)`); }
  catch (e) { console.log(`• ${name}: denied (${e.code || "ok"})`); }
}
// poll until predicate true (for async triggers)
async function waitFor(name, predicate, timeoutMs = 20000, every = 1500) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try { if (await predicate()) { rec(true, name); return; } } catch {}
    await new Promise(r => setTimeout(r, every));
  }
  rec(false, name, `timed out after ${timeoutMs}ms`);
}

async function resetAccount(a) {
  try { const u = await adminAuth.getUserByEmail(a.email); await adminAuth.deleteUser(u.uid); } catch {}
}
async function createAccount(a) {
  const u = await adminAuth.createUser({ email: a.email, password: a.pw, emailVerified: true });
  await adminDb.doc(`users/${u.uid}`).set({
    handle: a.handle, followerCount: 0, followingCount: 0, totalLikes: 0, postCount: 0,
    allowSharing: true, showFollowerCount: true, hasCompletedOnboarding: true,
    acceptedPolicyVersion: 1, acceptedPolicyAt: FV.serverTimestamp(),
    confirmedAdult: true, confirmedAdultAt: FV.serverTimestamp(), createdAt: FV.serverTimestamp(),
  });
  // private subcollection (to test owner-only read)
  await adminDb.doc(`users/${u.uid}/private/data`).set({ email: a.email, selectedMood: "numb" });
  return u.uid;
}

let A, B, sessA, sessB;
const ids = {};

try {
  console.log("=== SETUP: fresh staging accounts A + B ===");
  await resetAccount(ACCT.A); await resetAccount(ACCT.B);
  A = await createAccount(ACCT.A); B = await createAccount(ACCT.B);
  console.log(`A(${ACCT.handle ?? ACCT.A.handle})=${A}\nB=${B}`);
  sessA = webApp("A"); sessB = webApp("B");
  await signInWithEmailAndPassword(sessA.auth, ACCT.A.email, ACCT.A.pw);
  await signInWithEmailAndPassword(sessB.auth, ACCT.B.email, ACCT.B.pw);
  console.log("both signed in via client SDK\n");

  console.log("=== FUNCTIONALITY ===");
  // A creates a clean post (start hidden → validatePost promotes to live)
  ids.postA = `e2e_${Date.now()}_A`;
  await expectOk("A creates a clean post", () => setDoc(doc(sessA.db, "posts", ids.postA), {
    authorId: A, authorHandle: ACCT.A.handle, text: "first light, honestly", createdAt: serverTimestamp(),
    likeCount: 0, repostCount: 0, replyCount: 0, tag: "numb", moderationStatus: "pending_validation",
  }));
  await waitFor("validatePost promotes A's clean post → live",
    async () => (await adminDb.doc(`posts/${ids.postA}`).get()).get("moderationStatus") === "live");

  // B replies (clean) → should go live
  ids.replyClean = `e2e_reply_clean_${Date.now()}`;
  await expectOk("B replies to A (clean)", () => setDoc(doc(sessB.db, `posts/${ids.postA}/replies`, ids.replyClean), {
    authorId: B, authorHandle: ACCT.B.handle, text: "sending you quiet strength", createdAt: serverTimestamp(), likeCount: 0,
  }));
  await waitFor("B's clean reply promoted → live",
    async () => (await adminDb.doc(`posts/${ids.postA}/replies/${ids.replyClean}`).get()).get("moderationStatus") === "live");

  // B replies with PII → must be HELD (pending_review) by validateReply (M-1)
  ids.replyPII = `e2e_reply_pii_${Date.now()}`;
  await expectOk("B posts a PII reply (write accepted at rules layer)", () => setDoc(doc(sessB.db, `posts/${ids.postA}/replies`, ids.replyPII), {
    authorId: B, authorHandle: ACCT.B.handle, text: "my ex Sarah Johnson did this too", createdAt: serverTimestamp(), likeCount: 0,
  }));
  await waitFor("M-1: PII reply is HELD at pending_review (not deleted)",
    async () => {
      const s = await adminDb.doc(`posts/${ids.postA}/replies/${ids.replyPII}`).get();
      return s.exists && s.get("moderationStatus") === "pending_review";
    });

  // Counter: replyCount should reflect only the VISIBLE (live) reply, not the held one
  await waitFor("Counter: post.replyCount counts the live reply only (held excluded)",
    async () => (await adminDb.doc(`posts/${ids.postA}`).get()).get("replyCount") === 1);

  // A likes B's clean reply → reply likeCount++
  await expectOk("A likes B's clean reply", () => setDoc(doc(sessA.db, `posts/${ids.postA}/replies/${ids.replyClean}/likes`, A), { createdAt: serverTimestamp() }));
  await waitFor("Counter: clean reply likeCount → 1",
    async () => (await adminDb.doc(`posts/${ids.postA}/replies/${ids.replyClean}`).get()).get("likeCount") === 1);

  // B likes A's post → post likeCount++ AND A.totalLikes++
  await expectOk("B likes A's post", () => setDoc(doc(sessB.db, `posts/${ids.postA}/likes`, B), { createdAt: serverTimestamp() }));
  await waitFor("Counter: A's post likeCount → 1", async () => (await adminDb.doc(`posts/${ids.postA}`).get()).get("likeCount") === 1);
  await waitFor("Counter: A.totalLikes → 1", async () => (await adminDb.doc(`users/${A}`).get()).get("totalLikes") === 1);

  // A follows B → A.followingCount++, B.followerCount++
  await expectOk("A follows B", async () => {
    await setDoc(doc(sessA.db, `users/${A}/following`, B), { handle: ACCT.B.handle, createdAt: serverTimestamp() });
    await setDoc(doc(sessA.db, `users/${B}/followers`, A), { handle: ACCT.A.handle, createdAt: serverTimestamp() });
  });
  await waitFor("Counter: A.followingCount → 1", async () => (await adminDb.doc(`users/${A}`).get()).get("followingCount") === 1);
  await waitFor("Counter: B.followerCount → 1", async () => (await adminDb.doc(`users/${B}`).get()).get("followerCount") === 1);

  // A reposts B's post (first B needs a post)
  ids.postB = `e2e_${Date.now()}_B`;
  await expectOk("B creates a post (to be reposted)", () => setDoc(doc(sessB.db, "posts", ids.postB), {
    authorId: B, authorHandle: ACCT.B.handle, text: "the quiet after", createdAt: serverTimestamp(),
    likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "pending_validation",
  }));
  await waitFor("B's post → live", async () => (await adminDb.doc(`posts/${ids.postB}`).get()).get("moderationStatus") === "live");
  ids.repost = `${A}_repost_${ids.postB}`;
  await expectOk("A reposts B's post", () => setDoc(doc(sessA.db, "posts", ids.repost), {
    authorId: A, authorHandle: ACCT.A.handle, text: "the quiet after", createdAt: serverTimestamp(),
    likeCount: 0, repostCount: 0, replyCount: 0, isRepost: true,
    originalPostId: ids.postB, originalAuthorId: B, originalHandle: ACCT.B.handle, moderationStatus: "pending_validation",
  }));
  await waitFor("Counter: B's post repostCount → 1", async () => (await adminDb.doc(`posts/${ids.postB}`).get()).get("repostCount") === 1);

  // A saves B's post + a draft
  await expectOk("A saves B's post", () => setDoc(doc(sessA.db, `users/${A}/saved`, ids.postB), { createdAt: serverTimestamp() }));
  await expectOk("A creates a draft", () => setDoc(doc(sessA.db, `users/${A}/drafts`, `d_${Date.now()}`), { text: "what I can't say yet", createdAt: serverTimestamp() }));

  // A reports B's post
  await expectOk("A reports B's post", () => setDoc(doc(sessA.db, "reports", `e2e_report_${Date.now()}`), {
    reportedBy: A, reason: "other", reasonLabel: "test", type: "post", status: "pending",
    createdAt: serverTimestamp(), postId: ids.postB, reportedUserId: B, reportedHandle: ACCT.B.handle,
  }));

  console.log("\n=== SECURITY (adversarial — all must be DENIED) ===");
  await expectDenied("A cannot post AS B (forged authorId)", () => setDoc(doc(sessA.db, "posts", `evil_${Date.now()}`), {
    authorId: B, authorHandle: ACCT.B.handle, text: "forged", createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0,
  }));
  // Age-gate: a REAL change to confirmedAdult must be denied. Setting it to its
  // existing value isn't a diff, so strip it first to test the gate honestly.
  await adminDb.doc(`users/${A}`).update({ confirmedAdult: false });
  await new Promise(r => setTimeout(r, 800));
  await expectDenied("A cannot self-grant confirmedAdult (age-gate bypass)", () => updateDoc(doc(sessA.db, "users", A), { confirmedAdult: true }));
  await adminDb.doc(`users/${A}`).update({ confirmedAdult: true }); // restore so A stays usable
  // N-12 (informational, Low): the users-doc UPDATE rule has no hasOnly, so a
  // user CAN add arbitrary non-sensitive scratch fields to their own public
  // doc — same schema-lock class as R-1/N-1, but not rendered and not trusted
  // by any trigger. Probed (not counted as a security failure).
  await probe("[info N-12] arbitrary scratch field on own user doc", () => updateDoc(doc(sessA.db, "users", A), { e2eScratch: "x" }));
  await adminDb.doc(`users/${A}`).update({ e2eScratch: FV.delete() }).catch(()=>{});
  await expectDenied("A cannot inflate own followerCount", () => updateDoc(doc(sessA.db, "users", A), { followerCount: 9999 }));
  await expectDenied("A cannot self-unrestrict (write restricted)", () => updateDoc(doc(sessA.db, "users", A), { restricted: false }));
  await expectDenied("A cannot read B's /private PII", () => getDoc(doc(sessA.db, `users/${B}/private/data`)));
  await expectDenied("A cannot self-publish moderationStatus=live at create", () => setDoc(doc(sessA.db, "posts", `evil2_${Date.now()}`), {
    authorId: A, authorHandle: ACCT.A.handle, text: "sneaky live", createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "live",
  }));
  await expectDenied("A cannot forge a 'follow' notification into B (no real follower proof beyond A→B already exists, use like w/o like-doc)", () =>
    setDoc(doc(sessA.db, `users/${B}/notifications`, `like_${ids.postB}_${A}`), {
      type: "like", fromUserId: A, postId: ids.postB, isRead: false, createdAt: serverTimestamp(),
    }));
  // N-1: reply-update byline spoof on A's OWN reply — first A makes a reply, then tries to spoof authorHandle
  ids.replyA = `e2e_reply_A_${Date.now()}`;
  await expectOk("A creates own reply (for N-1 test)", () => setDoc(doc(sessA.db, `posts/${ids.postB}/replies`, ids.replyA), {
    authorId: A, authorHandle: ACCT.A.handle, text: "with you", createdAt: serverTimestamp(), likeCount: 0,
  }));
  await expectDenied("N-1: A cannot spoof authorHandle via reply update", () =>
    updateDoc(doc(sessA.db, `posts/${ids.postB}/replies/${ids.replyA}`), { text: "with you", authorHandle: ACCT.B.handle }));
  await expectDenied("N-1: A cannot inject scratch field via reply update", () =>
    updateDoc(doc(sessA.db, `posts/${ids.postB}/replies/${ids.replyA}`), { text: "with you", trustedByAdmin: true }));
  await expectDenied("A cannot read admins/{B}", () => getDoc(doc(sessA.db, "admins", B)));
  await expectDenied("A cannot read adminAuditLog", () => getDoc(doc(sessA.db, "adminAuditLog", "anything")));

  // Block: B blocks A (via admin setup), then A's like on B's post must be denied
  await adminDb.doc(`users/${B}/blocked/${A}`).set({ handle: ACCT.A.handle, createdAt: FV.serverTimestamp() });
  await new Promise(r => setTimeout(r, 1500));
  await expectDenied("Block: A (blocked by B) cannot like B's post", () => setDoc(doc(sessA.db, `posts/${ids.postB}/likes`, A), { createdAt: serverTimestamp() }));
  await expectDenied("Block: A (blocked by B) cannot reply to B's post", () => setDoc(doc(sessA.db, `posts/${ids.postB}/replies`, `blk_${Date.now()}`), {
    authorId: A, authorHandle: ACCT.A.handle, text: "blocked attempt", createdAt: serverTimestamp(), likeCount: 0,
  }));
  await adminDb.doc(`users/${B}/blocked/${A}`).delete(); // lift block so account A stays usable

  // ---- summary ----
  const pass = results.filter(r => r.ok).length, fail = results.length - pass;
  console.log(`\n=== SUMMARY: ${pass}/${results.length} passed, ${fail} failed ===`);
  if (fail) results.filter(r => !r.ok).forEach(r => console.log(`  ✗ ${r.name} — ${r.detail}`));

  await signOut(sessA.auth).catch(()=>{}); await signOut(sessB.auth).catch(()=>{});

  if (KEEP) {
    console.log(`\nLEFT PERSISTENT for simulator login (Debug build → staging):`);
    console.log(`   A:  ${ACCT.A.email}  /  ${ACCT.A.pw}   (handle @${ACCT.A.handle})`);
    console.log(`   B:  ${ACCT.B.email}  /  ${ACCT.B.pw}   (handle @${ACCT.B.handle})`);
    console.log(`   Account A has: a live post, a live + a HELD reply on it, likes, a follow of B, a repost, a save, a draft, a report.`);
    console.log(`   Re-run to reset; pass --clean to delete both accounts.`);
  } else {
    console.log("\nCleaning up (--clean)…");
    for (const id of [ids.postA, ids.postB, ids.repost]) { try { await adminDb.recursiveDelete(adminDb.doc(`posts/${id}`)); } catch {} }
    await resetAccount(ACCT.A); await resetAccount(ACCT.B);
    console.log("removed both accounts + their content.");
  }
  process.exit(fail ? 2 : 0);
} catch (e) {
  console.error("\nFATAL:", e.stack || e.message);
  process.exit(1);
}
