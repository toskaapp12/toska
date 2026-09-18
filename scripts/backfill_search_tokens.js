// Backfill `searchTokens` onto existing posts (owner 2026-09-18).
// Run per project:  GOOGLE_CLOUD_PROJECT=<proj> node scripts/backfill_search_tokens.js <proj>
// Idempotent — skips docs that already carry tokens. Uses ADC.
const admin = require("../functions/node_modules/firebase-admin");
const project = process.argv[2];
if (!project) { console.error("usage: node backfill_search_tokens.js <projectId>"); process.exit(1); }
admin.initializeApp({ projectId: project });
const db = admin.firestore();

// Mirrors functions/index.js searchTokensFor exactly.
function searchTokensFor(data) {
  const src = [data.text || "", data.tag || "", data.authorHandle || ""].join(" ");
  const tokens = src.toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .split(" ")
    .filter((w) => w.length >= 2);
  return [...new Set(tokens)].slice(0, 60);
}

(async () => {
  let done = 0, skipped = 0, last = null;
  for (;;) {
    let q = db.collection("posts").orderBy("__name__").limit(300);
    if (last) q = q.startAfter(last);
    const snap = await q.get();
    if (snap.empty) break;
    const batch = db.batch();
    let writes = 0;
    for (const d of snap.docs) {
      const x = d.data();
      if (Array.isArray(x.searchTokens)) { skipped++; continue; }
      batch.update(d.ref, { searchTokens: searchTokensFor(x) });
      writes++;
    }
    if (writes > 0) await batch.commit();
    done += writes;
    last = snap.docs[snap.docs.length - 1];
    console.log(`backfilled ${done} (skipped ${skipped})…`);
  }
  console.log(`DONE: ${done} stamped, ${skipped} already had tokens`);
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
