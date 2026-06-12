// Client/server PII-detector PARITY check (T-1, 2026-06-11).
//
// The name/PII detector exists in BOTH functions/moderation.js
// (containsNameOrIdentifyingInfo — the server HOLD decision) and
// toska/FeedView.swift (containsNameOrIdentifyingInfo — the compose-time
// warning). They are hand-synced with no automated pin, and three server-side
// false-positive fixes (M-2 title-words guard, N-13 number-list strip,
// N-13/N-15 keyword trims) once drifted: the client warned on grief content
// ("Pearl Jam", "Central Park", "my Broken Heart", timeline number lists,
// "lives in my head") that the server accepted.
//
// This script EXTRACTS the real Swift detector from FeedView.swift, compiles it
// standalone (swiftc -enable-bare-slash-regex), runs a shared corpus through it
// AND through moderation.js, and FAILS (exit 1) on any divergence. It is the
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
];

// ── Extract the Swift detector + its helpers from FeedView.swift ──
const swiftSrc = readFileSync(join(import.meta.dirname, "../toska/FeedView.swift"), "utf8").split("\n");
const startIdx = swiftSrc.findIndex((l) => l.startsWith("private let nameConfusableMap"));
const fnIdx = swiftSrc.findIndex((l) => l.startsWith("func containsNameOrIdentifyingInfo"));
if (startIdx < 0 || fnIdx < 0) { console.error("could not locate Swift detector"); process.exit(2); }
// Function closes at the first line that is exactly "}" at col 0 after fnIdx.
let endIdx = -1;
for (let i = fnIdx + 1; i < swiftSrc.length; i++) { if (swiftSrc[i] === "}") { endIdx = i; break; } }
if (endIdx < 0) { console.error("could not find detector function close"); process.exit(2); }
const detectorSrc = swiftSrc.slice(startIdx, endIdx + 1).join("\n");

const corpusSwift = CORPUS.map(([t]) => `  ${JSON.stringify(t)},`).join("\n");
const harness = `import Foundation
${detectorSrc}
let corpus = [
${corpusSwift}
]
for t in corpus {
  print((containsNameOrIdentifyingInfo(t) ? "hold" : "allow") + "\\t" + t)
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
const clientVerdict = new Map(clientOut.map((line) => { const [v, ...rest] = line.split("\t"); return [rest.join("\t"), v]; }));

// ── Compare ──
let mismatches = 0;
for (const [text, expected] of CORPUS) {
  const server = serverDetect(text) ? "hold" : "allow";
  const client = clientVerdict.get(text);
  const agree = server === client;
  const meetsExpected = server === expected && client === expected;
  if (!agree || !meetsExpected) {
    mismatches++;
    console.log(`✗ server=${server} client=${client} expected=${expected}  | ${text}`);
  }
}
if (mismatches === 0) {
  console.log(`✓ detector parity: ${CORPUS.length}/${CORPUS.length} cases — client and server agree and match expected`);
  process.exit(0);
} else {
  console.error(`\n${mismatches} parity mismatch(es) — the Swift and JS detectors have drifted. Re-sync FeedView.swift and moderation.js.`);
  process.exit(1);
}
