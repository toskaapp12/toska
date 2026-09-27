#!/usr/bin/env node
// toska web-app + security audit (owner-requested, 2026-09-27).
//
//   node scripts/audit_web_security.mjs            # static + config checks
//   LIVE=1 node scripts/audit_web_security.mjs     # + live checks against app.toskaapp.com
//
// Exit 0 = clean, 1 = findings. Designed to run in CI (static+config) and
// by hand with LIVE=1 after any hosting deploy. This is the webapp's
// standing guard — it has no E2E harness, so every class of bug we've
// fixed by hand gets a check here to keep it fixed.
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
let failures = 0;
const fail = (msg) => { failures++; console.error("  ✗ " + msg); };
const ok = (msg) => console.log("  ✓ " + msg);
const section = (t) => console.log("\n== " + t + " ==");

const js = (f) => readFileSync(join(root, "webapp/js", f), "utf8");
const appJs = js("app.js");
const writesJs = js("writes.js");
const allJs = readdirSync(join(root, "webapp/js")).filter((f) => f.endsWith(".js"))
  .map((f) => [f, js(f)]);

// ---------------------------------------------------------------- XSS surface
section("XSS surface");
{
  // Every innerHTML must be a known static-SVG assignment — user content
  // only ever flows through createTextNode (el()'s child path).
  const SAFE_INNERHTML = /\.innerHTML = (EYE_SVG|EYE_OFF_SVG|svg|show \? EYE_OFF_SVG : EYE_SVG)/;
  for (const [f, src] of allJs) {
    for (const line of src.split("\n")) {
      if (line.includes("innerHTML") && !SAFE_INNERHTML.test(line)) {
        fail(`${f}: unexpected innerHTML: ${line.trim().slice(0, 90)}`);
      }
      for (const bad of ["insertAdjacentHTML", "document.write", "eval(", "new Function", "javascript:"]) {
        // ACCEPTED: moderation.js's CommonJS shim runs SAME-ORIGIN static
        // vendor files that pre-commit pins byte-identical to the server's
        // moderation source (client-subset-of-server invariant). Equivalent
        // trust to a local <script>; verified below that the fetch targets
        // never change. Any OTHER dynamic-code sink still fails the audit.
        if (f === "moderation.js" && bad === "new Function") continue;
        if (line.includes(bad) && !line.trim().startsWith("//")) {
          fail(`${f}: forbidden sink '${bad}': ${line.trim().slice(0, 90)}`);
        }
      }
    }
  }
  // The one accepted dynamic-code site must keep its exact same-origin
  // fetch targets — anything else there fails.
  const mod = js("moderation.js");
  const fetches = [...mod.matchAll(/fetch\("([^"]+)"\)/g)].map((m) => m[1]).sort();
  if (JSON.stringify(fetches) === JSON.stringify(["/js/vendor/moderation.js", "/js/vendor/moderationLogic.js"])) {
    ok("moderation shim fetches pinned to the two same-origin vendor files");
  } else {
    fail(`moderation.js fetch targets changed: ${fetches.join(", ")}`);
  }
  if (!failures) ok("no unsafe HTML sinks (innerHTML = static SVGs only; content via createTextNode)");
}

// ------------------------------------------------------- script/import hygiene
section("script + import hygiene");
{
  const html = readFileSync(join(root, "webapp/index.html"), "utf8");
  const srcs = [...html.matchAll(/<script[^>]*src="([^"]+)"/g)].map((m) => m[1]);
  for (const s of srcs) {
    if (!s.startsWith("/js/")) fail(`index.html loads non-local script: ${s}`);
  }
  ok(`index.html scripts local-only (${srcs.length})`);
  const imports = [...appJs.matchAll(/from "(https:[^"]+)"/g)].map((m) => m[1])
    .concat([...writesJs.matchAll(/from "(https:[^"]+)"/g)].map((m) => m[1]));
  for (const i of imports) {
    if (!i.startsWith("https://www.gstatic.com/firebasejs/")) {
      fail(`non-gstatic remote import: ${i}`);
    }
  }
  ok(`remote imports gstatic-only (${imports.length})`);
}

// ------------------------------------------------------------------- secrets
section("secrets");
{
  const patterns = [
    [/AIza[0-9A-Za-z_-]{35}/, "Google API key", true], // public web key is EXPECTED in config.js
    [/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "private key", false],
    [/sk_live_[0-9a-zA-Z]+/, "Stripe secret", false],
    [/AuthKey_[A-Z0-9]{10}\.p8/, "ASC key path", false],
  ];
  for (const [f, src] of allJs) {
    for (const [re, name, allowedInConfig] of patterns) {
      if (re.test(src) && !(allowedInConfig && f === "config.js")) {
        fail(`${f}: ${name} pattern present`);
      }
    }
  }
  ok("no secret patterns outside the public web config");
}

// ---------------------------------------------------------- behavioral guards
section("behavioral guards (bug-class pins)");
{
  const pins = [
    [writesJs, "if (o.authorId === uid) return \"own_post\"", "self-repost client guard"],
    [writesJs, "inFlight.has(key)", "write-path in-flight guard"],
    [writesJs, "postId }", "reverse-ref postId field (deletion sweep)"],
    [appJs, "expirationDate" , null], // optional
    [appJs, "expandedThreads", "reply-thread collapse state"],
    [appJs, "handle\" + ((d.isRepost ? d.originalAuthorId : d.authorId) === me?.uid ? \" own\"", "own-handle accent class"],
    [appJs, "you reposted", "own-repost strip copy"],
    [appJs, "#/prompt", "what-others-said route"],
    [appJs, "targetPostId = d.isRepost && !isReplyRepost ? (d.originalPostId ?? postId) : postId", "repost interaction retarget"],
    [appJs, "policyEnabled", "kill-switch gates"],
    [appJs, "draft_${me.uid}", "per-uid draft keys (account isolation)"],
  ];
  for (const [src, needle, name] of pins) {
    if (!name) continue;
    if (src.includes(needle)) ok(name);
    else fail(`missing pin: ${name} (needle not found: ${needle.slice(0, 50)}…)`);
  }
}

// --------------------------------------------------------------- CSP / headers
section("hosting headers (firebase.json)");
{
  const cfg = JSON.parse(readFileSync(join(root, "firebase.json"), "utf8"));
  const all = cfg.hosting.headers.find((h) => h.source === "**");
  const get = (k) => all?.headers.find((x) => x.key === k)?.value;
  const csp = get("Content-Security-Policy") ?? "";
  const checks = [
    [csp.includes("default-src 'self'"), "CSP default-src 'self'"],
    [csp.includes("object-src 'none'"), "CSP object-src 'none'"],
    [csp.includes("frame-ancestors 'none'"), "CSP frame-ancestors 'none'"],
    [!csp.includes("unsafe-inline'") || !csp.match(/script-src[^;]*unsafe-inline/), "CSP script-src has no unsafe-inline"],
    [get("X-Content-Type-Options") === "nosniff", "X-Content-Type-Options nosniff"],
    [get("X-Frame-Options") === "DENY", "X-Frame-Options DENY"],
    [(get("Referrer-Policy") ?? "").includes("strict-origin"), "Referrer-Policy strict-origin"],
    [!!cfg.hosting.headers.find((h) => h.source === "/p/**"), "/p/** hardened variant present"],
  ];
  for (const [cond, name] of checks) cond ? ok(name) : fail(name + " MISSING");
}

// -------------------------------------------------------------------- live
if (process.env.LIVE === "1") {
  section("LIVE: app.toskaapp.com");
  const fetchText = async (url) => {
    const r = await fetch(url, { redirect: "follow" });
    return { status: r.status, headers: r.headers, text: await r.text() };
  };
  try {
    const home = await fetchText("https://app.toskaapp.com/");
    home.status === 200 ? ok("/ responds 200") : fail(`/ status ${home.status}`);
    const csp = home.headers.get("content-security-policy") ?? "";
    csp.includes("frame-ancestors 'none'") ? ok("live CSP served") : fail("live CSP missing/weak");
    (home.headers.get("x-content-type-options") === "nosniff")
      ? ok("live nosniff") : fail("live nosniff missing");

    const bundle = await fetchText("https://app.toskaapp.com/js/app.js");
    // Deployed bundle carries the same feature pins as local — catches
    // "fixed locally, never deployed" drift.
    for (const marker of ["expandedThreads", "#/prompt", "you reposted", "policyEnabled"]) {
      bundle.text.includes(marker) ? ok(`deployed bundle has: ${marker}`)
        : fail(`DEPLOYED BUNDLE STALE — missing: ${marker}`);
    }
    const writes = await fetchText("https://app.toskaapp.com/js/writes.js");
    writes.text.includes('return "own_post"') ? ok("deployed writes has self-repost guard")
      : fail("DEPLOYED writes.js stale — self-repost guard missing");

    const p404 = await fetchText("https://app.toskaapp.com/p/definitely-not-a-real-post");
    (p404.status === 404 || p404.status === 410) ? ok(`/p/ unknown id → ${p404.status}`)
      : fail(`/p/ unknown id returned ${p404.status} (expected 404)`);
  } catch (e) {
    fail(`live checks errored: ${e.message}`);
  }
}

console.log(failures === 0
  ? "\n✓ WEB AUDIT CLEAN"
  : `\n${failures} finding(s)`);
process.exit(failures === 0 ? 0 : 1);
