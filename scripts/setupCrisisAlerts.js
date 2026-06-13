// Seed + verify the PROD crisis-alert pipeline.
//
//   system/crisisAlertRecipients   { uids: [<adminUid>, ...] }
//
// onPostCreatedAlertAdmins (functions/index.js) reads this doc, then for each
// uid reads users/{uid}/private/data.fcmToken and pushes a neutral "crisis
// post" alert. If the doc is absent it falls back to a baked-in admin uid; if
// NO recipient has an fcmToken, the alert SILENTLY DROPS. This script seeds the
// doc AND reports, per recipient, whether a delivery token exists — so we know
// alerts will actually arrive, not just that the config is present.
//
// Usage:
//   node scripts/setupCrisisAlerts.js
//
// Requires gcloud application-default credentials against prod. If it errors
// with an auth message, run `gcloud auth application-default login` once, then
// re-run. Idempotent (uses .set() with merge-safe data).

const admin = require("firebase-admin");
admin.initializeApp({ projectId: "toska-4ebf4" });
const db = admin.firestore();

// Recipients for prod crisis alerts. Default: the prod admin (salinarotess@
// gmail.com). Add more uids here (or edit the Firestore doc directly later —
// no redeploy needed) to page additional people.
const RECIPIENT_UIDS = ["alcxPIqLQZcTIwF5wjJMkK1yPlW2"];

(async () => {
  try {
    await db.collection("system").doc("crisisAlertRecipients").set({
      uids: RECIPIENT_UIDS,
    });
    console.log(`✔ seeded system/crisisAlertRecipients = { uids: [${RECIPIENT_UIDS.join(", ")}] }`);

    console.log("\n— verifying delivery-readiness (fcmToken per recipient) —");
    let deliverable = 0;
    for (const uid of RECIPIENT_UIDS) {
      const priv = await db.collection("users").doc(uid).collection("private").doc("data").get();
      const token = priv.data()?.fcmToken;
      const hasToken = typeof token === "string" && token.length > 0;
      if (hasToken) deliverable++;
      console.log(`  ${hasToken ? "✔" : "✖"} ${uid}  ${hasToken ? "fcmToken present" : "NO fcmToken — alerts to this uid will DROP"}`);
    }

    // How many concerning posts currently sit unreviewed (context for the admin).
    const concerning = await db.collection("posts").where("concerningContent", "==", true).count().get();
    console.log(`\nℹ ${concerning.data().count} post(s) currently flagged concerningContent (prod).`);

    if (deliverable === 0) {
      console.log("\n⚠ NO recipient has an fcmToken — crisis pushes will be configured but undeliverable.");
      console.log("  Fix: sign in to the iOS app as the admin on a real device with notifications");
      console.log("  ENABLED (grants APNs token → users/{uid}/private/data.fcmToken), then re-run to confirm.");
      process.exit(0);
    }

    console.log(`\n✔ ${deliverable}/${RECIPIENT_UIDS.length} recipient(s) deliverable. Crisis-alert pipeline is live.`);
    process.exit(0);
  } catch (err) {
    console.error("\n✖ failed:", err.message);
    if (/credential|auth|UNAUTHENTICATED|default/i.test(err.message)) {
      console.error("\nThis looks like an auth error. Run once:");
      console.error("  gcloud auth application-default login");
      console.error("Then re-run: node scripts/setupCrisisAlerts.js");
    }
    process.exit(1);
  }
})();
