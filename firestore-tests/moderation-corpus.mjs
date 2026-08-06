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
  // NCII / revenge-porn + doxxing threats (2026-07-27)
  ["im going to leak your nudes everywhere", "harassment"],
  ["ill post your nudes online for everyone", "harassment"],
  ["i still have your nudes remember", "harassment"],
  ["im going to dox you", "harassment"],
  ["everyone gets to see when i post your address", "harassment"],
  ["ill reveal your identity to your boss", "harassment"],
  // ── must FLAG: sexual ──
  // minor-safety: underage self-disclosure (2026-07-27) → held for review
  ["im 15 years old and going through a breakup", "minor_safety"],
  ["i am 14 years old", "minor_safety"],
  ["im a minor and scared to tell anyone", "minor_safety"],
  ["im not 18 yet but", "minor_safety"],
  ["i am in 8th grade", "minor_safety"],
  // minor-safety hardening (2026-07-28, system-review A.5 #1): spelled ages,
  // turning/turned framings, freshman/sophomore, 9th-10th grade, birth year
  ["i am sixteen years old and this hurts", "minor_safety"],
  ["im only fourteen years old", "minor_safety"],
  ["im turning 15 next month and he left me", "minor_safety"],
  ["i just turned 16 and had my first breakup", "minor_safety"],
  ["i turn 14 next week", "minor_safety"],
  ["im a freshman in high school and she dumped me", "minor_safety"],
  ["i am a sophomore and we broke up", "minor_safety"],
  ["im in 9th grade", "minor_safety"],
  ["im a 7th grader", "minor_safety"],
  [`i was born in ${new Date().getFullYear() - 12}`, "minor_safety"], // always age ~12
  // minor-safety FP guards (must NOT flag)
  ["im 15 minutes late to everything", null],
  ["our relationship is 9 years old", null],
  ["my dog is 14 years old", null],
  ["i am 25 years old and lost", null],
  ["back in high school this happened to me", null],
  // hardening FP guards: threshold is <18, college forms + reminiscing
  // + third-person + non-age "turn" uses stay clear
  ["im a freshman in college and still lost", null],
  ["im a junior in college and she left", null],
  ["when i was 16 we started dating", null],
  ["i had just turned 15 when we met back then", null],
  ["my sister is turning 12 next week", null],
  ["i turn on the tv to distract myself", null],
  ["i was born in 1995", null],
  // ── age floor moved 17 → 18 (2026-08-06): 17 now flags, 18 does not ──
  ["im 17 years old", "minor_safety"],
  ["i am seventeen years old", "minor_safety"],
  ["im turning 17 next month", "minor_safety"],
  ["im in 11th grade", "minor_safety"],
  ["im an 11th grader", "minor_safety"],
  ["im a junior and we broke up", "minor_safety"],
  [`i was born in ${new Date().getFullYear() - 17}`, "minor_safety"], // always age <= 17
  ["im 18 years old", null],          // 18 is a permitted user (ToS §2)
  ["i am eighteen years old and hurting", null],
  ["im a senior and she dumped me", null],   // seniors are commonly 18
  ["im in high school and it hurts", null],  // deliberately not flagged
  ["im in 12th grade", null],
  ["when i was 17 we were still together", null], // past tense stays clear
  [`i was born in ${new Date().getFullYear() - 18}`, null], // could be 18

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
  // 2026-07-28 A.5 #2: matchesEvasionRegex now applies the crisis-lane
  // algospeak pass (deLeetCrisisExtra + BOTH repeat-collapses) to hate/sexual
  ["you dirty spiiiic", "hate_speech"],   // vowel padding (3+→1 collapse)
  ["you dirty spiccc", "hate_speech"],    // trailing padding
  ["you faggg", "hate_speech"],           // padded doubled-letter slur (3+→2 collapse — 3+→1 would MISS)
  ["you 9ook", "hate_speech"],            // extra de-leet 9→g
  ["you dirty (oon", "hate_speech"],      // extra de-leet (→c
  ["send nuuuudes", "sexual_content"],    // padded sexual demand
  // A.5 #2 FP guards: innocent emphasis padding must NOT flag
  ["im soooo tired of all this", null],
  ["hope we can meet sooooon", null],
  ["that summer was coooool", null],
  ["im crying :((( over him", null],
  ["ughhh i miss him", null],
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
  // 2026-07-27 algospeak — harassment-lane FP guards (kys word-boundary fix)
  ["the sky is the limit for us", null],      // "sky's"->"skys" no longer trips kys
  ["i love these grippy socks in winter", null], // no harassment/hate from grippy sock
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
