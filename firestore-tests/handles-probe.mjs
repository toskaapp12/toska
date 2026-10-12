// LIVE STAGING probe — handle-availability read paths (task 3 design input).
// As a NON-ADMIN client: (1) is the iOS pre-check query users.where(handle==x)
// allowed or denied? (2) is getDoc(handles/x) allowed (the F1 directory leak)?
// Self-cleaning; Admin SDK seeds a target handle row.
import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword } from "firebase/auth";
import { getFirestore, doc, getDoc, getDocs, collection, query, where, limit } from "firebase/firestore";

const PROJECT_ID = "toskastaging";
admin.initializeApp({ projectId: PROJECT_ID });
const adminDb = admin.firestore();

const webApp = initializeApp({
  apiKey: process.env.TOSKA_STAGING_WEB_API_KEY, authDomain: `${PROJECT_ID}.firebaseapp.com`,
  projectId: PROJECT_ID, appId: process.env.TOSKA_STAGING_APP_ID,
  messagingSenderId: process.env.TOSKA_STAGING_SENDER_ID,
});
const webDb = getFirestore(webApp);

const stamp = Date.now();
const targetHandle = `probe_target_${stamp}`;
const targetUid = `probe_uid_${stamp}`;

try {
  const cred = await signInWithEmailAndPassword(getAuth(webApp),
    process.env.TOSKA_STAGING_EMAIL, process.env.TOSKA_STAGING_PW);
  console.log("signed in:", cred.user.uid.slice(0, 6));

  await adminDb.collection("handles").doc(targetHandle).set({ uid: targetUid });
  await adminDb.collection("users").doc(targetUid).set({ handle: targetHandle, followerCount: 0 });

  // 1. iOS pre-check shape
  try {
    const s = await getDocs(query(collection(webDb, "users"), where("handle", "==", targetHandle), limit(1)));
    console.log("users.where(handle==x): ALLOWED, docs:", s.size, s.size ? "uid=" + s.docs[0].id : "");
  } catch (e) { console.log("users.where(handle==x): DENIED", e.code); }

  // 2. handles point-get (the F1 vector)
  try {
    const s = await getDoc(doc(webDb, "handles", targetHandle));
    console.log("getDoc(handles/x): ALLOWED, exists:", s.exists(), s.exists() ? "uid=" + s.data().uid : "");
  } catch (e) { console.log("getDoc(handles/x): DENIED", e.code); }
} finally {
  await adminDb.collection("handles").doc(targetHandle).delete().catch(() => {});
  await adminDb.collection("users").doc(targetUid).delete().catch(() => {});
  process.exit(0);
}
