// Server-side mirror of toska/FeedView.swift::containsNameOrIdentifyingInfo.
//
// Why this exists separately from the JS containsPII() helper inside
// functions/index.js: the iOS pre-publish detector grew a much larger
// surface area in the 2026-05-01 pre-launch sprint (confusable folding,
// leet, separator collapse, last names, dotted initials, apartment numbers)
// and a tampered client that bypasses the iOS check would otherwise slip
// straight through to feed. This module ports the full Swift detector so
// the server can reject the same inputs the iOS app rejects, and is wired
// into validatePost / validateReply in index.js for create-time enforcement.
// containsPII() in index.js also delegates here so the post-update / reply-
// update / DM moderation triggers benefit from the same coverage.
//
// Keep this file in sync with toska/FeedView.swift::containsNameOrIdentifyingInfo
// when adding new evasion vectors. The test suite at
// firestore-tests/moderation.test.js pins both the regression set (all
// original Swift cases still flag) and the new evasion cases.

// ============================================================
// Constants — mirror the Swift sets verbatim so behavior is identical.
// ============================================================

const COMMON_NAMES = new Set([
  "james", "john", "robert", "michael", "david", "richard", "joseph", "thomas", "charles",
  "christopher", "matthew", "anthony", "donald", "steven", "andrew", "joshua",
  "kenneth", "kevin", "brian", "george", "timothy", "ronald", "edward", "jason", "jeffrey", "ryan",
  "jacob", "gary", "nicholas", "eric", "jonathan", "stephen", "larry", "justin", "scott", "brandon",
  "benjamin", "samuel", "raymond", "gregory", "alexander", "patrick", "dennis", "jerry",
  "tyler", "aaron", "jose", "adam", "nathan", "henry", "peter", "zachary", "douglas", "harold",
  "patricia", "jennifer", "linda", "barbara", "elizabeth", "susan", "jessica", "sarah", "karen",
  "lisa", "nancy", "betty", "margaret", "sandra", "ashley", "dorothy", "kimberly", "emily", "donna",
  "michelle", "carol", "amanda", "melissa", "deborah", "stephanie", "rebecca", "sharon", "laura", "cynthia",
  "kathleen", "amy", "angela", "shirley", "brenda", "pamela", "emma", "nicole", "helen",
  "samantha", "katherine", "christine", "debra", "rachel", "carolyn", "janet", "catherine", "maria", "heather",
  "diane", "ruth", "julie", "olivia", "joyce", "virginia", "victoria", "kelly", "lauren", "christina",
  "joan", "evelyn", "judith", "megan", "andrea", "cheryl", "hannah", "jacqueline", "martha", "gloria",
  "teresa", "sara", "madison", "frances", "kathryn", "janice", "jean", "abigail", "alice",
  "alex", "chris", "taylor", "casey", "riley", "jamie", "quinn", "avery",
  "cameron", "dakota", "skyler", "charlie", "finley", "harper", "logan",
  "ethan", "aiden", "jackson", "sebastian", "mateo", "owen", "oliver",
  "sophia", "isabella", "charlotte", "amelia", "chloe", "penelope", "layla",
  "nora", "zoey", "eleanor", "hazel", "audrey",
  "claire", "skylar", "paisley", "everly", "caroline",
  "genesis", "emilia", "kennedy", "kinsley", "naomi", "aaliyah", "elena",
  // Common nicknames — mirror of the Swift addition. Filtered out:
  //   - jordan (country, high FP), max/drew/sue (verbs/intensifiers),
  //   - bob/rob/nick (verbs in common usage).
  "mike", "tom", "jim", "tim", "dan", "sam", "ben", "tony", "jake",
  "leo", "ian", "kyle", "evan", "greg", "jeff", "kurt", "paul",
  "pete", "eli", "brett", "todd", "troy",
  "liz", "beth", "kate", "ann", "jane", "lynn", "abby", "becky", "jess",
]);

const COMMON_LAST_NAMES = new Set([
  "smith", "johnson", "williams", "jones", "garcia", "miller", "davis",
  "rodriguez", "martinez", "hernandez", "lopez", "gonzalez", "wilson",
  "anderson", "thomas", "taylor", "jackson", "martin", "perez",
  "thompson", "harris", "clark", "ramirez", "lewis", "robinson",
  "scott", "torres", "nguyen", "flores", "adams", "nelson", "rivera",
  "campbell", "mitchell", "carter", "roberts", "gomez", "phillips",
  "evans", "turner", "parker", "cruz", "edwards", "collins", "reyes",
  "stewart", "morris", "morales", "murphy", "rogers", "gutierrez",
  "ortiz", "morgan", "peterson", "bailey", "kelly", "howard", "ramos",
  "richardson", "watson", "chavez", "bennett", "mendoza", "ruiz",
  "hughes", "alvarez", "castillo", "sanders", "patel", "myers", "ross",
  "foster", "jimenez", "cooper", "walker", "allen", "washington",
  "jefferson", "lincoln", "kennedy", "obama",
]);

const AMBIGUOUS_WORDS = new Set([
  "will", "grace", "angel", "mark", "frank", "art", "may",
  "joy", "hope", "faith", "chance", "chase", "hunter",
  "summer", "autumn", "winter", "dawn", "eve",
  "rose", "lily", "iris", "ivy", "pearl", "ruby", "amber",
  "brook", "cliff", "dale", "glen", "heath", "lance", "miles",
  "norm", "pat", "ray", "rex", "rod", "skip", "wade",
  "violet", "olive", "sage", "holly", "ginger",
  "sandy", "misty", "stormy", "sunny", "cherry", "candy",
  "destiny", "trinity", "harmony", "melody", "serenity",
]);

const SAFE_CAPITALIZED_WORDS = new Set([
  "i", "im", "ive", "ill", "id",
  "god", "christmas", "easter", "halloween", "valentines",
  "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
  "january", "february", "march", "april", "june", "july", "august",
  "september", "october", "november", "december",
  "american", "english", "spanish", "french", "chinese", "japanese",
  "toska", "giphy", "apple", "google", "firebase",
]);

// Common two-word proper nouns that are NOT a person's name — places, brands,
// media, and capitalized greetings — so the full-name heuristic below doesn't
// hold "I miss New York" or "we watched Harry Potter". Long-tail proper nouns
// not listed here will still be held for review (the safe direction for an
// anonymity app — held, not deleted).
const SAFE_PROPER_NOUN_BIGRAMS = new Set([
  "new york", "new jersey", "new orleans", "new mexico", "new hampshire",
  "los angeles", "san francisco", "san diego", "san antonio", "san jose",
  "las vegas", "rhode island", "north carolina", "south carolina",
  "north dakota", "south dakota", "west virginia", "new zealand",
  "hong kong", "costa rica", "puerto rico", "united states", "united kingdom",
  "great britain", "saudi arabia", "south africa", "south korea",
  "taylor swift", "harry potter", "taco bell", "burger king", "old navy",
  "stranger things", "breaking bad", "black friday",
  "happy birthday", "happy holidays", "merry christmas",
  "good morning", "good evening", "good afternoon", "good night", "good luck",
  "thank god",
]);

// M-2 (2026-06-08 audit): common English words that appear Capitalized inside
// titles, place names, bands, and set phrases ("Last Night", "Central Park",
// "Pearl Jam", "Grand Canyon", "The Notebook", "Empty Promises"). The
// two-capitalized-words full-name heuristic below false-positived on every one
// of these on an app where grief posts are full of such phrases. A real
// person's full name is rarely built from two common English words, so if a
// bigram contains one of these AND neither token is a known given name, it's
// treated as a phrase, not a name. This is intentionally a common-ENGLISH-word
// list (a bounded, stable set) rather than an exhaustive non-name proper-noun
// list (which can't scale). Real names like "Sarah Jones" or the uncommon
// "Tess Salinaro" stay flagged because they don't contain a title word.
const COMMON_TITLE_WORDS = new Set([
  "the", "a", "an", "of", "and", "to", "in", "on", "at", "for",
  "last", "first", "next", "final", "every",
  "night", "day", "days", "morning", "evening", "afternoon", "today", "tomorrow", "yesterday",
  "central", "grand", "royal", "golden", "old", "new", "big", "little", "great",
  "park", "city", "town", "river", "lake", "mountain", "mountains", "ocean", "sea", "beach",
  "street", "avenue", "road", "drive", "lane", "garden", "gardens", "square", "bridge",
  "tower", "valley", "hill", "hills", "falls", "bay", "island", "forest", "woods", "creek",
  "heights", "view", "point", "north", "south", "east", "west", "upper", "lower", "middle",
  "house", "home", "world", "war", "story", "stories", "love", "heart", "hearts",
  "summer", "winter", "spring", "autumn", "fall", "sunset", "sunrise",
  "moon", "sun", "star", "stars", "light", "lights", "dark", "darkness",
  "dream", "dreams", "time", "times", "life", "death", "end", "ending", "beginning",
  "dead", "alive", "real", "true", "lost", "found", "broken", "empty", "promise", "promises",
  "gold", "silver", "blue", "red", "green", "white", "black", "gray", "grey",
  "fire", "water", "earth", "wind", "rain", "snow", "storm", "cloud", "clouds", "sky",
  "song", "songs", "music", "dance", "band", "club", "bar", "cafe", "coffee",
  "book", "books", "movie", "film", "show", "game", "games", "play", "party",
  "school", "college", "work", "office", "store", "shop", "mall", "market",
  "food", "dinner", "lunch", "breakfast", "pearl", "jam", "canyon", "notebook",
  "station", "airport", "university", "library", "museum", "hotel", "plaza",
  "center", "centre", "hall", "theater", "theatre", "stadium", "arena",
  "church", "temple", "castle", "palace", "diamond", "crystal", "rose", "stone",
]);

// Full-name shape: two consecutive Capitalized words ("Tess Salinaro",
// "John Smith") — a strong signal of a person's name even when neither word
// is in our first/last-name dictionaries. 2026-06-01: added after a real full
// name slipped through (uncommon name + no relationship context). Guards skip
// safe words, all-ambiguous pairs, known non-name bigrams, and (M-2) common
// English title/phrase bigrams. NOTE: this only catches the BOTH-capitalized
// shape; "Tess salinaro" (lowercase surname) and bare single names still slip
// — reliably catching those needs NER/ML.
function looksLikeFullName(text) {
  const re = /\b([A-Z][a-z]+)\s+([A-Z][a-z]+)\b/g;
  for (const m of text.matchAll(re)) {
    const w1 = m[1].toLowerCase();
    const w2 = m[2].toLowerCase();
    if (w1.length < 2 || w2.length < 2) continue;
    if (SAFE_CAPITALIZED_WORDS.has(w1) || SAFE_CAPITALIZED_WORDS.has(w2)) continue;
    if (AMBIGUOUS_WORDS.has(w1) && AMBIGUOUS_WORDS.has(w2)) continue;
    if (SAFE_PROPER_NOUN_BIGRAMS.has(`${w1} ${w2}`)) continue;
    // M-2: a bigram containing a common English title/phrase word is a phrase,
    // not a name — UNLESS the other token is a known given name (keeps "Sarah
    // Park", "Grace Lake" flagged while clearing "Central Park", "Last Night").
    if ((COMMON_TITLE_WORDS.has(w1) || COMMON_TITLE_WORDS.has(w2))
        && !COMMON_NAMES.has(w1) && !COMMON_NAMES.has(w2)) continue;
    return true;
  }
  return false;
}

const IDENTIFYING_PATTERNS = [
  "instagram", "insta", "snapchat", "snap", "tiktok", "twitter",
  "facebook", "linkedin", "phone number", "my number", "text me",
  "call me", "dm me", "follow me", "find me", "look me up",
  "last name", "full name", "school name",
  // Launch-readiness (2026-06-10): removed loose "works at"/"goes to"/"lives
  // in"/"lives on" — literal substrings that false-positive heavily on normal
  // grief writing ("she works at the hospital where we met", "lives in my head
  // rent free now", "he goes to my gym"). index.js's identifyingPhrases already
  // dropped them for the same reason; this aligns the delegated detector and
  // cuts a large false-positive class. "lives at" (street context) + "address"
  // are more specific and kept.
  "lives at", "address",
  // N-15 (2026-06-10 re-review): removed the loose "apartment"/"apt "/"suite "
  // substrings — they false-positived on benign text ("adapt to change", "the
  // suite life", "my apartment is empty now"). Real unit numbers are still
  // caught by the gated Layer-2 regex below (\b(apt|unit|suite|ste)…\d+), which
  // requires a following number.
  "her name is", "his name is", "their name is",
  // NOTE: "named " was previously in this list as a broad keyword and
  // false-positived on legitimate sentences like "she named the dog Rex"
  // or "we named the album X". The careful NAMED_PATTERNS check below
  // (which requires the following token to be capitalized) is strictly
  // better and catches the cases we care about ("she was named Olivia")
  // without the FP surface. Mirror of the Swift removal.
  "zip code", "zipcode",
  "discord", "telegram", "whatsapp", "signal",
  "threads", "bluesky", "reddit",
];

// Two-letter social-platform shorthand (ig:, sc:, fb:) — word-boundary
// anchored so generic English ("dig:", "fab:", "abs.") doesn't false-
// positive. The full names (instagram, snapchat, facebook) are in
// IDENTIFYING_PATTERNS above; this catches the very common shortcut
// syntax `ig: sarahreal` that the keyword list misses because "ig"
// alone is too generic to substring-match.
const SOCIAL_SHORTHAND_RE = /\b(ig|sc|fb)\b\s*[:.\-]/i;

const RELATIONSHIP_PREFIXES = [
  "my ex ", "my friend ", "my bf ", "my gf ",
  "my boyfriend ", "my girlfriend ", "my sister ", "my brother ",
  "my mom ", "my dad ", "my mother ", "my father ",
  "my coworker ", "my boss ", "my roommate ", "my neighbor ",
  "this girl ", "this guy ", "this boy ", "this man ", "this woman ",
];

const NAMED_PATTERNS = ["named ", "called ", "name is ", "name was "];

const STREET_SUFFIXES = "street|st|avenue|ave|boulevard|blvd|drive|dr|lane|ln|road|rd|way|place|pl|court|ct|circle|cir|terrace|trail|parkway|pkwy";
const STREET_REGEX = new RegExp(`\\d+\\s+[A-Za-z]+\\s+(${STREET_SUFFIXES})\\b`, 'i');

// Doxxable location-context patterns. These catch the subtle locator
// phrasing that the literal street-suffix / phone / "lives at" rules miss:
//   "he works at chicago mercy hospital"
//   "the cafe above the bodega on 5th and vine"
//   "she goes to UCLA"
//   "from brooklyn"
// Heuristic — some false positives on legitimate "we worked at the same
// hospital" venting. Tighter than letting a doxx with no street number
// through.
const LOCATION_CONTEXT_PATTERNS = [
  // Workplace + capitalized proper-noun anchor (institution / business).
  /\b(works at|worked at|employed at)\s+(the\s+)?[A-Z][A-Za-z'-]+/,
  // Education with named institution / school district.
  /\b(goes to|went to|attends|studies at|enrolled at|graduated from)\s+(the\s+)?[A-Z][A-Za-z'-]+/,
  // Common identifiable-place context — hospital / school / etc. preceded
  // by a locator preposition.
  /\b(at|near|behind|above|across from|next to|in front of)\s+(the\s+)?(hospital|school|university|college|library|station|airport|bodega|cafe|bar|diner|restaurant|coffee shop|gym|church|mosque|temple|synagogue|park|mall|stadium|theater|theatre|hotel|motel|hostel|hospital)\b/i,
  // Cross-street intersection: "on 5th and vine", "at park and 33rd".
  /\b(on|at|near|by)\s+[A-Za-z0-9]+\s+(and|&)\s+[A-Za-z0-9]+\s+(street|st|ave|avenue|blvd|drive|dr)\b/i,
  /\b(corner of|intersection of)\s+[A-Za-z0-9]+\s+(and|&)\s+[A-Za-z0-9]+\b/i,
  // From [City] — top-50ish US population list plus a handful of major
  // international cities. Trimmed to common single-word and two-word
  // entries; long-tail city names are intentionally not enumerated.
  /\b(from|in|near|outside)\s+(new york|brooklyn|manhattan|queens|los angeles|chicago|houston|phoenix|philadelphia|san diego|dallas|austin|seattle|denver|boston|portland|miami|atlanta|nashville|charlotte|detroit|memphis|baltimore|milwaukee|sacramento|kansas city|las vegas|long beach|fresno|oakland|minneapolis|cleveland|tampa|honolulu|new orleans|wichita|raleigh|omaha|tucson|albuquerque|st louis|saint louis|cincinnati|pittsburgh|anchorage|st paul|saint paul|toledo|newark|jersey city|orlando|tulsa|arlington|virginia beach|colorado springs|london|paris|tokyo|berlin|toronto|sydney|melbourne|dublin|madrid|rome|amsterdam|barcelona|mumbai|delhi|beijing|shanghai|mexico city)\b/i,
];

const CRISIS_NUMBERS = [
  "988-273-8255", "9882738255", "988 273 8255",
  "1-800-273-8255", "18002738255", "1 800 273 8255",
  "741741", "741 741",
  "1-800-799-7233", "18007997233",
  "1-800-656-4673", "18006564673",
];

// Confusable map: Cyrillic + Greek lookalikes folded to Latin. Mirror of
// nameConfusableMap in FeedView.swift.
const NAME_CONFUSABLE_MAP = {
  // Cyrillic uppercase
  "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O",
  "Р": "P", "С": "C", "Т": "T", "У": "Y", "Х": "X", "І": "I", "Ј": "J",
  // Cyrillic lowercase
  "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o",
  "р": "p", "с": "c", "т": "t", "у": "y", "х": "x", "і": "i", "ј": "j",
  // Greek uppercase
  "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K",
  "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X",
  // Greek lowercase
  "α": "a", "β": "b", "ε": "e", "ι": "i", "ο": "o", "ρ": "p",
  "τ": "t", "υ": "y", "χ": "x",
};

const NAME_LEET_MAP = {
  "0": "o", "1": "i", "3": "e", "4": "a",
  "5": "s", "7": "t", "8": "b",
  "@": "a", "$": "s",
};

// ============================================================
// Normalization helpers — mirror of canonicalize / aggressiveNormalizeForNameMatch.
// ============================================================

// Mathematical Alphanumeric Symbols (U+1D400..U+1D7FF) cover bold, italic,
// script, fraktur, and double-struck letterforms that render as visually
// indistinguishable Latin letters but ship as different code points so
// they slip past the name detector. The block is contiguous and folds
// modularly: each 26-letter run starts at one of the offsets below.
// Enumerating all known starting offsets here is more reliable than NFKC
// (which is invasive and has unwanted side effects on emoji + symbols).
//
// Offsets cover: bold, italic, bold-italic, script, bold-script, fraktur,
// double-struck, bold-fraktur, sans-serif, sans-serif bold, sans-serif
// italic, sans-serif bold-italic, monospace — both upper and lower case.
const MATH_ALPHA_UPPER_OFFSETS = [
  0x1D400, 0x1D434, 0x1D468, 0x1D49C, 0x1D4D0, 0x1D504, 0x1D538,
  0x1D56C, 0x1D5A0, 0x1D5D4, 0x1D608, 0x1D63C, 0x1D670,
];
const MATH_ALPHA_LOWER_OFFSETS = [
  0x1D41A, 0x1D44E, 0x1D482, 0x1D4B6, 0x1D4EA, 0x1D51E, 0x1D552,
  0x1D586, 0x1D5BA, 0x1D5EE, 0x1D622, 0x1D656, 0x1D68A,
];

// Bidi controls + invisible separators that render-as-nothing but split
// tokens. Stripping them BEFORE NFD decompose prevents an attacker from
// fragmenting a flagged name with `J​ohn` (zero-width space splits
// the token before tokenizeAlphanumeric runs) or reversing it with U+202E
// (RTL override flips visual order without changing codepoint sequence).
//
// Built from an explicit codepoint list (rather than a hand-typed literal of
// invisible characters) so the set is reviewable and extendable. All entries
// are BMP, so \uXXXX in the constructed class is sufficient.
const STRIP_INVISIBLE_CODEPOINTS = [
  0x200b, 0x200c, 0x200d, 0x200e, 0x200f, // ZWSP, ZWNJ, ZWJ, LRM, RLM
  0x202a, 0x202b, 0x202c, 0x202d, 0x202e, // bidi embed/override controls
  0x2060,                                 // word joiner
  0x2066, 0x2067, 0x2068, 0x2069,         // bidi isolates
  0xfeff,                                 // zero-width no-break space / BOM
  // 2026-06-01 audit: render-as-nothing separators an attacker can splice
  // into a flagged name with NO visible change, fragmenting the token so the
  // name lookup misses (e.g. `Sa­rah` looks exactly like "Sarah").
  0x00ad,                 // soft hyphen
  0x034f,                 // combining grapheme joiner
  0x061c,                 // arabic letter mark
  0x115f, 0x1160,         // Hangul choseong / jungseong fillers
  0x17b4, 0x17b5,         // Khmer invisible inherent vowels
  0x180e,                 // Mongolian vowel separator
  0x3164,                 // Hangul filler
  0xffa0,                 // halfwidth Hangul filler
];
const STRIP_INVISIBLE_RE = new RegExp(
  "[" +
    STRIP_INVISIBLE_CODEPOINTS.map(
      (cp) => "\\u" + cp.toString(16).padStart(4, "0")
    ).join("") +
    "]",
  "g"
);

// Fold fullwidth digits (U+FF10..U+FF19) to ASCII 0-9. Used by the phone
// heuristic, which counts ASCII \d; without this, a number typed in
// fullwidth digits renders as digits to a human but counts as zero.
function foldFullwidthDigits(s) {
  return s.replace(/[０-９]/g, (d) =>
    String.fromCharCode(d.charCodeAt(0) - 0xfee0)
  );
}

function foldMathAlpha(cp) {
  for (const start of MATH_ALPHA_UPPER_OFFSETS) {
    if (cp >= start && cp <= start + 25) return String.fromCharCode(0x41 + (cp - start));
  }
  for (const start of MATH_ALPHA_LOWER_OFFSETS) {
    if (cp >= start && cp <= start + 25) return String.fromCharCode(0x61 + (cp - start));
  }
  return null;
}

function canonicalize(text) {
  if (!text) return "";
  // Strip invisible separators + bidi controls before normalization so
  // an evader can't fragment tokens or reverse visual order to slip past
  // the detector.
  const stripped = text.replace(STRIP_INVISIBLE_RE, "");
  const decomposed = stripped.normalize("NFD");
  let result = "";
  // Iterate code points (handles surrogate pairs correctly).
  for (const ch of decomposed) {
    const cp = ch.codePointAt(0);
    // Combining marks (U+0300..U+036F) — drop after NFD decompose.
    if (cp >= 0x0300 && cp <= 0x036F) continue;
    // Fullwidth uppercase (U+FF21..U+FF3A) → ASCII.
    if (cp >= 0xFF21 && cp <= 0xFF3A) {
      result += String.fromCodePoint(cp - 0xFEE0);
      continue;
    }
    // Fullwidth lowercase (U+FF41..U+FF5A) → ASCII.
    if (cp >= 0xFF41 && cp <= 0xFF5A) {
      result += String.fromCodePoint(cp - 0xFEE0);
      continue;
    }
    // Mathematical Alphanumeric Symbols (U+1D400..U+1D7FF) → ASCII letter.
    // Covers bold/italic/script/fraktur/double-struck/sans-serif/monospace
    // letterforms that look identical to Latin but ship as separate code
    // points (e.g. `𝐉𝐨𝐡𝐧` renders as "John" but bypasses the name match
    // without folding).
    if (cp >= 0x1D400 && cp <= 0x1D7FF) {
      const folded = foldMathAlpha(cp);
      if (folded) {
        result += folded;
        continue;
      }
    }
    if (NAME_CONFUSABLE_MAP[ch]) {
      result += NAME_CONFUSABLE_MAP[ch];
      continue;
    }
    result += ch;
  }
  return result.toLowerCase();
}

// Same combining-mark + invisible-separator strip as canonicalize, but
// preserves case and does NOT fold confusables / fullwidth / math-alpha.
// Used to tokenize text in Layers 4 / 4.5: an attacker who inserts
// standalone combining marks (e.g. `S̶arah` = S + U+0336 + arah) fragments
// the token under the default `\p{L}\p{N}` split because combining marks
// are Mn category. Stripping them first re-merges the token so the name
// lookup sees `Sarah` as a single capitalized word.
function stripCombiningMarksKeepCase(text) {
  if (!text) return "";
  const stripped = text.replace(STRIP_INVISIBLE_RE, "");
  const decomposed = stripped.normalize("NFD");
  let result = "";
  for (const ch of decomposed) {
    const cp = ch.codePointAt(0);
    if (cp >= 0x0300 && cp <= 0x036F) continue;
    result += ch;
  }
  return result;
}

function aggressiveNormalizeForNameMatch(text) {
  const canon = canonicalize(text);
  let deLeet = "";
  for (const ch of canon) {
    deLeet += NAME_LEET_MAP[ch] || ch;
  }
  // Collapse single-letter separator chains.
  // Pattern: word boundary, single letter, then 1+ runs of (separator+ then
  // single letter), bounded by word boundary. Single-character classes only,
  // no nested quantifiers — backtracking-safe.
  return deLeet.replace(/\b[a-z](?:[.\-_ ]+[a-z])+\b/g, (match) => {
    return match.replace(/[.\-_ ]+/g, "");
  });
}

// Token splitter: equivalent to Swift's
// `text.components(separatedBy: CharacterSet.alphanumerics.inverted)`.
// JS regex `\W` in Unicode mode (`u` flag) matches non-letter/digit/underscore;
// we want non-alphanumeric, so split on any sequence of non-letter/non-digit
// that includes underscore. Use `\P{L}` and `\P{N}` via a unicode-property class.
function tokenizeAlphanumeric(text) {
  return text.split(/[^\p{L}\p{N}]+/u).filter((t) => t.length > 0);
}

function sentenceStarters(text) {
  const starters = new Set();
  for (const sentence of text.split(/[.!?\n]/)) {
    const trimmed = sentence.trim();
    if (!trimmed) continue;
    const tokens = tokenizeAlphanumeric(trimmed);
    if (tokens.length > 0) starters.add(tokens[0]);
  }
  return starters;
}

function isUpperFirst(word) {
  if (!word) return false;
  // First code point — not first UTF-16 unit (handles emoji-prefixed tokens
  // even though they're non-alphanumeric and won't appear in tokens here).
  const first = String.fromCodePoint(word.codePointAt(0));
  return first === first.toUpperCase() && first !== first.toLowerCase();
}

// ============================================================
// Shared URL / link detector (T-10, 2026-06-11).
//
// Previously there were THREE URL detectors that drifted: this module's inline
// Layer-1 regexes (the HOLD decision), index.js `urlPatterns`/`containsURL`
// (the pii-vs-abuse_link LABEL decision), and index.js SPAM_PATTERNS (posts-
// only). The first two disagreed (e.g. youtu.be held-but-mislabeled). This is
// now the single source — Layer-1 below uses it, and index.js imports it for
// the label decision, so the hold and the label can never disagree again.
//
// Country-code TLDs (.be/.ru/.it/…) are intentionally NOT matched generically:
// they collide with ordinary prose ("maybe.be", "split.it") and the false-
// positive cost on a grief app outweighs catching a bare cc-TLD domain. The
// few cc-TLD link forms that matter in practice (youtu.be, t.me) are listed
// explicitly.
// ============================================================
const URL_REGEXES = [
  /https?:\/\//i,
  /\bwww\.[a-z]/i,
  /\b[a-z0-9-]+\.(com|net|org|io|co|app|xyz|gg|tv|me|info|link)\b/i,
  /\b(cash\.app|linktr\.ee|bit\.ly|tinyurl|youtu\.be|t\.me)\b/i,
];

function containsURL(text) {
  if (typeof text !== "string" || text.length === 0) return false;
  return URL_REGEXES.some((re) => re.test(text));
}

// ============================================================
// Main detector — mirror of containsNameOrIdentifyingInfo in FeedView.swift.
// ============================================================

function containsNameOrIdentifyingInfo(text) {
  if (typeof text !== "string" || text.length === 0) return false;
  const lowered = text.toLowerCase();

  // ----- Original chain -----

  for (const pattern of IDENTIFYING_PATTERNS) {
    if (lowered.includes(pattern)) return true;
  }

  // Social-shorthand label syntax (ig: / sc: / fb: with optional space +
  // colon/period/dash). Word-boundary anchored so "dig: deeper", "abs.",
  // "fab-" don't false-positive.
  if (SOCIAL_SHORTHAND_RE.test(text)) return true;

  // @handle
  if (/@[a-zA-Z]/.test(text)) return true;

  // Possessive name. N-17 launch tuning (2026-06-11): a LONE FIRST-name
  // possessive ("Jessica's laugh") is allowed — a bare first name identifies
  // no one and naming a feeling/memory is the modal breakup post. A LAST-name
  // possessive ("Johnson's") is more identifying and still held.
  const possessiveRegex = /\b([A-Z][a-z]{2,})'s\b/g;
  for (const match of text.matchAll(possessiveRegex)) {
    const name = match[1].toLowerCase();
    if (COMMON_LAST_NAMES.has(name) && name.length >= 3 && !AMBIGUOUS_WORDS.has(name)) return true;
  }

  // Relationship prefix + capitalized first word. N-17 (2026-06-11): "my ex
  // Sarah" (prefix + bare FIRST name) is allowed; a prefix + LAST name ("my ex
  // Johnson") stays held, and a prefix + FULL name ("my ex Sarah Johnson") is
  // caught by looksLikeFullName below.
  for (const prefix of RELATIONSHIP_PREFIXES) {
    const idx = lowered.indexOf(prefix);
    if (idx === -1) continue;
    const after = text.slice(idx + prefix.length).trim();
    const firstToken = after.split(/[^\p{L}\p{N}]+/u).filter((t) => t.length > 0)[0];
    if (!firstToken) continue;
    if (isUpperFirst(firstToken)
        && COMMON_LAST_NAMES.has(firstToken.toLowerCase()) && firstToken.length >= 3) return true;
  }

  // "named X" / "called X" / "name is X". N-17: same — a following bare FIRST
  // name is allowed; a LAST name is held; a FULL name is caught below.
  for (const pattern of NAMED_PATTERNS) {
    const idx = lowered.indexOf(pattern);
    if (idx === -1) continue;
    const after = text.slice(idx + pattern.length).trim();
    const firstToken = after.split(/[^\p{L}\p{N}]+/u).filter((t) => t.length > 0)[0];
    if (!firstToken) continue;
    if (isUpperFirst(firstToken)
        && COMMON_LAST_NAMES.has(firstToken.toLowerCase()) && firstToken.length >= 3) return true;
  }

  // Street address.
  if (STREET_REGEX.test(text)) return true;

  // Doxxable location-context (works at X, the cafe above the bodega on
  // 5th and vine, from brooklyn, etc.). Heuristic; some false positives
  // on legitimate venting that name a workplace/city without targeting a
  // specific person. Caught here, the post-trigger deletes it server-
  // side; if it turns out to be over-aggressive we trim the patterns.
  for (const re of LOCATION_CONTEXT_PATTERNS) {
    if (re.test(text)) return true;
  }

  // N-17 (2026-06-11): the mid-sentence LONE-FIRST-NAME detector was removed —
  // a bare first name ("I miss John") is the modal breakup post and identifies
  // no one. Full names are still caught by looksLikeFullName below (the two-
  // capitalized-words shape), and lone LAST names by the canonicalized
  // name-layers further down. Contact info / addresses / handles are unchanged.

  // Full-name shape: two consecutive Capitalized words ("Tess Salinaro").
  if (looksLikeFullName(text)) return true;

  // 10+ digits → phone number heuristic.
  // Strip invisible separators (so `5​5​5…` collapses to a contiguous run)
  // and fold fullwidth digits U+FF10..U+FF19 → ASCII (so a phone typed in
  // fullwidth digits, `５５５１２３４５６７`, is counted by the \d heuristic
  // below instead of slipping past as zero ASCII digits). 2026-06-01 audit.
  let digitStripped = foldFullwidthDigits(text.replace(STRIP_INVISIBLE_RE, ""));
  for (const num of CRISIS_NUMBERS) {
    digitStripped = digitStripped.split(num).join("");
  }
  // M-2 (2026-06-08 audit): remove breakup-timeline number lists BEFORE the
  // separator-collapse below, so they don't merge into one long run that
  // survives the year/small-number strips and inflates the digit count past
  // the phone threshold. Targeted so real phone groupings — which mix 2–4
  // digit groups — are untouched (the second pattern needs 4+ consecutive
  // 1–3 digit tokens; a phone's 4-digit exchange/line groups break that run):
  //   - 2+ consecutive 4-digit year tokens: "we dated 2019 2020 2021 2022 2023"
  //   - 4+ consecutive 1–3 digit tokens:    "scores were 100 95 88 76 65 54 …"
  // A real international phone ("+44 20 7946 0958") matches neither and still
  // trips the >=10-digit check below.
  digitStripped = digitStripped
    .replace(/\b(?:19|20)\d\d(?:\s+(?:19|20)\d\d)+\b/g, " ")
    .replace(/\b\d{1,3}(?:\s+\d{1,3}){3,}\b/g, " ");
  // Collapse phone-format separators between digits so a formatted phone
  // like `(555) 123-4567` survives the date/year/small-number strips
  // below. Without this, `\b\d{1,3}\b` peels `555`, `123` and `\b\d{4,5}\b`
  // peels `4567` because parens/space/dash sit at word boundaries around
  // each digit chunk — total digit count goes to zero. Lookahead-anchored
  // so a separator at end of text (e.g., trailing `.`) doesn't gobble.
  // Plain whitespace IS included in the class because users write phones
  // as `555 123 4567`; the false-positive risk (a sentence with 10+ digits
  // separated only by single spaces) is acceptable on a heartbreak app.
  digitStripped = digitStripped.replace(/(\d)[-.\s()]+(?=\d)/g, "$1");
  digitStripped = digitStripped
    .replace(/\d{1,2}[:/]\d{2}/g, "")
    .replace(/\b\d{4,5}\b/g, "")
    .replace(/\b\d{1,3}\b/g, "")
    .replace(/\$[\d,]+/g, "")
    .replace(/\d{1,2}\/\d{1,2}\/\d{2,4}/g, "");
  const digitCount = (digitStripped.match(/\d/g) || []).length;
  if (digitCount >= 10) return true;

  // ----- Evasion-hardening layers (mirror of Swift Layers 1-6) -----

  // Layer 1: URL / social-link detection (shared detector, T-10).
  if (containsURL(text)) return true;

  // Layer 2: Apartment / unit / suite numbers.
  if (/\b(apt|unit|suite|ste)\.?\s*#?\s*\d+[a-z]?\b/i.test(text)) return true;
  if (/#\s*\d{1,4}[a-z]?\b/.test(text)) return true;

  // Layer 3: Dotted initials with relationship context — "my ex J.S."
  for (const prefix of RELATIONSHIP_PREFIXES) {
    const idx = lowered.indexOf(prefix);
    if (idx === -1) continue;
    const window = text.slice(idx + prefix.length, idx + prefix.length + 40);
    if (/\b[A-Z]\.[A-Z]\.?/.test(window)) return true;
  }

  // Layer 4: Per-token canonicalize-then-name-lookup.
  // Tokenize the COMBINING-MARK-STRIPPED form of the text, not the raw
  // text. Standalone combining marks (U+0300-U+036F) are Mn category and
  // get treated as token separators under `\p{L}\p{N}` split — an
  // attacker writing `S̶arah` (= S + U+0336 + arah) fragments the token
  // into ['S', 'arah'] under raw tokenization, and neither piece matches
  // a name. Stripping combining marks (case-preserving) before split
  // collapses the token to `Sarah` so the name lookup sees it.
  const canonical = canonicalize(text);
  const canonStarters = sentenceStarters(canonical);
  const layer4Words = stripCombiningMarksKeepCase(text)
    .split(/[^\p{L}\p{N}]+/u)
    .filter((w) => w.length > 0);
  for (const word of layer4Words) {
    const canonWord = canonicalize(word);
    if (canonWord.length < 2) continue;
    if (AMBIGUOUS_WORDS.has(canonWord)) continue;
    if (SAFE_CAPITALIZED_WORDS.has(canonWord)) continue;
    const isFirst = COMMON_NAMES.has(canonWord);
    const isLast = COMMON_LAST_NAMES.has(canonWord) && canonWord.length >= 3;
    if (!isFirst && !isLast) continue;
    if (!isUpperFirst(word)) continue;
    // Sentence-starter exemption applies only to legit-prose tokens.
    // If canonicalize had to fold confusables / fullwidth / accents to
    // reach the name (i.e. the original lowercased token differs from the
    // canonical token), that's evasion and the starter exemption no
    // longer applies — "Mіchael" at the start of a sentence is an attack,
    // not a casual capitalization. Mirror of the Swift Layer 4 fix.
    const isEvasion = word.toLowerCase() !== canonWord;
    // N-17 (2026-06-11): a PLAIN lone FIRST name is allowed (the dominant FP —
    // "I miss John" is the modal breakup post and identifies no one). An
    // OBFUSCATED first name (confusables / leet / fullwidth / combining-mark =
    // isEvasion) is still HELD: deliberately evading the name filter signals
    // intent to identify-and-hide. LAST names are always held; FULL names are
    // caught by looksLikeFullName + the last-name component.
    if (isFirst && !isLast && !isEvasion) continue;
    if (!isEvasion && canonStarters.has(canonWord)) continue;
    return true;
  }

  // Layer 4.5: Reversed-token name lookup. The canonicalize step strips
  // bidi-override characters (so a render-time visual flip can't slip
  // through), but doesn't try a literal codepoint reversal — an attacker
  // who writes "haraS" as plain ASCII (no bidi codepoints) sails through
  // every prior layer because the forward token doesn't match any name.
  // Reverse each canonicalized token and re-check against the name sets.
  // Length floor of 4 keeps the false-positive budget tight: short names
  // reversed (e.g. "ana" → "ana", "rae" → "ear") collide with common
  // English fragments. Palindromes are skipped since the forward layers
  // would have already had a chance. Ambiguous / safe lists apply to the
  // reversed form too — if the reversed string is a common word, it's
  // more likely an incidental collision than evasion.
  // Uses the same combining-mark-stripped tokenization as Layer 4 so
  // `S̶mith` (combining-mark fragmentation) is reversed as `htimS`.
  for (const word of layer4Words) {
    const canonWord = canonicalize(word);
    if (canonWord.length < 4) continue;
    const reversed = [...canonWord].reverse().join("");
    if (reversed === canonWord) continue; // palindrome — forward layers cover
    if (AMBIGUOUS_WORDS.has(reversed)) continue;
    if (SAFE_CAPITALIZED_WORDS.has(reversed)) continue;
    // N-17 (2026-06-11): a REVERSED name is by definition an evasion attempt
    // (nobody writes a name backwards casually), so first names still flag here
    // — same rationale as the obfuscation gate in Layer 4.
    const isFirstRev = COMMON_NAMES.has(reversed);
    const isLastRev = COMMON_LAST_NAMES.has(reversed) && reversed.length >= 3;
    if (isFirstRev || isLastRev) return true;
  }

  // Layer 5: Whole-text aggressive normalization.
  const aggressive = aggressiveNormalizeForNameMatch(text);
  const canonicalTokens = new Set(tokenizeAlphanumeric(canonical));
  const aggressiveTokens = tokenizeAlphanumeric(aggressive).filter((t) => t.length >= 2);
  for (const token of aggressiveTokens) {
    if (AMBIGUOUS_WORDS.has(token)) continue;
    if (SAFE_CAPITALIZED_WORDS.has(token)) continue;
    // N-17 (2026-06-11): Layer 5 only fires on tokens that emerge AFTER
    // aggressive normalization but are NOT in the plain canonical tokenization
    // (the `canonicalTokens.has` skip below) — i.e. spaced/separated names like
    // "j o h n", which is itself an evasion vector. So first names still flag
    // here, consistent with the obfuscation gate in Layer 4.
    const isName = COMMON_NAMES.has(token) || (COMMON_LAST_NAMES.has(token) && token.length >= 3);
    if (!isName) continue;
    if (canonicalTokens.has(token)) continue;
    return true;
  }

  // Layer 6: Identifying-pattern keywords on canonicalized text.
  for (const pattern of IDENTIFYING_PATTERNS) {
    if (canonical.includes(pattern)) return true;
  }

  return false;
}

module.exports = {
  containsNameOrIdentifyingInfo,
  containsURL,
  canonicalize,
  aggressiveNormalizeForNameMatch,
  // Exposed for tests / future composition.
  COMMON_NAMES,
  COMMON_LAST_NAMES,
  AMBIGUOUS_WORDS,
  SAFE_CAPITALIZED_WORDS,
};
