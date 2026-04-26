// One-off admin script: strip legacy PII fields from pre-migration user docs.
//
// Context: firestore.rules:62 grants `allow read: if isOwner(userId) || isAuth()`
// on the users collection. The migration notes on that rule describe moving
// sensitive fields (email, fcmToken, selectedMood, notify*/pushEnabled/
// gentleCheckIn) from the main user doc into users/{uid}/private/data so
// other authenticated users can't read them. Clients write to the new
// location now, but pre-migration accounts still have legacy copies on the
// main doc until their owner opens Settings / onboarding and triggers a
// re-save. This script does the one-time scrub so the rule is safe as-is
// without waiting for every user to return.
//
// Safety: each batch reads the private/data doc for the user first and only
// deletes a legacy field on the main doc if the private copy already exists
// OR we preserve the value by writing it into private/data within the same
// batch. No value is dropped on the floor.
//
// Usage:
//   cd functions
//   node scrubLegacyPII.js                    # dry run (prints, writes nothing)
//   node scrubLegacyPII.js --apply            # performs writes
//   node scrubLegacyPII.js --apply --limit=50 # cap how many users to touch
//
// Requires that ADC credentials (or GOOGLE_APPLICATION_CREDENTIALS env var)
// point at a service account with Firestore write access.

const admin = require("firebase-admin");
admin.initializeApp();
const db = admin.firestore();
const { FieldValue } = admin.firestore;

// The complete set of legacy fields we're migrating out of the main user
// doc. Source of truth is firestore.rules:43-61. Keep in sync if any new
// sensitive field is introduced on the main doc.
const LEGACY_FIELDS = [
  "email",
  "fcmToken",
  "fcmTokenUpdatedAt",
  "selectedMood",
  "notifyLikes",
  "notifyReplies",
  "notifyFollows",
  "notifyReposts",
  "notifySaves",
  "notifyMessages",
  "notifyMilestones",
  "pushEnabled",
  "gentleCheckIn",
];

const APPLY = process.argv.includes("--apply");
const LIMIT_ARG = process.argv.find(a => a.startsWith("--limit="));
const LIMIT = LIMIT_ARG ? parseInt(LIMIT_ARG.split("=")[1], 10) : Infinity;

async function scrubUser(userDoc) {
  const userData = userDoc.data() || {};
  const present = LEGACY_FIELDS.filter(f => userData[f] !== undefined);
  if (present.length === 0) return { uid: userDoc.id, scrubbed: [], preserved: 0 };

  // Read the private/data doc so we don't clobber anything newer there.
  const privateRef = userDoc.ref.collection("private").doc("data");
  const privateSnap = await privateRef.get();
  const privateData = privateSnap.exists ? (privateSnap.data() || {}) : {};

  // Fields to preserve: anything on the main doc whose private copy is
  // missing or empty. We copy the legacy value into private/data before
  // deleting from the main doc.
  const toPreserve = {};
  for (const field of present) {
    if (privateData[field] === undefined || privateData[field] === null) {
      toPreserve[field] = userData[field];
    }
  }

  if (!APPLY) {
    return {
      uid: userDoc.id,
      dryRun: true,
      wouldScrub: present,
      wouldPreserve: Object.keys(toPreserve),
    };
  }

  const batch = db.batch();
  if (Object.keys(toPreserve).length > 0) {
    batch.set(privateRef, toPreserve, { merge: true });
  }
  const deletePatch = {};
  for (const field of present) deletePatch[field] = FieldValue.delete();
  batch.update(userDoc.ref, deletePatch);
  await batch.commit();

  return {
    uid: userDoc.id,
    scrubbed: present,
    preserved: Object.keys(toPreserve).length,
  };
}

async function main() {
  console.log(`Legacy PII scrub — ${APPLY ? "APPLY mode" : "DRY RUN"}`);
  console.log(`Fields: ${LEGACY_FIELDS.join(", ")}\n`);

  const usersSnap = await db.collection("users").get();
  console.log(`Found ${usersSnap.size} user docs. Processing${LIMIT !== Infinity ? ` up to ${LIMIT}` : ""}...\n`);

  let processed = 0;
  let touched = 0;
  let preservedTotal = 0;

  for (const userDoc of usersSnap.docs) {
    if (processed >= LIMIT) break;
    processed++;
    try {
      const result = await scrubUser(userDoc);
      if (result.scrubbed && result.scrubbed.length > 0) {
        touched++;
        preservedTotal += result.preserved;
        console.log(`${result.uid}: scrubbed ${result.scrubbed.join(",")} (preserved ${result.preserved})`);
      } else if (result.wouldScrub && result.wouldScrub.length > 0) {
        touched++;
        preservedTotal += result.wouldPreserve.length;
        console.log(`${result.uid}: WOULD scrub ${result.wouldScrub.join(",")} (would preserve ${result.wouldPreserve.length})`);
      }
    } catch (err) {
      console.error(`${userDoc.id}: FAILED —`, err.message);
    }
  }

  console.log(`\nDone. Processed: ${processed}. Users touched: ${touched}. Values preserved into private/data: ${preservedTotal}.`);
  if (!APPLY) console.log(`\nThis was a dry run. Add --apply to perform writes.`);
  process.exit(0);
}

main().catch(e => { console.error(e); process.exit(1); });
