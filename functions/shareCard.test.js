// node --test shareCard.test.js — the og:image card renderer.
const test = require("node:test");
const assert = require("node:assert/strict");
const { renderShareCardPNG, W, H } = require("./shareCard");

// PNG signature + IHDR dimensions, read straight from the buffer.
function pngInfo(buf) {
  assert.deepEqual([...buf.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], "PNG signature");
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

test("renders a 1200x630 PNG", () => {
  const buf = renderShareCardPNG({ text: "the silence in the kitchen at night.", tag: "lonely", likeCount: 7 });
  const { width, height } = pngInfo(buf);
  assert.equal(width, W);
  assert.equal(height, H);
  assert.ok(buf.length > 5000, `suspiciously small PNG: ${buf.length}`);
});

test("edge cases render without throwing", () => {
  for (const text of [
    "a",
    "x".repeat(2000),
    ("word ").repeat(400).trim(),
    "i still love you 💔 and i hate that i do",
    "line\nbreaks\n\neverywhere",
    "널 아직도 사랑해", // non-latin scripts fall back too
  ]) {
    const buf = renderShareCardPNG({ text, tag: null, likeCount: 0 });
    pngInfo(buf);
  }
});

// 2026-07-28 (A.5 #5): a single unbroken token wider than the box must be
// hard-broken by characters — every wrapped line must actually fit maxWidth.
test("wrapLines hard-breaks unbroken tokens to fit the box", () => {
  const { wrapLines } = require("./shareCard");
  const { createCanvas } = require("@napi-rs/canvas");
  const ctx = createCanvas(1200, 630).getContext("2d");
  ctx.font = "64px Newsreader";
  const maxWidth = 1200 - 96 * 2;
  for (const text of ["x".repeat(500), "short then " + "y".repeat(300) + " after"]) {
    const lines = wrapLines(ctx, text, maxWidth);
    for (const line of lines) {
      assert.ok(
        ctx.measureText(line).width <= maxWidth,
        `line overflows box: ${line.length} chars, ${ctx.measureText(line).width}px`
      );
    }
    // Round-trip: no characters lost by the breaker.
    assert.equal(lines.join("").replace(/ /g, ""), text.replace(/ /g, ""));
  }
});
