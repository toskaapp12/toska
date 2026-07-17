// READ-ONLY probe: live world-readable posts still carrying autoHiddenReportCount
// (or the other timestamp markers the new go-live gate requires absent).
// Run against prod + staging via ADC.
import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const projectId = process.argv[2];
if (!projectId) { console.error("usage: node autohide-probe.mjs <projectId>"); process.exit(1); }
const app = initializeApp({ credential: applicationDefault(), projectId });
const db = getFirestore(app);

const snap = await db.collection("posts").where("autoHiddenReportCount", ">", 0).get();
let contaminated = 0;
for (const d of snap.docs) {
  const s = d.get("moderationStatus") ?? "live";
  if (s === "live") {
    contaminated++;
    console.log(`LIVE+marker: posts/${d.id} autoHiddenReportCount=${d.get("autoHiddenReportCount")}`);
  } else {
    console.log(`held (ok, hidden): posts/${d.id} status=${s}`);
  }
}
console.log(`${projectId}: ${snap.size} posts carry autoHiddenReportCount; ${contaminated} of them LIVE (world-readable).`);
