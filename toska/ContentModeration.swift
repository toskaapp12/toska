//
//  ContentModeration.swift
//  toska
//
//  IMPROVE (2026-06-11): extracted verbatim from FeedView.swift to make the
//  ~1050-line PII/crisis/handle moderation engine findable and to shrink the
//  feed file. Same module, so all symbols stay visible to callers. The
//  detector-parity.mjs test now extracts the Swift detector from THIS file.
//

import Foundation
import FirebaseFirestore

// MARK: - Content Safety Checks
//
// Split into two tiers so the gentle-check rail can be partially user-controlled
// without disabling the most critical safety surface.
//
// `explicitCrisisPhrases` = direct statements of suicidal ideation or self-harm.
// These always trigger the check-in regardless of the user's gentleCheckIn
// toggle — a person typing these may not be in a state to have pre-opted into
// a safety rail, so the rail is always on. This mirrors iOS Emergency SOS's
// design (can't be fully disabled).
//
// `softConcernPhrases` = expressions of hopelessness/despair that may indicate
// risk but also show up in everyday venting. These respect the user's
// gentleCheckIn toggle so users who find the rail intrusive can opt out of the
// softer tier without losing the explicit-tier safety net.

// Keep in sync with functions/index.js MOD_CRISIS_EXPLICIT / MOD_CRISIS_SOFT.
// (The server additionally normalizes leet/unicode/spaced evasions; the
// client is a best-effort pre-publish check, the server is the backstop.)
let explicitCrisisPhrases = [
    // direct suicide vocabulary + common misspellings
    "suicidal", "suicide", "suicidel", "sucide", "sucidal", "suiside", "suacide",
    // self-killing intent
    "kill myself", "killing myself", "kill my self", "want to kill myself",
    "wanna kill myself", "going to kill myself", "gonna kill myself",
    "off myself", "end myself", "delete myself", "unalive", "unalive myself",
    // 2026-07-17 red-team extension: gerund form — word-boundary matching means
    // "unalive" does NOT match "unaliving" ("thinking about unaliving tonight").
    "unaliving",
    "hang myself", "hanging myself", "neck myself",
    // ending my life
    "end my life", "ending my life", "end it all", "ending it all",
    "take my own life", "take my life", "want to end my life",
    // wanting to die / be dead
    "want to die", "wanna die", "want to be dead", "ready to die",
    "wish i was dead", "wish i were dead", "wish i could die",
    "better off dead", "rather be dead",
    // self-harm
    "hurt myself", "want to hurt myself", "harm myself", "self harm",
    "self-harm", "selfharm", "cut myself", "cutting myself", "burn myself",
    // not wanting to exist / wake up
    "don't want to wake up", "dont want to wake up", "don't want to be here",
    "dont want to be here", "don't want to exist", "dont want to exist",
    "want to disappear", "want to vanish",
    // Non-English explicit crisis (2026-06-11) — kept in sync with the server's
    // MOD_CRISIS_EXPLICIT (index.js). Curated starter set (Spanish/Portuguese/
    // French); not comprehensive — needs native-speaker review per language.
    // T-4 (2026-06-11): reflexive self-harm verbs require first-person self-
    // intent framing so relational "tu vas / il va me faire du mal" ("[you/he]
    // will hurt ME") no longer trips; ambiguous hyperbole moved to
    // softConcernPhrases. Mirror of index.js.
    // Spanish — unambiguous self-directed intent
    "quiero morir", "no quiero vivir", "ya no quiero vivir", "quiero suicidarme",
    "voy a suicidarme", "quiero matarme", "me quiero matar",
    "acabar con mi vida", "terminar con mi vida", "quitarme la vida",
    "quiero hacerme dano", "quiero hacerme daño", "voy a hacerme dano", "voy a hacerme daño",
    "quiero lastimarme", "voy a lastimarme",
    "quero morrer", "nao quero viver", "não quero viver", "vou me matar",
    "tirar minha vida", "acabar com minha vida",
    "je veux mourir", "me suicider", "je vais me suicider",
    "mettre fin a mes jours", "mettre fin à mes jours",
    "veux me faire du mal", "vais me faire du mal", "envie de me faire du mal",
]

let softConcernPhrases = [
    "can't go on", "cant go on", "can't do this anymore", "cant do this anymore",
    "can't keep going", "can't take it anymore", "cant take it anymore",
    "no reason to live", "nothing to live for", "no point in living",
    "no point anymore", "not worth living", "give up on everything",
    "want to give up", "done with life", "done with everything",
    "tired of living", "tired of being alive", "better off without me",
    "everyone better off without me", "no one would care", "no one would notice",
    "nobody cares", "nobody would miss me", "won't be missed",
    "disappear forever", "why am i still here", "wish i wasn't here",
    "wish i didn't exist", "want it to stop", "want it all to end", "nothing left",
    // T-4 (2026-06-11): non-English phrases demoted from the explicit tier
    // (they false-positive on hyperbole / 3rd-party speech). Still held for
    // review, just not paging. Mirror of index.js MOD_CRISIS_SOFT.
    "envie de mourir", "voy a matarme", "mejor muerto", "mejor muerta",
    // #5 (2026-06-11 crisis red-team): soft-tier disclosures that slipped
    // through. Mirror of index.js MOD_CRISIS_SOFT.
    "point of living", "better off if i was gone", "better off if i wasn't",
    "everyone would be better off if i", "not waking up", "wish i wouldn't wake up",
    "thinking about not waking", "what's the point anymore", "whats the point anymore",
    // 2026-07-17 red-team extension (soft tier — held + gentle check-in, never
    // paged; over-hold is the safe direction):
    // "kms" — ubiquitous "kill myself" shorthand. Deliberately SOFT, not
    // explicit: most usage is flippant, and the token can collide with
    // "kilometers" ("300 kms apart") — a soft hold on that rare collision is
    // acceptable collateral; paging a human on every "ugh kms" is not.
    "kms",
    // paraphrases the red team slipped through entirely
    "no reason to keep going", "no reason to go on",
    // farewell-note shape ("this is my goodbye post, don't try to find me")
    "this is my goodbye",
]

// Back-compat alias so existing call sites that only care about "is it
// concerning at all" keep working while surfaces migrate to crisisLevel(for:).
let concerningPhrases = explicitCrisisPhrases + softConcernPhrases

enum CrisisLevel {
    /// Explicit ideation or self-harm — always show the check-in.
    case explicit
    /// Softer hopelessness signals — check-in respects gentleCheckIn setting.
    case soft
}

// Mirror of the server matchesCrisisPhrase (index.js): match against the plain
// lowercased text AND the de-leet/de-confusable/de-spaced normalization, plus a
// space/punct-insensitive fallback (length-guarded so short tokens don't FP).
// IMPROVE #1 (2026-06-11): previously this did a bare `lowered.contains`, so an
// obfuscated disclosure ("k1ll myself", "s u i c i d e") was held by the server
// but NEVER surfaced the compose-time gentle check-in — failing exactly the
// vulnerable user the feature exists for. Now normalized identically to the
// server so the hold and the check-in fire on the same input.
private func crisisPhraseMatch(_ text: String, _ list: [String]) -> Bool {
    func noSpaceOf(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }
    // Ambiguous-glyph fold: "1", "!", "|" stand in for BOTH "i" and "l"
    // (ki11 / k!ll / ki|| → kill), and real text mixes positions freely
    // ("k1ll myse1f" has an i-position AND an l-position "1"). Uniform
    // substitution (an all-i form and an all-l form, the previous approach)
    // misses every mixed-position case, so collapse the entire ambiguous
    // class — including literal "i" and "l" — to one symbol in BOTH the text
    // and the phrase, making the match position-independent. Mirrors the
    // server matchesCrisisPhrase (moderationLogic.js); crisis-only (kept OUT
    // of the name/PII path, where !/| and i↔l collapsing would
    // false-positive); over-detection is the accepted-safe direction here.
    func foldAmbiguousIL(_ s: String) -> String {
        String(s.map { "1!|il".contains($0) ? "l" : $0 })
    }
    let lowered = text.lowercased()
    let normalized = aggressiveNormalizeForNameMatch(text)
    let noSpace = noSpaceOf(normalized)
    // Fold the raw text too (not just the normalized form): normalization's
    // leet map already committed "1"->"i" before we could fold, so both
    // inputs go through foldAmbiguousIL from their own starting points.
    let folded = foldAmbiguousIL(aggressiveNormalizeForNameMatch(foldAmbiguousIL(text)))
    let foldedNoSpace = noSpaceOf(folded)
    for phrase in list {
        if lowered.contains(phrase) || normalized.contains(phrase) { return true }
        if folded.contains(foldAmbiguousIL(phrase)) { return true }
        let pNoSpace = phrase.filter { $0.isLetter || $0.isNumber }
        if pNoSpace.count >= 6 &&
            (noSpace.contains(pNoSpace) || foldedNoSpace.contains(foldAmbiguousIL(pNoSpace))) { return true }
    }
    return false
}

func crisisLevel(for text: String) -> CrisisLevel? {
    if crisisPhraseMatch(text, explicitCrisisPhrases) { return .explicit }
    if crisisPhraseMatch(text, softConcernPhrases) { return .soft }
    return nil
}

// Confusable map used by `canonicalize`. Covers the unicode points a poster
// most commonly reaches for when trying to slip a name past the warning
// modal: Cyrillic / Greek lookalikes that render visually identical to
// Latin letters in the iOS system font. The map is intentionally LARGER
// than `moderationHomoglyphMap` (used by contentViolation) because the
// name-detection path needs to fold both upper- and lower-case forms — a
// poster typing "sаrah" with Cyrillic а is the exact case we want to catch,
// and the slur-detection map only handles uppercase.
//
// Fullwidth letters (U+FF21..U+FF5A, "Ｓａｒａｈ") are handled by code-point
// arithmetic in `canonicalize` rather than this table — they're contiguous
// and the table would just be 52 mechanical entries.
private let nameConfusableMap: [Character: Character] = [
    // Cyrillic uppercase
    "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O",
    "Р": "P", "С": "C", "Т": "T", "У": "Y", "Х": "X", "І": "I", "Ј": "J",
    "Ѕ": "S", "Ԁ": "D", "Һ": "H",
    // Cyrillic lowercase (ѕ U+0455 is the perfect "s" lookalike; mirror of
    // NAME_CONFUSABLE_MAP in functions/moderation.js)
    "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o",
    "р": "p", "с": "c", "т": "t", "у": "y", "х": "x", "і": "i", "ј": "j",
    "ѕ": "s", "ԁ": "d", "һ": "h",
    // Latin script g (U+0261), the standard "g" confusable outside Cyrillic
    "ɡ": "g",
    // Greek uppercase
    "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K",
    "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X",
    // Greek lowercase
    "α": "a", "β": "b", "ε": "e", "ι": "i", "ο": "o", "ρ": "p",
    "τ": "t", "υ": "y", "χ": "x",
]

private let nameLeetMap: [Character: Character] = [
    "0": "o", "1": "i", "3": "e", "4": "a",
    "5": "s", "7": "t", "8": "b",
    "@": "a", "$": "s",
]

/// Lossless-ish normalization for the name-detection path. Folds the cases
/// that don't change semantic meaning of a name token but do bypass an
/// ASCII-only substring lookup:
///   - NFD decompose then strip combining marks (U+0300..U+036F): "Sårāh" → "Sarah"
///   - Fullwidth ASCII (U+FF21..U+FF5A) → ASCII: "Ｓａｒａｈ" → "Sarah"
///   - Confusable Cyrillic / Greek letters → Latin: "Sаrah" → "Sarah"
///   - Lowercase
///
/// Deliberately does NOT do leet substitution — that's destructive on legit
/// numbers ("3 months ago" must NOT become "e months ago" for the general
/// prose checks). Leet lives in `aggressiveNormalizeForNameMatch`, which is
/// only consulted by the curated-name lookup.
// Mathematical Alphanumeric Symbols (U+1D400..U+1D7FF) cover bold/italic/
// script/fraktur/double-struck/sans-serif/monospace letterforms that render
// visually identical to Latin but ship as separate codepoints. Without
// folding, "𝐉𝐨𝐡𝐧" looks like "John" but the name match never fires.
// Each 26-letter run starts at one of these offsets — enumerating them
// is more reliable than NFKC, which is invasive on emoji + symbols.
//
// Mirror of MATH_ALPHA_*_OFFSETS in functions/moderation.js. Keep in sync
// when adding new style ranges.
private let mathAlphaUpperOffsets: [UInt32] = [
    0x1D400, 0x1D434, 0x1D468, 0x1D49C, 0x1D4D0, 0x1D504, 0x1D538,
    0x1D56C, 0x1D5A0, 0x1D5D4, 0x1D608, 0x1D63C, 0x1D670,
]
private let mathAlphaLowerOffsets: [UInt32] = [
    0x1D41A, 0x1D44E, 0x1D482, 0x1D4B6, 0x1D4EA, 0x1D51E, 0x1D552,
    0x1D586, 0x1D5BA, 0x1D5EE, 0x1D622, 0x1D656, 0x1D68A,
]

private func foldMathAlpha(_ value: UInt32) -> Unicode.Scalar? {
    for start in mathAlphaUpperOffsets where value >= start && value <= start + 25 {
        return Unicode.Scalar(0x41 + (value - start))
    }
    for start in mathAlphaLowerOffsets where value >= start && value <= start + 25 {
        return Unicode.Scalar(0x61 + (value - start))
    }
    return nil
}

// Case-PRESERVING fold of math-alphanumeric + fullwidth letterforms (F-1).
// Mirror of foldLetterformsKeepCase in functions/moderation.js — keeps case so
// the two-capitalized-words full-name shape still matches a folded name.
private func foldLetterformsKeepCase(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
        let v = scalar.value
        if v >= 0xFF21 && v <= 0xFF3A, let s = Unicode.Scalar(v - 0xFEE0) { result.unicodeScalars.append(s); continue }
        if v >= 0xFF41 && v <= 0xFF5A, let s = Unicode.Scalar(v - 0xFEE0) { result.unicodeScalars.append(s); continue }
        if v >= 0x1D400 && v <= 0x1D7FF, let s = foldMathAlpha(v) { result.unicodeScalars.append(s); continue }
        result.unicodeScalars.append(scalar)
    }
    return result
}

/// Strip-set: invisible separators + bidi controls that fragment tokens or
/// reverse visual order without changing the codepoint sequence the
/// detector sees. Removed BEFORE NFD decompose so e.g. "Sa​rah" (with a
/// zero-width space splitting Sa | rah) collapses to "sarah" instead of
/// tokenizing into ["sa", "rah"] — the latter never matches a name.
///
/// Covers: U+200B-D (zero-width space/joiner/non-joiner), U+2060 (word
/// joiner), U+202A-E (LRE/RLE/PDF/LRO/RLO bidi controls), U+2066-9
/// (LRI/RLI/FSI/PDI bidi isolates), U+FEFF (BOM / zero-width no-break).
///
/// Mirror of STRIP_INVISIBLE_RE in functions/moderation.js.
private func stripInvisibleSeparators(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        let v = scalar.value
        // Kept byte-identical to the JS STRIP_INVISIBLE_CODEPOINTS set
        // (functions/moderation.js) so client + server fold the SAME render-as-
        // nothing separators — otherwise the client under-detects a name/crisis
        // phrase the server holds (a vulnerable user sees "posted normally").
        if (v >= 0x200B && v <= 0x200F) { continue }   // ZWSP..RLM (incl LRM/RLM)
        if (v >= 0x202A && v <= 0x202E) { continue }   // bidi embed/override
        if v == 0x2060 { continue }                    // word joiner
        if (v >= 0x2066 && v <= 0x2069) { continue }   // bidi isolates
        if v == 0xFEFF { continue }                    // ZWNBSP / BOM
        if v == 0x00AD { continue }                    // soft hyphen
        if v == 0x034F { continue }                    // combining grapheme joiner
        if v == 0x061C { continue }                    // arabic letter mark
        if (v == 0x115F || v == 0x1160) { continue }   // Hangul choseong/jungseong fillers
        if (v == 0x17B4 || v == 0x17B5) { continue }   // Khmer invisible inherent vowels
        if v == 0x180E { continue }                    // Mongolian vowel separator
        if v == 0x3164 { continue }                    // Hangul filler
        if v == 0xFFA0 { continue }                    // halfwidth Hangul filler
        out.unicodeScalars.append(scalar)
    }
    return out
}

/// Strips invisible separators + combining marks but preserves case, and
/// does NOT fold confusables / fullwidth / math-alpha. Used to tokenize
/// text in Layers 4 / 4.5: an attacker who inserts standalone combining
/// marks (e.g. `S̶arah` = S + U+0336 + arah) fragments the token under
/// the default `CharacterSet.alphanumerics.inverted` split because
/// combining marks are Mn category. Stripping them first re-merges the
/// token so the name lookup sees `Sarah` as one capitalized word.
/// Mirror of stripCombiningMarksKeepCase in functions/moderation.js.
private func stripCombiningMarksKeepCase(_ text: String) -> String {
    let stripped = stripInvisibleSeparators(text)
    let decomposed = stripped.decomposedStringWithCanonicalMapping
    var result = ""
    result.reserveCapacity(decomposed.count)
    for scalar in decomposed.unicodeScalars {
        let value = scalar.value
        if value >= 0x0300 && value <= 0x036F { continue }
        result.unicodeScalars.append(scalar)
    }
    return result
}

private func canonicalize(_ text: String) -> String {
    let stripped = stripInvisibleSeparators(text)
    let decomposed = stripped.decomposedStringWithCanonicalMapping
    var result = ""
    result.reserveCapacity(decomposed.count)
    for scalar in decomposed.unicodeScalars {
        let value = scalar.value
        // Combining marks — drop after NFD decompose.
        if value >= 0x0300 && value <= 0x036F { continue }
        // Fullwidth uppercase A-Z (U+FF21..U+FF3A).
        if value >= 0xFF21 && value <= 0xFF3A {
            result.unicodeScalars.append(Unicode.Scalar(value - 0xFEE0)!)
            continue
        }
        // Fullwidth lowercase a-z (U+FF41..U+FF5A).
        if value >= 0xFF41 && value <= 0xFF5A {
            result.unicodeScalars.append(Unicode.Scalar(value - 0xFEE0)!)
            continue
        }
        // Mathematical Alphanumeric Symbols → ASCII letter.
        if value >= 0x1D400 && value <= 0x1D7FF {
            if let folded = foldMathAlpha(value) {
                result.unicodeScalars.append(folded)
                continue
            }
        }
        let ch = Character(scalar)
        if let mapped = nameConfusableMap[ch] {
            result.append(mapped)
        } else {
            result.unicodeScalars.append(scalar)
        }
    }
    return result.lowercased()
}

/// Aggressive normalization for the curated-name lookup ONLY.
/// Builds on `canonicalize` then:
///   - Substitutes leet characters (0→o, 1→i, 3→e, 4→a, 5→s, 7→t, 8→b, @→a, $→s)
///   - Collapses single-letter separator chains: "j.o.h.n" / "j-o-h-n" /
///     "j_o_h_n" / "j o h n" → "john"
///
/// Conservative on false positives by design: the result is checked ONLY
/// against the curated first/last name sets. We do NOT run this output
/// through the general identifying-pattern keywords or the address regex,
/// because de-leet would mangle legit numeric content ("3 months ago" → "e
/// months ago"; "$200 bucks" → "s200 bucks") and the collapse pass would
/// fuse incidental letter sequences into spurious tokens.
// Compiled once at file scope. Pattern: single letter, then 1+ runs of
// (separator+ then single letter), bounded by word boundaries. Matches
// "j.o.h.n", "j o h n", "j-o-h-n", "j_o_h_n", etc. Single-character classes
// only and no nested quantifiers — backtracking-safe even on a 2000-char
// text. Force-unwrapping is OK here: the pattern is a constant, so a
// failure to compile would surface immediately on first call.
private let nameSeparatorCollapseRegex: NSRegularExpression =
    try! NSRegularExpression(pattern: "\\b[a-z](?:[.\\-_ ]+[a-z])+\\b")

private func aggressiveNormalizeForNameMatch(_ text: String) -> String {
    let canon = canonicalize(text)
    var deLeet = ""
    deLeet.reserveCapacity(canon.count)
    for ch in canon {
        deLeet.append(nameLeetMap[ch] ?? ch)
    }
    var result = deLeet
    let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
    let matches = nameSeparatorCollapseRegex.matches(in: result, range: nsRange)
    // Iterate in reverse so earlier-match indices remain valid as we mutate.
    for match in matches.reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        let collapsed = String(result[range]).filter { $0.isLetter }
        result.replaceSubrange(range, with: collapsed)
    }
    return result
}

/// Surnames intentionally restricted to predominantly-proper-noun forms.
/// Excluded high-FP names that are also common English words: Brown, White,
/// Green, Hill, Wood, Long, King, Price, Young, Ward, Cook, Hall, Gray,
/// Wright, Reed — flagging "the brown dog" or "King" (used as a noun for
/// rulers) on a heartbreak post would be worse than missing a surname mention.
/// Tradeoff accepted: this list intentionally undercovers; the cost of a
/// false positive in this app (deletes a vulnerable user's post) outweighs
/// the cost of missing a surname that could have been caught.
private let commonLastNames: Set<String> = [
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
]

func containsNameOrIdentifyingInfo(_ text: String) -> Bool {
    let commonNames: Set<String> = [
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
        // Common nicknames — added 2026-05-01 sprint after the test suite
        // surfaced an evasion-vector miss for "M1k3" (de-leets to "mike",
        // which had no entry in the full-name list). Filtered out:
        //   - jordan (country, high FP risk)
        //   - max, drew, sue (common verbs/intensifiers)
        //   - bob, rob, nick (also verbs in common usage)
        // Mirror set lives in functions/moderation.js — keep in sync.
        "mike", "tom", "jim", "tim", "dan", "sam", "ben", "tony", "jake",
        "leo", "ian", "kyle", "evan", "greg", "jeff", "kurt", "paul",
        "pete", "eli", "brett", "todd", "troy",
        "liz", "beth", "kate", "ann", "jane", "lynn", "abby", "becky", "jess",
    ]
    let ambiguousWords: Set<String> = [
                // Common English words that happen to also be names
                "will", "grace", "angel", "mark", "frank", "art", "may",
                "joy", "hope", "faith", "chance", "chase", "hunter",
                "summer", "autumn", "winter", "dawn", "eve",
                "rose", "lily", "iris", "ivy", "pearl", "ruby", "amber",
                "brook", "cliff", "dale", "glen", "heath", "lance", "miles",
                "norm", "pat", "ray", "rex", "rod", "skip", "wade",
                "violet", "olive", "sage", "holly", "ginger",
                "sandy", "misty", "stormy", "sunny", "cherry", "candy",
                "destiny", "trinity", "harmony", "melody", "serenity",
            ]
    let identifyingPatterns = [
        "instagram", "insta", "snapchat", "snap", "tiktok", "twitter",
        "facebook", "linkedin", "phone number", "my number", "text me",
        "call me", "dm me", "follow me", "find me", "look me up",
        "last name", "full name", "school name",
        // T-1 (2026-06-11): removed the loose "works at"/"goes to"/"lives in"/
        // "lives on" and "apartment"/"apt "/"suite " substrings to match the
        // server (moderation.js N-13/N-15 trims). They false-positived heavily
        // on normal grief writing ("lives in my head", "adapt to change" → "apt ",
        // "the suite life", "my apartment is empty now") that the server already
        // accepts. "lives at" (street context) + "address" are specific and kept;
        // real unit numbers are still caught by the gated apartment regex below.
        "lives at", "address",
        "her name is", "his name is", "their name is",
        // NOTE: "named " was previously in this list as a broad keyword and
        // false-positived on legitimate sentences like "she named the dog
        // Rex" or "we named the album X". The careful `namedPatterns` check
        // below (which requires the following token to be capitalized) is
        // strictly better and catches the cases we care about ("she was
        // named Olivia") without the FP surface. Same removal in the
        // server-side mirror at functions/moderation.js.
        "zip code", "zipcode",
        "discord", "telegram", "whatsapp", "signal",
        "threads", "bluesky", "reddit",
    ]
    let lowered = text.lowercased()
    for pattern in identifyingPatterns { if lowered.contains(pattern) { return true } }

    // Two-letter social-platform shorthand (ig:/sc:/fb: with optional space).
    // Word-boundary anchored so "dig: deeper", "fab.", "abs-" don't flag.
    // Mirror of SOCIAL_SHORTHAND_RE in functions/moderation.js.
    if text.range(of: "\\b(ig|sc|fb)\\b\\s*[:.\\-]|\\b(?:my|on|add\\s+me\\s+on|find\\s+me\\s+on)\\s+(ig|sc|fb)\\b\\s+(?:is\\s+)?[a-z0-9._]{3,}", options: [.regularExpression, .caseInsensitive]) != nil {
        return true
    }

    if text.range(of: "@[a-zA-Z]", options: .regularExpression) != nil { return true }

    // Spelled-out email (#2 fuzz, 2026-06-11): "name at provider dot com" — the
    // literal-email form is caught by the URL layer (the host trips the URL
    // regex), but the obfuscated form has no dot/@. Mirror of moderation.js.
    if text.range(of: "\\b[a-z0-9._%+-]+\\s+at\\s+[a-z0-9][a-z0-9.\\s-]*\\s+dot\\s+(com|net|org|io|co|edu|gov|me|gg|us|uk|ca)\\b", options: [.regularExpression, .caseInsensitive]) != nil { return true }

    // Possessive name. N-17 (2026-06-11): a lone FIRST-name possessive
    // ("Jessica's") is allowed; a LAST-name possessive ("Johnson's") still
    // flags. Mirror of moderation.js.
    if text.range(of: "\\b[A-Z][a-z]{2,}'s\\b", options: .regularExpression) != nil {
        let matches = text.matches(of: /\b([A-Z][a-z]{2,})'s\b/)
        for match in matches {
            let name = String(match.1).lowercased()
            if commonLastNames.contains(name) && name.count >= 3 && !ambiguousWords.contains(name) { return true }
        }
    }

    // "my ex [Name]", "my friend [Name]", "my sister [Name]" etc.
    let relationshipPrefixes = ["my ex ", "my friend ", "my bf ", "my gf ",
        "my boyfriend ", "my girlfriend ", "my sister ", "my brother ",
        "my mom ", "my dad ", "my mother ", "my father ",
        "my coworker ", "my boss ", "my roommate ", "my neighbor ",
        "this girl ", "this guy ", "this boy ", "this man ", "this woman "]
    // N-17 (2026-06-11): "my ex Sarah" (prefix + bare FIRST name) is allowed; a
    // prefix + LAST name ("my ex Johnson") still flags; a prefix + FULL name is
    // caught by looksLikeFullName below. Mirror of moderation.js.
    for prefix in relationshipPrefixes {
        if let range = lowered.range(of: prefix) {
            let afterPrefix = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let firstWord = afterPrefix.components(separatedBy: CharacterSet.alphanumerics.inverted).first,
               !firstWord.isEmpty, firstWord.first?.isUppercase == true,
               commonLastNames.contains(firstWord.lowercased()), firstWord.count >= 3 {
                return true
            }
        }
    }

    // "named X" / "called X" / "name is X". N-17: same — a following bare FIRST
    // name is allowed; a LAST name flags; a FULL name is caught below.
    let namedPatterns = ["named ", "called ", "name is ", "name was "]
    for pattern in namedPatterns {
        if let range = lowered.range(of: pattern) {
            let afterPattern = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let firstWord = afterPattern.components(separatedBy: CharacterSet.alphanumerics.inverted).first,
               !firstWord.isEmpty, firstWord.first?.isUppercase == true,
               commonLastNames.contains(firstWord.lowercased()), firstWord.count >= 3 {
                return true
            }
        }
    }

    // Any capitalized word that looks like a proper noun mid-sentence
    // (not a sentence starter, not an ambiguous word, not a known safe word)
    let safeCapitalizedWords: Set<String> = [
        "i", "im", "ive", "ill", "id",
        "god", "christmas", "easter", "halloween", "valentines",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "june", "july", "august",
        "september", "october", "november", "december",
        "american", "english", "spanish", "french", "chinese", "japanese",
        "toska", "giphy", "apple", "google", "firebase",
        // "MacBook" pairs with a capitalized model word ("MacBook Pro"/"Air")
        // that the Mc/Mac-aware name regex would otherwise read as a surname.
        // Mirror of moderation.js.
        "macbook",
    ]

    // Street address pattern: "123 Main St" / "456 Oak Avenue"
    let streetSuffixes = "street|st|avenue|ave|boulevard|blvd|drive|dr|lane|ln|road|rd|way|place|pl|court|ct|circle|cir|terrace|trail|parkway|pkwy"
    if text.range(of: "\\d+\\s+[A-Za-z]+\\s+(\(streetSuffixes))\\b", options: .regularExpression) != nil { return true }

    // B-2 (2026-06-16): doxxable location-context ("works at Chicago Mercy
    // Hospital", "above the bodega on 5th and vine", "from brooklyn"). VERBATIM
    // mirror of functions/moderation.js LOCATION_CONTEXT_PATTERNS, ported to the
    // client so the compose-time warning fires on the SAME inputs the server
    // holds on (previously these were server-only — the post silently vanished
    // into pending-review with no warning). Per-pattern case sensitivity matches
    // the server EXACTLY: the workplace/education anchors are case-sensitive
    // (require a Capitalized institution); the rest carry /i (.caseInsensitive).
    // Pinned by location-context cases in detector-parity.mjs.
    if text.range(of: "\\b(works at|worked at|employed at)\\s+(the\\s+)?[A-Z][A-Za-z'-]+", options: .regularExpression) != nil { return true }
    if text.range(of: "\\b(goes to|went to|attends|studies at|enrolled at|graduated from)\\s+(the\\s+)?[A-Z][A-Za-z'-]+", options: .regularExpression) != nil { return true }
    if text.range(of: "\\b(at|near|behind|above|across from|next to|in front of)\\s+(the\\s+)?(hospital|school|university|college|library|station|airport|bodega|cafe|bar|diner|restaurant|coffee shop|gym|church|mosque|temple|synagogue|park|mall|stadium|theater|theatre|hotel|motel|hostel)\\b", options: [.regularExpression, .caseInsensitive]) != nil { return true }
    if text.range(of: "\\b(on|at|near|by)\\s+[A-Za-z0-9]+\\s+(and|&)\\s+[A-Za-z0-9]+\\s+(street|st|ave|avenue|blvd|drive|dr)\\b", options: [.regularExpression, .caseInsensitive]) != nil { return true }
    if text.range(of: "\\b(corner of|intersection of)\\s+[A-Za-z0-9]+\\s+(and|&)\\s+[A-Za-z0-9]+\\b", options: [.regularExpression, .caseInsensitive]) != nil { return true }
    if text.range(of: "\\b(from|in|near|outside)\\s+(new york|brooklyn|manhattan|queens|los angeles|chicago|houston|phoenix|philadelphia|san diego|dallas|austin|seattle|denver|boston|portland|miami|atlanta|nashville|charlotte|detroit|memphis|baltimore|milwaukee|sacramento|kansas city|las vegas|long beach|fresno|oakland|minneapolis|cleveland|tampa|honolulu|new orleans|wichita|raleigh|omaha|tucson|albuquerque|st louis|saint louis|cincinnati|pittsburgh|anchorage|st paul|saint paul|toledo|newark|jersey city|orlando|tulsa|arlington|virginia beach|colorado springs|london|paris|tokyo|berlin|toronto|sydney|melbourne|dublin|madrid|rome|amsterdam|barcelona|mumbai|delhi|beijing|shanghai|mexico city)\\b", options: [.regularExpression, .caseInsensitive]) != nil { return true }
    // C-4 (2026-06-11): the N-17 change gutted the mid-sentence lone-first-name
    // loop here (a bare first name like "I miss John" is now allowed). The
    // `sentences` / `sentenceStarters` / `words` locals it used were left behind
    // as dead code (the compiler warned `sentenceStarters` was never used); they
    // are removed. Layer 4 below has its own `canonicalSentenceStarters`.

    // Full-name shape: two consecutive Capitalized words ("Tess Salinaro").
    // Mirror of functions/moderation.js looksLikeFullName (2026-06-02). Catches
    // uncommon names with no relationship context; lowercase-surname / bare
    // single names still slip (that needs NER). Excludes common non-name
    // proper nouns so "New York" / "Harry Potter" don't trip it.
    let safeProperNounBigrams: Set<String> = [
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
    ]
    // T-1 / M-2 (2026-06-11): common English words that appear Capitalized inside
    // titles, place names, bands, and set phrases ("Last Night", "Central Park",
    // "Pearl Jam", "Empty Promises", "Broken Heart") — extremely common in grief
    // posts. The two-capitalized-words heuristic below false-positived on every
    // one of these. A real full name is rarely built from two common English
    // words, so if a bigram contains one of these AND neither token is a known
    // given name, treat it as a phrase, not a name. Mirror of COMMON_TITLE_WORDS
    // in functions/moderation.js — this guard was server-only until T-1.
    let commonTitleWords: Set<String> = [
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
    ]
    // F-1 (2026-06-12): match the two-cap-words shape over the CANONICALIZED
    // text, not the raw text — canonicalize folds math-alphanumeric / fullwidth
    // letterforms to case-preserved ASCII ("𝐒𝐚𝐫𝐚𝐡 𝐒𝐦𝐢𝐭𝐡" → "Sarah Smith"),
    // which read as legible names but never matched the ASCII regex. Mirror of
    // moderation.js.
    let fullNameSource = foldLetterformsKeepCase(text)
    // Each token allows an optional "Mc"/"Mac" prefix so internal-capital
    // surnames (McNiel, MacArthur) match — the plain [A-Z][a-z]+ shape stops at
    // the second capital, so "Ally McNiel" slipped through. Mirror of moderation.js.
    for match in fullNameSource.matches(of: /\b((?:Ma?c)?[A-Z][a-z]+)\s+((?:Ma?c)?[A-Z][a-z]+)\b/) {
        let w1 = String(match.1).lowercased()
        let w2 = String(match.2).lowercased()
        if w1.count < 2 || w2.count < 2 { continue }
        if safeCapitalizedWords.contains(w1) || safeCapitalizedWords.contains(w2) { continue }
        if ambiguousWords.contains(w1) && ambiguousWords.contains(w2) { continue }
        if safeProperNounBigrams.contains("\(w1) \(w2)") { continue }
        // M-2: a bigram with a common English title/phrase word is a phrase, not
        // a name — UNLESS the other token is a known given name (keeps "Sarah
        // Park" / "Grace Lake" flagged while clearing "Central Park" / "Last Night").
        if (commonTitleWords.contains(w1) || commonTitleWords.contains(w2))
            && !commonNames.contains(w1) && !commonNames.contains(w2) { continue }
        return true
    }
    let crisisNumbers = [
            "988-273-8255", "9882738255", "988 273 8255",
            "1-800-273-8255", "18002738255", "1 800 273 8255",
            "741741", "741 741",
            "1-800-799-7233", "18007997233",
            "1-800-656-4673", "18006564673",
        ]
    var digitStripped = text
    for number in crisisNumbers {
        digitStripped = digitStripped.replacingOccurrences(of: number, with: "")
    }
    // T-1 / M-2 (2026-06-11): remove breakup-timeline number lists BEFORE the
    // separator-collapse below, so they don't merge into one long run that
    // survives the year/small-number strips and trips the >=10-digit phone
    // threshold. Targeted so real phone groupings (which mix 2–4 digit groups)
    // are untouched: (a) 2+ consecutive 4-digit year tokens ("we dated 2019 2020
    // 2021 2022 2023"); (b) 4+ consecutive 1–3 digit tokens ("scores 100 95 88
    // 76 65"). A real international phone matches neither. Mirror of the JS fix
    // in functions/moderation.js — this strip was server-only until T-1.
    digitStripped = digitStripped
            .replacingOccurrences(of: "\\b(?:19|20)\\d\\d(?:\\s+(?:19|20)\\d\\d)+\\b", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\b\\d{1,3}(?:\\s+\\d{1,3}){3,}\\b", with: " ", options: .regularExpression)
    // Collapse phone-format separators between digits so a formatted phone
    // like `(555) 123-4567` survives the date/year/small-number strips
    // below. Without this, `\b\d{1,3}\b` peels `555`/`123` and
    // `\b\d{4,5}\b` peels `4567` because parens/space/dash sit at word
    // boundaries around each chunk — total digit count goes to zero.
    // Mirror of the JS fix in functions/moderation.js.
    digitStripped = digitStripped
            .replacingOccurrences(of: "(\\d)[-.\\s()]+(?=\\d)", with: "$1", options: .regularExpression)
    digitStripped = digitStripped
            .replacingOccurrences(of: "\\d{1,2}[:/]\\d{2}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\b\\d{4,5}\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\b\\d{1,3}\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\$[\\d,]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\d{1,2}/\\d{1,2}/\\d{2,4}", with: "", options: .regularExpression)
        let digits = digitStripped.filter { $0.isNumber }
        if digits.count >= 10 { return true }

    // ============================================================
    // EVASION HARDENING — additive layers for the 2026-05-01 pre-launch sprint.
    //
    // The original chain (above) handles plain prose well, but heartbroken
    // posters in a public-anonymous app sometimes try to dodge the warning
    // modal with cryptic stylization. Generic anonymous social apps fail
    // mostly to harassment + hate speech (Whisper, Yik Yak, Secret all died
    // this way); heartbreak content is structurally brand-safer but
    // introduces a different sharp edge: a poster in a high-emotion state
    // is tempted to identify their ex by name, address, social handle, or
    // workplace. Anonymous + public + named-target = textbook defamation,
    // plus an Apple-Guideline-1.2 takedown trigger.
    //
    // Vectors closed by the layers below:
    //   - Unicode confusables  (Sаrah, Ｓａｒａｈ, Sårāh)
    //   - Leetspeak             (j0hn, 5arah, m1k3, m@tt)
    //   - Separator tricks      (J.o.h.n, j-o-h-n, j o h n, j_o_h_n)
    //   - Last names            (Smith from accounting)
    //   - Apartment / unit nums (apt 4B, unit 12, #207)
    //   - Initials w/ context   (my ex J.S.)
    //   - URLs                  (instagram.com/handle, t.me/handle)
    //
    // Layers run AFTER the original chain so we don't change its semantics —
    // anything that already flagged still flags first; new layers only
    // catch inputs the original missed.
    // ============================================================

    // Layer 1: URL / social-link detection.
    // The existing identifyingPatterns catches the keyword "instagram", but
    // misses domain-style references like "instagram.com/handle" when the
    // surrounding context doesn't already trip the keyword. The url
    // detection in contentViolation() is upstream of name detection at
    // every call site, so most of these are already caught — this layer
    // is defense in depth for surfaces that may eventually consult name
    // detection without a contentViolation gate (and to make the behavior
    // explicit when reading this function in isolation).
    let urlRegexes = [
        "https?://",
        "\\bwww\\.[a-z]",
        "\\b(instagram|tiktok|facebook|twitter|snapchat|linkedin|reddit|youtube|youtu|t|discord|telegram|whatsapp|signal|onlyfans|threads|bluesky|cash\\.app|venmo|paypal)\\.(com|me|gg|tv|be|co|app|net|org|io)\\b",
        "\\b(linktr\\.ee|bit\\.ly|tinyurl)\\b",
    ]
    for pattern in urlRegexes {
        if lowered.range(of: pattern, options: .regularExpression) != nil { return true }
    }

    // Layer 2: Apartment / unit / suite numbers.
    // The existing identifyingPatterns includes "apartment", "apt ", "suite "
    // — but "apt " requires a trailing space, so "apt4B" or "apt.4B" miss.
    // It also has no rule for bare "#207". This layer fixes both.
    let apartmentRegex = "\\b(apt|unit|suite|ste)\\.?\\s*#?\\s*\\d+[a-z]?\\b"
    if lowered.range(of: apartmentRegex, options: .regularExpression) != nil { return true }
    if text.range(of: "#\\s*\\d{1,4}[a-z]?\\b", options: .regularExpression) != nil { return true }

    // Layer 3: Dotted initials with relationship context — "my ex J.S.".
    // The existing relationship-prefix loop tokenizes "J.S." into single
    // chars and bails on the count >= 2 check. Scan a 40-char window after
    // each prefix for a dotted-initials pattern instead.
    for prefix in relationshipPrefixes {
        if let range = lowered.range(of: prefix) {
            let afterPrefix = String(text[range.upperBound...])
            let scanWindow = String(afterPrefix.prefix(40))
            if scanWindow.range(of: "\\b[A-Z]\\.[A-Z]\\.?", options: .regularExpression) != nil {
                return true
            }
        }
    }

    // Layer 4: Per-token canonicalize-then-name-lookup.
    // Catches confusables (Cyrillic/Greek/fullwidth) and accented forms.
    // Capitalization gate: original first character must be uppercase, AND
    // the canonicalized token must not be a sentence-starter in the
    // canonicalized text — same false-positive guards the existing
    // first-name loop applies.
    // Tokenize the COMBINING-MARK-STRIPPED form so an attacker writing
    // `S̶arah` doesn't fragment to ['S', 'arah']. Mirror of the JS Layer
    // 4 fix in functions/moderation.js.
    let canonical = canonicalize(text)
    let canonicalSentenceStarters: Set<String> = Set(
        canonical.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted).first(where: { !$0.isEmpty }) }
    )
    let originalTokens = stripCombiningMarksKeepCase(text)
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    for word in originalTokens {
        let canonWord = canonicalize(word)
        if canonWord.count < 2 { continue }
        if ambiguousWords.contains(canonWord) { continue }
        if safeCapitalizedWords.contains(canonWord) { continue }
        let isFirstName = commonNames.contains(canonWord)
        let isLastName = commonLastNames.contains(canonWord) && canonWord.count >= 3
        if !isFirstName && !isLastName { continue }
        // F-1 (2026-06-12): obfuscation = the raw token differs from its canonical
        // form. Computed BEFORE the uppercase gate because math-alphanumeric
        // letters ("𝐒𝐦𝐢𝐭𝐡") carry no Unicode case, so firstChar.isUppercase is
        // false and the token was skipped before its evasion was evaluated.
        let isEvasion = word.lowercased() != canonWord
        // Require an uppercase-first token to count as a name — UNLESS it's an
        // evasion token (its canonical form is the real signal). Mirror of
        // moderation.js.
        if let firstChar = word.first {
            if !firstChar.isUppercase && !isEvasion { continue }
        } else { continue }
        // Sentence-starter exemption applies only to legit-prose tokens.
        // If canonicalize had to fold confusables / fullwidth / accents to
        // reach the name (i.e. the original lowercased token differs from
        // the canonical token), that's evidence of deliberate evasion and
        // the sentence-start exemption no longer applies — "Mіchael" at the
        // start of a sentence is an attack, not a casual capitalization.
        // N-17 (2026-06-11): a PLAIN lone FIRST name is allowed (the dominant FP
        // — "I miss John"); an OBFUSCATED first name (confusables/leet/fullwidth
        // = isEvasion) or any LAST name is still flagged. Mirror of moderation.js.
        if isFirstName && !isLastName && !isEvasion { continue }
        // B-1 (2026-06-16): gate the sentence-starter exemption to first names
        // only — a known LAST name as a sentence subject ("Garcia broke my
        // heart") must stay HELD, not be exempted as legit prose. Mirror of
        // moderation.js. (Redundant with the line above for pure first names;
        // kept explicit so both detectors read identically.)
        if !isEvasion && isFirstName && !isLastName && canonicalSentenceStarters.contains(canonWord) { continue }
        return true
    }

    // Layer 4.5: Reversed-token name lookup. Mirror of the server-side
    // moderation.js Layer 4.5. canonicalize strips bidi-override codepoints
    // (so a render-time visual flip can't slip through), but doesn't try
    // a literal reversal — "haraS" written in plain ASCII passes every
    // prior layer because the forward token isn't in the name set. We
    // reverse each canonicalized token and re-check. Length floor of 4
    // keeps false positives down (short reversed strings hit too many
    // common English fragments); palindromes are skipped because the
    // forward layers would have already had a chance.
    for word in originalTokens {
        let canonWord = canonicalize(word)
        if canonWord.count < 4 { continue }
        let reversed = String(canonWord.reversed())
        if reversed == canonWord { continue }
        if ambiguousWords.contains(reversed) { continue }
        if safeCapitalizedWords.contains(reversed) { continue }
        let isFirstRev = commonNames.contains(reversed)
        let isLastRev = commonLastNames.contains(reversed) && reversed.count >= 3
        if isFirstRev || isLastRev { return true }
    }

    // Layer 5: Whole-text aggressive normalization.
    // Catches separator chains (j.o.h.n, j o h n) and leet (j0hn, 5arah)
    // collapsing to a known first or last name. Only flags when the
    // aggressive form differs from the canonical form (i.e. there's
    // actual evidence of evasion — otherwise Layer 4 already had a chance).
    let aggressive = aggressiveNormalizeForNameMatch(text)
    let canonicalTokens = canonical.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    let canonicalTokenSet = Set(canonicalTokens)
    let aggressiveTokens = aggressive.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
    for token in aggressiveTokens {
        if ambiguousWords.contains(token) { continue }
        if safeCapitalizedWords.contains(token) { continue }
        let isName = commonNames.contains(token) || (commonLastNames.contains(token) && token.count >= 3)
        if !isName { continue }
        if canonicalTokenSet.contains(token) { continue }  // already had a chance via Layer 4
        return true
    }

    // Layer 6: Identifying-pattern keywords on canonicalized text.
    // The original loop ran identifyingPatterns against `lowered`, missing
    // fullwidth ("Ｉｎｓｔａｇｒａｍ ＠me") and confusable variants. Re-run
    // the same patterns against canonicalized text. (We already returned
    // true for any original-text match above; this only catches inputs
    // where the original missed due to non-ASCII evasion.)
    for pattern in identifyingPatterns {
        if canonical.contains(pattern) { return true }
    }

    return false
}

// Handle generation uses 8 hex chars from a UUID (16^8 ≈ 4 billion combinations).
// No Firestore uniqueness check is performed — collision probability is negligible
// at current scale. If the app grows significantly, consider adding a Firestore
// transaction that verifies uniqueness before committing the handle.
private let handleAdjectives = [
    "quiet", "still", "soft", "lost", "tired", "gentle", "fading", "sleepless",
    "distant", "hollow", "heavy", "broken", "wandering", "waiting", "restless",
    "silent", "lonely", "aching", "drifting", "numb", "awake", "unsaid", "almost",
    "barely", "dimly", "slowly", "sadly", "deeply", "half", "nearly"
]

private let handleNouns = [
    "ghost", "echo", "rain", "shadow", "light", "heart", "moon", "night",
    "storm", "drift", "flame", "cloud", "wave", "stone", "dust", "ember",
    "frost", "shore", "wound", "blur", "haze", "tide", "spark", "soul",
    "dream", "ache", "sigh", "dark", "glow", "void"
]

func generateUniqueHandle(attempt: Int = 0, completion: @escaping (String) -> Void) {
    guard attempt < 10 else {
        completion("anonymous_\(UUID().uuidString.prefix(8).lowercased())")
        return
    }
    let adj = handleAdjectives.randomElement() ?? "quiet"
    let noun = handleNouns.randomElement() ?? "ghost"
    let num = Int.random(in: 1...999)
    let candidate = "\(adj)_\(noun)_\(num)"

    Firestore.firestore().collection("users")
        .whereField("handle", isEqualTo: candidate)
        .limit(to: 1)
        .getDocuments { snapshot, _ in
            if let docs = snapshot?.documents, !docs.isEmpty {
                generateUniqueHandle(attempt: attempt + 1, completion: completion)
            } else {
                completion(candidate)
            }
        }
}

/// Native async variant of `generateUniqueHandle`. Used by sign-up paths
/// (Apple, Google, Email) where wrapping the callback version in a
/// continuation+TaskGroup race created a hang risk: if Firestore was
/// unreachable, the callback never fired, the wrapping Task leaked, and
/// the sign-up button's spinner stayed forever. Native async/await
/// participates in Task cancellation, so a `withTimeout(seconds:)`
/// wrapper actually aborts a stuck attempt.
///
/// On any Firestore error or cancellation, falls back to a UUID-based
/// handle — statistically unique without a network round-trip. On 10
/// candidate collisions in a row (vanishingly unlikely at current scale),
/// also falls back to UUID.
///
/// Total budget recommendation: wrap with `withTimeout(seconds: 5)` at
/// the call site so the worst-case sign-up handle assignment is bounded.
/// On timeout, the call site should also fall back to a UUID handle.
func generateUniqueHandleAsync(attempt: Int = 0) async -> String {
    guard attempt < 10 else {
        return "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
    }
    let adj = handleAdjectives.randomElement() ?? "quiet"
    let noun = handleNouns.randomElement() ?? "ghost"
    let num = Int.random(in: 1...999)
    let candidate = "\(adj)_\(noun)_\(num)"

    let snap: QuerySnapshot?
    do {
        snap = try await Firestore.firestore().collection("users")
            .whereField("handle", isEqualTo: candidate)
            .limit(to: 1)
            .getDocumentsAsync()
    } catch {
        // Network/permission/timeout — UUID fallback is statistically
        // unique with no further round-trip, which is what we want when
        // the backend is misbehaving during a sign-up flow.
        return "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
    }
    if Task.isCancelled {
        return "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
    }
    if let docs = snap?.documents, !docs.isEmpty {
        return await generateUniqueHandleAsync(attempt: attempt + 1)
    }
    return candidate
}

/// Commits a new users/{uid} doc TOGETHER with its handles/{handle.lowercased()}
/// uniqueness-registry row in one batch — firestore.rules requires the pair
/// (users create checks the registry row via getAfter; the registry create is
/// only possible while the handle is unclaimed). On a batch failure — almost
/// always the candidate being claimed between generation and commit — retries
/// with fresh candidates, ending on a UUID handle (collision-proof in
/// practice). Returns the handle that actually committed. Throws only when
/// even the UUID attempt fails (backend down / rules mismatch), in which case
/// the caller's existing user-doc-write error path applies.
func commitUserDocClaimingHandle(uid: String, initialHandle: String, baseData: [String: Any]) async throws -> String {
    let db = Firestore.firestore()
    var candidate = initialHandle
    var lastError: Error = NSError(domain: "toska", code: -1)
    for attempt in 0..<4 {
        var data = baseData
        data["handle"] = candidate
        let batch = db.batch()
        batch.setData(data, forDocument: db.collection("users").document(uid))
        batch.setData(["uid": uid], forDocument: db.collection("handles").document(candidate.lowercased()))
        do {
            try await batch.commit()
            return candidate
        } catch {
            lastError = error
            candidate = attempt < 2
                ? await generateUniqueHandleAsync()
                : "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
        }
    }
    throw lastError
}

func containsConcerningContent(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return concerningPhrases.contains(where: { lowered.contains($0) })
}

// MARK: - Content Moderation

enum ContentViolationType {
    case slur
    case threat
    case sexual
    case spam
    case harassment
    case link
}

// Character-lookup tables precomputed at file scope so contentViolation(in:)
// doesn't rebuild them on every keystroke. These are small constants; sharing
// is safe and makes the hot path (normalizeForModeration runs on every typed
// character as the user composes) cheap.
private let moderationZeroWidthCharacters: Set<Character> = [
    "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}"
]
private let moderationHomoglyphMap: [Character: Character] = [
    // Cyrillic lookalikes
    "\u{0430}": "a", "\u{0435}": "e", "\u{043E}": "o", "\u{0440}": "p",
    "\u{0441}": "c", "\u{0443}": "y", "\u{0445}": "x", "\u{0456}": "i",
    // Greek lookalikes
    "\u{0391}": "a", "\u{0392}": "b", "\u{0395}": "e", "\u{0397}": "h",
    "\u{0399}": "i", "\u{039A}": "k", "\u{039C}": "m", "\u{039D}": "n",
    "\u{039F}": "o", "\u{03A1}": "p", "\u{03A4}": "t", "\u{03A5}": "y",
]

private func normalizeForModeration(_ text: String) -> String {
    // Single-pass normalization:
    //   1. lowercase (Swift's Unicode-aware lowercase)
    //   2. strip zero-width characters
    //   3. fold homoglyphs to their ASCII lookalike
    // Previous implementation looped over 20 homoglyph pairs, each iteration
    // doing s.map(...).reduce("", +) — quadratic string concatenation per
    // pair, ~O(n² × 20) on the text length. On a 2000-character letter this
    // was roughly 80M operations, enough to cause visible typing lag while
    // composing. The current version is a single O(n) walk with O(1)
    // dictionary lookups per character.
    var result = ""
    result.reserveCapacity(text.count)
    for scalar in text.lowercased() {
        if moderationZeroWidthCharacters.contains(scalar) { continue }
        if let replacement = moderationHomoglyphMap[scalar] {
            result.append(replacement)
        } else {
            result.append(scalar)
        }
    }
    return result
}

private func collapseForModeration(_ text: String) -> String {
    // Collapse runs of 3+ identical letters to 2: "niggggger" → "nigger", "faaag" → "faag"
    // Keeping 2 preserves double-letter words (e.g. "pass", "well") while defeating evasion.
    var result = ""
    var count = 0
    var last: Character = "\0"
    for char in text {
        if char == last && char.isLetter {
            count += 1
            if count <= 2 { result.append(char) }
        } else {
            count = 1
            last = char
            result.append(char)
        }
    }
    return result
}

private func stripSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: " ", with: "")
}

func contentViolation(in text: String) -> ContentViolationType? {
    let normalized = normalizeForModeration(text)
    let collapsed = collapseForModeration(normalized)
    let noSpaces = stripSpaces(normalized)
    let collapsedNoSpaces = stripSpaces(collapsed)

    // Check all four forms for maximum evasion resistance
    let forms = [normalized, collapsed, noSpaces, collapsedNoSpaces]

    // --- Slurs and hate speech ---
    // Word-boundary-anchored slurs mirror the server MOD_HATE fix: unanchored,
    // "sp[i1]ck?" matched "suspicious"/"auspicious", "c[o0][o0]n" matched
    // "cocoon"/"raccoon"/"tycoon", "g[o0][o0]k" matched "gobbledygook" — all
    // routing routine writing to .slur (blocks compose; server hard-deletes the
    // reply). The (?!... armor) exclusion spares "a chink in the/his armor".
    let slurPatterns = [
        "n[i1!*]gg", "f[a@*]gg", "r[e3]t[a@]rd", "tr[a@]nny", "d[yi1]ke",
        "\\bch[i1]nks?\\b(?!\\s+in\\s+\\w+\\s+armou?r)", "\\bsp[i1]ck?s?\\b", "\\bk[i1]kes?\\b", "\\bw[e3]tb[a@]cks?\\b", "\\bg[o0][o0]ks?\\b",
        "\\bc[o0][o0]ns?\\b", "towelhead", "raghead", "beaner", "zipperhead",
    ]
    for form in forms {
        for pattern in slurPatterns {
            if form.range(of: pattern, options: .regularExpression) != nil { return .slur }
        }
    }

    // --- Threats and violence (targeted at others) ---
    // Checked BEFORE harassment, same as the server's computePost/ReplyFlagReason:
    // text containing both ("kys, i'll kill you") must triage to the more
    // severe category on every surface.
    let threatPhrases = [
        "kill you", "kill him", "kill her", "kill them",
        "shoot you", "shoot him", "shoot her", "shoot them",
        // 2026-07-01: mirror of the server MOD_THREAT re-expansion — the
        // narrowing to single fixed strings dropped determiner/possessive
        // phrasings ("burn down your house", "shoot up her school").
        "shoot up the", "shoot up your", "shoot up his", "shoot up her",
        "shoot up their", "shoot up my", "shoot up a school",
        "stab you", "stab him", "stab her", "stab them",
        // Bare "bomb"/"blow up" hard-blocked grief language ("she dropped a bomb
        // on me", "bath bomb", "before I blow up at him") that the server's
        // MOD_THREAT does NOT flag — so the client was blocking posts the backend
        // publishes live, with no override (threat is edit-only). Use targeted
        // forms instead. Same for "beat you" inside "beat yourself up".
        "bomb you", "bomb your", "blow you up", "blow up your",
        "burn your house", "burn his house", "burn her house", "burn their house",
        "burn down your", "burn down his", "burn down her", "burn down their",
        "rape you", "rape her", "rape him",
        "find you and", "find where you live", "know where you live",
        "hunt you down", "coming for you",
        "gonna hurt you", "going to hurt you",
        "beat you up", "beat the shit",
        "curb stomp", "slit your throat", "bash your head",
        "put a bullet", "put you in the ground",
    ]
    for phrase in threatPhrases {
        if normalized.contains(phrase) { return .threat }
    }

    // --- Directed self-harm encouragement (not emotional venting) ---
    let harassmentPhrases = [
        "kill yourself", "kys", "go die", "you should die",
        "hope you die", "go hang yourself", "neck yourself",
        "drink bleach", "jump off a bridge",
        "nobody likes you", "everyone hates you",
        "the world is better without you",
        "you're worthless", "youre worthless",
        "you're pathetic", "youre pathetic",
        "you deserve to suffer", "you deserve to die",
        "go away and never come back",
        "no one will miss you", "noone will miss you",
    ]
    for phrase in harassmentPhrases {
        if normalized.contains(phrase) { return .harassment }
    }
    for phrase in harassmentPhrases {
        if noSpaces.contains(phrase.replacingOccurrences(of: " ", with: "")) { return .harassment }
    }

    // --- Sexual content ---
    let sexualPatterns = [
        "porn", "hentai", "xxx", "onlyfans", "only fans",
        "nudes", "send nudes", "dick pic", "pussy pic",
        "jerk off", "jack off", "masturbat",
        "\\bcum on\\b", "\\bcum in\\b", "creampie",
        "blowjob", "blow job", "handjob", "hand job",
        "anal sex", "oral sex",
        "f[u\\*]ck me daddy", "choke me",
        "sex tape", "sextape", "sext me", "sexting",
        "nsfw", "r34", "rule34", "rule 34",
        "hook ?up", "booty ?call",
    ]
    for pattern in sexualPatterns {
        if normalized.range(of: pattern, options: .regularExpression) != nil { return .sexual }
    }

    // --- Spam ---
    let spamPhrases = [
        "buy now", "click here", "limited time", "act now",
        "free money", "make money", "earn money",
        "crypto", "bitcoin", "ethereum", "nft",
        "follow my", "check my bio", "link in bio",
        "discount code", "promo code", "use code",
        "dm me for", "dm for",
        "cashapp", "venmo me", "paypal me",
        "subscribe to", "check out my",
        "telegram", "whatsapp me",
    ]
    for phrase in spamPhrases {
        if normalized.contains(phrase) { return .spam }
    }

    // --- URL/link detection ---
    let urlPatterns = [
        "https?://", "www\\.", "\\.com/", "\\.net/", "\\.org/",
        "\\.io/", "\\.co/", "\\.me/", "\\.ly/",
        "bit\\.ly", "tinyurl", "linktr\\.ee",
    ]
    for pattern in urlPatterns {
        if normalized.range(of: pattern, options: .regularExpression) != nil { return .link }
    }
    // Bare domain pattern: word.tld (but not common false positives)
    let bareDomainExclusions = ["i.e", "e.g", "a.m", "p.m", "u.s", "mr.", "mrs.", "dr."]
    if normalized.range(of: "[a-z0-9]+\\.(com|net|org|io|co|app|xyz|gg|tv|me)\\b", options: .regularExpression) != nil {
        let hasFalsePositive = bareDomainExclusions.contains { normalized.contains($0) }
        if !hasFalsePositive { return .link }
    }

    return nil
}

func contentViolationMessage(for type: ContentViolationType) -> String {
    switch type {
    case .slur:
        return "this contains language that could hurt people. toska is a space for everyone."
    case .threat:
        return "this sounds like it could be threatening toward someone. toska is for expressing feelings, not directing harm."
    case .sexual:
        return "this contains sexual content that isn't appropriate for toska."
    case .spam:
        return "this looks like it might be spam or promotional content."
    case .harassment:
        return "this looks like it's directed at hurting someone. toska is for expressing your own feelings, not tearing others down."
    case .link:
        return "toska doesn't allow links. this is an anonymous space — keep it about the words."
    }
}

