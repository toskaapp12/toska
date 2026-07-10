// Daily-prompt PARITY PIN (2026-07-09, closes F-P5-1).
//
// iOS FeedViewModel.dailyPrompts and web webapp/js/app.js DAILY_PROMPTS are
// each a client-static list; both surfaces pick today's prompt via
// `dayOfYear % count`. If the two lists differ in LENGTH or CONTENT, `% N`
// vs `% M` selects a DIFFERENT prompt per surface every day (the exact bug
// F-P5-1: iOS had grown to 395 while web was stuck at 40). This pin fails CI
// the moment they drift so it can't recur. Compares (text, tag) in order.
//
// Run: `node prompt-parity.mjs` (wired into `npm run test:pins`).

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

// iOS: tuples `("text", "tag", "icon"),` inside `static let dailyPrompts = [ ... ]`.
function parseIOS() {
  const src = readFileSync(join(root, "toska", "FeedViewModel.swift"), "utf8").split("\n");
  const out = [];
  let inArray = false;
  for (const line of src) {
    if (!inArray) {
      if (/static let dailyPrompts\b.*\[/.test(line)) inArray = true;
      continue;
    }
    if (/^\s*\]/.test(line)) break; // end of array
    const m = line.match(/^\s*\("(.*?)",\s*"(.*?)",\s*"(.*?)"\),?\s*$/);
    if (m) out.push([m[1], m[2]]);
  }
  return out;
}

// web: entries `["text", "tag"],` inside `const DAILY_PROMPTS = [ ... ];`.
function parseWeb() {
  const src = readFileSync(join(root, "webapp", "js", "app.js"), "utf8").split("\n");
  const out = [];
  let inArray = false;
  for (const line of src) {
    if (!inArray) {
      if (/const DAILY_PROMPTS\s*=\s*\[/.test(line)) inArray = true;
      continue;
    }
    if (/^\s*\];/.test(line)) break;
    const m = line.match(/^\s*\["(.*?)",\s*"(.*?)"\],?\s*$/);
    if (m) out.push([m[1], m[2]]);
  }
  return out;
}

const ios = parseIOS();
const web = parseWeb();

console.log("=== DAILY-PROMPT PARITY (iOS FeedViewModel.dailyPrompts vs web app.js DAILY_PROMPTS) ===");
console.log(`iOS entries: ${ios.length}, web entries: ${web.length}`);

const problems = [];
if (ios.length === 0) problems.push("parsed 0 iOS prompts — the parser or the Swift array shape changed");
if (web.length === 0) problems.push("parsed 0 web prompts — the parser or the JS array shape changed");
if (ios.length !== web.length) {
  problems.push(`LENGTH mismatch: iOS ${ios.length} vs web ${web.length} → dayOfYear % count diverges every day`);
}
const n = Math.min(ios.length, web.length);
let contentDrift = 0;
for (let i = 0; i < n; i++) {
  if (ios[i][0] !== web[i][0] || ios[i][1] !== web[i][1]) {
    if (contentDrift < 5) {
      console.error(`  index ${i} differs:\n    iOS: ${JSON.stringify(ios[i])}\n    web: ${JSON.stringify(web[i])}`);
    }
    contentDrift++;
  }
}
if (contentDrift > 0) problems.push(`${contentDrift} entr${contentDrift === 1 ? "y" : "ies"} differ in text/tag`);

if (problems.length === 0) {
  console.log(`\n✓ daily-prompt lists in parity — ${ios.length} entries, identical order + text + tag`);
  process.exit(0);
}
console.error(`\n✗ daily-prompt DRIFT: ${problems.join("; ")}.`);
console.error("Regenerate web DAILY_PROMPTS verbatim from FeedViewModel.dailyPrompts (text, tag), same order.");
process.exit(1);
