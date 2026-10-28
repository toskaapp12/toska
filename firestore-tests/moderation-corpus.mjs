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
const { computePostFlagReason, computeReplyFlagReason, isPostExplicitCrisis, isPostConcerning } =
  require("../functions/moderationLogic.js");

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

  // ── A2 (2026-10-28 multi-user audit): phrasings that published LIVE on staging ──
  // group-dehumanizing hate → "dehumanizing" (HELD everywhere, never deleted)
  ["all women are worthless trash and deserve nothing", "dehumanizing"],
  ["all men are subhuman garbage and should be exterminated", "dehumanizing"],
  ["men are literally vermin", "dehumanizing"],
  ["immigrants should all be gassed", "dehumanizing"],
  ["immigrants should all be deported", null],   // political speech, not dehumanizing — stays live
  ["exterminate the jews", "dehumanizing"],
  ["he is subhuman", "dehumanizing"],
  // explicit sexual detail → "sexual_explicit" (HELD, overridable at compose)
  ["the sex was the only good part, explicit details about his dick", "sexual_explicit"],
  ["she fucked me hard every night and now nothing", "sexual_explicit"],
  ["he used to eat me out and now he won't even text", "sexual_explicit"],
  ["fuck me daddy she said", "sexual_content"],   // pre-existing hard tier still wins
  // third-person physical threat → "targeted_threat"
  ["i am going to hurt him so badly when i see him next", "targeted_threat"],
  ["im gonna beat him up when i see him", "targeted_threat"],
  ["i will break his jaw", "targeted_threat"],
  // underage: bare age at a clause boundary, curly apostrophe, age+gender, bare born-in
  ["i am 15 and my first boyfriend just broke up with me before homecoming", "minor_safety"],
  ["im 16, he was 19", "minor_safety"],
  ["i’m 16 and this is my first breakup", "minor_safety"],   // curly apostrophe (iOS keyboard)
  ["16f here and he was 19", "minor_safety"],
  ["f16 and heartbroken", "minor_safety"],
  ["16 m and she left", "minor_safety"],
  ["born in 2012 and already heartbroken, is that normal", "minor_safety"],
  [`born in ${new Date().getFullYear() - 13} and he left me`, "minor_safety"],
  // ACCEPTED MISS (owner 2026-10-28): no present-tense first-person marker; adding
  // it would hold adults reminiscing. Pinned as null so a future change is deliberate.
  ["being dumped in 9th grade is the worst thing that happened to me", null],
  // ── A2 must-stay-LIVE controls (owner 2026-10-28) ──
  ["he fucked me over so badly", null],
  ["this breakup fucked me up", null],
  ["she really fucked me around for months", null],
  ["fuck me, i miss him so much", null],          // exclamation, not sexual
  ["he's such a dick honestly", null],
  ["he is a dick but i still love him", null],
  ["the sex was good but nothing else was", null],
  ["54 days since she left", null],
  ["i have 54 photos of us", null],
  ["it is going to hurt him when he finds out", null],   // emotional hurt
  ["i don't want to hurt her but i have to go", null],
  ["my daughter born in 2012 keeps asking about him", null],
  ["my dog born in 2013 misses him too", null],
  ["im 15 minutes late to everything now", null],
  ["i am 15 years into this and still lost", null],       // "years into" guard via "years old" only
  ["the men in my family never talk about feelings", null],
  ["all women are not the same, she was different", null],
  ["women are strong and i was not", null],
  ["i was born in 1995", null],
];

// A2: replies run computeReplyFlagReason (now spam-checked; same reasons otherwise)
const REPLY_CASES = [
  ["buy my crypto course now, link in bio, cashapp me and get rich", "spam_or_commercial"],
  ["all men are subhuman garbage and should be exterminated", "dehumanizing"],
  ["explicit details about his dick", "sexual_explicit"],
  ["you dirty spic", "hate_speech"],               // slur tier: still hard-deleted by applyReplyModeration
  ["you are not alone in this at all", null],
  ["he fucked me over too, i get it", null],
];

let failed = 0;
for (const [text, expected] of REPLY_CASES) {
  const got = computeReplyFlagReason(text) ?? null;
  if (got !== expected) { failed++; console.error(`✗ REPLY FAIL [${text}] => ${got} (expected ${expected})`); }
}
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

// ── crisis-tier pin (2026-10-07 pentest) ──
// matchesCrisisPhrase only applied the 3+→1 repeat collapse, so padding the
// double letter itself ("killl myself" → "kil myself") destroyed the match,
// and dotless ı (U+0131) was unmapped AND deleted by the no-space lane.
// Both were EXECUTED bypasses of the full pipeline. Pin them + FP guards.
// [text, expectExplicit, expectConcerning]
const CRISIS_CASES = [
  ["i want to kill myself", true, true],          // control
  ["i want to killl myself", true, true],         // padded double letter
  ["i want to killlll myself", true, true],       // longer pad
  ["kiilll myself", true, true],                  // pad spanning the i/l pair
  ["k1lll myself", true, true],                   // leet + pad
  ["i want to kıll myself", true, true],          // dotless ı (U+0131)
  ["commit suıcıde", true, true],                 // dotless ı in suicide
  ["betttter off dead", true, true],              // padded double ("better off dead" is explicit-tier)
  // FP guards: emphasis padding + double-letter words must stay clean
  ["my landlord billled me twice", false, false],
  ["we killed it at karaoke last night", false, false],
  ["that was a brilliant skilllful move", false, false],
  ["i am sooooo done with him", false, false],
  // ── A2 (2026-10-28 audit): digits must never fold into the ≤3-char algospeak tokens ──
  ["54 days since she left", false, false],          // "54" → "sa" was held as crisis
  ["i have 54 photos of us", false, false],
  ["post 54: the playlist still feels like theirs", false, false],
  ["it has been 5h since he texted", false, false],  // "5h" → "sh"
  ["room 0d at the hotel", false, false],            // "0d" → "od"
  ["we were together 4 years and 5 months", false, false],
  // …while real algospeak / initialisms still hold (soft tier) or page (explicit)
  ["ugh kms", false, true],
  ["k.m.s honestly", false, true],
  ["k m s", false, true],
  ["i relapsed into sh again", false, true],
  ["i am a sa survivor", false, true],
  ["s.a. survivor here", false, true],
  ["i want to unalive myself", true, true],
  ["thinking about sewer slide tonight", true, true],
  ["thinking about sewerslide tonight", true, true],
  ["usa visa salsa", false, false],                  // "sa" inside words must not fire
  ["shhh it's okay", false, false],                  // "sh" inside a longer token
];
let crisisFailed = 0;
for (const [text, wantExplicit, wantConcerning] of CRISIS_CASES) {
  const gotE = !!isPostExplicitCrisis(text);
  const gotC = !!isPostConcerning(text);
  if (gotE !== wantExplicit || gotC !== wantConcerning) {
    crisisFailed++;
    console.error(`✗ CRISIS FAIL [${text}] => explicit:${gotE}/concerning:${gotC} (expected ${wantExplicit}/${wantConcerning})`);
  }
}
if (crisisFailed > 0) {
  console.error(`\n${crisisFailed}/${CRISIS_CASES.length} crisis-tier mismatch(es) — matchesCrisisPhrase drifted.`);
  process.exit(1);
}
console.log(`✓ crisis-tier pin: ${CRISIS_CASES.length}/${CRISIS_CASES.length} — padding + dotless-ı evasions held, FP guards clean`);
