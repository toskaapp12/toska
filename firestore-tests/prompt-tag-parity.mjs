// Cross-platform constant parity: daily prompts + post tags (2026-09-21
// fresh-eyes review). These lists are hand-duplicated in the iOS client and
// the web client, and "today's prompt" is picked as dayOfYear % list.length
// on each platform independently — so a single added/removed/edited entry on
// one side silently shows DIFFERENT prompts per platform and mislabels
// prompt responses (promptDate semantics). Crisis lists have had a parity
// gate since July; prompts/tags get the same treatment here.
//
// Run: node prompt-tag-parity.mjs   (exits 1 on any divergence)
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const ios = readFileSync(join(root, "toska/FeedViewModel.swift"), "utf8");
const web = readFileSync(join(root, "webapp/js/app.js"), "utf8");
const writes = readFileSync(join(root, "webapp/js/writes.js"), "utf8");

let failed = false;
const fail = (msg) => { console.error("✗ " + msg); failed = true; };

// ---- prompts -------------------------------------------------------------
// iOS: dailyPrompts: [(String, String, String)] = [ ("text", "tag", "icon"), … ]
// Array closes with 8-space-indented "]" — the next tuple-looking code
// after it (a fallback return in a function) must NOT be swallowed.
const iosBlock = ios.split("dailyPrompts: [(String, String, String)] = [")[1]
    ?.split("\n        ]")[0] ?? "";
const iosPrompts = [...iosBlock.matchAll(/\(\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"/g)]
    .map((m) => [m[1], m[2]]);

// web: DAILY_PROMPTS = [ ["text", "tag"], … ]
const webBlock = web.split("DAILY_PROMPTS = [")[1]?.split("\n];")[0] ?? "";
const webPrompts = [...webBlock.matchAll(/\[\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"\]/g)]
    .map((m) => [m[1], m[2]]);

if (!iosPrompts.length || !webPrompts.length) {
    fail(`prompt extraction broke (iOS ${iosPrompts.length}, web ${webPrompts.length}) — update the regexes in this script`);
} else if (iosPrompts.length !== webPrompts.length) {
    fail(`prompt COUNT diverged: iOS ${iosPrompts.length} vs web ${webPrompts.length} — dayOfYear %% length now differs per platform`);
} else {
    iosPrompts.forEach(([text, tag], i) => {
        const [wText, wTag] = webPrompts[i];
        if (text !== wText) fail(`prompt ${i} text diverged:\n    iOS: ${text}\n    web: ${wText}`);
        if (tag !== wTag) fail(`prompt ${i} tag diverged: iOS "${tag}" vs web "${wTag}"`);
    });
}

// ---- tags ----------------------------------------------------------------
// iOS single source: sharedTags TagItem entries in FeedView.swift.
const feedView = readFileSync(join(root, "toska/FeedView.swift"), "utf8");
const iosTagsBlock = feedView.split("let sharedTags: [TagItem] = [")[1]?.split("\n]")[0] ?? "";
const iosTags = [...iosTagsBlock.matchAll(/TagItem\(name:\s*"([a-z ]+)"/g)].map((m) => m[1]);
// web: POST_TAGS = ["longing", …]
const webTagsBlock = writes.split("POST_TAGS = [")[1]?.split("]")[0] ?? "";
const webTags = [...webTagsBlock.matchAll(/"([a-z ]+)"/g)].map((m) => m[1]);

if (!iosTags.length || !webTags.length) {
    fail(`tag extraction broke (iOS ${iosTags.length}, web ${webTags.length}) — update the regexes in this script`);
} else {
    const iosSet = new Set(iosTags), webSet = new Set(webTags);
    for (const t of webSet) if (!iosSet.has(t)) fail(`web tag "${t}" missing from iOS sharedTags`);
    for (const t of iosSet) if (!webSet.has(t)) fail(`iOS tag "${t}" missing from web POST_TAGS`);
}

if (failed) process.exit(1);
console.log(`✓ prompt parity: ${iosPrompts.length} prompts identical (text+tag) across iOS/web`);
console.log(`✓ tag parity: ${webTags.length} post tags present on both platforms`);
