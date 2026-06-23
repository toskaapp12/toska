// Repost rule probe — confirms the green-then-grey failure modes and that the
// 2026-06 client fix (fresh text/authorId + resolve-or-omit originalHandle)
// makes the repost create rule pass. Run against the Firestore emulator:
//   firebase emulators:exec --only firestore "node firestore-tests/repost-probe.mjs"
import { initializeTestEnvironment, assertSucceeds, assertFails } from "@firebase/rules-unit-testing";
import { setDoc, doc, serverTimestamp } from "firebase/firestore";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RULES = fs.readFileSync(path.join(__dirname, "..", "firestore.rules"), "utf8");

const env = await initializeTestEnvironment({
  projectId: "toska-repost-probe",
  firestore: { rules: RULES, host: "localhost", port: 8080 },
});

const seed = (fn) => env.withSecurityRulesDisabled((ctx) => fn(ctx.firestore()));
const setUser = (uid, fields = {}) =>
  seed((db) => setDoc(doc(db, "users", uid), {
    handle: `handle_${uid}`, followerCount: 0, followingCount: 0, totalLikes: 0,
    confirmedAdult: true, ...fields,
  }));
const setPost = (id, authorId, extra = {}) =>
  seed((db) => setDoc(doc(db, "posts", id), {
    authorId, authorHandle: `handle_${authorId}`, text: "hello",
    createdAt: new Date(), likeCount: 0, repostCount: 0, replyCount: 0, ...extra,
  }));

// Build a repost payload like PostInteractionManager.repost does.
function repostPayload({ reposter, originalPostId, text, originalAuthorId, originalHandle }) {
  const d = {
    authorId: reposter, authorHandle: `handle_${reposter}`, text,
    likeCount: 0, repostCount: 0, replyCount: 0, isShareable: true,
    isRepost: true, originalPostId, originalAuthorId,
    createdAt: serverTimestamp(), moderationStatus: "pending_validation",
  };
  if (originalHandle !== undefined) d.originalHandle = originalHandle;
  return d;
}

let pass = 0, fail = 0;
async function check(label, expectAllow, promise) {
  try {
    await (expectAllow ? assertSucceeds(promise) : assertFails(promise));
    console.log(`  ✓ ${label}`); pass++;
  } catch (e) {
    console.log(`  ✗ ${label} — ${e.message.split("\n")[0]}`); fail++;
  }
}

await env.clearFirestore();
await setUser("bob"); // the reposter (confirmedAdult, handle_bob)

console.log("Scenario A — original author's USER DOC IS MISSING (e.g. seeded post, no user doc):");
await setPost("origA", "carol", { text: "the storm passed" }); // no setUser("carol")
{
  const bob = env.authenticatedContext("bob").firestore();
  await check("OLD: sends originalHandle → DENIED", false,
    setDoc(doc(bob, "posts", "bob_repost_origA"),
      repostPayload({ reposter: "bob", originalPostId: "origA", text: "the storm passed", originalAuthorId: "carol", originalHandle: "handle_carol" })));
  await check("NEW: omits originalHandle → ALLOWED", true,
    setDoc(doc(bob, "posts", "bob_repost_origA2"),
      repostPayload({ reposter: "bob", originalPostId: "origA", text: "the storm passed", originalAuthorId: "carol" /* omit */ })));
}

console.log("Scenario B — author user doc EXISTS but feed handle is STALE:");
await env.clearFirestore(); await setUser("bob");
await setUser("carol"); // handle_carol
await setPost("origB", "carol", { text: "still here" });
{
  const bob = env.authenticatedContext("bob").firestore();
  await check("OLD: sends stale originalHandle 'old_carol' → DENIED", false,
    setDoc(doc(bob, "posts", "bob_repost_origB"),
      repostPayload({ reposter: "bob", originalPostId: "origB", text: "still here", originalAuthorId: "carol", originalHandle: "old_carol" })));
  await check("NEW: sends RESOLVED live handle 'handle_carol' → ALLOWED", true,
    setDoc(doc(bob, "posts", "bob_repost_origB2"),
      repostPayload({ reposter: "bob", originalPostId: "origB", text: "still here", originalAuthorId: "carol", originalHandle: "handle_carol" })));
}

console.log("Scenario C — feed TEXT is stale (post edited after feed loaded):");
await env.clearFirestore(); await setUser("bob"); await setUser("carol");
await setPost("origC", "carol", { text: "the current real text" });
{
  const bob = env.authenticatedContext("bob").firestore();
  await check("OLD: sends stale text → DENIED", false,
    setDoc(doc(bob, "posts", "bob_repost_origC"),
      repostPayload({ reposter: "bob", originalPostId: "origC", text: "an old cached version", originalAuthorId: "carol", originalHandle: "handle_carol" })));
  await check("NEW: sends FRESH text → ALLOWED", true,
    setDoc(doc(bob, "posts", "bob_repost_origC2"),
      repostPayload({ reposter: "bob", originalPostId: "origC", text: "the current real text", originalAuthorId: "carol", originalHandle: "handle_carol" })));
}

await env.cleanup();
console.log(`\n${fail === 0 ? "ALL PASS" : "SOME FAILED"} — ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
