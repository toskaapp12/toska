// Delete ALL throwaway test accounts created during the full-app-test pass on
// STAGING: Auth users with test-pattern @example.com emails + their users/{uid}
// doc, private subcollection, and handles/{handle} claim. Run from functions/.
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getAuth } from "firebase-admin/auth";
initializeApp({ projectId: "toskastaging" });
const db = getFirestore(), auth = getAuth();
const TEST = /^(pw7_|ftc_|ft_c_|short_|adult_|ft_a_|ft_b_|ftc2_|ftsignin_|ftclean_)/i;

let deleted = 0, pageToken;
do {
  const res = await auth.listUsers(1000, pageToken);
  for (const u of res.users) {
    const email = (u.email || "").toLowerCase();
    if (!(email.endsWith("@example.com") && TEST.test(email))) continue;
    // Firestore user doc + handle + private
    try {
      const snap = await db.collection("users").doc(u.uid).get();
      const handle = snap.exists ? snap.data().handle : null;
      await db.recursiveDelete(db.collection("users").doc(u.uid));
      if (handle) await db.collection("handles").doc(String(handle).toLowerCase()).delete().catch(() => {});
    } catch {}
    await auth.deleteUser(u.uid).catch(() => {});
    console.log("deleted " + email + " (" + u.uid + ")");
    deleted++;
  }
  pageToken = res.pageToken;
} while (pageToken);
console.log("RESULT deleted " + deleted + " test accounts");

// Crisis-safety sweep: delete any undeliveredCrisisPages records left by test
// crisis posts (keyed crisisAlert_<testPostId>). Staging has no real crisis
// recipients, so an unclaimed record trips the crisisDeliveryWatchdog ~15min
// later (the 2026-10-27 false alarm). Also clears the matching alert claim.
const TESTPOST = /crisisAlert_(ftpost_|ft_a_|ft_b_|probePost|fulltest|hfmt_|pwmsg_)/i;
const recs = await db.collection("undeliveredCrisisPages").get();
let crisisDel = 0;
for (const d of recs.docs) {
  if (TESTPOST.test(d.id)) {
    await d.ref.delete().catch(() => {});
    await db.collection("processedTriggerEvents").doc(d.id).delete().catch(() => {});
    crisisDel++;
  }
}
console.log("RESULT deleted " + crisisDel + " test crisis records (undeliveredCrisisPages)");
