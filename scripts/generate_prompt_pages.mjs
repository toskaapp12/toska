// Static generator for the /prompts/ editorial section on www.toskaapp.com.
//
// Reads DAILY_PROMPTS from webapp/js/app.js (the same pinned list iOS and web
// serve — prompt-parity.mjs guards the mirror), and emits into docs/ (GitHub
// Pages):
//   docs/prompts/index.html           — archive, grouped by feeling
//   docs/prompts/t/{tagSlug}.html     — one collection page per tag
//   docs/prompts/{slug}.html          — one page per prompt (395)
// and regenerates docs/sitemap.xml to include every page.
//
// Slugs are derived deterministically from prompt text (first 8 words,
// kebab-case, de-duped by order) — DO NOT edit prompt text casually: it
// changes the slug and orphans the indexed URL. If a prompt must be
// reworded, keep its old slug alive via the REDIRECTS map below.
//
// Run:  node scripts/generate_prompt_pages.mjs
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DOCS = join(ROOT, "docs");
const OUT = join(DOCS, "prompts");
const ORIGIN = "https://www.toskaapp.com";
const APP_URL = "https://app.toskaapp.com";

// Reworded prompts keep their old slug → new slug here; emits a redirect stub.
const REDIRECTS = {};

// ── load the pinned prompt list ──
const appJs = readFileSync(join(ROOT, "webapp", "js", "app.js"), "utf8");
const start = appJs.indexOf("const DAILY_PROMPTS = [");
const end = appJs.indexOf("\n];", start);
if (start < 0 || end < 0) throw new Error("DAILY_PROMPTS not found in app.js");
const literal = appJs.slice(start + "const DAILY_PROMPTS = ".length, end + 2);
const PROMPTS = vm.runInNewContext(`(${literal})`);
if (!Array.isArray(PROMPTS) || PROMPTS.length < 300) {
  throw new Error(`parsed ${PROMPTS?.length} prompts — expected the full list`);
}

// ── voice: one quiet frame per feeling, shared by its pages (honest about
// being editorial; no fake per-page essays that would read as filler) ──
const TAG_FRAME = {
  "longing": "longing is the feeling that keeps checking the door. these prompts don't try to close it — they just give the waiting somewhere to go.",
  "numb": "sometimes the loudest thing you feel is nothing. these prompts are for the flat days, when the words come slower than the hurt did.",
  "anger": "anger is grief with its jaw set. write it here instead of sending it — the point is the saying, not the delivery.",
  "regret": "regret rereads everything. these prompts let you look back on purpose, once, instead of all night by accident.",
  "acceptance": "acceptance isn't a finish line, it's a tide. these prompts are for the days it comes in.",
  "confusion": "when you don't know what you feel yet, naming the not-knowing counts. start anywhere.",
  "unsent": "every breakup writes messages that never get sent. this is where they can exist without arriving.",
  "moving on": "moving on is mostly small, undramatic choices made again and again. these prompts honor the small ones.",
  "still love you": "you can love someone and not go back. these prompts hold both of those at once.",
};
const frameFor = (tag) => TAG_FRAME[tag] ||
  "a nightly question for whatever tonight is. answer it for no one, anonymously.";

// ── helpers ──
const esc = (s) => String(s)
  .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;").replaceAll("'", "&#39;");
const kebab = (s) => s.toLowerCase().normalize("NFKD")
  .replace(/[’']/g, "").replace(/[^a-z0-9]+/g, "-")
  .replace(/^-+|-+$/g, "");
const tagSlug = (t) => kebab(t);
const truncate = (s, n) => s.length <= n ? s : s.slice(0, n - 1).trimEnd() + "…";

// Stable slugs: first 8 words, then de-dupe in list order.
const seen = new Map();
const entries = PROMPTS.map(([text, tag], i) => {
  let slug = kebab(text.split(/\s+/).slice(0, 8).join(" ")) || `prompt-${i + 1}`;
  if (slug.length > 60) slug = slug.slice(0, 60).replace(/-[^-]*$/, "");
  const n = seen.get(slug) ?? 0;
  seen.set(slug, n + 1);
  if (n > 0) slug = `${slug}-${n + 1}`;
  return { text, tag, slug, i };
});

const byTag = new Map();
for (const e of entries) {
  if (!byTag.has(e.tag)) byTag.set(e.tag, []);
  byTag.get(e.tag).push(e);
}

// ── shared chrome (palette = docs/index.html tokens) ──
const CSS = `
* { margin:0; padding:0; box-sizing:border-box; }
:root { --ink:#14130f; --paper:#fff; --ground:#eeeff1; --soft:#72757e; --faint:#91949c;
        --plum:#6d55c9; --plum-soft:#9387c0; --night:#0b0a10; --hairline:#e2e4e8; }
body { font-family: Georgia,'Times New Roman',serif; background:var(--ground); color:var(--ink); line-height:1.7; }
.sans { font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; }
header { background:var(--night); color:#e6e7ea; text-align:center; padding:44px 24px 36px; }
header a.logo { font-style:italic; font-size:30px; color:#fff; text-decoration:none; }
header .crumb { margin-top:10px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
  font-size:12.5px; }
header .crumb a { color:rgba(230,231,234,0.65); text-decoration:none; margin:0 8px; }
header .crumb a:hover { color:#fff; }
main { max-width:680px; margin:0 auto; padding:24px; }
section { background:var(--paper); border-radius:14px; padding:40px 36px; margin:22px 0; }
h1.prompt { font-style:italic; font-weight:normal; font-size:30px; line-height:1.45; }
.tagchip { display:inline-block; margin-bottom:18px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
  font-size:12px; color:var(--plum); border:1px solid var(--hairline); border-radius:999px; padding:5px 14px;
  text-decoration:none; }
.frame { color:var(--soft); font-size:16px; margin-top:20px; }
.cta { background:var(--night); color:#e6e7ea; }
.cta p { color:rgba(230,231,234,0.75); }
.cta a.button { display:inline-block; margin-top:18px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
  font-size:14px; color:#fff; background:var(--plum); border-radius:999px; padding:11px 24px; text-decoration:none; }
.cta a.plain { color:var(--plum-soft); font-size:14px; margin-left:16px; }
ul.plist { list-style:none; }
ul.plist li { border-bottom:1px solid var(--hairline); }
ul.plist li:last-child { border-bottom:none; }
ul.plist a { display:block; padding:14px 2px; color:var(--ink); text-decoration:none; font-style:italic; font-size:17px; }
ul.plist a:hover { color:var(--plum); }
.pn { display:flex; justify-content:space-between; gap:16px; font-size:14px; }
.pn a { color:var(--plum); text-decoration:none; max-width:46%; }
h2 { font-size:21px; margin-bottom:14px; font-weight:normal; }
.muted { color:var(--faint); font-size:13.5px; }
footer { text-align:center; padding:28px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
  font-size:12px; color:var(--faint); }
footer a { color:var(--faint); }
`;

const page = ({ title, desc, canonical, body, crumb }) => `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${esc(title)}</title>
<meta name="description" content="${esc(desc)}">
<link rel="canonical" href="${canonical}">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(desc)}">
<meta property="og:type" content="article">
<meta property="og:url" content="${canonical}">
<meta name="twitter:card" content="summary">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%230b0a10'/%3E%3Ctext x='32' y='45' font-family='Georgia,serif' font-size='40' fill='%236d55c9' text-anchor='middle'%3Et%3C/text%3E%3C/svg%3E">
<style>${CSS}</style>
</head>
<body>
<header>
  <a class="logo" href="/">toska</a>
  <div class="crumb">${crumb}</div>
</header>
<main>
${body}
</main>
<footer>
  <a href="/">toska</a> — an anonymous space for heartbreak ·
  <a href="/privacy.html">privacy</a> · <a href="/terms.html">terms</a>
</footer>
</body>
</html>`;

const CTA = `
<section class="cta">
  <h2>answer it where no one knows you</h2>
  <p>toska is an anonymous space for heartbreak — no names, no faces, no feeds designed to keep you scrolling. one prompt a night, strangers who get it.</p>
  <a class="button" href="${APP_URL}">open toska</a><a class="plain sans" href="/">about the app</a>
</section>`;

// ── per-prompt pages ──
rmSync(OUT, { recursive: true, force: true });
mkdirSync(join(OUT, "t"), { recursive: true });
let written = 0;
for (const e of entries) {
  const sameTag = byTag.get(e.tag).filter((x) => x.slug !== e.slug);
  // deterministic "related": the 4 list-neighbors within the tag (no RNG — stable builds)
  const idx = byTag.get(e.tag).findIndex((x) => x.slug === e.slug);
  const related = [...sameTag.slice(Math.max(0, idx - 2)), ...sameTag].slice(0, 4);
  const prev = entries[(e.i + entries.length - 1) % entries.length];
  const next = entries[(e.i + 1) % entries.length];
  const canonical = `${ORIGIN}/prompts/${e.slug}.html`;
  const body = `
<section>
  <a class="tagchip" href="/prompts/t/${tagSlug(e.tag)}.html">${esc(e.tag)}</a>
  <h1 class="prompt">${esc(e.text)}</h1>
  <p class="frame">${esc(frameFor(e.tag))}</p>
</section>
${CTA}
<section>
  <h2>more for ${esc(e.tag)}</h2>
  <ul class="plist">
    ${related.map((r) => `<li><a href="/prompts/${r.slug}.html">${esc(truncate(r.text, 90))}</a></li>`).join("\n    ")}
  </ul>
  <p class="muted sans" style="margin-top:14px;"><a href="/prompts/t/${tagSlug(e.tag)}.html" style="color:var(--plum);">all ${byTag.get(e.tag).length} ${esc(e.tag)} prompts →</a></p>
</section>
<section class="pn sans">
  <a href="/prompts/${prev.slug}.html">← ${esc(truncate(prev.text, 46))}</a>
  <a href="/prompts/${next.slug}.html" style="text-align:right;">${esc(truncate(next.text, 46))} →</a>
</section>`;
  writeFileSync(join(OUT, `${e.slug}.html`), page({
    title: `${truncate(e.text, 60)} — a toska writing prompt`,
    desc: `a nightly heartbreak writing prompt from toska: "${truncate(e.text, 120)}" — ${frameFor(e.tag).split(".")[0]}.`,
    canonical,
    crumb: `<a href="/prompts/">prompts</a> · <a href="/prompts/t/${tagSlug(e.tag)}.html">${esc(e.tag)}</a>`,
    body,
  }));
  written++;
}

// ── tag collection pages ──
for (const [tag, list] of byTag) {
  const canonical = `${ORIGIN}/prompts/t/${tagSlug(tag)}.html`;
  const body = `
<section>
  <h1 class="prompt" style="font-size:24px;">writing prompts for ${esc(tag)}</h1>
  <p class="frame">${esc(frameFor(tag))}</p>
</section>
<section>
  <ul class="plist">
    ${list.map((e) => `<li><a href="/prompts/${e.slug}.html">${esc(e.text)}</a></li>`).join("\n    ")}
  </ul>
</section>
${CTA}`;
  writeFileSync(join(OUT, "t", `${tagSlug(tag)}.html`), page({
    title: `${list.length} heartbreak writing prompts for ${tag} — toska`,
    desc: `${frameFor(tag)} ${list.length} anonymous nightly prompts for ${tag}.`,
    canonical,
    crumb: `<a href="/prompts/">prompts</a> · ${esc(tag)}`,
    body,
  }));
}

// ── index ──
{
  const canonical = `${ORIGIN}/prompts/`;
  const body = `
<section>
  <h1 class="prompt" style="font-size:26px;">the toska prompts</h1>
  <p class="frame">every night, toska asks one question about heartbreak. these are all ${entries.length} of them — written for the 2am version of you, sorted by what you're feeling. answer in your head, in your notes app, or anonymously in toska.</p>
</section>
${[...byTag.entries()].map(([tag, list]) => `
<section>
  <h2><a href="/prompts/t/${tagSlug(tag)}.html" style="color:var(--ink); text-decoration:none;">${esc(tag)}</a> <span class="muted sans">· ${list.length}</span></h2>
  <ul class="plist">
    ${list.slice(0, 5).map((e) => `<li><a href="/prompts/${e.slug}.html">${esc(truncate(e.text, 90))}</a></li>`).join("\n    ")}
  </ul>
  <p class="muted sans" style="margin-top:12px;"><a href="/prompts/t/${tagSlug(tag)}.html" style="color:var(--plum);">all ${list.length} →</a></p>
</section>`).join("\n")}
${CTA}`;
  writeFileSync(join(OUT, "index.html"), page({
    title: `${entries.length} heartbreak writing prompts, one for every night — toska`,
    desc: "the full archive of toska's nightly heartbreak prompts — longing, anger, the unsent texts, moving on. answer anonymously.",
    canonical,
    crumb: `<a href="/prompts/">prompts</a>`,
    body,
  }));
}

// ── redirect stubs for reworded prompts ──
for (const [oldSlug, newSlug] of Object.entries(REDIRECTS)) {
  writeFileSync(join(OUT, `${oldSlug}.html`),
    `<!DOCTYPE html><html><head><meta charset="UTF-8"><link rel="canonical" href="${ORIGIN}/prompts/${newSlug}.html"><meta http-equiv="refresh" content="0; url=/prompts/${newSlug}.html"></head><body></body></html>`);
}

// ── sitemap: keep the existing non-prompt urls, append ours ──
{
  const today = new Date().toISOString().slice(0, 10);
  const existing = readFileSync(join(DOCS, "sitemap.xml"), "utf8");
  const keep = [...existing.matchAll(/<url>\s*<loc>([^<]+)<\/loc>(?:\s*<lastmod>([^<]+)<\/lastmod>)?\s*<\/url>/g)]
    .filter((m) => !m[1].includes("/prompts/"));
  const urls = [
    ...keep.map((m) => ({ loc: m[1], lastmod: m[2] })),
    { loc: `${ORIGIN}/prompts/`, lastmod: today },
    ...[...byTag.keys()].map((t) => ({ loc: `${ORIGIN}/prompts/t/${tagSlug(t)}.html`, lastmod: today })),
    ...entries.map((e) => ({ loc: `${ORIGIN}/prompts/${e.slug}.html`, lastmod: today })),
  ];
  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
    urls.map((u) => `  <url>\n    <loc>${u.loc}</loc>${u.lastmod ? `\n    <lastmod>${u.lastmod}</lastmod>` : ""}\n  </url>`).join("\n") +
    `\n</urlset>\n`;
  writeFileSync(join(DOCS, "sitemap.xml"), xml);
}

console.log(`✓ ${written} prompt pages, ${byTag.size} tag pages, index, sitemap (${written + byTag.size + 1} urls added)`);
