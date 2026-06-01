// One-off script to seed prod admin Firestore docs:
//   admins/{uid}                     { role: "admin" }
//   system/crisisAlertRecipients     { uids: [uid] }
//
// Usage:
//   node scripts/setupProdAdmin.js
//
// Requires gcloud application-default credentials. If this errors with an
// auth message, run `gcloud auth application-default login` once, then
// re-run this script.
//
// Safe to re-run (uses .set() with the same data — idempotent).

const admin = require("firebase-admin");
admin.initializeApp({
  projectId: "toska-4ebf4",
});

const db = admin.firestore();
const ADMIN_UID = "alcxPIqLQZcTIwF5wjJMkK1yPlW2";

(async () => {
  try {
    await db.collection("admins").doc(ADMIN_UID).set({ role: "admin" });
    console.log(`✔ admins/${ADMIN_UID} set role=admin`);

    await db.collection("system").doc("crisisAlertRecipients").set({
      uids: [ADMIN_UID],
    });
    console.log(`✔ system/crisisAlertRecipients set uids=[${ADMIN_UID}]`);

    console.log("\nDone. You can now sign in to https://www.toskaapp.com/admin");
    process.exit(0);
  } catch (err) {
    console.error("\n✖ setup failed:", err.message);
    console.error("\nIf this is an auth error, run:");
    console.error("  gcloud auth application-default login");
    console.error("Then re-run this script.");
    process.exit(1);
  }
})();
