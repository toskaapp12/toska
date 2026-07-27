// Client/server PII-detector PARITY check (T-1, 2026-06-11).
//
// The name/PII detector exists in BOTH functions/moderation.js
// (containsNameOrIdentifyingInfo — the server HOLD decision) and
// toska/ContentModeration.swift (containsNameOrIdentifyingInfo — the compose-
// time warning). They are hand-synced with no automated pin, and three server-side
// false-positive fixes (M-2 title-words guard, N-13 number-list strip,
// N-13/N-15 keyword trims) once drifted: the client warned on grief content
// ("Pearl Jam", "Central Park", "my Broken Heart", timeline number lists,
// "lives in my head") that the server accepted.
//
// This script EXTRACTS the real Swift detector + crisis matcher from
// ContentModeration.swift, compiles it standalone (swiftc -enable-bare-slash-
// regex), runs shared name + crisis corpora through it AND through
// moderation.js / moderationLogic.js, and FAILS (exit 1) on any divergence. It is the
// missing pin. Requires macOS + a Swift toolchain, so it is NOT part of the
// default `npm test` (which must run on any CI); run it on a macOS lane:
//
//   node detector-parity.mjs
//
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { containsNameOrIdentifyingInfo: serverDetect } = require("../functions/moderation.js");
// Crisis matcher parity (added 2026-06-30): the crisis phrase lists + matcher
// exist in BOTH moderationLogic.js (matchesCrisisPhrase / isPostExplicitCrisis /
// isPostConcerning) and ContentModeration.swift (crisisPhraseMatch / crisisLevel),
// hand-synced with no pin — the same drift risk as the name path. Pin them too.
const { isPostExplicitCrisis, isPostConcerning } = require("../functions/moderationLogic.js");
function serverCrisis(t) {
  if (isPostExplicitCrisis(t)) return "explicit";
  if (isPostConcerning(t)) return "soft";
  return "none";
}
// Crisis corpus: [text, expected level]. Includes the leet-evasion strings the
// 2026-06-30 fix closed (1/!/| → i or l) plus benign digit/punctuation lines
// that must NOT over-detect from the ambiguous-glyph expansion.
const CRISIS_CORPUS = [
  ["i want to kill myself", "explicit"],
  ["i want to ki11 myself", "explicit"],   // 1 -> l
  ["i want to k!ll myself", "explicit"],   // ! -> i
  ["i want to ki|| myself", "explicit"],   // | -> l
  ["i think about su1c1de a lot", "explicit"], // 1 -> i in-word
  ["thinking about su!c!de tonight", "explicit"], // ! -> i in-word
  ["i feel so suicidal", "explicit"],
  ["i can't go on", "soft"],
  ["nobody would miss me", "soft"],
  ["there's no point in living", "soft"],
  ["this breakup is killing me", "none"],  // idiom
  ["i could die of embarrassment", "none"],// idiom
  ["1 more day and then i'm free!", "none"],// benign digit/! — no over-detection
  ["he broke my heart!!! i hate this", "none"], // benign ! run
  // 2026-07-27 algospeak — true positives
  ["thinking about sewerslide tonight", "explicit"], // suicide algospeak
  ["i keep thinking about self deletion", "explicit"],
  ["im suuuuicidal rn", "explicit"],       // repeated-char padding
  ["dealing with sa from my ex", "soft"],  // SA disclosure (word-boundary)
  ["he did s.a. to me", "soft"],           // dotted initialism
  ["still processing my csa", "soft"],
  ["finally leaving a dv situation", "soft"],
  ["struggling with sh again", "soft"],    // self-harm shorthand
  ["back in my 9rippy sock era", "soft"],  // 9->g leet + coded term
  ["might just yeet myself lol", "soft"],
  // 2026-07-27 algospeak — false-positive guards (must stay "none")
  ["salsa dancing then visa paperwork", "none"], // sa inside salsa/visa
  ["moving back to the usa", "none"],
  ["i wish i could sleep, my sister called", "none"], // sh in wish, si in sister
  ["the sky is the limit for us", "none"], // kys/sky FP fix
  ["shes a pro analyst at a thin spot", "none"], // proana/thinspo space-strip FP
  ["i wanted him to stay", "none"],        // ed in wanted
  ["si tu quieres podemos hablar", "none"],// Spanish "si" not flagged
];

// Shared corpus: [text, expected]  — expected is the agreed verdict both layers
// must produce. 'allow' = clean (no warning / no hold); 'hold' = flagged.
const CORPUS = [
  // N-17: plain lone first names allowed
  ["I miss John so much", "allow"],
  ["my ex Sarah broke my heart", "allow"],
  ["Jessica's laugh haunts me", "allow"],
  ["this guy Tyler ghosted me", "allow"],
  // The three server FP-fixes (must be 'allow' on BOTH layers):
  ["he lives in my head rent free", "allow"],     // N-13/N-15 keyword trim
  ["adapt to change is hard", "allow"],            // "apt " substring trim
  ["the suite life is over", "allow"],             // "suite " trim
  ["my apartment is empty now", "allow"],          // "apartment" trim
  ["he goes to my gym still", "allow"],            // "goes to" trim
  ["we dated in 2019 2020 2021 2022 2023", "allow"], // M-2 number-list strip
  ["I still hear Pearl Jam", "allow"],             // M-2 title-words
  ["we met at Central Park", "allow"],             // M-2 title-words
  ["that Last Night together", "allow"],           // M-2 title-words
  ["those Empty Promises", "allow"],               // M-2 title-words
  ["my Broken Heart", "allow"],                    // M-2 title-words
  // Must STILL hold on both layers (no over-correction):
  ["my ex Sarah Johnson did this", "hold"],        // full name
  ["his name is David Smith", "hold"],             // full name
  ["Sarah Park broke my heart", "hold"],           // name + title word → still a name
  ["dm me on insta", "hold"],                      // contact
  ["my ex @sarahreal", "hold"],                    // handle
  ["call me at 555 123 4567", "hold"],             // phone
  ["she lives at 123 Main Street", "hold"],        // address
  ["I miss J0hn", "hold"],                         // obfuscated first name
  ["thinking of Mіchael", "hold"],                 // Cyrillic confusable
  // #2 fuzz (2026-06-11): spelled-out email must hold on BOTH layers
  ["email me sarah at gmail dot com", "hold"],
  ["reach me john dot smith at gmail dot com", "hold"],
  // …and must NOT over-hold ordinary prose with "at"/"dot"
  ["I was never good at math", "allow"],
  ["look at this dot to dot puzzle", "allow"],
  // F-1 (2026-06-12): math-alphanumeric "fancy text" names must HOLD on both
  // layers (they fold to legible Latin names but bypassed the ASCII gates).
  ["my ex \u{1D412}\u{1D426}\u{1D422}\u{1D42D}\u{1D421}", "hold"], // math-bold "Smith" lone surname
  // F-2: "ig" handle handoff without a separator must HOLD
  ["my ig is sarahreal", "hold"],
  ["follow my dreams", "allow"], // …but a bare "my X" with no handle stays allowed
  // B-1 (2026-06-16): a known LAST name as a SENTENCE SUBJECT must HOLD on both
  // layers — the sentence-starter exemption used to spare it, leaking a surname.
  ["Garcia broke my heart", "hold"],               // surname as sentence subject
  ["Johnson cheated on me", "hold"],               // surname as sentence subject
  ["I'm devastated. Garcia left me.", "hold"],     // surname starting a later sentence
  // …but a pure FIRST name as a sentence subject must STILL be allowed (the fix
  // must not over-hold the modal "I miss <firstname>" prose).
  ["Sarah broke my heart", "allow"],               // first name as sentence subject
  // B-2 (2026-06-16): doxxable location-context now fires on BOTH layers (the
  // client warning was previously server-only). Workplace/education anchors are
  // case-sensitive; place/city patterns are case-insensitive.
  ["he works at Chicago Mercy Hospital", "hold"],  // workplace + institution
  ["she goes to UCLA", "hold"],                     // education + institution
  ["from brooklyn", "hold"],                        // city context (lowercase)
  ["meet me near the hospital", "hold"],            // locator + place noun
  ["we worked at the same place", "allow"],         // generic venting, no anchor
];

// ── Extract the Swift detector + its helpers from FeedView.swift ──
const swiftSrc = readFileSync(join(import.meta.dirname, "../toska/ContentModeration.swift"), "utf8").split("\n");
// Start the extraction at the crisis phrase lists (line ~33) rather than the
// name-confusable map, so the compiled binary ALSO exposes crisisLevel() and its
// helpers — the span from here through containsNameOrIdentifyingInfo's close is
// self-contained (the normalizer + its deps sit inside it).
const startIdx = swiftSrc.findIndex((l) => l.startsWith("let explicitCrisisPhrases"));
const fnIdx = swiftSrc.findIndex((l) => l.startsWith("func containsNameOrIdentifyingInfo"));
if (startIdx < 0 || fnIdx < 0) { console.error("could not locate Swift detector"); process.exit(2); }
// Function closes at the first line that is exactly "}" at col 0 after fnIdx.
let endIdx = -1;
for (let i = fnIdx + 1; i < swiftSrc.length; i++) { if (swiftSrc[i] === "}") { endIdx = i; break; } }
if (endIdx < 0) { console.error("could not find detector function close"); process.exit(2); }
const detectorSrc = swiftSrc.slice(startIdx, endIdx + 1).join("\n");

const corpusSwift = CORPUS.map(([t]) => `  ${JSON.stringify(t)},`).join("\n");
const crisisSwift = CRISIS_CORPUS.map(([t]) => `  ${JSON.stringify(t)},`).join("\n");
const harness = `import Foundation
${detectorSrc}
func crisisVerdict(_ t: String) -> String {
  switch crisisLevel(for: t) {
  case .explicit: return "explicit"
  case .soft: return "soft"
  case .none: return "none"
  }
}
let corpus = [
${corpusSwift}
]
for t in corpus {
  print((containsNameOrIdentifyingInfo(t) ? "hold" : "allow") + "\\t" + t)
}
let crisisCorpus = [
${crisisSwift}
]
for t in crisisCorpus {
  print("CRISIS\\t" + crisisVerdict(t) + "\\t" + t)
}
`;

const dir = mkdtempSync(join(tmpdir(), "toska-parity-"));
const swiftFile = join(dir, "parity.swift");
const binFile = join(dir, "parity_bin");
writeFileSync(swiftFile, harness);
try {
  execFileSync("swiftc", ["-enable-bare-slash-regex", swiftFile, "-o", binFile], { stdio: ["ignore", "ignore", "inherit"] });
} catch {
  console.error("swiftc failed (need macOS + Swift toolchain to run the parity check)");
  process.exit(2);
}
const clientOut = execFileSync(binFile, { encoding: "utf8" }).trim().split("\n");
const clientVerdict = new Map();
const clientCrisis = new Map();
for (const line of clientOut) {
  const parts = line.split("\t");
  if (parts[0] === "CRISIS") {
    clientCrisis.set(parts.slice(2).join("\t"), parts[1]);
  } else {
    clientVerdict.set(parts.slice(1).join("\t"), parts[0]);
  }
}

// ── Compare ──
let mismatches = 0;
for (const [text, expected] of CORPUS) {
  const server = serverDetect(text) ? "hold" : "allow";
  const client = clientVerdict.get(text);
  const agree = server === client;
  const meetsExpected = server === expected && client === expected;
  if (!agree || !meetsExpected) {
    mismatches++;
    console.log(`✗ NAME server=${server} client=${client} expected=${expected}  | ${text}`);
  }
}
for (const [text, expected] of CRISIS_CORPUS) {
  const server = serverCrisis(text);
  const client = clientCrisis.get(text);
  const agree = server === client;
  const meetsExpected = server === expected && client === expected;
  if (!agree || !meetsExpected) {
    mismatches++;
    console.log(`✗ CRISIS server=${server} client=${client} expected=${expected}  | ${text}`);
  }
}
const total = CORPUS.length + CRISIS_CORPUS.length;
if (mismatches === 0) {
  console.log(`✓ detector parity: ${total}/${total} cases (name + crisis) — client and server agree and match expected`);
  process.exit(0);
} else {
  console.error(`\n${mismatches} parity mismatch(es) — the Swift and JS detectors have drifted. Re-sync ContentModeration.swift with moderation.js / moderationLogic.js.`);
  process.exit(1);
}
