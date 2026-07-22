// Moderation corpus pin for computePostFlagReason (functions/moderationLogic.js).
//
// The slur / threat / harassment / sexual lists are the SERVER trust boundary
// (the client is bypassable and posts can be edited after publish). Unlike the
// name + crisis matchers (pinned by detector-parity.mjs), these lists had NO
// automated coverage — which is exactly how a k-required regression in the
// "spic" pattern slipped through a fix round and reopened a real slur to the
// server gate. This corpus locks both directions: real abuse MUST flag, and
// grief/idiom false-positives (which HARD-DELETE replies when they hit hate/
// sexual) MUST NOT. Run in CI / pre-commit: exits 1 on any mismatch.
//
//   node firestore-tests/moderation-corpus.mjs
//
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { computePostFlagReason } = require("../functions/moderationLogic.js");

// [text, expectedReason | null]
const CASES = [
  // ── must FLAG: slurs (hate_speech) ──
  ["you dirty spic", "hate_speech"],          // "spic" (k optional) — the regression case
  ["a bunch of spics", "hate_speech"],        // plural, no k
  ["you spick", "hate_speech"],
  ["you stupid coon", "hate_speech"],
  ["fucking chink", "hate_speech"],
  ["go back you wetback", "hate_speech"],
  // ── must FLAG: threats (targeted_threat) ──
  ["im going to kill you", "targeted_threat"],
  ["coming for you tonight", "targeted_threat"],
  ["i will shoot up her school", "targeted_threat"],
  ["burn down your house", "targeted_threat"],
  // ── must FLAG: harassment (was server-narrower than client) ──
  ["everyone hates you", "harassment"],
  ["no one will miss you", "harassment"],
  ["the world is better without you", "harassment"],
  ["you deserve to suffer", "harassment"],
  ["go hang yourself", "harassment"],
  ["kys", "harassment"],
  // ── must FLAG: sexual ──
  ["send nudes", "sexual_content"],
  ["lets hook up tonight", "sexual_content"],
  ["post your booty call", "sexual_content"],
  ["rule34 stuff", "sexual_content"],
  ["cum on me", "sexual_content"],
  // ── must FLAG: evasions the server used to miss (H2, 2026-07-22 deep audit) ──
  // These are exactly the forms the iOS client blocks but the SERVER (the real
  // trust boundary, and the edit re-moderation path) let through until the
  // hate/sexual lists were routed through the evasion normalizer.
  ["you dirty s p i c", "hate_speech"],   // single-letter-spaced slur
  ["you dirty sp1c", "hate_speech"],      // leet slur
  ["you dirty spіс", "hate_speech"],      // homoglyph slur (Cyrillic і U+0456 + с U+0441)
  // ── must NOT flag: grief / idiom false-positives ──
  ["i got so suspicious of him", null],       // "spic" substring
  ["auspicious new start", null],
  ["a conspicuous absence", null],
  ["healing in my cocoon", null],             // "coon" substring
  ["a raccoon got into the trash", null],
  ["he became a tycoon", null],
  ["it was total gobbledygook", null],        // "gook" substring
  ["there was a chink in his armor", null],   // idiom exclusion
  ["the scum on the surface", null],          // "cum on" substring
  ["come get your things, come for your stuff", null], // was "come for you" FP
  ["this breakup is killing me", null],       // idiom, not threat
  ["i could kill for a coffee", null],
  ["i want to die alone", null],              // grief, routes to crisis not threat/harassment
  ["i just want some acceptance", null],
  ["we should talk it out", null],
];

let failed = 0;
for (const [text, expected] of CASES) {
  const got = computePostFlagReason(text);
  const norm = got === null || got === undefined ? null : got;
  const ok = norm === expected;
  if (!ok) {
    failed++;
    console.error(`✗ FAIL [${text}] => ${norm} (expected ${expected})`);
  }
}

if (failed > 0) {
  console.error(`\n${failed}/${CASES.length} moderation-corpus mismatch(es) — computePostFlagReason drifted. Re-check moderationLogic.js MOD_HATE/MOD_THREAT/MOD_HARASSMENT/MOD_SEXUAL.`);
  process.exit(1);
}
console.log(`✓ moderation-corpus: ${CASES.length}/${CASES.length} — slur/threat/harassment/sexual gate + grief FPs all correct`);
