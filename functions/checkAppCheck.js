// Inspect App Check enforcement status for Firestore + Auth on prod.
//
//   cd functions && node checkAppCheck.js

const admin = require("firebase-admin");
admin.initializeApp({ projectId: "toska-4ebf4" });

const SERVICES = [
  "firestore.googleapis.com",
  "identitytoolkit.googleapis.com", // Firebase Auth
  "storage.googleapis.com",
];

(async () => {
  const token = (await admin.app().options.credential.getAccessToken()).access_token;
  for (const svc of SERVICES) {
    const url = `https://firebaseappcheck.googleapis.com/v1/projects/toska-4ebf4/services/${svc}`;
    const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    if (res.status === 404) {
      console.log(`${svc}: not configured (App Check off)`);
      continue;
    }
    const body = await res.json();
    console.log(`${svc}: enforcementMode=${body.enforcementMode || "(unset)"}`);
  }
  process.exit(0);
})();
