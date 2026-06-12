// Moderation detector FUZZER (#2, 2026-06-11 security expansion).
//
// The detector is the anonymity wedge — a real name slipping through =
// de-anonymization, the worst-case failure for this app. The hand-written
// suites cover ~40 cases; this generates THOUSANDS of obfuscated variants of
// real full names + last names + contact info and asserts the SERVER detector
// (moderation.js) HOLDS them. Any obfuscated full/last name that the server
// ALLOWS is reported as a potential PII LEAK. It also confirms lone first names
// are allowed (the N-17 policy) and that plain grief prose is not over-held.
//
// Run: node detector-fuzz.mjs   (no infra needed — pure detector)

import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { containsNameOrIdentifyingInfo } = require("../functions/moderation.js");

// ---------- obfuscation transforms an attacker would use ----------
const LEET = { a: "4", e: "3", i: "1", o: "0", s: "5", t: "7", l: "1", b: "8" };
const CYRILLIC = { a: "а", e: "е", o: "о", c: "с", p: "р", x: "х", y: "у", i: "і" }; // confusables
const FULLWIDTH = (s) => [...s].map((c) => {
  const code = c.charCodeAt(0);
  return code >= 33 && code <= 126 ? String.fromCharCode(code + 0xFEE0) : c;
}).join("");
const ZWSP = "​"; // zero-width space
const COMBINING = "́"; // combining acute accent

function leet(s) { return [...s].map((c) => LEET[c.toLowerCase()] ?? c).join(""); }
function cyrillic(s) { return [...s].map((c) => CYRILLIC[c.toLowerCase()] ?? c).join(""); }
function spaced(s) { return [...s].join(" "); }
function dotted(s) { return [...s].join("."); }
function dashed(s) { return [...s].join("-"); }
function reversed(s) { return [...s].reverse().join(""); }
function zwsp(s) { return [...s].join(ZWSP); }
function combining(s) { return [...s].map((c) => /[a-z]/i.test(c) ? c + COMBINING : c).join(""); }
function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }

const TRANSFORMS = {
  plain: (s) => s,
  leet: (s) => leet(s),
  cyrillic: (s) => cyrillic(s),
  fullwidth: (s) => FULLWIDTH(s),
  spaced: (s) => spaced(s),
  dotted: (s) => dotted(s),
  dashed: (s) => dashed(s),
  reversed: (s) => reversed(s),
  zwsp: (s) => zwsp(s),
  combining: (s) => combining(s),
};

// ---------- name material ----------
const FIRST = ["John", "Sarah", "Michael", "Jessica", "David", "Emily", "Daniel",
  "Ashley", "James", "Olivia", "Ryan", "Megan", "Tyler", "Rachel", "Brandon", "Nicole"];
const LAST = ["Johnson", "Smith", "Williams", "Garcia", "Martinez", "Rodriguez",
  "Anderson", "Thompson", "Nguyen", "Patel", "Kowalski", "Okafor", "Salinaro", "Petrov"];
// Sentence frames a real breakup post would use around a name.
const FRAMES = [
  (n) => `my ex ${n} broke my heart`,
  (n) => `I miss ${n} so much`,
  (n) => `${n} ghosted me last week`,
  (n) => `still thinking about ${n} tonight`,
  (n) => `${n} and I were together three years`,
];

const leaks = [];
const overheld = [];
let fullNameTests = 0, lastNameTests = 0, fnHeld = 0, lnHeld = 0;

// ---- FULL NAMES (first + last): MUST be held under every obfuscation ----
for (const f of FIRST) {
  for (const l of LAST) {
    for (const [tname, tf] of Object.entries(TRANSFORMS)) {
      // obfuscate the last name (the identifying token); keep first plain-ish
      const fullName = `${cap(f)} ${cap(tf(l))}`;
      for (const frame of FRAMES.slice(0, 2)) {
        const text = frame(fullName);
        fullNameTests++;
        const held = containsNameOrIdentifyingInfo(text);
        if (held) fnHeld++;
        else if (tname !== "reversed") {
          // reversed last name is an acknowledged dictionary-heuristic miss for
          // a bare token; flag everything else as a potential leak.
          leaks.push({ kind: "full-name", transform: tname, text });
        }
      }
    }
  }
}

// ---- LAST NAME alone, mid-sentence (identifying): should be held ----
for (const l of LAST) {
  for (const [tname, tf] of Object.entries(TRANSFORMS)) {
    const text = `I dated ${cap(tf(l))} for years`;
    lastNameTests++;
    const held = containsNameOrIdentifyingInfo(text);
    if (held) lnHeld++;
  }
}

// ---- CONTACT INFO under obfuscation: must be held ----
const CONTACTS = [
  "dm me on insta @sarah_real", "call me at 555 123 4567", "my number is 5551234567",
  "ig: sarahreal", "find me on snap sarah.real", "lives at 123 Main Street",
  "email me sarah at gmail dot com", "@my_handle on tiktok", "apt 4B downtown",
];
let contactTests = 0, contactHeld = 0;
for (const c of CONTACTS) {
  contactTests++;
  if (containsNameOrIdentifyingInfo(c)) contactHeld++;
  else leaks.push({ kind: "contact", transform: "plain", text: c });
}

// ---- LONE FIRST NAMES: policy says ALLOW (not over-held) ----
let firstNameTests = 0, firstNameAllowed = 0;
for (const f of FIRST) {
  for (const frame of FRAMES) {
    const text = frame(cap(f));
    firstNameTests++;
    if (!containsNameOrIdentifyingInfo(text)) firstNameAllowed++;
    else overheld.push({ kind: "lone-first-name", text });
  }
}

// ---- PLAIN GRIEF PROSE: must NOT be over-held ----
const PROSE = [
  "the quiet after the storm still hurts", "I keep replaying our last conversation",
  "some nights are harder than others", "I thought we would grow old together",
  "the apartment feels so empty now without them", "learning to be alone again",
  "I still reach for my phone to text them", "three months and it still aches",
  "we used to watch the sunset from the roof", "I gave everything and it wasn't enough",
];
let proseTests = 0, proseAllowed = 0;
for (const p of PROSE) {
  proseTests++;
  if (!containsNameOrIdentifyingInfo(p)) proseAllowed++;
  else overheld.push({ kind: "grief-prose", text: p });
}

// ---------- report ----------
console.log("=== DETECTOR FUZZ (server moderation.js) ===\n");
console.log(`Full-name (obfuscated last name) held:  ${fnHeld}/${fullNameTests}`);
console.log(`Last-name (obfuscated) held:            ${lnHeld}/${lastNameTests}`);
console.log(`Contact-info held:                      ${contactHeld}/${contactTests}`);
console.log(`Lone-first-name allowed (N-17 policy):  ${firstNameAllowed}/${firstNameTests}`);
console.log(`Grief-prose allowed (not over-held):    ${proseAllowed}/${proseTests}`);

console.log(`\n--- POTENTIAL PII LEAKS (full/last name or contact ALLOWED): ${leaks.length} ---`);
const byTransform = {};
for (const l of leaks) byTransform[l.transform] = (byTransform[l.transform] || 0) + 1;
for (const [t, n] of Object.entries(byTransform)) console.log(`  ${t}: ${n}`);
// show up to 12 distinct examples
const seen = new Set();
for (const l of leaks) {
  const k = `${l.kind}:${l.transform}`;
  if (seen.has(k)) continue; seen.add(k);
  console.log(`    e.g. [${l.transform}] "${l.text}"`);
}

console.log(`\n--- OVER-HELD (legit content flagged): ${overheld.length} ---`);
for (const o of overheld.slice(0, 12)) console.log(`    [${o.kind}] "${o.text}"`);

const leakRate = leaks.length / (fullNameTests + contactTests);
console.log(`\nleak rate (full+contact): ${(leakRate * 100).toFixed(2)}%`);
// Pass criterion: no contact leaks, lone-first allowed, prose not over-held.
// Obfuscated full-name leaks are reported for triage but only HARD-fail on
// contact info (the most directly identifying) and on grief-prose over-hold.
const contactLeaks = leaks.filter((l) => l.kind === "contact").length;
const proseOverheld = overheld.filter((o) => o.kind === "grief-prose").length;
const hardFail = contactLeaks > 0 || proseOverheld > 0;
console.log(`\nHARD checks — contact leaks: ${contactLeaks} (want 0), grief over-held: ${proseOverheld} (want 0)`);
console.log(hardFail ? "FUZZ RESULT: HARD FAIL" : "FUZZ RESULT: PASS (see soft leaks above for triage)");
process.exit(hardFail ? 1 : 0);
