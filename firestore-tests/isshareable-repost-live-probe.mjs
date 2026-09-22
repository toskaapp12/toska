// LIVE-STAGING tampered-CLIENT probe for the reply-repost isShareable pin
// (firestore.rules:1058-1072). Unlike the *-live-probe.mjs scripts, this uses the
// CLIENT SDK signed in as a real non-admin user, so the DEPLOYED rules actually
// apply (Admin SDK bypasses them). Admin SDK is used ONLY to seed/read/cleanup.
// Staging Firestore App Check is UNENFORCED, so client writes need no App Check.
// Creds via env (never inline): SB_APIKEY, EB, PB, BUID, BHANDLE.
// Run from firestore-tests/ (module resolution). Self-cleaning.
import { initializeApp as adminInit, applicationDefault } from "firebase-admin/app";
import { getFirestore as adminFs, FieldValue } from "firebase-admin/firestore";
import { initializeApp as clientInit } from "firebase/app";
import { getAuth, signInWithEmailAndPassword } from "firebase/auth";
import { getFirestore, doc, setDoc, serverTimestamp } from "firebase/firestore";

const admin = adminFs(adminInit({ credential: applicationDefault(), projectId: "toskastaging" }));
const client = clientInit({ apiKey: process.env.SB_APIKEY, authDomain: "toskastaging.firebaseapp.com", projectId: "toskastaging" });
const cauth = getAuth(client);
await signInWithEmailAndPassword(cauth, process.env.EB, process.env.PB);
const cdb = getFirestore(client);
console.log("signed in as B uid=", cauth.currentUser.uid, "(expected", process.env.BUID + ")");

const PID = process.pid;
const AUTHOR = `probe_author_${PID}`;          // the reply author whose consent gates sharing
const POST = `probe_post_${PID}`;              // parent post
const REPLY = `probe_reply_${PID}`;            // the reply being reposted
const RTEXT = "a reply the author may or may not want shared";
const created = [];                            // repost doc ids that actually landed (cleanup)

async function seedAuthor(allowSharing) {
  await admin.collection("users").doc(AUTHOR).set({
    handle: `handle_${AUTHOR}`, followerCount: 0, followingCount: 0, totalLikes: 0,
    confirmedAdult: true, allowSharing,
  });
}
async function deleteAuthor() { await admin.collection("users").doc(AUTHOR).delete(); }

async function seedThread() {
  await admin.collection("posts").doc(POST).set({
    authorId: "probe_someone", authorHandle: "handle_probe_someone", text: "parent post",
    createdAt: FieldValue.serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0,
    moderationStatus: "live",
  });
  await admin.collection("posts").doc(POST).collection("replies").doc(REPLY).set({
    authorId: AUTHOR, authorHandle: `handle_${AUTHOR}`, text: RTEXT,
    createdAt: FieldValue.serverTimestamp(), likeCount: 0, moderationStatus: "live",
  });
}

function payload(isShareable) {
  const p = {
    authorId: process.env.BUID, authorHandle: process.env.BHANDLE, text: RTEXT,
    likeCount: 0, repostCount: 0, replyCount: 0,
    isRepost: true, originalPostId: POST, originalReplyId: REPLY, originalAuthorId: AUTHOR,
    createdAt: serverTimestamp(), moderationStatus: "pending_validation",
  };
  if (isShareable !== undefined) p.isShareable = isShareable;
  return p;
}

let pass = 0, fail = 0;
async function check(label, expectAllow, isShareable) {
  const id = `probe_rr_${PID}_${created.length}_${Math.floor(Math.random()*1e6)}`;
  let allowed;
  try { await setDoc(doc(cdb, "posts", id), payload(isShareable)); allowed = true; created.push(id); }
  catch (e) { allowed = false; if (!/PERMISSION_DENIED|Missing or insufficient/i.test(e.message)) { console.log("  (unexpected err:", e.message, ")"); } }
  const ok = allowed === expectAllow;
  ok ? pass++ : fail++;
  console.log(`${ok ? "✓" : "✗ FAIL"} ${label} => ${allowed ? "ALLOWED" : "DENIED"} (expected ${expectAllow ? "ALLOWED" : "DENIED"})`);
}

try {
  await seedThread();

  await seedAuthor(false); // author has OPTED OUT of sharing
  await check("author.allowSharing=false + isShareable=TRUE (overstate)", false, true);
  await check("author.allowSharing=false + isShareable=false (understate)", true, false);
  await check("author.allowSharing=false + isShareable OMITTED (defaults→consent needed)", false, undefined);

  await seedAuthor(true);  // author CONSENTS
  await check("author.allowSharing=true + isShareable=TRUE (consented)", true, true);

  await deleteAuthor();    // orphaned/deleted author
  await check("author DELETED + isShareable=TRUE (exists() guard)", false, true);
  await check("author DELETED + isShareable=false (understate, still repostable)", true, false);
} finally {
  // cleanup
  for (const id of created) { try { await admin.collection("posts").doc(id).delete(); } catch {} }
  try { await admin.collection("posts").doc(POST).collection("replies").doc(REPLY).delete(); } catch {}
  try { await admin.collection("posts").doc(POST).delete(); } catch {}
  try { await deleteAuthor(); } catch {}
  console.log(`\n${fail === 0 ? "PROBE PASS" : `PROBE FAIL (${fail})`} — ${pass}/${pass+fail}`);
  process.exit(fail === 0 ? 0 : 1);
}
