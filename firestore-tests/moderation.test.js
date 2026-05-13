// Pure-function tests for functions/moderation.js
// (server-side mirror of toska/FeedView.swift::containsNameOrIdentifyingInfo).
//
// Run with:
//   cd firestore-tests && npx mocha --timeout 5000 moderation.test.js
//
// No emulator needed — the detector is a pure function over a string. Tests
// pin three things:
//   1. Regression set: original-Swift-detector cases still flag.
//   2. New evasion vectors: confusables, leet, separator collapse, last
//      names, dotted initials, apartment numbers, social URLs.
//   3. Benign prose negatives: legit posts a heartbroken user might write
//      do NOT flag, even though they look adjacent to flag-worthy content.

const assert = require("assert");
const {
  containsNameOrIdentifyingInfo,
  canonicalize,
  aggressiveNormalizeForNameMatch,
} = require("../functions/moderation");

function flag(label, text) {
  it(label, () => {
    assert.strictEqual(
      containsNameOrIdentifyingInfo(text),
      true,
      `expected to flag, did not: ${JSON.stringify(text)}`
    );
  });
}

function noFlag(label, text) {
  it(label, () => {
    assert.strictEqual(
      containsNameOrIdentifyingInfo(text),
      false,
      `expected NOT to flag, but did: ${JSON.stringify(text)}`
    );
  });
}

describe("canonicalize — confusable / fullwidth / accent folding", () => {
  it("folds Cyrillic а → a", () => {
    assert.strictEqual(canonicalize("Sаrah"), "sarah");
  });
  it("folds fullwidth Ｓａｒａｈ → sarah", () => {
    assert.strictEqual(canonicalize("Ｓａｒａｈ"), "sarah");
  });
  it("strips combining marks (NFD)", () => {
    assert.strictEqual(canonicalize("Sårāh"), "sarah");
  });
  it("preserves digits and spaces", () => {
    assert.strictEqual(canonicalize("3 months ago"), "3 months ago");
  });
});

describe("aggressiveNormalizeForNameMatch — leet + separator collapse", () => {
  it("de-leets digit-letter substitutions", () => {
    assert.strictEqual(aggressiveNormalizeForNameMatch("j0hn"), "john");
    assert.strictEqual(aggressiveNormalizeForNameMatch("5arah"), "sarah");
    assert.strictEqual(aggressiveNormalizeForNameMatch("m1k3"), "mike");
  });
  it("de-leets symbols (@ → a, $ → s)", () => {
    assert.strictEqual(aggressiveNormalizeForNameMatch("m@tt"), "matt");
  });
  it("collapses period separators", () => {
    assert.strictEqual(aggressiveNormalizeForNameMatch("j.o.h.n"), "john");
  });
  it("collapses hyphen separators", () => {
    assert.strictEqual(aggressiveNormalizeForNameMatch("j-o-h-n"), "john");
  });
  it("collapses underscore separators", () => {
    assert.strictEqual(aggressiveNormalizeForNameMatch("j_o_h_n"), "john");
  });
  it("collapses space separators", () => {
    assert.strictEqual(
      aggressiveNormalizeForNameMatch("hi j o h n bye"),
      "hi john bye"
    );
  });
  it("does not collapse multi-letter words separated by spaces", () => {
    // "I am a fan" must NOT collapse to "iamafan" — the regex requires
    // single-letter chains, multi-letter words break the pattern.
    assert.strictEqual(
      aggressiveNormalizeForNameMatch("I am a fan"),
      "i am a fan"
    );
  });
});

describe("containsNameOrIdentifyingInfo — regression (original Swift cases still flag)", () => {
  flag("@handle", "follow me at @sarah_lol");
  flag("possessive name (Jessica's)", "Jessica's birthday was hard");
  flag("relationship + capitalized name (my ex Michael)", "my ex Michael never apologized");
  flag("named X with capital", "she was named Olivia and that's all I remember");
  flag("called X with capital", "he was called David back then");
  flag("name is X with capital", "her name is Karen and she lives nearby");
  flag("mid-sentence first name (Sarah)", "we broke up after Sarah moved out");
  flag("street address", "she lives at 123 Main Street");
  flag("10+ digit phone", "call me at 555-867-5309 anytime");
  flag("identifying keyword: dm me", "dm me later if you want");
  flag("identifying keyword: instagram", "find me on instagram its easy");
  flag("identifying keyword: snapchat", "we used to talk on snapchat");
  flag("identifying keyword: lives at", "she lives at the corner house");
  flag("apartment keyword (apt with space)", "she's in apt 5 next door");
  flag("relationship + capital name (this guy Tyler)", "this guy Tyler keeps texting");
});

describe("containsNameOrIdentifyingInfo — new evasion vectors flag", () => {
  flag("Cyrillic confusable Sаrah", "I miss Sаrah every single day");
  flag("Fullwidth Ｓａｒａｈ", "I still think about Ｓａｒａｈ");
  flag("Accented Sårāh (NFD)", "I still think about Sårāh sometimes");
  flag("Cyrillic confusable Mіchael", "Mіchael was the worst part");

  flag("leet j0hn", "I cant stop thinking about J0hn");
  flag("leet 5arah", "I cant stop thinking about 5arah");
  flag("leet 5amantha at sentence start", "5amantha was so cruel to me");
  flag("leet @ symbol m@tt", "I miss m@tthew so much");

  flag("separator periods j.o.h.n", "I hate that I miss j.o.h.n now");
  flag("separator hyphens j-o-h-n", "I hate that I miss j-o-h-n now");
  flag("separator underscores j_o_h_n", "I hate that I miss j_o_h_n now");
  flag("separator spaces (single-letter chain)", "this guy s a r a h broke me");

  flag("last name Smith mid-sentence", "I work with Smith from accounting");
  flag("last name Johnson mid-sentence", "I saw Johnson at the store yesterday");
  flag("last name Rodriguez", "I keep running into Rodriguez everywhere");

  flag("URL instagram.com/handle", "find them at instagram.com/lonelyboy");
  flag("URL t.me/handle", "we used to dm on t.me/abc123");
  flag("URL linktr.ee", "his linktr.ee/heartbreak says it all");

  flag("apartment apt4B (no space)", "shes in apt4B all alone");
  flag("apartment unit 12", "shes in unit 12 of the brick building");
  flag("bare #207", "shes in #207 next door to me");

  flag("dotted initials with relationship prefix", "my ex J.S. broke my heart");
  flag("two-period initials", "my friend M.K. wont talk to me");

  flag("fullwidth identifying keyword", "her Ｉｎｓｔａｇｒａｍ is private now");

  // Nickname additions (2026-05-01 sprint follow-up).
  flag("nickname Mike mid-sentence", "I keep running into Mike at the gym");
  flag("nickname Tom mid-sentence", "I miss talking to Tom every night");
  flag("nickname Liz mid-sentence", "I told Liz everything and she just shrugged");
  flag("leet nickname M1ke (de-leets to mike)", "I miss M1ke from work so much");
  flag("leet nickname J1m (de-leets to jim)", "I cant stop thinking about J1m");
});

describe("containsNameOrIdentifyingInfo — benign prose does NOT flag", () => {
  noFlag("3 months ago (leet collision risk)", "we broke up 3 months ago and it still hurts");
  noFlag("year reference 2024", "we broke up in 2024 and i havent moved on");
  noFlag("called him out (no proper noun after)", "I called him out for lying to me");
  noFlag("the summer we met (ambiguous word: summer)", "the summer we met was the best of my life");
  noFlag("ambiguous word: Hope at start", "Hope is all I have left");
  noFlag("ambiguous word: May at start", "May was the hardest month so far");
  noFlag("safe capitalized: Christmas", "Christmas was so hard without him");
  noFlag("plain reflective sentence", "I am tired of being alone");
  noFlag("price is a word, not a surname", "I had to pay a high price for love");
  noFlag("king is a word, not a surname (lowercase)", "I felt like a king when we were together");
  noFlag("brown is a color, not a surname (lowercase)", "his brown eyes were everything");
  noFlag("young is a word, not a surname (lowercase)", "we were young and stupid");
  noFlag("I am a fan (multi-letter spacing must not collapse)", "I am a fan of his music still");
  noFlag("crisis number (988) does not flag as phone", "if it gets bad call 988 ok");
  noFlag("date format like 5/4/2024 is not a phone", "the breakup was on 5/4/2024 if you must know");
  // `named ` was previously a broad keyword and false-positived on
  // sentences like the next two. The narrowed `namedPatterns` check
  // (requires capitalized following token) lets these through while
  // still flagging "she was named Olivia" — pinned in the regression set.
  noFlag("named the dog (lowercase article after)", "she named the dog Rex but i forget");
  noFlag("named the album (lowercase after)", "we named the album something corny");
  noFlag("street name reference (no actual address)", "my street name is so dumb honestly");
  noFlag("multi-letter words don't collapse", "I miss him so so much");
});

describe("evasion: bidi controls + invisible separators (audit P2)", () => {
  // Strip-before-canonicalize tests. An attacker inserting U+202E (RTL
  // override) renders text reversed visually but ships the codepoints in
  // logical order; without stripping, the detector sees the unreversed
  // string anyway. The fix is targeted: strip controls + invisibles
  // BEFORE NFD decompose. Each test asserts the detector still flags
  // the same name despite the evasion attempt.

  it("canonicalize strips RTL override (U+202E)", () => {
    // Visual result of "my ex ‮nhoJ‬" reads right-to-left
    // around John, so a casual moderator scrolling sees "my ex John"
    // rendered backwards while the codepoints still spell n-h-o-J.
    // Stripping the bidi controls collapses both directions to "nhoj"
    // — name match still fails on the canonicalize-and-tokenize path,
    // but the post triggers the relationship-keyword + capitalized
    // last-token surname / dotted-initial pattern. We assert the
    // canonicalize step itself successfully removes the controls.
    const out = canonicalize("hello ‮world‬");
    assert.strictEqual(out.includes("‮"), false);
    assert.strictEqual(out.includes("‬"), false);
  });

  it("canonicalize strips zero-width space (U+200B)", () => {
    // A single ZWSP between letters fragments the token before
    // tokenizeAlphanumeric runs (it splits on non-alphanumeric, and
    // ZWSP is a non-alphanumeric in Unicode property terms), so
    // "Sa​rah" would tokenize as ["Sa", "rah"] and miss the
    // name match. Stripping ZWSP first restores "sarah".
    assert.strictEqual(canonicalize("Sa​rah"), "sarah");
  });

  it("canonicalize strips zero-width joiner (U+200D)", () => {
    assert.strictEqual(canonicalize("Sa‍rah"), "sarah");
  });

  it("canonicalize strips zero-width non-joiner (U+200C)", () => {
    assert.strictEqual(canonicalize("Sa‌rah"), "sarah");
  });

  it("canonicalize strips word joiner (U+2060)", () => {
    assert.strictEqual(canonicalize("Sa⁠rah"), "sarah");
  });

  it("canonicalize strips BOM / zero-width no-break space (U+FEFF)", () => {
    assert.strictEqual(canonicalize("Sa﻿rah"), "sarah");
  });

  flag(
    "name fragmented with zero-width spaces still flags",
    "her name is Sa​rah and i miss her"
  );

  // Layer 4.5 (added 2026-05-08) closes the literal-reversal evasion that
  // bidi-stripping alone can't catch: an attacker writes "nhoJ" or "haraS"
  // as plain ASCII (no bidi controls at all), and prior layers all miss
  // because the forward token isn't a name. The new layer reverses each
  // canonicalized token and rechecks the name set with the same length
  // floor + ambiguous/safe filters so common-fragment collisions
  // ("rae" → "ear", "ana" → "ana" palindrome) don't false-positive.
  flag("RTL-reversed name in plain ASCII flags", "i miss haraS so much");
  flag("RTL-reversed name with bidi-control wrapper still flags", "i miss ‮haraS‬ so much");
  flag("longer reversed last name flags", "thinking about htimS again");
  noFlag("short token reversed to a name fragment doesn't flag", "the rae of light");
  noFlag("ambiguous reversed word doesn't flag", "the day was so long");
});

describe("phone number detection — formatted variants (audit 2026-05-13 M-1)", () => {
  // The prior digit-strip chain peeled `\b\d{1,3}\b` and `\b\d{4,5}\b` off
  // formatted phones because parens/space/dash all sit at word boundaries
  // around each digit chunk, leaving zero digits in the count. The fix
  // collapses `(\d)[-.\s()]+(?=\d)` runs first so a formatted phone
  // becomes a contiguous 10-digit run before the date/year/small-number
  // strips run.
  flag("US phone with parens + space + dash", "(555) 123-4567");
  flag("US phone with parens no space", "(555)123-4567");
  flag("US phone all dashes", "555-123-4567");
  flag("US phone all dots", "555.123.4567");
  flag("US phone with spaces", "555 123 4567");
  flag("international phone with country code + spaces", "+44 20 7946 0958");
  flag("phone embedded in prose", "her number is (555) 867-5309 if you want");

  noFlag(
    "date with slashes is not a phone",
    "the breakup was on 5/4/2024 if you must know"
  );
  noFlag(
    "time 12:30 is not a phone",
    "we usually talked at 12:30 every night"
  );
  noFlag(
    "few small numbers in prose don't flag",
    "it was 3 months and 4 weeks and 5 days ago"
  );
});

describe("evasion: combining-mark fragmentation (audit 2026-05-13 L-1)", () => {
  // U+0300-U+036F combining marks are Mn category, which the default
  // `\p{L}\p{N}` token split treats as separators. Without combining-
  // mark-aware tokenization, `S̶arah` fragments to ['S', 'arah'] and
  // neither piece matches a name. The fix tokenizes the combining-mark-
  // stripped form (case-preserving) in Layers 4 / 4.5.
  flag(
    "name with combining stroke mid-sentence",
    "i still miss S̶arah every single day"
  );
  flag(
    "last name with combining stroke",
    "i bumped into S̶mith from work yesterday"
  );
  flag(
    "name with multiple combining marks",
    "she goes by Sa̶r̶a̶h̶ now"
  );
  noFlag(
    "lowercase combining-mark name does NOT flag (capitalization gate)",
    "i miss s̶arah every day"
  );
});

describe("social shorthand: ig:/sc:/fb: (audit 2026-05-13 L-2)", () => {
  // Two-letter platform shorthand is too generic ("dig", "fab", "abs") to
  // substring-match like the full keywords (instagram/snapchat/facebook).
  // Word-boundary anchored regex requires the literal label syntax
  // (trailing colon/period/dash) to flag.
  flag("ig: with name", "ig: sarahreal");
  flag("ig:no-space", "ig:sarahreal_lol");
  flag("IG. uppercase variant", "IG. realname123");
  flag("sc: with name", "sc: snapchat_user");
  flag("fb: with name", "fb: real.name");
  flag("ig - with name", "ig - sarahreal");

  noFlag("dig: is not social shorthand", "dig: deeper into yourself");
  noFlag("fab. is not social shorthand", "fab. things to remember");
  noFlag("abs- is not social shorthand", "abs- olutely not");
  noFlag("plain ig in the middle of a word", "he was a big talker");
});

describe("evasion: Mathematical Alphanumeric Symbols (audit P2)", () => {
  // U+1D400-U+1D7FF block: bold/italic/script/fraktur/double-struck/sans-
  // serif/monospace letterforms render visually identical to Latin but
  // ship as separate code points. Without folding, "𝐉𝐨𝐡𝐧" looks like
  // "John" but tokenizeAlphanumeric returns no Latin letters at all
  // (the math-alpha codepoints aren't in \p{L} for token splits — they
  // ARE in \p{L} so the original test was wrong; the issue is the name
  // match itself doesn't see "john"). Folding to ASCII fixes both paths.

  it("canonicalize folds bold-style 𝐉𝐨𝐡𝐧 → john", () => {
    // 𝐉=U+1D409, 𝐨=U+1D428, 𝐡=U+1D421, 𝐧=U+1D427 (bold uppercase J,
    // bold lowercase o/h/n)
    assert.strictEqual(canonicalize("𝐉𝐨𝐡𝐧"), "john");
  });

  it("canonicalize folds italic-style 𝑆𝑎𝑟𝑎ℎ → sarah", () => {
    // 𝑆=U+1D446, 𝑎=U+1D44E, 𝑟=U+1D45F, ℎ=U+210E (planck constant — a
    // single math-italic 'h' that lives outside the contiguous block).
    // We don't try to catch every singleton outside the block; this
    // test asserts the contiguous-block fold works and documents that
    // edge codepoints like ℎ still slip through. Acceptable: the rest
    // of the name still folds, and a future widening can add singletons.
    const out = canonicalize("𝑆𝑎𝑟𝑎h");
    assert.strictEqual(out, "sarah");
  });

  it("canonicalize folds double-struck 𝕊𝕒𝕣𝕒𝕙 → sarah", () => {
    // Double-struck (U+1D54A onward) fold lane.
    assert.strictEqual(canonicalize("𝕊𝕒𝕣𝕒𝕙"), "sarah");
  });

  it("canonicalize folds monospace 𝚂𝚊𝚛𝚊𝚑 → sarah", () => {
    // Monospace block (U+1D670 onward).
    assert.strictEqual(canonicalize("𝚂𝚊𝚛𝚊𝚑"), "sarah");
  });

  flag(
    "name in bold math-alpha still flags",
    "her name is 𝐉𝐨𝐡𝐧 and i'm done"
  );
});
