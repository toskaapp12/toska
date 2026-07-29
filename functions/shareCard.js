// OG share-card images — renders the 1200×630 quote card that /p/{postId}
// pages reference as og:image, so shared links unfurl visually (iMessage,
// X, Slack) instead of as bare text. Same privacy bar as everything else in
// the share layer: the words, the tag, the felt count — never the writer.
//
// Rendering is @napi-rs/canvas (prebuilt native, works on Cloud Functions
// linux-x64) with the bundled Newsreader variable TTF (OFL) — the design
// system's serif, so cards match the app's editorial look.
const { createCanvas, GlobalFonts } = require("@napi-rs/canvas");
const path = require("path");

// 2026-07-28 (A.5 #5): registration must not be able to take down the card
// endpoint — a missing/corrupt bundled font previously failed at module load,
// 500ing EVERY og:image. Degrade to the system face instead (an off-brand
// card beats a broken unfurl on every shared link). Handles both failure
// modes: a throw AND registerFromPath's boolean-false return.
function registerFontSafe(file, family) {
  try {
    const ok = GlobalFonts.registerFromPath(path.join(__dirname, "fonts", file), family);
    if (ok === false) console.warn(`shareCard: font ${family} did not register — cards fall back to the system face`);
  } catch (err) {
    console.warn(`shareCard: font ${family} failed to register — cards fall back to the system face:`, err.message);
  }
}
registerFontSafe("Newsreader.ttf", "Newsreader");
// Monochrome emoji fallback (OFL) — post text carries emoji often; without a
// fallback family they rasterize as tofu boxes. The monochrome glyphs render
// in the ink color, matching the card's editorial look.
registerFontSafe("NotoEmoji.ttf", "Noto Emoji");
const QUOTE_FONT = (size) => `${size}px Newsreader, "Noto Emoji"`;

const W = 1200;
const H = 630;
const PAD = 96;
// Palette mirrors the share pages / docs marketing set ("2am" mood).
const BG = "#0b0a10";
const INK = "#eeeff1";
const MUTED = "#91949c";
const PLUM = "#9387c0";

// Greedy word-wrap using real text metrics. Returns lines; caller picks the
// font size that fits the box.
function wrapLines(ctx, text, maxWidth) {
  const words = text.replace(/\s+/g, " ").trim().split(" ");
  const lines = [];
  let line = "";
  for (const word of words) {
    const probe = line ? `${line} ${word}` : word;
    if (ctx.measureText(probe).width <= maxWidth) { line = probe; continue; }
    if (line) { lines.push(line); line = ""; }
    if (ctx.measureText(word).width <= maxWidth) { line = word; continue; }
    // 2026-07-28 (A.5 #5): a single unbroken token wider than the box used to
    // become one overflowing line ("|| !line") and bleed past the card edge.
    // Hard-break it by characters instead — mid-token breaks are ugly, but a
    // 2000-char keyboard-mash is already not prose.
    for (const ch of word) {
      if (line && ctx.measureText(line + ch).width > maxWidth) {
        lines.push(line);
        line = ch;
      } else {
        line += ch;
      }
    }
  }
  if (line) lines.push(line);
  return lines;
}

// The card gives long posts a smaller face rather than truncating early —
// truncation is a last resort (very long posts get an ellipsis line).
const SIZES = [64, 54, 46, 40, 34];
const MAX_LINES = 8;

function renderShareCardPNG({ text, tag, likeCount }) {
  const canvas = createCanvas(W, H);
  const ctx = canvas.getContext("2d");

  ctx.fillStyle = BG;
  ctx.fillRect(0, 0, W, H);

  // Quote — pick the largest size whose wrapped lines fit the text box.
  const boxWidth = W - PAD * 2;
  const footerReserve = 120;
  const boxHeight = H - PAD - footerReserve;
  let fontSize = SIZES[SIZES.length - 1];
  let lines = null;
  for (const size of SIZES) {
    ctx.font = QUOTE_FONT(size);
    const candidate = wrapLines(ctx, text, boxWidth);
    if (candidate.length * size * 1.35 <= boxHeight && candidate.length <= MAX_LINES) {
      fontSize = size;
      lines = candidate;
      break;
    }
  }
  if (!lines) {
    ctx.font = QUOTE_FONT(fontSize);
    lines = wrapLines(ctx, text, boxWidth).slice(0, MAX_LINES);
    const last = lines[lines.length - 1];
    lines[lines.length - 1] = last.replace(/\s*\S*$/, "") + " …";
  }
  const lineHeight = fontSize * 1.35;
  // Vertically center the quote block in the space above the footer.
  const blockHeight = lines.length * lineHeight;
  let y = PAD + (boxHeight - blockHeight) / 2 + fontSize;
  ctx.fillStyle = INK;
  ctx.font = QUOTE_FONT(fontSize);
  ctx.textBaseline = "alphabetic";
  for (const line of lines) {
    ctx.fillText(line, PAD, y);
    y += lineHeight;
  }

  // Footer — wordmark left, meta right. Identity never appears here.
  const footerY = H - 72;
  ctx.fillStyle = PLUM;
  ctx.font = "36px Newsreader";
  ctx.fillText("toska", PAD, footerY);

  const metaBits = [];
  if (typeof tag === "string" && tag) metaBits.push(tag);
  if (typeof likeCount === "number" && likeCount > 0) {
    metaBits.push(`felt ${likeCount} ${likeCount === 1 ? "time" : "times"}`);
  }
  if (metaBits.length) {
    const meta = metaBits.join("  ·  ");
    ctx.fillStyle = MUTED;
    ctx.font = "26px Newsreader";
    const metaWidth = ctx.measureText(meta).width;
    ctx.fillText(meta, W - PAD - metaWidth, footerY);
  }

  return canvas.toBuffer("image/png");
}

module.exports = { renderShareCardPNG, wrapLines, W, H };
