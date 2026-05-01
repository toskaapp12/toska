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

const IDENTIFYING_PATTERNS = [
  "instagram", "insta", "snapchat", "snap", "tiktok", "twitter",
  "facebook", "linkedin", "phone number", "my number", "text me",
  "call me", "dm me", "follow me", "find me", "look me up",
  "last name", "full name", "school name", "works at", "goes to",
  "lives in", "lives on", "lives at", "address",
  "apartment", "apt ", "suite ",
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

function canonicalize(text) {
  if (!text) return "";
  const decomposed = text.normalize("NFD");
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
    if (NAME_CONFUSABLE_MAP[ch]) {
      result += NAME_CONFUSABLE_MAP[ch];
      continue;
    }
    result += ch;
  }
  return result.toLowerCase();
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
// Main detector — mirror of containsNameOrIdentifyingInfo in FeedView.swift.
// ============================================================

function containsNameOrIdentifyingInfo(text) {
  if (typeof text !== "string" || text.length === 0) return false;
  const lowered = text.toLowerCase();

  // ----- Original chain -----

  for (const pattern of IDENTIFYING_PATTERNS) {
    if (lowered.includes(pattern)) return true;
  }

  // @handle
  if (/@[a-zA-Z]/.test(text)) return true;

  // Possessive name: "Jessica's", "Mike's"
  const possessiveRegex = /\b([A-Z][a-z]{2,})'s\b/g;
  for (const match of text.matchAll(possessiveRegex)) {
    const name = match[1].toLowerCase();
    if (!AMBIGUOUS_WORDS.has(name)) return true;
  }

  // Relationship prefix + capitalized first word (>=2 chars).
  for (const prefix of RELATIONSHIP_PREFIXES) {
    const idx = lowered.indexOf(prefix);
    if (idx === -1) continue;
    const after = text.slice(idx + prefix.length).trim();
    const firstToken = after.split(/[^\p{L}\p{N}]+/u).filter((t) => t.length > 0)[0];
    if (!firstToken) continue;
    if (firstToken.length >= 2 && isUpperFirst(firstToken)) return true;
  }

  // "named X", "called X", "name is X", "name was X" — capitalized following.
  for (const pattern of NAMED_PATTERNS) {
    const idx = lowered.indexOf(pattern);
    if (idx === -1) continue;
    const after = text.slice(idx + pattern.length).trim();
    const firstToken = after.split(/[^\p{L}\p{N}]+/u).filter((t) => t.length > 0)[0];
    if (!firstToken) continue;
    if (isUpperFirst(firstToken)) return true;
  }

  // Street address.
  if (STREET_REGEX.test(text)) return true;

  // Mid-sentence proper noun matching a known first name.
  const starters = new Set();
  for (const sentence of text.split(/[.!?\n]/)) {
    const trimmed = sentence.trim();
    if (!trimmed) continue;
    const t = trimmed.split(/[^\p{L}\p{N}]+/u).filter((s) => s.length > 0)[0];
    if (t) starters.add(t);
  }
  const words = text.split(/[^\p{L}\p{N}]+/u).filter((w) => w.length > 0);
  for (const word of words) {
    const lower = word.toLowerCase();
    if (lower.length < 2) continue;
    if (AMBIGUOUS_WORDS.has(lower)) continue;
    if (SAFE_CAPITALIZED_WORDS.has(lower)) continue;
    if (COMMON_NAMES.has(lower)) {
      if (isUpperFirst(word)) {
        if (starters.has(word)) continue;
        return true;
      }
    }
  }

  // 10+ digits → phone number heuristic.
  let digitStripped = text;
  for (const num of CRISIS_NUMBERS) {
    digitStripped = digitStripped.split(num).join("");
  }
  digitStripped = digitStripped
    .replace(/\d{1,2}[:/]\d{2}/g, "")
    .replace(/\b\d{4,5}\b/g, "")
    .replace(/\b\d{1,3}\b/g, "")
    .replace(/\$[\d,]+/g, "")
    .replace(/\d{1,2}\/\d{1,2}\/\d{2,4}/g, "");
  const digitCount = (digitStripped.match(/\d/g) || []).length;
  if (digitCount >= 10) return true;

  // ----- Evasion-hardening layers (mirror of Swift Layers 1-6) -----

  // Layer 1: URL / social-link detection.
  const urlRegexes = [
    /https?:\/\//i,
    /\bwww\.[a-z]/i,
    /\b(instagram|tiktok|facebook|twitter|snapchat|linkedin|reddit|youtube|youtu|t|discord|telegram|whatsapp|signal|onlyfans|threads|bluesky|cash\.app|venmo|paypal)\.(com|me|gg|tv|be|co|app|net|org|io)\b/i,
    /\b(linktr\.ee|bit\.ly|tinyurl)\b/i,
  ];
  for (const re of urlRegexes) {
    if (re.test(text)) return true;
  }

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
  const canonical = canonicalize(text);
  const canonStarters = sentenceStarters(canonical);
  for (const word of words) {
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
    if (!isEvasion && canonStarters.has(canonWord)) continue;
    return true;
  }

  // Layer 5: Whole-text aggressive normalization.
  const aggressive = aggressiveNormalizeForNameMatch(text);
  const canonicalTokens = new Set(tokenizeAlphanumeric(canonical));
  const aggressiveTokens = tokenizeAlphanumeric(aggressive).filter((t) => t.length >= 2);
  for (const token of aggressiveTokens) {
    if (AMBIGUOUS_WORDS.has(token)) continue;
    if (SAFE_CAPITALIZED_WORDS.has(token)) continue;
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
  canonicalize,
  aggressiveNormalizeForNameMatch,
  // Exposed for tests / future composition.
  COMMON_NAMES,
  COMMON_LAST_NAMES,
  AMBIGUOUS_WORDS,
  SAFE_CAPITALIZED_WORDS,
};
