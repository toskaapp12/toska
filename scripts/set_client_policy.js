// The kill-switch lever (2026-09-21). Writes config/clientPolicy — the doc
// both clients mirror live. Clients FAIL OPEN, so an absent doc/field means
// "everything enabled, no minimum build".
//
// Usage (ADC auth, same as the other admin scripts):
//   node scripts/set_client_policy.js <projectId>                    # show current
//   node scripts/set_client_policy.js <projectId> minBuild=87        # force-update below 87
//   node scripts/set_client_policy.js <projectId> kill.gifs=true     # pause a feature
//   node scripts/set_client_policy.js <projectId> kill.gifs=false    # resume it
//   node scripts/set_client_policy.js <projectId> notice="toska is being looked after — back in an hour."
//   node scripts/set_client_policy.js <projectId> notice=            # clear the banner
//
// Features: compose, replies, gifs, search, share.
const admin = require("../functions/node_modules/firebase-admin");
const project = process.argv[2];
if (!project) { console.error("usage: node set_client_policy.js <projectId> [key=value …]"); process.exit(1); }
admin.initializeApp({ projectId: project });
const ref = admin.firestore().collection("config").doc("clientPolicy");

(async () => {
  const updates = {};
  for (const arg of process.argv.slice(3)) {
    const i = arg.indexOf("=");
    if (i < 0) { console.error(`bad arg (want key=value): ${arg}`); process.exit(1); }
    const key = arg.slice(0, i), raw = arg.slice(i + 1);
    const value = raw === "true" ? true : raw === "false" ? false
      : /^\d+$/.test(raw) ? Number(raw) : raw;
    updates[key] = value;
  }
  if (Object.keys(updates).length) {
    await ref.set({ minBuild: 1, kill: {}, notice: "" }, { merge: true }); // ensure shape
    await ref.update(updates);
    console.log("updated:", updates);
  }
  const snap = await ref.get();
  console.log(`${project} config/clientPolicy:`, JSON.stringify(snap.data() ?? "(absent — clients fail open)"));
  process.exit(0);
})().catch((e) => { console.error(e.message); process.exit(1); });
