// Inspect App Check enforcement status for Firestore + Auth on prod.
//
//   cd functions && node checkAppCheck.js
//
// CORRECTNESS NOTE (2026-06-09 re-review): the prior version of this script did
// NOT check res.ok and did NOT set a quota project. With user ADC the
// firebaseappcheck API returns 403 ("quota project not set") whose error body
// has no enforcementMode field — so `body.enforcementMode || "(unset)"` printed
// "(unset)" for EVERY service regardless of the real state. That false
// "(unset)" is what the 2026-06-08 audit (AC-1) read as "App Check OFF in
// prod" — when prod Firestore was in fact ENFORCED. Fixes: send
// `x-goog-user-project` so the API accepts the call, and throw on !res.ok so a
// failed request can never masquerade as "(unset)". See setAppCheck.js to view
// both projects / change enforcement.

const admin = require("firebase-admin");
const PROJECT = "toska-4ebf4";
admin.initializeApp({ projectId: PROJECT });

const SERVICES = [
  "firestore.googleapis.com",
  "identitytoolkit.googleapis.com", // Firebase Auth
];

(async () => {
  const token = (await admin.app().options.credential.getAccessToken()).access_token;
  for (const svc of SERVICES) {
    const url = `https://firebaseappcheck.googleapis.com/v1/projects/${PROJECT}/services/${svc}`;
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${token}`, "x-goog-user-project": PROJECT },
    });
    if (res.status === 404) {
      console.log(`${svc}: not configured (App Check off)`);
      continue;
    }
    const body = await res.json();
    if (!res.ok) {
      console.error(`${svc}: API error ${res.status} — ${JSON.stringify(body)}`);
      continue;
    }
    console.log(`${svc}: enforcementMode=${body.enforcementMode || "(unset)"}`);
  }
  process.exit(0);
})();
