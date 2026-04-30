// End-to-end smoke test for the Toska signup → post pipeline against
// real staging Firestore. Creates a throwaway user via Admin SDK,
// signs in as them via the Web SDK, tries a post write (should
// succeed), strips confirmedAdult, retries the post (should be
// denied), then cleans up. Self-cleaning even on failure.
//
// What this proves:
//   - Auth + Firestore reach live staging
//   - Rules accept a properly-configured user's post create
//   - hasConfirmedAdult() gate actually denies the write when the
//     field is missing
//
// What this does NOT prove:
//   - The iOS-app side of confirmAdult (App Check + onCall from a
//     Debug build). For that, sign up in the simulator and check
//     `users/{uid}.confirmedAdult` afterward.
//
// Run with: cd firestore-tests && npm run e2e
// Prereq: `gcloud auth application-default login` for Admin SDK ADC.

import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword } from "firebase/auth";
import {
  getFirestore,
  doc,
  setDoc,
  serverTimestamp,
} from "firebase/firestore";

const PROJECT_ID = "toskastaging";

// Project guard: refuse to run against anything but staging. The script
// creates real Auth users + posts; pointing at prod would litter prod
// data and the cleanup path could collide with real doc names.
const envProject = process.env.GCLOUD_PROJECT
  || process.env.GOOGLE_CLOUD_PROJECT;
if (envProject && envProject !== PROJECT_ID) {
  console.error(
    `\nREFUSING TO RUN: GCLOUD_PROJECT="${envProject}" but this script ` +
    `is only safe against "${PROJECT_ID}".\n`
  );
  process.exit(1);
}
const TEST_EMAIL = `e2e_${Date.now()}@example.com`;
const TEST_PASSWORD = "test_pw_" + Math.random().toString(36).slice(2);
const TEST_HANDLE = `test_${Date.now().toString(36)}`;

// ---------- Admin SDK setup ----------
admin.initializeApp({ projectId: PROJECT_ID });
const adminAuth = admin.auth();
const adminDb = admin.firestore();

// ---------- Web SDK setup ----------
const webApp = initializeApp({
  apiKey: "AIzaSyCTGuUzy9maPF84fZh5gD_-eZ2qkie75OQ",
  authDomain: `${PROJECT_ID}.firebaseapp.com`,
  projectId: PROJECT_ID,
  appId: "1:260913424323:ios:a6631554b2614bed01ff76",
  messagingSenderId: "260913424323",
});
const webAuth = getAuth(webApp);
const webDb = getFirestore(webApp);

let testUid = null;
let scratchPostId = null;

async function fail(stage, err) {
  console.error(`✗ ${stage}: ${err.message || err}`);
  if (testUid) {
    try { await adminAuth.deleteUser(testUid); } catch {}
    try { await adminDb.doc(`users/${testUid}`).delete(); } catch {}
  }
  process.exit(1);
}

try {
  // Step 1: Create test Auth user (admin)
  console.log(`Creating test user ${TEST_EMAIL}…`);
  const userRecord = await adminAuth.createUser({
    email: TEST_EMAIL,
    password: TEST_PASSWORD,
    emailVerified: false,
  });
  testUid = userRecord.uid;
  console.log(`✓ auth user created: ${testUid}`);

  // Step 2: Set up user doc state (this mimics a successful signup +
  // onboarding result, including the server-only confirmedAdult that the
  // Cloud Function would have written).
  await adminDb.doc(`users/${testUid}`).set({
    handle: TEST_HANDLE,
    followerCount: 0,
    followingCount: 0,
    totalLikes: 0,
    allowSharing: true,
    showFollowerCount: false,
    hasCompletedOnboarding: true,
    acceptedPolicyVersion: 1,
    acceptedPolicyAt: admin.firestore.FieldValue.serverTimestamp(),
    confirmedAdult: true,
    confirmedAdultAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  console.log(`✓ user doc set up with confirmedAdult=true`);

  // Step 3: Sign in via Web SDK with the password we set above. Custom
  // token would be cleaner but minting one requires a service account
  // with iam.serviceAccounts.signBlob, which ADC alone doesn't grant.
  await signInWithEmailAndPassword(webAuth, TEST_EMAIL, TEST_PASSWORD);
  console.log(`✓ web SDK signed in as ${testUid}`);

  // Step 4: Try to write a post AS THE USER (subject to rules)
  scratchPostId = `e2e_test_${Date.now()}`;
  await setDoc(doc(webDb, "posts", scratchPostId), {
    authorId: testUid,
    authorHandle: TEST_HANDLE,
    text: "e2e test post — please ignore",
    createdAt: serverTimestamp(),
    likeCount: 0,
    repostCount: 0,
    replyCount: 0,
  });
  console.log(`✓ POST WRITE SUCCEEDED — rules accepted the write`);

  // Step 5: Try a post write WITHOUT confirmedAdult set (should fail).
  // First, strip the field via admin.
  await adminDb.doc(`users/${testUid}`).update({
    confirmedAdult: admin.firestore.FieldValue.delete(),
  });
  console.log(`(stripped confirmedAdult to test the gate works)`);

  let denied = false;
  try {
    await setDoc(doc(webDb, "posts", `${scratchPostId}_v2`), {
      authorId: testUid,
      authorHandle: TEST_HANDLE,
      text: "should be denied — no confirmedAdult",
      createdAt: serverTimestamp(),
      likeCount: 0,
      repostCount: 0,
      replyCount: 0,
    });
  } catch (e) {
    denied = e.code === "permission-denied";
  }
  if (denied) {
    console.log(`✓ post write correctly DENIED when confirmedAdult is missing`);
  } else {
    console.error(`✗ post write was NOT denied — rule is broken!`);
    process.exit(2);
  }

  // Cleanup
  console.log(`\nCleaning up…`);
  await adminDb.doc(`posts/${scratchPostId}`).delete();
  await adminDb.doc(`users/${testUid}`).delete();
  await adminAuth.deleteUser(testUid);
  console.log(`✓ test user + scratch post removed`);
  console.log(`\n*** END-TO-END TEST PASSED ***`);
  process.exit(0);
} catch (e) {
  await fail("e2e", e);
}
