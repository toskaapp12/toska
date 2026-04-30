// PROJECT GUARD — refuse to run unless the operator explicitly opts in OR
// the project ID looks non-production. This script wipes every post,
// reply, like, conversation, message, circle, report, daily moment,
// final post, pending deletion, and per-user subcollection — pointing it
// at production by accident would be irrecoverable. Common mistake mode
// is `gcloud config set project <real-project>` lingering in the shell
// after a debugging session.
//
// Bypass paths:
//   - GCLOUD_PROJECT env var ends with -test, -dev, or -staging
//   - GCLOUD_PROJECT is in the explicit non-prod allowlist below
//     (covers Toska's `toskastaging` project, which doesn't fit the
//     hyphenated suffix shape)
//   - --allow-prod argv flag is passed (for the rare legitimate
//     prod cleanup; treat as a deliberate, confirmed action)
const admin = require("firebase-admin");

// Known non-prod project IDs that the suffix regex below doesn't catch.
// Keep this list short and audited — every entry here gets blanket
// permission to be wiped without --allow-prod.
const NON_PROD_PROJECTS = new Set(["toskastaging"]);

const projectId = process.env.GCLOUD_PROJECT
  || process.env.GOOGLE_CLOUD_PROJECT
  || "";
const allowProd = process.argv.includes("--allow-prod");
const looksTesty = NON_PROD_PROJECTS.has(projectId)
  || /-(?:test|dev|staging)$/.test(projectId);

if (!allowProd && !looksTesty) {
  console.error(
    `\nREFUSING TO RUN: project "${projectId || "(unset)"}" doesn't look like a test/dev project.\n` +
    `\nThis script wipes every post, reply, conversation, circle, report, and per-user subcollection.\n` +
    `If this is intentional (e.g. one-time cleanup of a doomed prod), pass --allow-prod:\n` +
    `  node cleanup.js --allow-prod\n` +
    `\nOtherwise, point at a test project:\n` +
    `  GCLOUD_PROJECT=toska-4ebf4-test node cleanup.js\n`
  );
  process.exit(1);
}

admin.initializeApp();
const db = admin.firestore();
console.log(`Cleanup running against project: ${projectId || "(default)"}`);

// Iteration cap is a defensive bound: this script is admin tooling meant for
// dev/test databases, but if someone accidentally points it at a collection
// with millions of docs it would otherwise loop forever and exhaust memory.
// 500 iterations × 200/batch = 100K docs is plenty for the use cases this
// script targets. Hitting the cap is logged so the operator knows there's
// more left to clean up — re-run, or use the production-side resumePostDeletion
// scheduler for very large collections.
const MAX_DELETE_ITERATIONS = 500;

async function deleteCol(ref) {
  let total = 0;
  let snap;
  let iterations = 0;
  do {
    if (iterations >= MAX_DELETE_ITERATIONS) {
      console.warn(`deleteCol cap hit at ${total} docs; re-run to continue.`);
      break;
    }
    snap = await ref.limit(200).get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach(d => batch.delete(d.ref));
    await batch.commit();
    total += snap.size;
    iterations++;
  } while (!snap.empty);
  return total;
}

async function main() {
  console.log("Cleaning test data...\n");

  const posts = await db.collection("posts").get();
  for (const doc of posts.docs) {
    await deleteCol(doc.ref.collection("replies"));
    await deleteCol(doc.ref.collection("likes"));
    await deleteCol(doc.ref.collection("reflections"));
    await doc.ref.delete();
  }
  console.log("Deleted " + posts.size + " posts + subcollections");

  const convos = await db.collection("conversations").get();
  for (const doc of convos.docs) {
    await deleteCol(doc.ref.collection("messages"));
    await doc.ref.delete();
  }
  console.log("Deleted " + convos.size + " conversations");

  const circles = await db.collection("feelingCircles").get();
  for (const doc of circles.docs) {
    await deleteCol(doc.ref.collection("messages"));
    await doc.ref.delete();
  }
  console.log("Deleted " + circles.size + " feeling circles");

  console.log("Deleted " + await deleteCol(db.collection("reports")) + " reports");
  console.log("Deleted " + await deleteCol(db.collection("dailyMoment")) + " daily moments");
  console.log("Deleted " + await deleteCol(db.collection("finalPosts")) + " final posts");
  console.log("Deleted " + await deleteCol(db.collection("pendingDeletions")) + " pending deletions");

  const users = await db.collection("users").get();
  for (const doc of users.docs) {
    for (const sub of ["notifications","liked","saved","following","followers","presence","blocked","private"]) {
      await deleteCol(doc.ref.collection(sub));
    }
    await doc.ref.update({ followerCount: 0, followingCount: 0, totalLikes: 0 });
  }
  console.log("Cleaned " + users.size + " user subcollections + reset counts");

  console.log("\nDone! Database is clean.");
  process.exit(0);
}

main().catch(e => { console.error(e); process.exit(1); });
