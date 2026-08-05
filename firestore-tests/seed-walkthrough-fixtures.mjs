// Seed the WalkthroughUITests feed fixtures on STAGING, idempotently.
//
// WHY: test03/test05/test14 need a stable, findable post containing
// "first light, honestly" in the for-you feed. It MUST be authored by a
// DIFFERENT account than the test runner (+nice/A), because test05 likes it
// and test14 reports it — both are blocked on your own post (self-like guard,
// report hidden on own-post). It must also be FRESH each run so feed drift
// (staging accumulates live posts) doesn't push it below the tests' bounded
// scroll-search. This script re-seeds it fresh, as actor B, with a fixed doc id
// (idempotent — overwrites in place, so it never proliferates) and waits for
// validatePost to promote it live before returning.
//
// RUN before the walkthrough suite:
//   cd firestore-tests && node seed-walkthrough-fixtures.mjs
//
// (test13's "refrigerator hum" fixture is self-composed by that test via the
// app UI on the author's own profile, so it needs no external seed.)
import { initializeApp } from 'firebase/app';
import { getAuth, signInWithEmailAndPassword } from 'firebase/auth';
import { getFirestore, doc, setDoc, getDoc, deleteDoc, serverTimestamp } from 'firebase/firestore';

const CFG = { apiKey: 'AIzaSyCTGuUzy9maPF84fZh5gD_-eZ2qkie75OQ', authDomain: 'toskastaging.firebaseapp.com', projectId: 'toskastaging' };
const B_EMAIL = 'salinarotess+webv1rb70g8@gmail.com';
// Never hardcode this (2026-07-22 GitGuardian leak). Current value lives in
// ~/Desktop/toska/.local-credentials.md (gitignored).
const B_PASS = process.env.TOSKA_STAGING_TEST_PW_B;
if (!B_PASS) { console.error('set TOSKA_STAGING_TEST_PW_B (see .local-credentials.md)'); process.exit(1); }
const FIXTURE_ID = 'wt_fixture_firstlight';
const FIXTURE_TEXT = 'first light, honestly';

const app = initializeApp(CFG, 'seed');
const db = getFirestore(app), auth = getAuth(app);
await signInWithEmailAndPassword(auth, B_EMAIL, B_PASS);
const uid = auth.currentUser.uid;
const usnap = await getDoc(doc(db, 'users', uid));
if (!usnap.exists() || usnap.data().confirmedAdult !== true) {
  console.error('FIXTURE SEED BLOCKED: account B is not confirmedAdult on staging — the post-create rule will deny. Set users/' + uid + '.confirmedAdult=true first.');
  process.exit(1);
}
const handle = usnap.data().handle;
// Delete any previous fixture first (2026-08-05). This used to be a bare
// setDoc described as "overwrites in place" — but when the doc already exists
// that is an UPDATE, and the posts update rule limits an author to
// ['text','editedAt'], so re-seeding failed with PERMISSION_DENIED from the
// second run onward (silently leaving a stale, buried fixture and failing
// test14 with "No post row found in feed"). Authors may delete their own post,
// so delete-then-create gives the fresh createdAt the tests need.
await deleteDoc(doc(db, 'posts', FIXTURE_ID)).catch(() => {});
await setDoc(doc(db, 'posts', FIXTURE_ID), {
  authorId: uid, authorHandle: handle, text: FIXTURE_TEXT,
  createdAt: serverTimestamp(), likeCount: 0, repostCount: 0, replyCount: 0,
  moderationStatus: 'pending_validation', isRepost: false, tag: 'numb',
});
const sleep = ms => new Promise(r => setTimeout(r, ms));
let live = false;
for (let i = 0; i < 15; i++) {
  const s = await getDoc(doc(db, 'posts', FIXTURE_ID));
  if (s.exists() && s.data().moderationStatus === 'live') { live = true; break; }
  await sleep(2000);
}
console.log(`walkthrough fixture "${FIXTURE_TEXT}" seeded as ${handle} (id=${FIXTURE_ID}) live=${live}`);
process.exit(live ? 0 : 2);
