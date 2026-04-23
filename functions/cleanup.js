const admin = require("firebase-admin");
admin.initializeApp();
const db = admin.firestore();

async function deleteCol(ref) {
  let total = 0;
  let snap;
  do {
    snap = await ref.limit(200).get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach(d => batch.delete(d.ref));
    await batch.commit();
    total += snap.size;
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
    for (const sub of ["notifications","liked","saved","following","followers","presence","blocked"]) {
      await deleteCol(doc.ref.collection(sub));
    }
    await doc.ref.update({ followerCount: 0, followingCount: 0, totalLikes: 0 });
  }
  console.log("Cleaned " + users.size + " user subcollections + reset counts");

  console.log("\nDone! Database is clean.");
  process.exit(0);
}

main().catch(e => { console.error(e); process.exit(1); });
