// Inspect OR set App Check enforcement (AC-1) for Firestore + Auth, on prod
// and/or staging. Companion to checkAppCheck.js, which is read-only on prod.
//
// enforcementMode lifecycle (the SAFE rollout — do NOT jump straight to
// ENFORCED on a project with live clients):
//   (unset)/OFF  → App Check ignored entirely (Toska today)
//   UNENFORCED   → tokens collected + verified/unverified METRICS gathered,
//                  but NOBODY is blocked. Zero lockout risk. Set this first,
//                  exercise the real iOS app (App Attest = REAL DEVICE, not
//                  simulator) + admin.html, then read the App Check dashboard
//                  and confirm verified ≈ 100% / unverified ≈ 0.
//   ENFORCED     → requests without a valid App Check token are REJECTED.
//                  Only flip here once UNENFORCED metrics are clean, or every
//                  direct Firestore read/write from a client whose token isn't
//                  validating breaks instantly.
//
// USAGE
//   Read-only check (default — both projects, all services):
//     cd functions && node setAppCheck.js
//
//   Set a mode (requires --apply; prod additionally requires --yes-prod):
//     node setAppCheck.js --project=toskastaging --mode=UNENFORCED --apply
//     node setAppCheck.js --project=toska-4ebf4  --mode=UNENFORCED --apply --yes-prod
//     node setAppCheck.js --project=toska-4ebf4  --mode=ENFORCED   --apply --yes-prod
//
// `storage` is intentionally NOT touched — Toska uses no Firebase Storage
// (no storage.rules, no FirebaseStorage in the iOS client), so enforcing it
// would be meaningless. It's shown read-only for completeness.

const admin = require("firebase-admin");

const PROD = "toska-4ebf4";
const STAGING = "toskastaging";
// Services we manage. identitytoolkit == Firebase Auth.
const MANAGED = ["firestore.googleapis.com", "identitytoolkit.googleapis.com"];
const READONLY_EXTRA = ["storage.googleapis.com"];
const VALID_MODES = ["OFF", "UNENFORCED", "ENFORCED"];

function arg(name) {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.split("=").slice(1).join("=") : undefined;
}
const HAS = (name) => process.argv.includes(`--${name}`);

const projectArg = arg("project");
const mode = (arg("mode") || "").toUpperCase();
const apply = HAS("apply");
const yesProd = HAS("yes-prod");

// One default app + ADC token, reused across projects (mirrors checkAppCheck.js).
// The firebaseappcheck API rejects user ADC unless a quota project is set, so
// each request carries `x-goog-user-project: <targetProject>` to bill quota to
// the Firebase project being queried (where the API is enabled).
let TOKEN;
async function token() {
  if (!TOKEN) {
    admin.initializeApp({ projectId: PROD });
    TOKEN = (await admin.app().options.credential.getAccessToken()).access_token;
  }
  return TOKEN;
}
function headers(projectId, json = false) {
  const h = {
    Authorization: `Bearer ${TOKEN}`,
    "x-goog-user-project": projectId,
  };
  if (json) h["Content-Type"] = "application/json";
  return h;
}

async function getMode(projectId, svc) {
  await token();
  const url = `https://firebaseappcheck.googleapis.com/v1/projects/${projectId}/services/${svc}`;
  const res = await fetch(url, { headers: headers(projectId) });
  if (res.status === 404) return "(unset)";
  const body = await res.json();
  if (!res.ok) throw new Error(`GET ${svc}: ${res.status} ${JSON.stringify(body)}`);
  return body.enforcementMode || "(unset)";
}

async function setMode(projectId, svc, newMode) {
  await token();
  const url =
    `https://firebaseappcheck.googleapis.com/v1/projects/${projectId}/services/${svc}` +
    `?updateMask=enforcementMode`;
  const res = await fetch(url, {
    method: "PATCH",
    headers: headers(projectId, true),
    body: JSON.stringify({
      name: `projects/${projectId}/services/${svc}`,
      enforcementMode: newMode,
    }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`PATCH ${svc}: ${res.status} ${JSON.stringify(body)}`);
  return body.enforcementMode || "(unset)";
}

async function reportProject(projectId) {
  console.log(`\n=== ${projectId} ===`);
  for (const svc of [...MANAGED, ...READONLY_EXTRA]) {
    console.log(`  ${svc}: enforcementMode=${await getMode(projectId, svc)}`);
  }
}

(async () => {
  // --- mutate path ---
  if (apply) {
    if (!VALID_MODES.includes(mode)) {
      console.error(`--apply requires --mode=<${VALID_MODES.join("|")}>`);
      process.exit(1);
    }
    if (!projectArg) {
      console.error("--apply requires --project=<toska-4ebf4|toskastaging>");
      process.exit(1);
    }
    if (projectArg === PROD && !yesProd) {
      console.error(`Refusing to change PROD (${PROD}) without --yes-prod.`);
      process.exit(1);
    }
    console.log(`Setting enforcementMode=${mode} on ${projectArg} for: ${MANAGED.join(", ")}`);
    for (const svc of MANAGED) {
      const before = await getMode(projectArg, svc);
      const after = await setMode(projectArg, svc, mode);
      console.log(`  ${svc}: ${before} -> ${after}`);
    }
    console.log("Done. Re-run with no args to verify.");
    process.exit(0);
  }

  // --- read-only default: check both projects ---
  console.log("Read-only check (pass --project/--mode/--apply to change). Lifecycle: (unset) -> UNENFORCED -> ENFORCED.");
  for (const p of projectArg ? [projectArg] : [PROD, STAGING]) {
    try {
      await reportProject(p);
    } catch (err) {
      console.log(`\n=== ${p} ===\n  error: ${err.message}`);
    }
  }
  process.exit(0);
})().catch((err) => {
  console.error("setAppCheck failed:", err.message);
  process.exit(1);
});
