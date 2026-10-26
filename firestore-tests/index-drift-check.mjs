// Staging↔prod index drift check — fails if the two projects' deployed
// Firestore indexes diverge. "Staging mirrors prod" silently stops being true
// the moment someone deploys indexes to one project but not the other; this
// catches that so the smoke-probe's staging result stays a valid proxy for prod.
//
// Needs READ access to BOTH projects' index definitions (gcloud, via ADC).
// Locally you have both. In CI only staging is authed (keyless WIF), so there
// this SKIPS with a notice — run it locally before any prod index/rules deploy
// (see runbooks/deploy-checklist.md). To enable it in CI, add a prod read-only
// WIF service account (roles/datastore.viewer) the same way as the staging probe.
//
// Run:  node index-drift-check.mjs
import { execFileSync } from "node:child_process";

const STAGING = "toskastaging", PROD = "toska-4ebf4";

function canon(project) {
  let out;
  try {
    out = execFileSync("gcloud", ["firestore", "indexes", "composite", "list",
      "--project", project, "--format=json", "--database=(default)"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch (e) {
    return { ok: false, err: (e.stderr || e.message || "").toString().slice(0, 120) };
  }
  const idx = JSON.parse(out).map((i) => {
    const cg = i.name.split("/collectionGroups/")[1].split("/")[0];
    const fields = (i.fields || [])
      .filter((f) => f.fieldPath !== "__name__")
      .map((f) => `${f.fieldPath}:${f.order || f.arrayConfig || "?"}`)
      .join(",");
    return `${cg}[${i.queryScope}]{${fields}}`;
  }).sort();
  return { ok: true, set: new Set(idx) };
}

const s = canon(STAGING), p = canon(PROD);
if (!s.ok) { console.log(`cannot read ${STAGING} indexes (${s.err}) — SKIP (likely no creds; run locally).`); process.exit(0); }
if (!p.ok) { console.log(`cannot read ${PROD} indexes (${p.err}) — SKIP (no prod creds in this env; run locally before a prod deploy).`); process.exit(0); }

const onlyStaging = [...s.set].filter((x) => !p.set.has(x));
const onlyProd = [...p.set].filter((x) => !s.set.has(x));
console.log(`composite indexes — staging: ${s.set.size}, prod: ${p.set.size}`);
if (onlyStaging.length === 0 && onlyProd.length === 0) {
  console.log("✓ no drift — staging and prod composite indexes match");
  process.exit(0);
}
if (onlyStaging.length) { console.log("\n✗ in STAGING but not PROD (deploy to prod):"); onlyStaging.forEach((x) => console.log("   " + x)); }
if (onlyProd.length) { console.log("\n✗ in PROD but not STAGING (deploy to staging):"); onlyProd.forEach((x) => console.log("   " + x)); }
console.log("\nfix: `firebase deploy --only firestore:indexes` to the lagging project.");
process.exit(1);
