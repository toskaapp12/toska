// Staging probe for the sharing-consent render gate + re-stamp (finding B).
// Proves that a post NEVER renders on any public surface when the author's live
// allowSharing is off — the two cases the owner asked for:
//   (1) a post from a user whose allowSharing is false
//   (2) a post whose author turns sharing OFF after it was shared
// Surfaces: /p/{id} (sharePage), /og/{id}.png (shareCardImage), /sitemap.xml
// (postsSitemap), publicFeed. Also verifies validatePost re-stamps isShareable.
//
// Run from functions/ (has firebase-admin):
//   GOOGLE_CLOUD_PROJECT=toskastaging node ../firestore-tests/consent-render-gate-probe.mjs
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

initializeApp({ projectId: "toskastaging" });
const db = getFirestore();
const BASE = "https://toskastaging.web.app";
const PUBLIC_FEED = "https://us-central1-toskastaging.cloudfunctions.net/publicFeed";
const run = Date.now().toString(36);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const uidA = `probe_a_${run}`;   // allowSharing: false
const uidB = `probe_b_${run}`;   // allowSharing: true, then flipped false
const pidA = `probePostA_${run}`;
const pidB = `probePostB_${run}`;
const pidC = `probePostC_${run}`;
const textA = `consent probe alpha ${run} placeholder breakup words only nothing identifying here today`;
const textB = `consent probe bravo ${run} placeholder breakup words only nothing identifying here today`;
const textC = `consent probe charlie ${run} placeholder breakup words only nothing identifying here today`;

function post(authorId, text) {
  return {
    authorId, authorHandle: `handle_${authorId}`, text,
    moderationStatus: "live", isShareable: true, isRepost: false,
    webFeatured: true, likeCount: 3, replyCount: 0, repostCount: 0,
    createdAt: FieldValue.serverTimestamp(),
  };
}
async function httpStatus(url) {
  try { const r = await fetch(url, { headers: { "Cache-Control": "no-cache" } }); return r.status; }
  catch (e) { return `ERR ${e.message}`; }
}
async function bodyContains(url, needle) {
  try { const r = await fetch(url, { headers: { "Cache-Control": "no-cache" } }); return (await r.text()).includes(needle); }
  catch { return false; }
}

const results = [];
const check = (name, pass, detail) => { results.push({ name, pass, detail }); console.log(`${pass ? "✓" : "✗ FAIL"}  ${name}${detail ? "  — " + detail : ""}`); };

try {
  // ---- seed ----
  await db.collection("users").doc(uidA).set({ handle: `handle_${uidA}`, allowSharing: false, followerCount: 0, followingCount: 0, totalLikes: 0 });
  await db.collection("users").doc(uidB).set({ handle: `handle_${uidB}`, allowSharing: true,  followerCount: 0, followingCount: 0, totalLikes: 0 });
  await db.collection("posts").doc(pidA).set(post(uidA, textA));
  await db.collection("posts").doc(pidB).set(post(uidB, textB));
  await db.collection("posts").doc(pidC).set(post(uidB, textC));

  console.log("seeded; waiting 8s for validatePost triggers…");
  await sleep(8000);

  // ---- re-stamp (B part 2): validatePost should have cleared isShareable on A ----
  const aDoc = (await db.collection("posts").doc(pidA).get()).data();
  check("validatePost re-stamped isShareable=false for allowSharing:false author", aDoc.isShareable === false, `isShareable=${aDoc.isShareable}`);

  // Force isShareable true again on A to test the RENDER GATE independently of the re-stamp.
  await db.collection("posts").doc(pidA).update({ isShareable: true });
  await sleep(1500);

  // ---- Scenario 1: post from an allowSharing:false user → 404 everywhere ----
  check("Scenario1 /p/  404 (author sharing off)", (await httpStatus(`${BASE}/p/${pidA}`)) === 404);
  check("Scenario1 /og/ 404 (author sharing off)", (await httpStatus(`${BASE}/og/${pidA}.png`)) === 404);
  check("Scenario1 sitemap omits the post", !(await bodyContains(`${BASE}/sitemap.xml?cb=${run}`, pidA)));
  check("Scenario1 publicFeed omits the text", !(await bodyContains(`${PUBLIC_FEED}?cb=${run}`, textA)), "(10-min memo caveat)");

  // ---- Positive control: author B consent ON → post B renders ----
  check("Control /p/  200 (author sharing on)", (await httpStatus(`${BASE}/p/${pidB}`)) === 200);
  check("Control /og/ 200 (author sharing on)", (await httpStatus(`${BASE}/og/${pidB}.png`)) === 200);

  // ---- Scenario 2: author turns sharing OFF after sharing → 404 everywhere ----
  // pidC was created while B's consent was ON but never fetched (no CDN cache),
  // so hitting it the first time AFTER the flip isolates the live render gate.
  await db.collection("users").doc(uidB).update({ allowSharing: false });
  await sleep(2000);
  check("Scenario2 /p/  404 (author turned sharing off)", (await httpStatus(`${BASE}/p/${pidC}`)) === 404);
  check("Scenario2 /og/ 404 (author turned sharing off)", (await httpStatus(`${BASE}/og/${pidC}.png`)) === 404);
} finally {
  // ---- cleanup ----
  for (const p of [pidA, pidB, pidC]) await db.collection("posts").doc(p).delete().catch(() => {});
  for (const u of [uidA, uidB]) await db.collection("users").doc(u).delete().catch(() => {});
  console.log("cleaned up probe docs.");
}

const failed = results.filter((r) => !r.pass);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);
