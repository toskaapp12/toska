// One-off: look up salinarotess@gmail.com's prod UID and check whether
// admins/{uid} exists. Run from functions/ so firebase-admin resolves.
//
//   cd functions && node checkAdminUid.js
//
// Requires `gcloud auth application-default login` (same as setupProdAdmin.js).

const admin = require("firebase-admin");
admin.initializeApp({ projectId: "toska-4ebf4" });

const EMAIL = "salinarotess@gmail.com";

(async () => {
  try {
    const user = await admin.auth().getUserByEmail(EMAIL);
    console.log(`Auth UID for ${EMAIL}: ${user.uid}`);

    const adminDoc = await admin.firestore().collection("admins").doc(user.uid).get();
    console.log(`admins/${user.uid} exists: ${adminDoc.exists}`);
    if (adminDoc.exists) console.log(`  data:`, adminDoc.data());

    // Also check the UID we previously seeded
    const SEEDED = "alcxPIqLQZcTIwF5wjJMkK1yPlW2";
    if (user.uid !== SEEDED) {
      console.log(`\n⚠ Seeded UID (${SEEDED}) ≠ actual UID (${user.uid})`);
      const seededDoc = await admin.firestore().collection("admins").doc(SEEDED).get();
      console.log(`admins/${SEEDED} exists: ${seededDoc.exists}`);
    } else {
      console.log(`\n✔ Seeded UID matches actual UID.`);
    }
    process.exit(0);
  } catch (err) {
    console.error("\n✖ check failed:", err.message);
    process.exit(1);
  }
})();
