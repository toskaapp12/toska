// Crisis-list PARITY check (2026-06-11). The crisis phrase lists are mirrored
// in functions/index.js (MOD_CRISIS_EXPLICIT / MOD_CRISIS_SOFT) and the Swift
// client (toska/ContentModeration.swift: explicitCrisisPhrases /
// softConcernPhrases). They are hand-synced with NO automated pin — and they
// DID drift (the #1 review finding: the client matcher + lists lagged the
// server, so obfuscated/added phrases held server-side but showed no client
// check-in). This extracts both sides and fails (exit 1) on any divergence in
// the ENGLISH/shared phrase sets, so future edits can't silently desync the
// safety rail. Run: node crisis-parity.mjs
//
// (The detector's NORMALIZATION is pinned separately by detector-parity.mjs for
// the PII path; the client crisis matcher now mirrors matchesCrisisPhrase too.)

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
process.env.GCLOUD_PROJECT = "toska-test";
const { __test } = require("../functions/index.js");

// Server: MOD_EXPLICIT_CRISIS, and MOD_CONCERNING = explicit ∪ soft.
const serverExplicit = new Set(__test.MOD_EXPLICIT_CRISIS);
const serverSoft = new Set(__test.MOD_CONCERNING.filter((p) => !serverExplicit.has(p)));

// Client: parse the two Swift array literals from ContentModeration.swift.
const swift = readFileSync(join(import.meta.dirname, "../toska/ContentModeration.swift"), "utf8");
function parseSwiftArray(name) {
  const start = swift.indexOf(`let ${name} = [`);
  if (start < 0) { console.error(`could not find ${name}`); process.exit(2); }
  const open = swift.indexOf("[", start);
  const close = swift.indexOf("\n]", open);
  const body = swift.slice(open + 1, close);
  // pull every "double-quoted" string literal, ignoring // comments
  return new Set(
    body.split("\n")
      .map((l) => l.replace(/\/\/.*$/, ""))
      .join("\n")
      .match(/"(?:[^"\\]|\\.)*"/g)
      ?.map((s) => JSON.parse(s)) ?? []
  );
}
const clientExplicit = parseSwiftArray("explicitCrisisPhrases");
const clientSoft = parseSwiftArray("softConcernPhrases");

function diff(label, server, client) {
  const onlyServer = [...server].filter((p) => !client.has(p));
  const onlyClient = [...client].filter((p) => !server.has(p));
  console.log(`${label}: server ${server.size}, client ${client.size}`);
  if (onlyServer.length) console.log(`  server-only (${onlyServer.length}): ${onlyServer.slice(0, 8).join(" | ")}`);
  if (onlyClient.length) console.log(`  client-only (${onlyClient.length}): ${onlyClient.slice(0, 8).join(" | ")}`);
  return onlyServer.length + onlyClient.length;
}

console.log("=== CRISIS LIST PARITY (server index.js vs client ContentModeration.swift) ===");
let drift = 0;
drift += diff("EXPLICIT tier", serverExplicit, clientExplicit);
drift += diff("SOFT tier", serverSoft, clientSoft);

if (drift === 0) {
  console.log("\n✓ crisis lists in parity — explicit and soft tiers match exactly");
  process.exit(0);
}
console.error(`\n✗ ${drift} crisis-phrase divergence(s) — the client check-in rail and the server hold have drifted. Re-sync ContentModeration.swift with index.js MOD_CRISIS_*.`);
process.exit(1);
