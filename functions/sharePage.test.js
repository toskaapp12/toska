// node --test sharePage.test.js — gating matrix + rendering for the public
// /p/{postId} share pages. Pure logic only; the onRequest wrapper in index.js
// is a thin transport shell around these.
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  isValidDocId,
  evaluateSharePage,
  escapeHtml,
  excerpt,
  monthLabel,
  renderPostHtml,
  renderNotFoundHtml,
  renderSitemapXml,
  CANONICAL_ORIGIN,
} = require("./sharePage");

const NOW = 1780000000000;
const ts = (ms) => ({ toMillis: () => ms });

// A post that passes every gate; tests override single fields to isolate one
// gate per case.
function livePost(overrides = {}) {
  return {
    authorId: "author1",
    authorHandle: "quietghost",
    text: "it has been four months and i still set two cups down for coffee.",
    moderationStatus: "live",
    isShareable: true,
    isRepost: false,
    likeCount: 12,
    tag: "grief",
    createdAt: ts(NOW - 86400e3 * 40),
    ...overrides,
  };
}

test("doc id validation", () => {
  assert.ok(isValidDocId("aB3_-x9012345678901z"));
  assert.ok(isValidDocId("uid123_repost_abcDEF"));
  assert.ok(!isValidDocId(""));
  assert.ok(!isValidDocId("a/b"));
  assert.ok(!isValidDocId("..%2Fadmin"));
  assert.ok(!isValidDocId("x".repeat(129)));
  assert.ok(!isValidDocId(null));
});

test("live shareable post renders, not indexable without curation", () => {
  const v = evaluateSharePage(livePost(), NOW);
  assert.deepEqual(v, { outcome: "render", indexable: false });
});

test("webFeatured post is indexable", () => {
  const v = evaluateSharePage(livePost({ webFeatured: true }), NOW);
  assert.deepEqual(v, { outcome: "render", indexable: true });
});

test("every not_found gate", () => {
  const cases = [
    ["missing doc", null],
    ["pending review", livePost({ moderationStatus: "pending_review" })],
    ["no moderationStatus field", livePost({ moderationStatus: undefined })],
    ["share opt-out", livePost({ isShareable: false })],
    ["isShareable absent", livePost({ isShareable: undefined })],
    ["whisper", livePost({ isWhisper: true })],
    ["midnight post", livePost({ isMidnightPost: true })],
    ["expired", livePost({ expiresAt: ts(NOW - 1) })],
    ["empty text", livePost({ text: "   " })],
    ["non-string text", livePost({ text: 42 })],
    ["repost with invalid original id", livePost({ isRepost: true, originalPostId: "a/b" })],
  ];
  for (const [name, post] of cases) {
    assert.equal(evaluateSharePage(post, NOW).outcome, "not_found", name);
  }
});

test("unexpired expiresAt still renders", () => {
  const v = evaluateSharePage(livePost({ expiresAt: ts(NOW + 3600e3) }), NOW);
  assert.equal(v.outcome, "render");
});

test("repost redirects to original", () => {
  const v = evaluateSharePage(
    livePost({ isRepost: true, originalPostId: "orig12345678901234ab" }), NOW);
  assert.deepEqual(v, { outcome: "redirect", to: "orig12345678901234ab" });
});

test("sensitive text is never indexable, even when featured", () => {
  // Phrases the moderation classifiers flag (crisis + spam). If a corpus
  // change ever un-flags these, this test failing is the signal to pick new
  // fixtures — the invariant under test is flagged ⇒ noindex.
  const crisis = livePost({ webFeatured: true, text: "i want to kill myself tonight" });
  const vc = evaluateSharePage(crisis, NOW);
  assert.equal(vc.outcome, "render", "crisis text still renders if live+shareable");
  assert.equal(vc.indexable, false);
  // Name-shaped text (real prod tester posts look like this) — a careless
  // webFeatured flag must not make it indexable.
  const named = livePost({ webFeatured: true, text: "Ally McNiel" });
  const vn = evaluateSharePage(named, NOW);
  assert.equal(vn.outcome, "render");
  assert.equal(vn.indexable, false);
});

test("escapeHtml neutralises injection", () => {
  assert.equal(
    escapeHtml(`<script>alert("x")</script>'&`),
    "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;&#39;&amp;");
});

test("excerpt collapses whitespace and cuts on word boundary", () => {
  assert.equal(excerpt("short  text\nhere", 100), "short text here");
  const long = "one two three four five six seven eight nine ten";
  const e = excerpt(long, 20);
  assert.ok(e.length <= 21 && e.endsWith("…"), e);
  assert.ok(!e.includes("thre "), "no mid-word cut: " + e);
});

test("monthLabel is month-granularity only", () => {
  assert.equal(monthLabel(Date.UTC(2026, 5, 15)), "june 2026");
  assert.equal(monthLabel(undefined), null);
});

test("rendered page: content in, identity out", () => {
  const post = livePost();
  const html = renderPostHtml("post123", post, { indexable: false, createdAtMs: Date.UTC(2026, 5, 15) });
  assert.ok(html.includes("two cups down for coffee"));
  assert.ok(html.includes(`<link rel="canonical" href="${CANONICAL_ORIGIN}/p/post123">`));
  assert.ok(html.includes('name="robots" content="noindex"'));
  assert.ok(html.includes("og:title"));
  assert.ok(html.includes(`content="${CANONICAL_ORIGIN}/og/post123.png"`), "og:image points at the card endpoint");
  assert.ok(html.includes("summary_large_image"));
  assert.ok(html.includes("felt 12 times"));
  assert.ok(html.includes("june 2026"));
  assert.ok(!html.includes("quietghost"), "handle must never render");
  assert.ok(!html.includes("author1"), "authorId must never render");
});

test("rendered page: indexable when curated", () => {
  const html = renderPostHtml("post123", livePost({ webFeatured: true }),
    { indexable: true, createdAtMs: NOW });
  assert.ok(html.includes('name="robots" content="index, follow"'));
});

test("rendered page: XSS via text/tag is escaped", () => {
  const post = livePost({ text: '<img src=x onerror=alert(1)>"', tag: "<b>" });
  const html = renderPostHtml("post123", post, { indexable: false, createdAtMs: NOW });
  assert.ok(!html.includes("<img src=x"));
  assert.ok(!html.includes("<b>"));
});

test("rendered page: XSS via postId is escaped (A.5 #4 defense-in-depth)", () => {
  // isValidDocId blocks these ids upstream; the template must not depend on it.
  const hostileId = '"><script>alert(1)</script>';
  const html = renderPostHtml(hostileId, livePost(), { indexable: false, createdAtMs: NOW });
  assert.ok(!html.includes("<script>"));
  assert.ok(html.includes("&lt;script&gt;")); // escaped form present in the URLs
});

test("not-found page is noindex", () => {
  const html = renderNotFoundHtml();
  assert.ok(html.includes('content="noindex"'));
});

test("sitemap xml shape", () => {
  const xml = renderSitemapXml([
    { postId: "abc", createdAtMs: Date.UTC(2026, 5, 15) },
    { postId: "def", createdAtMs: undefined },
  ]);
  assert.ok(xml.includes(`<loc>${CANONICAL_ORIGIN}/p/abc</loc>`));
  assert.ok(xml.includes("<lastmod>2026-06-15</lastmod>"));
  assert.ok(xml.includes(`<loc>${CANONICAL_ORIGIN}/p/def</loc>`));
  assert.ok(!xml.match(/def<\/loc>[\s\S]*?<lastmod>/), "no lastmod without createdAt");
});
