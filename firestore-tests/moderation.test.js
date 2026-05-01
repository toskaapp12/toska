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
