// Public share/SEO pages — pure logic for the /p/{postId} Cloud Function
// (roadmap phase-2, share layer). The onRequest wrapper lives in index.js;
// everything here is side-effect free so it can be unit-tested with node:test
// and never touches Firestore.
//
// Privacy invariants (same bar as publicFeed + share cards — words leave the
// platform, identity never does):
//   - live + isShareable only (author consent), never whisper/midnight/expired
//   - reposts redirect to the original (no duplicate public copies)
//   - rendered page carries text/tag/likeCount/month only — NO handle, NO
//     authorId, NO doc ids of other posts
//   - search indexing is opt-in via admin curation (webFeatured), matching
//     publicFeed's rationale: author consent is necessary but not sufficient
//     for surfaces we actively hand to crawlers (tester noise, PII-shaped test
//     posts). Non-featured shareable posts still render — a shared link must
//     unfurl — but carry noindex.
//   - anything the moderation classifiers would flag (crisis / concerning /
//     spam / hate / threat) is never indexable, regardless of curation.
const {
  computePostFlagReason,
  isPostConcerning,
  isPostExplicitCrisis,
} = require("./moderationLogic");
const { containsNameOrIdentifyingInfo } = require("./moderation");

// Where these pages canonically live. The Firebase Hosting site also answers
// on toska-4ebf4.web.app (and app.toskaapp.com once the owner wires DNS) —
// pinning one canonical origin keeps crawlers from splitting the same post
// across hosts. www.toskaapp.com stays on GitHub Pages (static) and is NOT
// this — it can't serve dynamic pages.
const CANONICAL_ORIGIN = "https://app.toskaapp.com";

// Mirrors isValidFirestoreDocId in toskaApp.swift (universal-link handler):
// reject anything outside the charset our doc ids actually use before it can
// reach a Firestore path. Auto-ids are 20 alnum chars; repost ids are
// `{uid}_repost_{postId}`, so allow enough length for the composite form.
function isValidDocId(id) {
  return typeof id === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(id);
}

// Decide what /p/{postId} does for a post snapshot's data (`post` is
// undefined/null for a missing doc). Returns one of:
//   { outcome: "not_found" }
//   { outcome: "redirect", to: "<originalPostId>" }
//   { outcome: "render", indexable: boolean }
function evaluateSharePage(post, nowMs) {
  if (!post) return { outcome: "not_found" };

  // A repost is the same words under a different doc id — send readers (and
  // crawlers, 301) to the one public copy. The original re-runs the full gate,
  // so an unshareable/expired original still 404s after the hop.
  if (post.isRepost === true) {
    return isValidDocId(post.originalPostId)
      ? { outcome: "redirect", to: post.originalPostId }
      : { outcome: "not_found" };
  }

  // Strict === checks (not rules-style defaults): the 2026-05-31 backfill set
  // every prod post's moderationStatus, and publicFeed already holds this
  // stricter line for public surfaces.
  if (post.moderationStatus !== "live") return { outcome: "not_found" };
  if (post.isShareable !== true) return { outcome: "not_found" };
  if (post.isWhisper === true || post.isMidnightPost === true) return { outcome: "not_found" };
  // isLetter (2026-08-05): letters are the most intimate content class and
  // BOTH clients already treat them as never publicly shareable (iOS
  // ShareConsent and web's copy-link menu both exclude isLetter), but rules
  // can't stop a tampered client writing isLetter + isShareable:true — this
  // server-side gate is what actually denies that doc a public /p/ page.
  if (post.isLetter === true) return { outcome: "not_found" };
  if (typeof post.text !== "string" || post.text.trim().length === 0) return { outcome: "not_found" };

  // Ephemeral window: whispers/midnight are the expiring kinds and are already
  // excluded above, but gate on expiresAt directly so a future expiring kind
  // can't leak past its window through this page.
  const expiresMs = post.expiresAt?.toMillis?.();
  if (typeof expiresMs === "number" && expiresMs <= nowMs) return { outcome: "not_found" };

  // containsNameOrIdentifyingInfo: prod carries name-shaped tester posts
  // (found live during the 2026-07-13 rollout verification) — a careless
  // webFeatured flag must not be able to hand one to crawlers.
  const sensitive =
    computePostFlagReason(post.text) !== null ||
    isPostExplicitCrisis(post.text) ||
    isPostConcerning(post.text) ||
    containsNameOrIdentifyingInfo(post.text);
  return { outcome: "render", indexable: post.webFeatured === true && !sensitive };
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// Single-line excerpt for <title> / og:description — collapse whitespace,
// hard-cap length on a word boundary where possible.
function excerpt(text, max) {
  const flat = text.replace(/\s+/g, " ").trim();
  if (flat.length <= max) return flat;
  const cut = flat.slice(0, max);
  const lastSpace = cut.lastIndexOf(" ");
  return (lastSpace > max * 0.6 ? cut.slice(0, lastSpace) : cut) + "…";
}

const MONTHS = ["january", "february", "march", "april", "may", "june",
  "july", "august", "september", "october", "november", "december"];

// Month-granularity date only: precise timestamps narrow down who wrote it.
function monthLabel(createdAtMs) {
  if (typeof createdAtMs !== "number" || !isFinite(createdAtMs)) return null;
  const d = new Date(createdAtMs);
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
}

// Shared page chrome — same palette/serif as the GitHub Pages marketing set
// (docs/404.html et al.) so the public surfaces read as one site.
function pageShell({ title, robots, head = "", body }) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${title}</title>
<meta name="robots" content="${robots}">
${head}<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%230b0a10'/%3E%3Ctext x='32' y='45' font-family='Georgia,serif' font-size='40' fill='%236d55c9' text-anchor='middle'%3Et%3C/text%3E%3C/svg%3E">
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { min-height: 100vh; display: flex; align-items: center; justify-content: center;
  background: #0b0a10; color: #eeeff1; padding: 24px;
  font-family: Georgia, 'Times New Roman', serif; line-height: 1.7; }
main { max-width: 620px; width: 100%; }
.brand { color: #9387c0; font-size: 15px; letter-spacing: 0.04em; margin-bottom: 28px; }
.brand a { color: #9387c0; text-decoration: none; }
blockquote { font-size: 23px; line-height: 1.65; white-space: pre-wrap; overflow-wrap: break-word; }
.meta { margin-top: 26px; color: #91949c; font-size: 14px; }
.meta .tag { color: #9387c0; }
.cta { margin-top: 44px; padding-top: 22px; border-top: 1px solid #23222c; color: #91949c; font-size: 14px; }
.cta a { color: #9387c0; }
.legal { margin-top: 30px; font-size: 12px; color: #5a5d66; }
.legal a { color: #7d80a8; text-decoration: none; }
h1 { font-weight: 500; font-size: 30px; margin-bottom: 10px; }
h1 span { color: #9387c0; }
p { color: #91949c; }
a { color: #9387c0; }
</style>
</head>
<body>
<main>
${body}
<p class="legal"><a href="https://www.toskaapp.com/privacy">privacy</a> · <a href="https://www.toskaapp.com/terms">terms</a></p>
</main>
</body>
</html>
`;
}

// The rendered share page. `post` has already passed evaluateSharePage.
function renderPostHtml(postId, post, { indexable, createdAtMs }) {
  // 2026-07-28 (A.5 #4): escape postId for parity with renderSitemapXml.
  // The caller gates on isValidDocId ([A-Za-z0-9_-]), so this is a no-op for
  // every id that can reach here — defense-in-depth only, so the HTML-safety
  // of this template doesn't depend on a gate in a different function.
  const safePostId = escapeHtml(postId);
  const canonicalUrl = `${CANONICAL_ORIGIN}/p/${safePostId}`;
  const title = escapeHtml(excerpt(post.text, 70)) + " — toska";
  const description = escapeHtml(excerpt(post.text, 200));
  const robots = indexable ? "index, follow" : "noindex";
  const cardUrl = `${CANONICAL_ORIGIN}/og/${safePostId}.png`;
  const head = `<link rel="canonical" href="${canonicalUrl}">
<meta property="og:site_name" content="toska">
<meta property="og:type" content="article">
<meta property="og:url" content="${canonicalUrl}">
<meta property="og:title" content="${title}">
<meta property="og:description" content="${description}">
<meta property="og:image" content="${cardUrl}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${title}">
<meta name="twitter:description" content="${description}">
<meta name="twitter:image" content="${cardUrl}">
`;
  const felt = typeof post.likeCount === "number" && post.likeCount > 0
    ? `felt ${post.likeCount} ${post.likeCount === 1 ? "time" : "times"}` : null;
  const month = monthLabel(createdAtMs);
  const metaBits = [
    typeof post.tag === "string" && post.tag
      ? `<span class="tag">${escapeHtml(post.tag)}</span>` : null,
    felt,
    month,
  ].filter(Boolean).join(" · ");
  const body = `<div class="brand"><a href="https://www.toskaapp.com/">toska</a></div>
<blockquote>${escapeHtml(post.text)}</blockquote>
${metaBits ? `<div class="meta">${metaBits}</div>` : ""}
<div class="cta">written anonymously on toska — a quiet place to put a breakup
into words. no names, no followers, no forever.
<a href="https://www.toskaapp.com/">about toska</a></div>`;
  return pageShell({ title, robots, head, body });
}

function renderNotFoundHtml() {
  const body = `<div style="text-align:center">
<h1><span>toska</span> — nothing here</h1>
<p>this post doesn't exist, has expired, or isn't shared publicly.
head to <a href="https://www.toskaapp.com/">toskaapp.com</a> instead.</p>
</div>`;
  return pageShell({ title: "not found — toska", robots: "noindex", body });
}

// Sitemap of the indexable set only (webFeatured + clean), built from post
// snapshots the caller already fetched. lastmod at day granularity — same
// reasoning as monthLabel, plus sitemaps don't need more.
function renderSitemapXml(entries) {
  const urls = entries.map(({ postId, createdAtMs }) => {
    const lastmod = typeof createdAtMs === "number" && isFinite(createdAtMs)
      ? `\n    <lastmod>${new Date(createdAtMs).toISOString().slice(0, 10)}</lastmod>` : "";
    return `  <url>\n    <loc>${CANONICAL_ORIGIN}/p/${escapeHtml(postId)}</loc>${lastmod}\n  </url>`;
  }).join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`;
}

module.exports = {
  CANONICAL_ORIGIN,
  isValidDocId,
  evaluateSharePage,
  escapeHtml,
  excerpt,
  monthLabel,
  renderPostHtml,
  renderNotFoundHtml,
  renderSitemapXml,
};
