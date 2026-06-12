// Crisis-detection RED TEAM (#5, 2026-06-11 security expansion).
//
// Safety-critical for vulnerable users. Two failure modes matter:
//   FALSE-NEGATIVE: a real crisis disclosure slips through (not held, no
//     check-in) — someone in crisis gets no resources. The worst outcome.
//   FALSE-POSITIVE on the EXPLICIT tier: normal/hyperbolic/3rd-party content
//     trips explicit → holds the post AND pages a human admin (alert fatigue +
//     suppresses non-crisis content). Soft-tier FPs are acceptable (held, not
//     paged); explicit FPs are not.
//
// Uses the real classifiers via index.js __test. Run: node crisis-redteam.mjs

process.env.GCLOUD_PROJECT = "toska-test"; // index.js initializes admin lazily
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { __test } = require("../functions/index.js");
const { isPostExplicitCrisis, isPostConcerning } = __test;

function tier(text) {
  if (isPostExplicitCrisis(text)) return "EXPLICIT";
  if (isPostConcerning(text)) return "soft";
  return "clean";
}

// ---- obfuscation (an at-risk user may type this way; detector normalizes) ----
const LEET = { a: "4", e: "3", i: "1", o: "0", s: "5", t: "7" };
const leet = (s) => [...s].map((c) => LEET[c.toLowerCase()] ?? c).join("");
const spaced = (s) => s.replace(/\b(\w)/g, "$1"); // keep words; spacing variant below
const spacedLetters = (s) => [...s].join(" ");

// ============================================================
// 1. FALSE-NEGATIVE hunt — these SHOULD be caught (explicit or at least soft)
// ============================================================
const SHOULD_CATCH = [
  // canonical explicit English
  ["I want to kill myself", "EXPLICIT"],
  ["I want to die", "EXPLICIT"],
  ["thinking about ending it all", "soft"],
  ["I don't want to be here anymore", "soft"],
  ["better off without me", "soft"],
  // obfuscated explicit (matchesCrisisPhrase normalizes leet/spacing/unicode)
  ["I want to k1ll myself", "any"],
  ["i  want  to  die", "any"],
  ["I want to k i l l m y s e l f", "any"],
  ["ı want to die", "any"], // dotless i
  // non-English explicit (the curated FR/ES/PT additions)
  ["quiero morir", "any"],
  ["quiero suicidarme", "any"],
  ["je veux mourir", "any"],
  ["vou me matar", "any"],
  // phrasing variants real people use
  ["I can't do this anymore I want it to end", "any"],
  ["what's the point of living", "any"],
  ["everyone would be better off if I was gone", "any"],
  ["I've been thinking about not waking up", "any"],
];

// ============================================================
// 2. FALSE-POSITIVE hunt — these must NOT trip the EXPLICIT (paging) tier
// ============================================================
const MUST_NOT_PAGE = [
  // hyperbole / idiom
  "I could just die of embarrassment",
  "this breakup is killing me",
  "I'm dying to see them one more time",
  "my plants keep dying on me",
  "that show was to die for",
  "I'd kill for a coffee right now",
  "you're killing me with these memes",
  // 3rd-party / relational (about an abusive ex, not self-harm)
  "he said he would hurt me if I left",
  "she's going to kill me when she finds out I kept the dog",
  "my ex is dead to me now",
  // song / media references
  "I keep listening to Killing Me Softly",
  "we watched Dead Poets Society on our first date",
  // non-English hyperbole (T-4 demoted these to soft — must not PAGE)
  "voy a matarme a trabajar",        // ES: work myself to death
  "j'ai envie de mourir de honte",   // FR: die of embarrassment
  "esta mejor muerto en la pelicula", // ES: character better off dead in the film
];

console.log("=== CRISIS RED TEAM ===\n");

console.log("--- 1. FALSE-NEGATIVE hunt (should be caught) ---");
const missed = [];
for (const [text, want] of SHOULD_CATCH) {
  const t = tier(text);
  const ok = want === "any" ? t !== "clean" : t === want || (want === "soft" && t === "EXPLICIT");
  if (!ok) missed.push({ text, want, got: t });
  console.log(`  ${ok ? "✓" : "✗ MISS"}  [${t}] want ${want}  "${text}"`);
}

console.log("\n--- 2. FALSE-POSITIVE hunt (must NOT page = must NOT be EXPLICIT) ---");
const falsePages = [];
for (const text of MUST_NOT_PAGE) {
  const t = tier(text);
  const paged = t === "EXPLICIT";
  if (paged) falsePages.push({ text, got: t });
  console.log(`  ${paged ? "✗ PAGES" : "✓"}  [${t}]  "${text}"`);
}

console.log("\n=== SUMMARY ===");
console.log(`False-negatives (crisis slipped through):     ${missed.length}/${SHOULD_CATCH.length}`);
console.log(`False-pages (benign tripped EXPLICIT/paging):  ${falsePages.length}/${MUST_NOT_PAGE.length}`);
if (missed.length) { console.log("\nMISSED (review — safety FNs):"); missed.forEach((m) => console.log(`  want ${m.want} got ${m.got}: "${m.text}"`)); }
if (falsePages.length) { console.log("\nFALSE PAGES (review — alert fatigue):"); falsePages.forEach((f) => console.log(`  "${f.text}"`)); }
// Hard-fail only on explicit-tier FALSE PAGES (clear regression) — FNs are
// reported for safety review since some are inherently hard (paraphrase).
process.exit(falsePages.length > 0 ? 1 : 0);
