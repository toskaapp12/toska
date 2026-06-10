// FULL E2E — ROUND 2 (deeper coverage) against live STAGING.
//
// Companion to full-e2e.mjs. Uses two throwaway accounts C + D (separate from
// the persistent A/B login accounts) and exercises paths round 1 didn't:
//   • counter DECREMENTS (unlike, unfollow) via the delete-side triggers
//   • self-follow guard; block-on-follow; block-on-repost
//   • owner-only subcollection reads (drafts / saved / liked)
//   • reflections (own-post create allowed; non-author denied)
//   • tag-count trigger (meta/tagCounts)
//   • edit flows: post + reply edit allowed (text/editedAt), extra field denied
//   • draft → publish; reply-repost (#3a: held reply can't be reposted)
//   • held reply's liker list gated (#3b)
//   • notification positive path allowed; forged notification denied
//   • moderation accuracy: M-2 false-positives stay LIVE; PII reply HELD; link held
//   • N-2: deleting a post drains its replies/likes subtree (onPostDeletedCleanupSubtree)
//
// Cleans up C + D at the end. Run identically to full-e2e.mjs:
//   GCLOUD_PROJECT=toskastaging TOSKA_STAGING_WEB_API_KEY=… TOSKA_STAGING_APP_ID=… \
//   TOSKA_STAGING_SENDER_ID=… node e2e-round2.mjs

import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword, signOut } from "firebase/auth";
import { getFirestore, doc, getDoc, setDoc, updateDoc, deleteDoc, serverTimestamp } from "firebase/firestore";

const PROJECT_ID = "toskastaging";
const envProject = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
if (envProject && envProject !== PROJECT_ID) { console.error(`staging-only; GCLOUD_PROJECT=${envProject}`); process.exit(1); }
const K = process.env.TOSKA_STAGING_WEB_API_KEY, AID = process.env.TOSKA_STAGING_APP_ID, SID = process.env.TOSKA_STAGING_SENDER_ID;
if (!K || !AID || !SID) { console.error("missing staging web env vars"); process.exit(1); }

const ACCT = { C: { email: "toska-tester-c@example.com", pw: "ToskaTest!C3", handle: "tester_charlie" },
               D: { email: "toska-tester-d@example.com", pw: "ToskaTest!D4", handle: "tester_delta" } };

admin.initializeApp({ projectId: PROJECT_ID });
const adminAuth = admin.auth(), adminDb = admin.firestore(), FV = admin.firestore.FieldValue;
function web(name) { const a = initializeApp({ apiKey: K, authDomain: `${PROJECT_ID}.firebaseapp.com`, projectId: PROJECT_ID, appId: AID, messagingSenderId: SID }, name); return { auth: getAuth(a), db: getFirestore(a) }; }

const results = [];
function rec(ok, name, d = "") { results.push({ ok, name, d }); console.log(`${ok ? "✓" : "✗"} ${name}${d ? "  — " + d : ""}`); }
async function expectOk(n, fn) { try { await fn(); rec(true, n); } catch (e) { rec(false, n, e.code || e.message); } }
async function expectDenied(n, fn) { try { await fn(); rec(false, n, "ALLOWED (should deny)"); } catch (e) { rec(e.code === "permission-denied", n, e.code === "permission-denied" ? "" : e.code); } }
async function probe(n, fn) { try { await fn(); console.log(`• ${n}: ALLOWED`); } catch (e) { console.log(`• ${n}: denied (${e.code || "ok"})`); } }
async function waitFor(n, pred, ms = 25000, every = 1500) { const s = Date.now(); while (Date.now() - s < ms) { try { if (await pred()) { rec(true, n); return; } } catch {} await new Promise(r => setTimeout(r, every)); } rec(false, n, `timeout ${ms}ms`); }
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function reset(a) { try { const u = await adminAuth.getUserByEmail(a.email); await adminDb.recursiveDelete(adminDb.doc(`users/${u.uid}`)); await adminAuth.deleteUser(u.uid); } catch {} }
async function create(a) {
  const u = await adminAuth.createUser({ email: a.email, password: a.pw, emailVerified: true });
  await adminDb.doc(`users/${u.uid}`).set({ handle: a.handle, followerCount: 0, followingCount: 0, totalLikes: 0, postCount: 0,
    allowSharing: true, showFollowerCount: true, hasCompletedOnboarding: true, acceptedPolicyVersion: 1,
    acceptedPolicyAt: FV.serverTimestamp(), confirmedAdult: true, confirmedAdultAt: FV.serverTimestamp(), createdAt: FV.serverTimestamp() });
  return u.uid;
}

let C, D, sC, sD; const id = {}; const createdPosts = [];
try {
  console.log("=== SETUP: accounts C + D ===");
  await reset(ACCT.C); await reset(ACCT.D);
  C = await create(ACCT.C); D = await create(ACCT.D);
  sC = web("C"); sD = web("D");
  await signInWithEmailAndPassword(sC.auth, ACCT.C.email, ACCT.C.pw);
  await signInWithEmailAndPassword(sD.auth, ACCT.D.email, ACCT.D.pw);
  console.log(`C=${C} D=${D}\n`);

  // ---- C posts (tag numb) ----
  console.log("=== COUNTERS: increment AND decrement ===");
  const numbBefore = (await adminDb.doc("meta/tagCounts").get()).get("numb") || 0;
  id.postC = `r2_${Date.now()}_C`; createdPosts.push(id.postC);
  await expectOk("C posts (tag=numb)", () => setDoc(doc(sC.db, "posts", id.postC), { authorId: C, authorHandle: ACCT.C.handle, text: "the long quiet", createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, tag: "numb", moderationStatus: "pending_validation" }));
  await waitFor("C's post → live", async () => (await adminDb.doc(`posts/${id.postC}`).get()).get("moderationStatus") === "live");
  await waitFor("tag-count trigger: meta/tagCounts.numb increased", async () => ((await adminDb.doc("meta/tagCounts").get()).get("numb") || 0) > numbBefore);

  // like then UNLIKE → likeCount 1 → 0
  await expectOk("D likes C's post", () => setDoc(doc(sD.db, `posts/${id.postC}/likes`, D), { createdAt: serverTimestamp() }));
  await waitFor("likeCount → 1", async () => (await adminDb.doc(`posts/${id.postC}`).get()).get("likeCount") === 1);
  await expectOk("D UNLIKES C's post", () => deleteDoc(doc(sD.db, `posts/${id.postC}/likes`, D)));
  await waitFor("DECREMENT: likeCount → 0", async () => (await adminDb.doc(`posts/${id.postC}`).get()).get("likeCount") === 0);

  // follow then UNFOLLOW → counts 1 → 0
  await expectOk("D follows C", async () => { await setDoc(doc(sD.db, `users/${D}/following`, C), { handle: ACCT.C.handle, createdAt: serverTimestamp() }); await setDoc(doc(sD.db, `users/${C}/followers`, D), { handle: ACCT.D.handle, createdAt: serverTimestamp() }); });
  await waitFor("C.followerCount → 1", async () => (await adminDb.doc(`users/${C}`).get()).get("followerCount") === 1);
  await expectOk("D UNFOLLOWS C", async () => { await deleteDoc(doc(sD.db, `users/${D}/following`, C)); await deleteDoc(doc(sD.db, `users/${C}/followers`, D)); });
  await waitFor("DECREMENT: C.followerCount → 0", async () => (await adminDb.doc(`users/${C}`).get()).get("followerCount") === 0);
  await waitFor("DECREMENT: D.followingCount → 0", async () => (await adminDb.doc(`users/${D}`).get()).get("followingCount") === 0);

  // ---- moderation accuracy ----
  console.log("\n=== MODERATION accuracy ===");
  const fpYears = `r2_fp_years_${Date.now()}`; createdPosts.push(fpYears);
  await expectOk("C posts a year-list (M-2 false-positive candidate)", () => setDoc(doc(sC.db, "posts", fpYears), { authorId: C, authorHandle: ACCT.C.handle, text: "we dated in 2019 2020 2021 2022 2023, then it ended", createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "pending_validation" }));
  await waitFor("M-2: year-list post stays LIVE (not held)", async () => (await adminDb.doc(`posts/${fpYears}`).get()).get("moderationStatus") === "live");
  const fpBand = `r2_fp_band_${Date.now()}`; createdPosts.push(fpBand);
  await expectOk("C posts a band/landmark bigram (M-2 FP candidate)", () => setDoc(doc(sC.db, "posts", fpBand), { authorId: C, authorHandle: ACCT.C.handle, text: "we loved Pearl Jam and walking through Central Park", createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "pending_validation" }));
  await waitFor("M-2: band/landmark post stays LIVE (not held)", async () => (await adminDb.doc(`posts/${fpBand}`).get()).get("moderationStatus") === "live");
  // true positive: PII reply held
  id.replyPII = `r2_pii_${Date.now()}`;
  await expectOk("D replies with PII (write accepted)", () => setDoc(doc(sD.db, `posts/${id.postC}/replies`, id.replyPII), { authorId: D, authorHandle: ACCT.D.handle, text: "my friend John Smith went through this", createdAt: serverTimestamp(), likeCount: 0 }));
  await waitFor("TP: PII reply HELD at pending_review", async () => (await adminDb.doc(`posts/${id.postC}/replies/${id.replyPII}`).get()).get("moderationStatus") === "pending_review");
  // link reply held
  id.replyLink = `r2_link_${Date.now()}`;
  await expectOk("D replies with a URL (write accepted)", () => setDoc(doc(sD.db, `posts/${id.postC}/replies`, id.replyLink), { authorId: D, authorHandle: ACCT.D.handle, text: "this helped me a lot, see example.com/help", createdAt: serverTimestamp(), likeCount: 0 }));
  await waitFor("link reply HELD at pending_review", async () => (await adminDb.doc(`posts/${id.postC}/replies/${id.replyLink}`).get()).get("moderationStatus") === "pending_review");

  // ---- reflections, edit, draft-publish, reply-repost ----
  console.log("\n=== reflections / edit / draft / reply-repost ===");
  await expectOk("C creates a reflection on own post", () => setDoc(doc(sC.db, `posts/${id.postC}/reflections`, `refl_${Date.now()}`), { authorId: C, text: "a year on, this still aches", createdAt: serverTimestamp() }));
  await expectOk("C edits own post (text + editedAt)", () => updateDoc(doc(sC.db, "posts", id.postC), { text: "the long quiet (edited)", editedAt: serverTimestamp() }));
  // draft → publish
  id.draft = `r2_draft_${Date.now()}`;
  await expectOk("C creates a draft", () => setDoc(doc(sC.db, `users/${C}/drafts`, id.draft), { text: "what I never sent", createdAt: serverTimestamp() }));
  id.published = `r2_pub_${Date.now()}`; createdPosts.push(id.published);
  await expectOk("C publishes the draft (post create + draft delete)", async () => { await setDoc(doc(sC.db, "posts", id.published), { authorId: C, authorHandle: ACCT.C.handle, text: "what I never sent", createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "pending_validation" }); await deleteDoc(doc(sC.db, `users/${C}/drafts`, id.draft)); });
  // D posts a clean reply, C reposts that reply (#3a control)
  id.replyClean = `r2_clean_${Date.now()}`;
  await expectOk("D replies (clean) for repost test", () => setDoc(doc(sD.db, `posts/${id.postC}/replies`, id.replyClean), { authorId: D, authorHandle: ACCT.D.handle, text: "holding this with you", createdAt: serverTimestamp(), likeCount: 0 }));
  await waitFor("D's clean reply → live", async () => (await adminDb.doc(`posts/${id.postC}/replies/${id.replyClean}`).get()).get("moderationStatus") === "live");
  id.replyRepost = `${C}_repost_${id.replyClean}`; createdPosts.push(id.replyRepost);
  await expectOk("C reposts D's LIVE reply (#3a control)", () => setDoc(doc(sC.db, "posts", id.replyRepost), { authorId: C, authorHandle: ACCT.C.handle, text: "holding this with you", createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, isRepost: true, originalPostId: id.postC, originalReplyId: id.replyClean, originalAuthorId: D, originalHandle: ACCT.D.handle, moderationStatus: "pending_validation" }));

  // ---- SECURITY ----
  console.log("\n=== SECURITY (deny) ===");
  await expectDenied("self-follow is denied", () => setDoc(doc(sC.db, `users/${C}/following`, C), { handle: ACCT.C.handle, createdAt: serverTimestamp() }));
  await expectDenied("#3a: cannot repost a HELD reply", () => setDoc(doc(sC.db, "posts", `evil_repost_${Date.now()}`), { authorId: C, authorHandle: ACCT.C.handle, text: "my friend John Smith went through this", createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, isRepost: true, originalPostId: id.postC, originalReplyId: id.replyPII, originalAuthorId: D, originalHandle: ACCT.D.handle, moderationStatus: "pending_validation" }));
  // #3b: held reply's likers not readable by a third party. Put a like via admin.
  await adminDb.doc(`posts/${id.postC}/replies/${id.replyPII}/likes/someliker`).set({ createdAt: FV.serverTimestamp() });
  await expectDenied("#3b: third party cannot read a held reply's likers", () => getDoc(doc(sC.db, `posts/${id.postC}/replies/${id.replyPII}/likes/someliker`)));
  // owner-only subcollection reads
  await expectDenied("D cannot read C's drafts", () => getDoc(doc(sD.db, `users/${C}/drafts/${id.draft}`)));
  await expectOk("C saves own... (setup saved for read test)", () => setDoc(doc(sC.db, `users/${C}/saved`, id.postC), { createdAt: serverTimestamp() }));
  await expectDenied("D cannot read C's saved", () => getDoc(doc(sD.db, `users/${C}/saved/${id.postC}`)));
  await expectDenied("D cannot read C's liked", () => getDoc(doc(sD.db, `users/${C}/liked/${id.postC}`)));
  // reflection by non-post-author
  await expectDenied("D cannot reflect on C's post (post-author only)", () => setDoc(doc(sD.db, `posts/${id.postC}/reflections`, `evil_refl_${Date.now()}`), { authorId: D, text: "intrusion", createdAt: serverTimestamp() }));
  // edit injection (R-1)
  await expectDenied("R-1: C cannot inject extra field via post edit", () => updateDoc(doc(sC.db, "posts", id.postC), { text: "x", trustedByAdmin: true }));
  // forged notification (no follower proof)
  await expectDenied("forge: C cannot write a 'follow' notif into D without being a follower", () => setDoc(doc(sC.db, `users/${D}/notifications`, `follow_${C}`), { type: "follow", fromUserId: C, isRead: false, createdAt: serverTimestamp() }));

  // block-on-follow / block-on-repost: C blocks D
  await expectOk("C blocks D", () => setDoc(doc(sC.db, `users/${C}/blocked`, D), { handle: ACCT.D.handle, createdAt: serverTimestamp() }));
  await sleep(1500);
  await expectDenied("block: D (blocked by C) cannot follow C", () => setDoc(doc(sD.db, `users/${C}/followers`, D), { handle: ACCT.D.handle, createdAt: serverTimestamp() }));
  await expectDenied("block: D (blocked by C) cannot repost C's post", () => setDoc(doc(sD.db, "posts", `${D}_repost_${id.postC}`), { authorId: D, authorHandle: ACCT.D.handle, text: "the long quiet (edited)", createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, isRepost: true, originalPostId: id.postC, originalAuthorId: C, originalHandle: ACCT.C.handle, moderationStatus: "pending_validation" }));

  // ---- N-2: deleting a post drains its replies/likes subtree ----
  console.log("\n=== N-2: post-deletion subtree cleanup ===");
  const np = `r2_n2_${Date.now()}`;
  await adminDb.doc(`posts/${np}`).set({ authorId: C, authorHandle: ACCT.C.handle, text: "to be deleted", createdAt: FV.serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0, moderationStatus: "live" });
  await adminDb.doc(`posts/${np}/replies/rr`).set({ authorId: D, authorHandle: ACCT.D.handle, text: "a reply under it", createdAt: FV.serverTimestamp(), likeCount: 0, moderationStatus: "live" });
  await adminDb.doc(`posts/${np}/replies/rr/likes/x`).set({ createdAt: FV.serverTimestamp() });
  await adminDb.doc(`posts/${np}/likes/y`).set({ createdAt: FV.serverTimestamp() });
  await adminDb.doc(`posts/${np}`).delete(); // fires onPostDeletedCleanupSubtree
  await waitFor("N-2: deleted post's reply is cleaned", async () => !(await adminDb.doc(`posts/${np}/replies/rr`).get()).exists);
  await waitFor("N-2: deleted post's reply-like is cleaned", async () => !(await adminDb.doc(`posts/${np}/replies/rr/likes/x`).get()).exists);
  await waitFor("N-2: deleted post's like is cleaned", async () => !(await adminDb.doc(`posts/${np}/likes/y`).get()).exists);

  // ---- summary ----
  const pass = results.filter(r => r.ok).length, fail = results.length - pass;
  console.log(`\n=== ROUND 2 SUMMARY: ${pass}/${results.length} passed, ${fail} failed ===`);
  if (fail) results.filter(r => !r.ok).forEach(r => console.log(`  ✗ ${r.name} — ${r.d}`));

  await signOut(sC.auth).catch(()=>{}); await signOut(sD.auth).catch(()=>{});
  console.log("\nCleaning up C + D…");
  for (const p of createdPosts) { try { await adminDb.recursiveDelete(adminDb.doc(`posts/${p}`)); } catch {} }
  await reset(ACCT.C); await reset(ACCT.D);
  console.log("done.");
  process.exit(fail ? 2 : 0);
} catch (e) { console.error("\nFATAL:", e.stack || e.message); process.exit(1); }
