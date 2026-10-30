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
    // 2026-07-27 algospeak extension (explicit — unambiguous suicide references).
    // Mirror of index.js MOD_CRISIS_EXPLICIT.
    "sewerslide", "sewer slide", "self deletion", "self-deletion", "self delete",
    "self deleting",
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
    // 2026-07-28 method-language extension (A.5 #3, EXPLICIT). Mirror of
    // functions/moderationLogic.js MOD_CRISIS_EXPLICIT — keep in exact sync
    // (crisis-parity pins list equality).
    "shoot myself", "blow my brains out",
    "slit my wrists", "cut my wrists", "slitting my wrists",
    "want to overdose", "going to overdose", "gonna overdose",
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
    // 2026-07-27 algospeak extension (SOFT — held + gentle check-in, never
    // paged). Short tokens (sa/csa/dv/sh) are word-boundary matched by
    // crisisPhraseMatch so they don't fire inside innocent words. SA/CSA/DV are
    // survivor DISCLOSURES routed to support+review, never abuse-takedown.
    // ("si" excluded — collides with Spanish "si"/"sí".) Mirror of index.js.
    "sa", "csa", "dv", "sh", "yeet myself", "grippy sock",
    // 2026-07-28 method/planning/goodbye extension (A.5 #3 — SOFT). Mirror of
    // functions/moderationLogic.js MOD_CRISIS_SOFT — keep in exact sync
    // (crisis-parity pins list equality). See the server comment for the
    // tiering rationale + deliberate exclusions (gun-to-my-head idiom,
    // goodbye note/letter = core breakup use-case, etc.).
    "overdose", "overdosing", "od",
    "bottle of pills", "take all my pills", "took all my pills", "swallow all my pills",
    "drown myself", "noose",
    "jump off a bridge", "jump off the roof", "jump in front of a",
    "tonights the night", "tonight's the night", "wrote my note", "writing my note",
    "last night on earth", "wont be here tomorrow", "won't be here tomorrow",
    "by the time you read this", "goodbye forever",
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
    // 2026-07-27 algospeak hardening — mirror of moderationLogic.js:
    // (a) collapse 3+ repeated chars ("suuuuicide" -> "suicide"); 3+ leaves real
    //     doubles untouched. (b) crisis-only extra de-leet 6/9->g, (/<->c.
    func collapseRepeats(_ s: String) -> String {
        s.replacingOccurrences(of: "(.)\\1{2,}", with: "$1", options: .regularExpression)
    }
    func deLeetExtra(_ s: String) -> String {
        var r = s
        for (from, to) in [("6", "g"), ("9", "g"), ("(", "c"), ("<", "c")] {
            r = r.replacingOccurrences(of: from, with: to)
        }
        return r
    }
    let lowered = text.lowercased()
    let normalized = aggressiveNormalizeForNameMatch(text)
    let noSpace = noSpaceOf(normalized)
    // Fold the raw text too (not just the normalized form): normalization's
    // leet map already committed "1"->"i" before we could fold, so both
    // inputs go through foldAmbiguousIL from their own starting points.
    let folded = foldAmbiguousIL(aggressiveNormalizeForNameMatch(foldAmbiguousIL(text)))
    let foldedNoSpace = noSpaceOf(folded)
    let collapsed = collapseRepeats(deLeetExtra(normalized))
    // 2026-10-07 pentest (mirror of moderationLogic.js): padding the DOUBLE
    // letter itself ("killl myself") defeated the 3+→1 collapse — it destroys
    // the double the phrase needs ("kil myself"). A 3+→2 form restores it,
    // and collapsing the ambiguous-class fold catches pads that span the
    // i/l pair ("kiilll myself").
    func collapseRepeatsKeepDouble(_ s: String) -> String {
        s.replacingOccurrences(of: "(.)\\1{2,}", with: "$1$1", options: .regularExpression)
    }
    let collapsedKeep = collapseRepeatsKeepDouble(deLeetExtra(normalized))
    let foldedCollapsed = collapseRepeats(folded)
    let foldedCollapsedNoSpace = noSpaceOf(foldedCollapsed)
    for phrase in list {
        let pNoSpace = String(phrase.filter { $0.isLetter || $0.isNumber }).lowercased()
        // Short tokens / initialisms (sa, sh, dv, csa, kms, kys) match ONLY as
        // standalone word-boundary tokens — a bare "sa" fires inside
        // "salsa/visa/usa", "kys" inside "sky's"->"skys". Mirror of the server.
        if pNoSpace.count <= 3 {
            // A2 (2026-10-28 audit, mirror of moderationLogic.js): test ONLY the
            // raw lowercased text. The normalized/de-leeted forms fold digits into
            // letters ("54" → "sa", "5h" → "sh", "0d" → "od"), which flagged
            // "54 days since" as crisis. Punctuated/spaced initialisms ("k.m.s",
            // "k m s", "s.a.") still match through the joiner between letters.
            let joined = pNoSpace.map { String($0) }.joined(separator: "[\\s.\\-_*·]*")
            let pattern = "(?<![a-z0-9])\(joined)(?![a-z0-9])"
            if lowered.range(of: pattern, options: .regularExpression) != nil { return true }
            continue
        }
        if lowered.contains(phrase) || normalized.contains(phrase) { return true }
        if folded.contains(foldAmbiguousIL(phrase)) { return true }
        if collapsed.contains(phrase) { return true }
        if collapsedKeep.contains(phrase) { return true }
        if foldedCollapsed.contains(collapseRepeats(foldAmbiguousIL(phrase))) { return true }
        if pNoSpace.count >= 6 &&
            (noSpace.contains(pNoSpace) || foldedNoSpace.contains(foldAmbiguousIL(pNoSpace))
             || collapseRepeats(noSpace).contains(pNoSpace)
             || collapseRepeatsKeepDouble(noSpace).contains(pNoSpace)
             || foldedCollapsedNoSpace.contains(collapseRepeats(foldAmbiguousIL(pNoSpace)))) { return true }
    }
    return false
}

func crisisLevel(for text: String) -> CrisisLevel? {
    if crisisPhraseMatch(text, explicitCrisisPhrases) { return .explicit }
    if crisisPhraseMatch(text, softConcernPhrases) { return .soft }
    return nil
}

// 2026-07-27: topic-specific crisis resources. When the concern is a sexual-
// assault or domestic-violence disclosure (not general suicidal distress), the
// check-in should surface RAINN / the DV hotline, not just 988. Client-only
// (the check-in is compose-time UX); uses the same word-boundary matcher so
// "sa"/"csa"/"dv" don't fire inside innocent words. Kept OUT of the crisis-parity
// pin (that pins only the held/paged lists); mirrored in webapp/js/gates.js.
enum CrisisTopic {
    case sexualAssault
    case domesticViolence
}

private let sexualAssaultTerms = [
    "sa", "csa", "sexual assault", "sexually assaulted", "assaulted me",
    "raped me", "he raped me", "she raped me", "was raped", "molested me",
]
private let domesticViolenceTerms = [
    "dv", "domestic violence", "domestic abuse", "abusive relationship",
    "he hit me", "she hit me", "he abused me", "she abused me", "he beat me",
]

func crisisTopic(for text: String) -> CrisisTopic? {
    if crisisPhraseMatch(text, sexualAssaultTerms) { return .sexualAssault }
    if crisisPhraseMatch(text, domesticViolenceTerms) { return .domesticViolence }
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
    // Dotless i family (2026-10-07 pentest): Turkish ı (U+0131) renders ≈ "i"
    // but has no NFD decomposition and wasn't mapped — "kıll myself" slipped
    // every lane. İ (U+0130) needs no entry: lowercasing yields i + combining
    // dot, which the NFD strip handles. Mirror of functions/moderation.js.
    "ı": "i", "Ɨ": "i", "ɨ": "i", "ɩ": "i", "Ɩ": "i",
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
    // 2026-10-29 expansion — generated from moderation.js (see its comment); keep in parity.
    "abbott", "acevedo", "acosta", "adams", "adkins", "aguilar", "aguirre", "alfaro", "allen", "allison", "alvarado", "alvarez",
    "andersen", "andrade", "andrews", "archer", "arellano", "arias", "armstrong", "arroyo", "atkins", "atkinson", "austin", "avalos",
    "avila", "ayala", "ayers", "bailey", "baker", "baldwin", "ball", "ballard", "banks", "barajas", "barber", "barker",
    "barnes", "barnett", "barr", "barrera", "barrett", "barron", "bartlett", "barton", "bass", "bates", "bauer", "bautista",
    "baxter", "bean", "beard", "beasley", "beck", "becker", "beil", "bell", "beltran", "bender", "benitez", "bennett",
    "benson", "bentley", "benton", "berg", "berger", "bernal", "berry", "best", "bishop", "black", "blackburn", "blackwell",
    "blair", "blanchard", "blankenship", "blevins", "bond", "bonilla", "booker", "boone", "booth", "bowen", "bowers", "bowman",
    "boyd", "boyer", "boyle", "bradford", "bradshaw", "branch", "brandt", "bravo", "bray", "brennan", "brewer", "bridges",
    "briggs", "brock", "brooks", "brown", "browning", "bryant", "buchanan", "buck", "buckley", "bullock", "burch", "burgess",
    "burke", "burnett", "burns", "burton", "bush", "butler", "byrd", "cabrera", "cain", "calderon", "caldwell", "calhoun",
    "callahan", "camacho", "campbell", "campos", "cannon", "cano", "cantrell", "cantu", "cardenas", "carey", "carlson", "carpenter",
    "carr", "carrillo", "carroll", "carson", "carter", "case", "castaneda", "castillo", "castro", "cervantes", "chambers", "chan",
    "chang", "chapman", "chase", "chavez", "chen", "cherry", "choi", "christensen", "chung", "church", "cisneros", "clark",
    "clarke", "clay", "clayton", "clements", "cline", "cobb", "cochran", "coffey", "cohen", "coleman", "collier", "collins",
    "colon", "combs", "compton", "conley", "conner", "conrad", "contreras", "conway", "cook", "cooper", "copeland", "cordova",
    "corona", "correa", "cortes", "cortez", "costa", "cox", "crane", "crawford", "crosby", "cross", "cruz", "cuevas",
    "cummings", "curry", "curtis", "daniels", "daugherty", "davenport", "davidson", "davila", "davis", "dawson", "day", "decker",
    "dejesus", "delacruz", "delarosa", "deleon", "delgado", "diaz", "dickerson", "dickson", "dillon", "dixon", "dodson", "dominguez",
    "donaldson", "donovan", "dorsey", "dougherty", "doyle", "drake", "duarte", "dudley", "duffy", "duke", "dunlap", "dunn",
    "duran", "durham", "dyer", "eaton", "edwards", "elliott", "ellis", "ellison", "enriquez", "erickson", "escobar", "esparza",
    "espinosa", "espinoza", "esquivel", "estes", "estrada", "evans", "everett", "farley", "farmer", "farrell", "faulkner", "ferguson",
    "fernandez", "fields", "figueroa", "fischer", "fisher", "fitzgerald", "fitzpatrick", "fleming", "flores", "flowers", "floyd", "flynn",
    "foley", "ford", "foster", "fowler", "fox", "frazier", "freeman", "friedman", "frost", "fry", "frye", "fuentes",
    "fuller", "gaines", "galindo", "gallagher", "gallegos", "galloway", "galvan", "garcia", "gardner", "garner", "garrison", "garza",
    "gates", "gentry", "gibbs", "gibson", "giles", "gill", "gillespie", "gilmore", "glass", "glover", "golden", "gomez",
    "gonzales", "gonzalez", "good", "goodman", "goodwin", "gould", "graves", "gray", "green", "greene", "greer", "griffin",
    "griffith", "grimes", "gross", "guerra", "guerrero", "guevara", "gutierrez", "guzman", "haas", "hahn", "hail", "hale",
    "haley", "hall", "hamilton", "hammond", "hampton", "hancock", "hansen", "hanson", "hardin", "harding", "harmon", "harrell",
    "harrington", "harris", "harrison", "hart", "hartman", "harvey", "hawkins", "hayden", "hayes", "haynes", "heath", "hebert",
    "henderson", "hendricks", "hendrix", "hensley", "henson", "hernandez", "herrera", "herring", "hess", "hester", "hickman", "hicks",
    "higgins", "hill", "hines", "hinton", "hobbs", "hodge", "hodges", "hoffman", "hogan", "holden", "holland", "holloway",
    "holmes", "holt", "hood", "hoover", "hopkins", "horn", "horne", "horton", "house", "houston", "howe", "howell",
    "huang", "hubbard", "huber", "hudson", "huerta", "huff", "huffman", "hughes", "hull", "humphrey", "hunt", "hunter",
    "hurley", "hurst", "hutchinson", "huynh", "ibarra", "ingram", "jacobs", "jacobson", "jaramillo", "jarvis", "jenkins", "jennings",
    "jensen", "jimenez", "johns", "johnson", "johnston", "jones", "jordan", "juarez", "kane", "kaufman", "kaur", "keller",
    "kelley", "kemp", "kerr", "khan", "king", "kirby", "klein", "kline", "knapp", "knight", "knox", "koch",
    "kramer", "krueger", "lam", "lamb", "landry", "lane", "lang", "larsen", "larson", "lawson", "leach", "leal",
    "leblanc", "levy", "lim", "lin", "lincoln", "lindsey", "little", "liu", "livingston", "long", "lopez", "love",
    "lowe", "lowery", "lozano", "lucero", "lugo", "lynch", "lyons", "macdonald", "macias", "mack", "madden", "maddox",
    "magana", "mahoney", "maldonado", "malone", "mann", "manning", "marks", "marquez", "marsh", "marshall", "martinez", "massey",
    "mata", "mathews", "mathis", "matthews", "maxwell", "mayer", "maynard", "mayo", "mays", "mcbride", "mccall", "mccann",
    "mccarthy", "mccarty", "mcclain", "mcclure", "mcconnell", "mccormick", "mccoy", "mccullough", "mcdaniel", "mcdonald", "mcdowell", "mcfarland",
    "mcgee", "mcgrath", "mcguire", "mcintosh", "mcintyre", "mckay", "mckee", "mckenzie", "mckinney", "mclaughlin", "mclean", "mcmahon",
    "mcmillan", "mcpherson", "meadows", "medina", "medrano", "mejia", "melendez", "melton", "mendez", "mendoza", "mercado", "merritt",
    "meyer", "meyers", "meza", "middleton", "miller", "mills", "mitchell", "molina", "monroe", "montes", "montgomery", "montoya",
    "moody", "moon", "moore", "mora", "morales", "moran", "moreno", "morris", "morrison", "morrow", "morse", "morton",
    "mosley", "moss", "moyer", "mueller", "mullen", "mullins", "munoz", "murillo", "murphy", "murray", "myers", "nash",
    "nava", "navarro", "neal", "newman", "newton", "nguyen", "nichols", "nicholson", "nielsen", "nieves", "nixon", "noble",
    "nolan", "norris", "norton", "nunez", "obama", "obrien", "ochoa", "oconnell", "oconnor", "odom", "odonnell", "olsen",
    "olson", "oneal", "oneill", "orozco", "orr", "ortega", "ortiz", "osborne", "owens", "pace", "pacheco", "padilla",
    "page", "palacios", "palmer", "park", "parks", "parra", "parrish", "parsons", "patel", "patterson", "patton", "payne",
    "pearson", "peck", "pena", "pennington", "peralta", "perez", "perkins", "perry", "person", "peters", "petersen", "peterson",
    "petty", "pham", "phan", "phelps", "phillips", "pierce", "pineda", "pittman", "pitts", "pollard", "ponce", "poole",
    "pope", "porter", "portillo", "potter", "potts", "powell", "powers", "pratt", "preston", "price", "prince", "proctor",
    "pruitt", "pugh", "quintana", "quintero", "ramirez", "ramos", "ramsey", "randolph", "rangel", "rasmussen", "ray", "reed",
    "reese", "reeves", "reid", "reilly", "reyes", "reyna", "reynolds", "rhodes", "rice", "rich", "richards", "richardson",
    "richmond", "rios", "rivas", "rivera", "rivers", "roach", "robbins", "roberson", "roberts", "robertson", "robinson", "robles",
    "rocha", "rodgers", "rodriguez", "rogers", "rojas", "rollins", "romero", "rosales", "rosas", "roth", "rowe", "rowland",
    "rubio", "ruiz", "rush", "russo", "salas", "salazar", "salgado", "salinas", "sampson", "sanchez", "sanders", "sandoval",
    "sanford", "santana", "santos", "saunders", "savage", "sawyer", "schaefer", "schmidt", "schmitt", "schneider", "schroeder", "schultz",
    "schwartz", "sellers", "serrano", "sexton", "shaffer", "shah", "sharp", "shaw", "shelton", "shepard", "shepherd", "sheppard",
    "sherman", "shields", "short", "sierra", "simmons", "simpson", "sims", "singh", "singleton", "skinner", "sloan", "small",
    "smith", "snow", "snyder", "solis", "solomon", "sosa", "soto", "sparks", "spears", "spence", "stafford", "stanton",
    "stark", "steele", "stein", "stephens", "stephenson", "stevens", "stevenson", "stewart", "stokes", "stone", "stout", "strickland",
    "strong", "stuart", "suarez", "sullivan", "summers", "sutton", "swanson", "sweeney", "tang", "tanner", "tapia", "tate",
    "terrell", "terry", "thornton", "torres", "townsend", "tran", "trejo", "trevino", "trujillo", "truong", "tucker", "turner",
    "underwood", "valdez", "valencia", "valentine", "valenzuela", "vance", "vang", "vargas", "vasquez", "vaughan", "vaughn", "vazquez",
    "vega", "velasquez", "velazquez", "velez", "ventura", "villa", "villalobos", "villanueva", "villarreal", "villegas", "wade", "wagner",
    "walker", "wall", "waller", "walls", "walsh", "walters", "walton", "wang", "ward", "ware", "warner", "washington",
    "waters", "watkins", "watson", "watts", "weaver", "webb", "weber", "webster", "weeks", "weiss", "welch", "wells",
    "west", "wheeler", "whitaker", "white", "whitehead", "whitney", "wiggins", "wilcox", "wiley", "wilkerson", "wilkins", "wilkinson",
    "williams", "williamson", "willis", "wilson", "winters", "wise", "wolf", "wolfe", "wong", "wood", "woodard", "woods",
    "woodward", "wright", "xiong", "yang", "yates", "yoder", "york", "young", "zamora", "zavala", "zhang", "zimmerman",
    "zuniga",
]

// Hoisted to file scope (2026-10-29) so likelyFirstName below can share them
// with containsNameOrIdentifyingInfo. Contents unchanged — mirror of moderation.js.
private let commonNames: Set<String> = [
    // 2026-10-29 expansion — generated from moderation.js (see its comment); keep in parity.
    "a'isha", "aad", "aadu", "aage", "aagje", "aagot", "aake", "aaliyah", "aapo", "aare", "aarni", "aaron",
    "aart", "aase", "aatos", "aavo", "aba", "abbas", "abby", "abdallah", "abderrahim", "abdi", "abdon", "abdoulaye",
    "abdu", "abdul", "abdullah", "abe", "abeer", "abel", "abigail", "abraham", "absalom", "abu'l-fadl", "acacio", "achille",
    "achilles", "acyuta", "ada", "adalbert", "adalberto", "adam", "adan", "addison", "adela", "adelaida", "adelaide", "adele",
    "adelheid", "adelina", "adem", "ademar", "adib", "adil", "adina", "admir", "adnan", "adolf", "adolfina", "adolfo",
    "adolph", "adolphe", "adolphus", "adrian", "adriana", "adriano", "adrienne", "adwoa", "aegidius", "afanasy", "afonso", "afra",
    "afshin", "agata", "agatha", "agathe", "agaton", "age", "agim", "aglaia", "agnar", "agne", "agnes", "agnese",
    "agneta", "agnete", "agneya", "agnieszka", "agota", "agrippina", "agustin", "ahinoam", "ahmad", "ahmed", "ahmet", "aida",
    "aidan", "aiden", "aija", "aiko", "aila", "aileen", "aili", "aimar", "aime", "aimee", "aina", "ainhoa",
    "aino", "airi", "aisling", "aitor", "aivar", "aivaras", "aivars", "ajay", "ajda", "ake", "akemi", "aki",
    "akif", "akihiko", "akihito", "akio", "akira", "akos", "akosua", "akram", "akseli", "akua", "alaa", "aladar",
    "aladdin", "alain", "alajos", "alan", "alana", "alasdair", "alba", "alban", "albert", "alberta", "albertas", "albertina",
    "alberto", "albin", "albina", "albino", "albrecht", "alcide", "alda", "aldo", "aldona", "alejandra", "alejandro", "aleks",
    "aleksa", "aleksandar", "aleksander", "aleksandr", "aleksandra", "aleksandras", "aleksanteri", "aleksej", "aleksey", "aleksi", "alen", "alena",
    "alenka", "ales", "alessandra", "alessandro", "alessia", "alessio", "aletta", "alex", "alexa", "alexander", "alexandr", "alexandra",
    "alexandre", "alexandrine", "alexandru", "alexej", "alexia", "alexis", "alexius", "alf", "alfhild", "alfons", "alfonso", "alfonz",
    "alfred", "alfreda", "alfredo", "algernon", "algirdas", "algis", "algot", "ali", "alice", "alicia", "alida", "alim",
    "alina", "alisha", "alison", "alissa", "alistair", "alix", "aljosa", "alla", "allan", "allie", "alma", "almudena",
    "alois", "aloisia", "aloisio", "alojz", "alojzy", "aloys", "aloysius", "alper", "althea", "alva", "alvar", "alvaro",
    "alvhild", "alvin", "alvina", "alvise", "alwin", "alyona", "alyssa", "amadea", "amadeus", "amaia", "amal", "amalia",
    "amalie", "amalric", "amanda", "amandine", "amandus", "amane", "amaya", "amber", "ambrosius", "ambrozy", "ambrus", "amelia",
    "amelie", "amenhotep", "amer", "amilcar", "amina", "aminata", "aminu", "amir", "amira", "ammavaru", "amos", "amparo",
    "amr", "amund", "amy", "ana", "anabela", "anabella", "anacleto", "anais", "anas", "anastasia", "anastasius", "anastasiya",
    "anatol", "anatoly", "ander", "anders", "anderson", "andi", "andoni", "andor", "andras", "andraz", "andre", "andrea",
    "andreas", "andree", "andrei", "andrej", "andrejs", "andres", "andrew", "andrey", "andri", "andrijana", "andris", "andrius",
    "andriy", "andrus", "andrzej", "andy", "aneta", "anete", "anett", "anette", "angel", "angela", "angele", "angelika",
    "angelina", "angelique", "angelo", "angie", "angus", "ani", "anica", "anika", "anis", "anisa", "anissa", "anita",
    "anitra", "anja", "anka", "anke", "ankit", "ann", "anna", "annabel", "annabeth", "annalena", "annalisa", "anne",
    "annegret", "anneli", "annelie", "anneliese", "annemarie", "annette", "anni", "annibale", "annie", "annika", "anniken", "annikki",
    "anny", "anouar", "anouk", "anri", "ansgar", "anssi", "antal", "antanas", "ante", "antero", "anthony", "anto",
    "antoine", "antoinette", "anton", "antonella", "antoni", "antonia", "antonietta", "antonija", "antonije", "antonin", "antonina", "antonino",
    "antonio", "ants", "antti", "antun", "anu", "anwar", "anya", "aodh", "aoife", "apollo", "apollonia", "arabella",
    "araceli", "aram", "aranka", "arantxa", "arash", "arben", "are", "ari", "aria", "ariadna", "ariadne", "ariana",
    "arianna", "aribert", "ariel", "arif", "arild", "arina", "ariobarzanes", "arja", "arkadiusz", "arkady", "arlene", "arlette",
    "armand", "armanda", "armando", "armel", "armin", "arna", "arnaldo", "arnar", "arne", "arnfinn", "arnold", "arnost",
    "arnulf", "arnulfo", "aron", "arpad", "arsaces", "arsene", "arsenije", "arsenius", "arslan", "art", "artaxerxes", "artem",
    "artemon", "arthur", "arttu", "artturi", "artur", "arturo", "arturs", "artyom", "arun", "arve", "arved", "arvid",
    "arvo", "arvydas", "arya", "arzu", "asa", "asaf", "ase", "asgeir", "asger", "ashkbous", "ashley", "ashraf",
    "asim", "asko", "aslak", "aslaug", "asma", "asmund", "asmundur", "assar", "asta", "astika", "aston", "astrid",
    "asuman", "asuncion", "atanas", "atanasije", "athanasios", "athanasius", "atle", "atsushi", "attila", "aud", "audrey", "audrius",
    "audun", "augusta", "augustina", "augustinus", "augusto", "augustus", "auke", "aulis", "aura", "aurel", "aurelia", "aurelie",
    "aurelien", "aurora", "aurore", "ausra", "ava", "avelina", "avery", "avgust", "avtandil", "axel", "aya", "ayaka",
    "ayako", "aydan", "aykut", "ayla", "aylin", "aymen", "ayse", "aysel", "ayumi", "ayyub", "azamat", "aziz",
    "aziza", "azra", "babak", "babasaheb", "badr", "bahar", "bakasura", "balbina", "baldomero", "balduin", "baldur", "baltasar",
    "baltazar", "balthazar", "barack", "barak", "barbara", "barbora", "barbro", "barnaba", "barnabas", "barney", "barnim", "barry",
    "bart", "bartholomaus", "bartholomew", "bartolomeo", "bartolomeu", "bartosz", "baruch", "bashar", "bashir", "basil", "basilius", "bastian",
    "bea", "beata", "beate", "beatrice", "beatrix", "beatriz", "becky", "beda", "bedrich", "begona", "behrouz", "bekir",
    "bela", "belinda", "bella", "ben", "benat", "bence", "benedetto", "benedict", "benedictus", "benedikt", "benedikte", "benedykt",
    "bengt", "bengta", "benigna", "benita", "benito", "benjamin", "benno", "benny", "beno", "bent", "bente", "beppe",
    "berend", "berengar", "berengere", "berenice", "berit", "bernadette", "bernard", "bernarda", "bernardina", "bernardo", "bernd", "bernhard",
    "bernt", "bert", "berta", "bertalan", "bertel", "bertha", "berthold", "bertil", "bertold", "bertram", "bertrand", "beryl",
    "beth", "bethany", "bettina", "betty", "beverly", "bhutamata", "biagio", "bianca", "bianka", "bilal", "biljana", "bill",
    "billy", "birger", "birgit", "birgitta", "birgitte", "birte", "bjarke", "bjarne", "bjarni", "bjarte", "bjorn", "blagoje",
    "blaise", "blake", "blanca", "blanka", "blas", "blasius", "bob", "bobby", "bodhmall", "bodil", "bodo", "bodog",
    "bogdan", "bogdana", "boglarka", "bogoljub", "bogomir", "bogumil", "bohumil", "bohumila", "bohumir", "bohuslav", "bojan", "bojana",
    "boldizsar", "boleslav", "bonaventura", "bonifatius", "bonnie", "bora", "borghild", "boris", "borislav", "borja", "borje", "borut",
    "botvid", "boyan", "boye", "bozena", "bozidar", "brad", "bradley", "brady", "brahmani", "brandon", "branimir", "branislav",
    "branislava", "brankica", "branko", "bratislav", "braulio", "brenda", "brendan", "brent", "brett", "brian", "brianna", "bridget",
    "brigita", "brigitta", "brigitte", "brita", "britt", "britta", "brittany", "bronislav", "bronislava", "brooke", "bror", "bruce",
    "bruna", "bruno", "bryan", "brynjar", "bulent", "burak", "burkhard", "buster", "cagla", "caitlin", "caleb", "calum",
    "calvin", "cameron", "camilla", "camille", "candace", "candida", "candido", "cansu", "carina", "carl", "carla", "carles",
    "carlo", "carlos", "carman", "carmelo", "carmen", "carmine", "carol", "carola", "carolina", "caroline", "carolyn", "carsten",
    "casey", "casper", "cassandra", "catarina", "caterina", "cathal", "catharina", "catherine", "cathy", "cato", "cecile", "cecilia",
    "cecilie", "cecylia", "cedric", "celeste", "celia", "celina", "celine", "celso", "cem", "cesar", "cethlenn", "cetin",
    "cezary", "chad", "chaim", "chandler", "chandra", "chantal", "charalampos", "charlene", "charles", "charlie", "charlotta", "charlotte",
    "chelamma", "chelsea", "cheryl", "cheyenne", "chiara", "chingiz", "chlodwig", "chloe", "chris", "christa", "christel", "christer",
    "christiaan", "christian", "christiane", "christina", "christine", "christoffer", "christoph", "christopher", "chuck", "ciara", "ciaran", "cigdem",
    "cindy", "cinzia", "ciprian", "cipriano", "ciriaco", "ciro", "claes", "claire", "clara", "clarice", "claude", "claudia",
    "claudio", "cleber", "clelia", "clement", "clemente", "clementina", "cloe", "clovis", "clyde", "cole", "colin", "colm",
    "colton", "conan", "concetta", "connie", "connor", "constance", "consuelo", "cora", "cordelia", "corentin", "corina", "cormac",
    "cornelia", "cornelis", "corneliu", "cornelius", "corrado", "courtney", "craig", "cristiana", "cristiano", "cristina", "cristobal", "crystal",
    "csaba", "csilla", "cunningham", "cuthbert", "cynthia", "cyril", "cyrus", "dafne", "dafydd", "dag", "dagfinn", "dagmar",
    "dagmara", "dagny", "dagur", "daichi", "daiki", "daisuke", "daisy", "dakota", "dalia", "dalibor", "dalila", "dalton",
    "damian", "damiano", "damien", "damir", "damjan", "damodar", "damon", "dan", "dana", "danica", "daniel", "daniela",
    "daniele", "danielle", "daniil", "danijel", "danilo", "dante", "danuta", "daphne", "dara", "dardan", "daria", "dario",
    "darius", "dariusz", "darja", "darko", "darren", "darryl", "darya", "daud", "david", "davida", "davide", "davor",
    "davorin", "davy", "dawid", "dawn", "dea", "dean", "deanna", "debbie", "debora", "deborah", "debra", "deepak",
    "dejan", "delfina", "delia", "demetria", "demetrio", "demetrios", "demetrius", "denes", "denis", "denisa", "denise", "deniz",
    "dennis", "derek", "derya", "desideria", "desiderius", "desire", "desiree", "devajuti", "devala", "dezider", "dezso", "diana",
    "diane", "diarmaid", "dick", "didrik", "diego", "dietmar", "dilara", "dimitar", "dimitri", "dimitrij", "dinesh", "dino",
    "dirk", "dmitry", "dobromir", "dobroslav", "dolly", "dolores", "domenico", "dominic", "dominik", "dominika", "dominique", "domonkos",
    "don", "donald", "donat", "donata", "donika", "donna", "donnie", "dora", "doreen", "dorian", "dorina", "doris",
    "dorofey", "dorota", "dorotea", "dorothea", "dorotheos", "dorothy", "dorottya", "dorrit", "dorte", "dorthe", "dositheus", "douglas",
    "draga", "dragan", "dragana", "dragica", "dragisa", "drago", "dragoljub", "dragomir", "dragoslav", "dragutin", "drahomir", "drahomira",
    "drazen", "drusilla", "duane", "duncan", "dunja", "dusan", "dusko", "duygu", "dylan", "ebba", "ebbe", "ebenezer",
    "eberhard", "eda", "edda", "eddie", "eden", "eder", "edgar", "edgaras", "edgardo", "edi", "edina", "edit",
    "edita", "edith", "edla", "edmond", "edmund", "edmundo", "edna", "edo", "edoardo", "edouard", "eduard", "eduardo",
    "eduards", "edurne", "edvard", "edvin", "edward", "edwin", "edwina", "edzard", "eerik", "eero", "eeva", "efim",
    "efraim", "egil", "egon", "eija", "eik", "eileen", "eilert", "einar", "eino", "eithne", "eivind", "eivor",
    "ekanamsha", "ekaterina", "ekkehard", "ekrem", "ela", "elaine", "eldar", "eleanor", "eleazar", "elek", "elemer", "elena",
    "eleonora", "eleonore", "elfrida", "elfriede", "eli", "elia", "eliana", "elias", "elida", "elie", "eliel", "eliezer",
    "elif", "elijah", "elimar", "elin", "elina", "eline", "elio", "elis", "elisa", "elisabet", "elisabeth", "elisabetta",
    "elise", "elisha", "eliza", "elizabeth", "elke", "ella", "elle", "ellen", "elli", "ellie", "ellinor", "elma",
    "elmar", "elmer", "elmira", "elmo", "elna", "elodie", "elof", "elon", "els", "elsa", "else", "elsie",
    "elton", "elvin", "elvir", "elvira", "elvis", "elza", "elzbieta", "ema", "emanuel", "emelie", "emi", "emil",
    "emile", "emilia", "emilian", "emilie", "emilija", "emilio", "emily", "emin", "emina", "emine", "emma", "emmanuel",
    "emmanuelle", "emmy", "emre", "enar", "endel", "endre", "eneko", "engelbert", "enguerrand", "enid", "eniko", "enn",
    "enoch", "enok", "enric", "enrico", "enrique", "enver", "enzo", "ephraim", "ercole", "erhard", "eric", "erica",
    "erich", "erik", "erika", "erin", "erion", "erkki", "erland", "erlend", "erling", "erna", "ernest", "ernesta",
    "ernesto", "erni", "erno", "ernst", "eros", "ervin", "erwan", "erwin", "eryk", "erzsebet", "esben", "esbjorn",
    "esdras", "eskil", "esmeralda", "espen", "estanislao", "esteban", "estelle", "ester", "estera", "estevao", "esther", "eszter",
    "ethan", "ethel", "etienne", "etsuko", "etta", "eudoxia", "eufemia", "eugen", "eugene", "eugenia", "eulalia", "eulogio",
    "eusebio", "eva", "evald", "evan", "evangelina", "evangelos", "eve", "evelin", "evelina", "evelyn", "even", "everly",
    "evert", "evgenia", "evi", "evita", "evzen", "ewa", "ewen", "eystein", "eysteinn", "ezechiel", "ezequiel", "fabian",
    "fabio", "fabiola", "fabrice", "fabrizio", "facundo", "fadil", "faina", "faith", "faiz", "famke", "fanni", "fanny",
    "farah", "farhad", "farid", "farooq", "fatih", "fatima", "fatma", "fatmir", "fatoumata", "fausta", "faustus", "fay",
    "federica", "federico", "fedir", "fedor", "fedora", "felice", "feliciano", "felicien", "felicity", "feliks", "felipe", "felix",
    "femi", "femke", "feodor", "feodora", "ferdinand", "ferdinanda", "ferdinando", "ferenc", "fernan", "fernanda", "fernando", "fidel",
    "filibert", "filip", "filipa", "filipe", "filipp", "filippa", "filippo", "filomena", "finley", "finn", "fiona", "fionnuala",
    "fiorella", "flavia", "flavio", "flemming", "fletcher", "fleur", "flidais", "flora", "florence", "florencia", "florent", "florentina",
    "florestan", "florian", "floriana", "florimond", "folke", "fran", "franca", "frances", "francesc", "francesca", "francesco", "francis",
    "francisca", "francisco", "franciscus", "franciska", "franciszek", "franco", "francois", "francoise", "franjo", "frank", "franklin", "frans",
    "frantisek", "franz", "franziska", "fred", "freddy", "frederica", "frederick", "frederico", "frederik", "fredrik", "fredrika", "frej",
    "freja", "freya", "frida", "fridolf", "fridtjof", "friederike", "friedrich", "frigyes", "fritiof", "fritjof", "frits", "fritz",
    "frode", "fruzsina", "fuad", "fulgence", "fulgencio", "fulvio", "fumiaki", "gabor", "gabriel", "gabriela", "gabriella", "gabrielle",
    "gad", "gael", "gaetan", "gaetano", "gaia", "gaius", "gaizka", "gaja", "galeazzo", "galina", "gareth", "garrett",
    "gary", "gaute", "gavin", "gavriil", "gay", "gaylord", "gedeon", "gediminas", "geert", "geir", "gemma", "genesis",
    "genevieve", "gennady", "gennaro", "genoveva", "geoffrey", "georg", "george", "georges", "georgi", "georgia", "georgina", "georgios",
    "georgy", "gerald", "geraldine", "gerard", "gerd", "gerda", "gereon", "gergely", "gerhard", "german", "germana", "germund",
    "gernot", "gerrit", "gert", "gertrud", "gertruda", "gertrude", "gervasio", "geza", "gezim", "ghassan", "gheorghe", "ghislain",
    "ghulam", "giacomo", "giancarlo", "gianfranco", "gianluca", "gianluigi", "gianmarco", "giannis", "gianpiero", "gianpietro", "giedrius", "gil",
    "gilbert", "gilberto", "gilda", "gilles", "gillian", "gina", "gino", "gintare", "gintautas", "gioacchino", "giorgia", "giorgio",
    "giosue", "giovanna", "giovanni", "girolamo", "gisbert", "gisela", "gisle", "gitte", "giulia", "giuliana", "giuliano", "giulio",
    "giuseppe", "giuseppina", "gizem", "gladys", "glauco", "gleb", "glenda", "glenn", "gloria", "goffredo", "gohar", "gojko",
    "gokalp", "gokhan", "gokturk", "gonzalo", "gopal", "goran", "gorazd", "gordon", "gorm", "gosta", "gottfried", "gotthilf",
    "gotthold", "grace", "graeme", "graham", "grainne", "grant", "grazyna", "greg", "greger", "gregor", "gregorio", "gregory",
    "greta", "gretchen", "grete", "gretel", "grethe", "grigory", "grimaldo", "griselda", "gro", "gry", "grzegorz", "guadalupe",
    "gualberto", "guangqi", "gudmund", "gudrun", "guglielmo", "guido", "guilherme", "guillaume", "gulnar", "gulsen", "gunda", "gunder",
    "gunhild", "gunilla", "gunn", "gunnar", "gunnel", "gunther", "gunvor", "gurli", "gus", "gustaf", "gustav", "gustave",
    "gustavo", "gustaw", "guttorm", "guy", "gwen", "gwendolyn", "gwenllian", "gwyneth", "gyatso", "gyda", "gyongyi", "gyorgy",
    "gyozo", "gyula", "haakon", "hadi", "hadrian", "hafsa", "hagop", "haitham", "hakan", "hakon", "halfdan", "halim",
    "halina", "halla", "halldor", "hallgeir", "hallvard", "halvar", "halvard", "halvdan", "halvor", "hamad", "hamid", "hamilcar",
    "hamish", "hampus", "hamza", "hana", "hande", "hanka", "hanna", "hannah", "hanne", "hannele", "hannelore", "hannes",
    "hannibal", "hanno", "hannu", "hans", "harald", "hardy", "harold", "harper", "harri", "harriet", "harry", "hartmut",
    "hartvig", "haruto", "hasan", "hashim", "hassan", "hatice", "hatun", "hauke", "havard", "hayato", "hazel", "heather",
    "hector", "hedda", "hedwig", "hege", "heidi", "heike", "heikki", "heiko", "heimo", "heinar", "heino", "heinrich",
    "heinz", "heitor", "helen", "helena", "helene", "helga", "helge", "hella", "helle", "helmer", "helmi", "helmut",
    "helvi", "hendrik", "hennadiy", "henning", "henny", "henri", "henrietta", "henriette", "henrik", "henrike", "henrique", "henry",
    "henryk", "herbert", "herborg", "heriberto", "herman", "hermann", "hermanus", "hermenegildo", "hermes", "hermina", "hermione", "herta",
    "hertha", "hideaki", "hideo", "hieronim", "hieronymus", "hilarius", "hilary", "hilda", "hilde", "hildegard", "hilding", "hildur",
    "hilja", "hille", "hillevi", "hilma", "hilmar", "hiram", "hirokazu", "hiroki", "hiroshi", "hiroto", "hiroyasu", "hiroyuki",
    "hisako", "hisham", "hitomi", "hitoshi", "holger", "honorata", "hope", "horst", "hortense", "howard", "hrafn", "hrvoje",
    "hryhorii", "hubert", "hubertus", "huda", "hugh", "hugo", "huguette", "hulda", "humbert", "husnu", "hussein", "huw",
    "hyacinthe", "iain", "ian", "ibolya", "ibrahim", "ichiro", "ida", "ignac", "ignatius", "ignaz", "igor", "ihor",
    "iiro", "iker", "ikshvaku", "ilan", "ilana", "ilario", "ildiko", "ileana", "ilhan", "ilir", "ilja", "ilkka",
    "ilmar", "ilmari", "ilmi", "ilona", "ilse", "ilya", "ilyas", "imad", "iman", "imants", "imelda", "immanuel",
    "imogen", "imran", "imre", "imrich", "ina", "inaki", "india", "indrek", "ines", "inez", "inga", "ingar",
    "inge", "ingeborg", "ingegerd", "ingemar", "inger", "ingmar", "ingo", "ingolf", "ingrid", "ingrida", "ingunn", "ingvald",
    "ingvar", "ingvild", "inigo", "inna", "ioan", "ioana", "ioann", "ioannes", "ioannis", "ionut", "iorwerth", "iosif",
    "ira", "irad", "irakli", "irena", "irenaus", "irene", "ireneusz", "irina", "iris", "irja", "irma", "irmgard",
    "isa", "isaak", "isabel", "isabella", "isabelle", "isaias", "isak", "isao", "ishana", "isidor", "isidora", "isidore",
    "isis", "isla", "islam", "ismael", "ismail", "ismet", "isolde", "issam", "istvan", "itai", "italia", "itziar",
    "iva", "ivan", "ivana", "ivanka", "ivar", "iveta", "ivica", "ivo", "ivona", "ivor", "izabela", "izabella",
    "izak", "izidor", "ja'far", "jaak", "jaakko", "jaan", "jacek", "jacinta", "jack", "jackson", "jacob", "jacopo",
    "jacqueline", "jacques", "jadabharata", "jade", "jadranka", "jadwiga", "jafar", "jagoda", "jaime", "jair", "jake", "jakob",
    "jakov", "jakub", "jalen", "jalmari", "james", "jamie", "jamil", "jamila", "jan", "jana", "janbai", "jane",
    "janet", "janez", "janice", "janina", "janis", "janko", "janne", "jannike", "janos", "janus", "janusz", "jared",
    "jari", "jarkko", "jarl", "jarmila", "jarmo", "jarno", "jaromir", "jaroslav", "jaroslava", "jasmin", "jasmina", "jasmine",
    "jasna", "jason", "jasper", "jaume", "javier", "jawad", "jay", "jayson", "jean", "jean-baptiste", "jean-claude", "jean-jacques",
    "jean-louis", "jean-luc", "jean-marie", "jean-pierre", "jean-yves", "jeanette", "jeanne", "jeannette", "jedediah", "jeff", "jefferson", "jeffrey",
    "jela", "jelena", "jelka", "jelle", "jemima", "jenna", "jennifer", "jenny", "jeno", "jens", "jenson", "jeremiah",
    "jeremias", "jeremy", "jerker", "jermaine", "jeroen", "jerome", "jeronimo", "jerry", "jerzy", "jesper", "jess", "jesse",
    "jessica", "jessie", "jesus", "jethro", "ji-min", "ji-u", "jill", "jim", "jimena", "jimmy", "jindrich", "jiri",
    "jiro", "jitka", "joachim", "joacim", "joakim", "joan", "joana", "joanna", "joanne", "joao", "joaquim", "joaquin",
    "job", "jocelyn", "jocelyne", "jochen", "joel", "jogvan", "johan", "johann", "johanna", "johanne", "johannes", "john",
    "johnny", "jolan", "jolanda", "jolanta", "jon", "jonah", "jonatan", "jonathan", "jone", "jonna", "jonne", "jonny",
    "joona", "joonas", "joost", "joran", "jordanka", "jorg", "jorge", "joris", "jorma", "jorn", "jorunn", "jose",
    "josef", "josefa", "josefina", "josefine", "joseph", "josephine", "joshua", "josiah", "josif", "josip", "jostein", "josu",
    "jouko", "jovan", "joy", "joyce", "jozef", "jozsef", "juan", "juana", "juda", "judas", "judit", "judith",
    "judy", "juha", "juhani", "juho", "jukka", "julia", "julian", "juliana", "juliane", "julianna", "julianne", "julie",
    "julien", "juliette", "julija", "julio", "julius", "juliusz", "junji", "junko", "juraj", "jurgen", "jurgis", "jurij",
    "jussi", "justin", "justina", "justine", "justus", "justyna", "jutta", "juuso", "jyri", "jyrki", "jytte", "kaare",
    "kaarle", "kaarlo", "kacper", "kadir", "kai", "kaija", "kaisa", "kaja", "kajetan", "kaleva", "kalevi", "kalina",
    "kalju", "kalle", "kalman", "kamal", "kamala", "kamil", "kamila", "kamilla", "kamran", "kaori", "kaoru", "kara",
    "kare", "karel", "karen", "kari", "karim", "karin", "karina", "karine", "karl", "karla", "karlis", "karlo",
    "karol", "karola", "karolina", "karoline", "karolis", "karoly", "kasimir", "kaspar", "kaspars", "kasper", "kata", "katalin",
    "katariina", "katarina", "katarzyna", "kate", "katerina", "katharina", "katharine", "katherine", "kathleen", "kathryn", "kathy", "kati",
    "katia", "katie", "katinka", "katja", "katrin", "katrina", "katrine", "katsuhiro", "katsumi", "kauko", "kawthar", "kayla",
    "kaylee", "kazimiera", "kazimira", "kazuaki", "kazuhiro", "kazuhito", "kazuki", "kazuko", "kazuo", "kazuto", "keanu", "keiichi",
    "keijo", "keiko", "keisha", "keisuke", "keith", "kelly", "kelvin", "ken", "ken'ichi", "kenan", "kendra", "kenji",
    "kennedy", "kenneth", "kent", "kentaro", "kenzo", "kersti", "kerstin", "kerttu", "kestutis", "kettil", "kevin", "khadija",
    "khalil", "khatun", "khosrow", "khristofor", "kieran", "kiko", "kilian", "kim", "kimberly", "kimiko", "kimmo", "kinga",
    "kinsley", "kira", "kirill", "kirk", "kirsi", "kirsten", "kirsti", "kirstine", "kitty", "kjartan", "kjell", "kjerstin",
    "kjetil", "klara", "klas", "klaudia", "klaudiusz", "klaus", "klemens", "klement", "kleopatra", "knud", "knut", "kofi",
    "koichi", "koji", "koki", "koldo", "koloman", "konrad", "konstantin", "kornel", "kornelia", "kornelius", "kosta", "kotaro",
    "kotori", "kris", "krista", "kristaps", "kristel", "kristen", "krister", "kristian", "kristiina", "kristin", "kristina", "kristine",
    "kristjan", "krisztina", "krunoslav", "krystof", "krystyna", "krzysztof", "ksenija", "kumiko", "kunibert", "kunigunde", "kuno", "kurt",
    "kustaa", "kuzma", "kwadwo", "kwame", "kwasi", "kyla", "kyle", "kyllikki", "kyoko", "kyosti", "lachlan", "lada",
    "ladislav", "ladislava", "laetitia", "laila", "lajos", "lalla", "lambert", "lamberto", "lana", "lance", "lara", "larisa",
    "larissa", "larry", "lars", "lasse", "laszlo", "latif", "latifa", "laura", "lauren", "laurent", "laurentius", "lauri",
    "lauritz", "lavinia", "lavrentiy", "lawrence", "layla", "lea", "leander", "leandra", "leandro", "lech", "lee", "leia",
    "leif", "leila", "leilani", "leire", "leiv", "lelio", "lemuel", "lena", "lene", "lenka", "lennart", "leo",
    "leon", "leona", "leonard", "leonardo", "leonel", "leonhard", "leonid", "leonora", "leonti", "leontina", "leopold", "lester",
    "leszek", "letitia", "lev", "levente", "levi", "levin", "lewis", "leyla", "lia", "liam", "liana", "libero",
    "libor", "libuse", "lidia", "lidija", "lidiya", "lieke", "liina", "liisa", "liisi", "lila", "lili", "lilia",
    "lilian", "liliana", "lilith", "lilja", "lillian", "lilly", "lily", "lina", "linda", "lindsay", "line", "linn",
    "linnea", "linus", "lionel", "lipot", "liridon", "lisa", "lisbet", "lisbeth", "lise", "liselotte", "lisette", "liv",
    "livia", "liz", "liza", "ljubica", "ljubisa", "ljubo", "ljudevit", "ljudmila", "lloyd", "lluis", "logan", "loic",
    "lola", "lolita", "lone", "lorant", "loredana", "lorena", "lorenz", "lorenzo", "loreta", "loretta", "lorinc", "lorna",
    "lorraine", "lothar", "lotta", "lotte", "lou", "louis", "louise", "lovisa", "lovro", "lubomir", "lubomira", "lubos",
    "luc", "luca", "lucas", "lucia", "luciana", "luciano", "lucie", "lucien", "lucinda", "lucio", "lucius", "lucjan",
    "lucy", "ludger", "ludivine", "ludmila", "ludmilla", "ludo", "ludolf", "ludovic", "ludovica", "ludovit", "ludvig", "ludvik",
    "ludwig", "ludwik", "ludwika", "luigi", "luis", "luisa", "luitgard", "luiza", "luka", "lukas", "luke", "luna",
    "lydia", "lynette", "lynn", "lyubov", "lyudmila", "maaike", "maarit", "mabel", "maciej", "mackenzie", "madeleine", "madhu",
    "madina", "madis", "madison", "mads", "mae", "maeve", "maffeo", "magda", "magdalena", "magdalene", "maggie", "magnar",
    "magne", "magnhild", "magnus", "mahadevi", "mahagauri", "mahanaim", "mahir", "mahmud", "mahmut", "mahound", "mahsa", "maia",
    "maike", "maiken", "maila", "maire", "maite", "maja", "makarios", "maksim", "malak", "malcolm", "malene", "malik",
    "malika", "malin", "malina", "malinda", "malte", "malvin", "malvina", "malwina", "mandy", "manfred", "manisha", "manon",
    "mans", "mansur", "mantas", "manuel", "manuela", "mara", "marat", "marc", "marcel", "marcela", "marcella", "marcelo",
    "marcia", "marcin", "marco", "marcos", "marcus", "marek", "maren", "margaret", "margareta", "margaretha", "margarida", "margarita",
    "marge", "margery", "margherita", "margit", "margita", "margot", "margret", "margrete", "margrethe", "marguerite", "mari", "maria",
    "mariah", "mariam", "marian", "mariana", "mariann", "marianna", "marianne", "mariano", "marica", "marie", "mariel", "marielle",
    "marija", "marijan", "marijana", "marika", "marilyn", "marin", "marina", "marinko", "marinus", "mario", "marion", "marisa",
    "mariska", "marit", "marius", "mariusz", "marja", "marjatta", "marjo", "marjorie", "marjut", "mark", "marketa", "markku",
    "marko", "markus", "marleen", "marlena", "marlene", "marlon", "marta", "marten", "martha", "marthe", "martin", "martina",
    "martine", "martino", "martinus", "marton", "martti", "marvin", "marwa", "mary", "maryam", "marzena", "masaaki", "masahiro",
    "masahito", "masako", "masami", "masanobu", "masanori", "masao", "masaru", "masashi", "masato", "masayuki", "masha", "mason",
    "massimiliano", "massimo", "mate", "matea", "matej", "mateo", "mateusz", "mathias", "mathilde", "matias", "matija", "matilda",
    "matilde", "matjaz", "mats", "matt", "matteo", "matthaus", "matthew", "matthias", "matti", "mattia", "mattias", "mattis",
    "matvey", "matyas", "maud", "mauno", "maura", "maureen", "maurice", "mauricio", "maurits", "maurizio", "mauro", "mavis",
    "max", "maxim", "maximilian", "may", "maya", "meagan", "meaghan", "mecislovas", "medard", "medea", "meelis", "meg",
    "megan", "meghan", "mehmet", "mehrdad", "meinrad", "melania", "melanie", "melchior", "melina", "melinda", "melis", "melisa",
    "melissa", "meliton", "melody", "mels", "melvin", "meng", "mercedes", "meredith", "merete", "meritites", "merve", "mervi",
    "mervyn", "meta", "mette", "mia", "micael", "micaela", "micah", "micha", "michael", "michaela", "michail", "michel",
    "michela", "michelangelo", "michele", "michelle", "michiel", "michiko", "michio", "mieszko", "miguel", "miha", "mihailo", "mihaly",
    "mihkel", "miika", "miina", "mikael", "mikaela", "mike", "mikhail", "mikkel", "mikko", "miklos", "miko", "mila",
    "milada", "milan", "milana", "milda", "mildred", "milena", "miles", "milica", "milivoj", "milja", "milka", "milko",
    "milla", "millicent", "milo", "milorad", "milos", "miloslav", "milovan", "milton", "mina", "mindaugas", "minna", "minoru",
    "mio", "mira", "miranda", "mircea", "mireille", "mirela", "mirella", "miriam", "mirja", "mirjam", "mirjana", "mirka",
    "mirko", "mirna", "miro", "miroslav", "miroslava", "mirsad", "mitja", "mitsuo", "mitsuru", "miyu", "mladen", "modestas",
    "mogens", "mohammad-reza", "mohyeddin", "moira", "mojca", "mojmir", "molly", "mona", "monica", "monika", "monique", "montserrat",
    "morgan", "moric", "moritz", "morten", "moses", "moshe", "motoko", "mstislav", "muhammad", "mukesh", "mulay", "murad",
    "murat", "muriel", "muslim", "mustafa", "mykhailo", "mykola", "mykolas", "myra", "myriam", "nabil", "nada", "nadezhda",
    "nadia", "nadine", "nadir", "nadja", "nafisa", "nahum", "nail", "naima", "najma", "nana", "nanami", "nancy",
    "nandor", "nanna", "naoki", "naoko", "naomi", "naoto", "napoleone", "narcis", "narcisa", "nasser", "natacha", "natale",
    "natalia", "natalie", "nataliia", "nataliya", "natanael", "natascha", "natasha", "natasja", "nate", "nathalie", "nathan", "nathanael",
    "nathaniel", "natsuki", "natsuko", "natsumi", "nazar", "nazario", "nazim", "nebojsa", "necati", "necmettin", "nedeljko", "neferu",
    "neil", "nekane", "nela", "nelly", "nelson", "nemain", "nemanja", "nenad", "nepomuk", "nerea", "nesrin", "nestor",
    "nestori", "neven", "nevena", "nevenka", "nevio", "niall", "niamh", "niccolo", "nicholas", "nico", "nicodemus", "nicola",
    "nicolaas", "nicolas", "nicolaus", "nicole", "nicoletta", "niels", "nigel", "niina", "nika", "nikanor", "nike", "nikita",
    "niklas", "nikodem", "nikola", "nikolai", "nikolaj", "nikolaos", "nikolaus", "nikolay", "nikoline", "nils", "nilufar", "nilufer",
    "nimi", "nina", "nino", "noam", "nobuko", "nobuo", "nobuyuki", "noe", "noel", "nonna", "noora", "nora",
    "norbert", "norberto", "noriaki", "noriko", "norma", "norman", "novak", "nuno", "nur", "nuria", "octavio", "odd",
    "oddvar", "odette", "odo", "odoardo", "odon", "ofelia", "ognjen", "oksana", "ola", "olaf", "olafur", "olaus",
    "olav", "olavi", "ole", "oleg", "oleksandr", "oleksii", "olena", "olga", "olgierd", "oliver", "olivia", "olivier",
    "olle", "olof", "olympia", "omar", "ondrej", "onni", "onno", "onur", "oona", "oreste", "orhan", "oriana",
    "oriol", "orion", "orjan", "orlando", "ornella", "orsolya", "orvar", "osama", "oscar", "oskar", "oskari", "oskars",
    "osman", "osmo", "osmund", "osten", "osvald", "osvaldo", "oswald", "oszkar", "otilia", "otis", "otmar", "oto",
    "ottavio", "ottilia", "ottilie", "otto", "ove", "owen", "ozge", "ozlem", "paavo", "pablo", "paco", "paddy",
    "padmavati", "padraig", "paisley", "pal", "pall", "palle", "paloma", "pamela", "panagiotis", "panchakanya", "pancho", "pantaleon",
    "panteleimon", "paola", "paolo", "paraskeva", "paris", "parker", "pascal", "pasquale", "patrice", "patricia", "patrick", "patrik",
    "patrizia", "patryk", "paul", "paula", "paulina", "pauline", "paulius", "paulo", "paulus", "pausanias", "pavel", "pavla",
    "pavle", "pavlina", "peder", "pedro", "peeter", "peggy", "pekka", "pelle", "penelope", "pentti", "pepe", "per",
    "percival", "pernilla", "pernille", "pero", "pertti", "petar", "pete", "peter", "petko", "petra", "petri", "petro",
    "petronella", "petru", "petrus", "petter", "petur", "philip", "phineas", "phoebe", "phyllis", "pia", "pierluigi", "piero",
    "pierre", "pieter", "pietro", "piia", "pilar", "piotr", "pirjo", "pirkko", "piroska", "pius", "platon", "pol",
    "polina", "pontus", "poul", "prakash", "preben", "predrag", "premysl", "priidu", "priit", "primoz", "priscilla", "prithu",
    "priya", "prosper", "prsnigarbha", "ptolemy", "pula", "purushottama", "pyotr", "quentin", "quinn", "qurban", "rachel", "radbod",
    "radka", "radmila", "radomir", "radoslav", "radovan", "rafael", "raffaella", "rafik", "rafiq", "ragna", "ragnar", "ragnhild",
    "ragnvald", "rahman", "raili", "raimo", "raimondas", "raimundas", "rainer", "raisa", "raivis", "raivo", "rajesh", "rajiv",
    "rajko", "rajmund", "rakel", "ralf", "ralph", "ramesh", "ramesses", "rami", "ramil", "ramon", "ramona", "rana",
    "randall", "randi", "randy", "rani", "raoul", "raphael", "raquel", "rashid", "rasim", "rasmus", "ratko", "ratri",
    "raul", "rauno", "rayan", "raymond", "raymund", "razvan", "rebeca", "rebecca", "rebeka", "rebekka", "recep", "regina",
    "reginald", "regine", "reidar", "reijo", "rein", "reinaldo", "reinhard", "reinhold", "reinier", "reka", "rembrandt", "remo",
    "renat", "renata", "renate", "renato", "renatus", "rene", "renee", "rens", "reuben", "rex", "reza", "rhys",
    "ria", "ricardo", "riccardo", "richa", "richard", "rick", "rifat", "rigmor", "rigobert", "rihards", "riina", "riitta",
    "rikard", "rikke", "riku", "riley", "rima", "rimma", "rina", "rino", "rinus", "risto", "rita", "ritva",
    "roald", "roar", "rob", "robert", "roberta", "roberto", "robin", "rocco", "roch", "rocio", "rodion", "rodolfo",
    "rodrigo", "roel", "roelof", "rogelio", "roger", "roland", "rolando", "rolf", "roma", "roman", "romana", "romeo",
    "romilda", "romina", "romuald", "romy", "ron", "ronald", "ronaldo", "ronan", "ronja", "ronny", "rory", "rosa",
    "rosalba", "rosalia", "rosalie", "rosalind", "rosalinda", "rosanna", "rosario", "rose", "rosemary", "rosina", "rosita", "ross",
    "rossana", "rostislav", "roswitha", "roxana", "roy", "ruben", "ruby", "rudi", "rudolf", "rufina", "rufus", "ruggero",
    "runar", "rune", "ruqayyah", "ruslan", "russell", "rut", "rutger", "ruth", "ruxandra", "ryan", "ryota", "ryszard",
    "ryuichi", "sabin", "sabina", "sabine", "sabrina", "saburo", "sadako", "saddam", "sadik", "sadiq", "safet", "sahar",
    "saida", "sakari", "sakarias", "saki", "saleh", "salim", "sally", "salma", "salome", "salvador", "salvatore", "sam",
    "samad", "samanta", "samantha", "samar", "sami", "samir", "samira", "samson", "samuel", "sancho", "sandor", "sandra",
    "sandro", "sandy", "sanja", "sanna", "sanne", "santeri", "santiago", "saoirse", "sara", "sarah", "sarunas", "sasa",
    "saskia", "satoru", "satoshi", "satu", "saul", "saulius", "savely", "saverio", "sayyid", "scarlett", "scott", "seamus",
    "sean", "sebald", "sebastian", "sebastiano", "sebastien", "selena", "selim", "selina", "selma", "semyon", "senol", "sepideh",
    "sepp", "seppo", "serafim", "serafima", "serena", "serge", "sergej", "sergey", "sergio", "sergiu", "sergius", "serhii",
    "seth", "severin", "severino", "seymour", "shahla", "shailaputri", "shannon", "shapur", "sharon", "shayma", "sheila", "sheldon",
    "shigeru", "shin", "shin'ichi", "shin'ya", "shinji", "shinzo", "shirin", "shirley", "shiro", "shizuka", "shlomo", "shota",
    "siarhiej", "sibel", "sibylla", "sidney", "siegbert", "siegfried", "sieglinde", "sienna", "sietske", "sigfrid", "sigismund", "sigmar",
    "sigmund", "signe", "sigrid", "sigrun", "sigurd", "sigvard", "sigve", "silas", "silja", "silje", "silke", "silva",
    "silvan", "silvana", "silvester", "silvia", "silvija", "silvio", "silviu", "simas", "sime", "simen", "simeon", "simo",
    "simon", "simona", "simonas", "simone", "sinikka", "sinisa", "sinivali", "siobhan", "siri", "sissel", "siv", "sivert",
    "sixten", "sixtus", "skylar", "skyler", "slaven", "slavko", "slavoljub", "slavomir", "slobodan", "snefrid", "snorre", "sofia",
    "sofie", "sofija", "sohil", "solange", "solveig", "sondre", "sonia", "sonja", "sonny", "sophia", "sophie", "soren",
    "sorin", "sotirios", "spencer", "spyridon", "srecko", "sreten", "srivatsa", "staffan", "stale", "stanislaus", "stanislav", "stanislava",
    "stanley", "steen", "stefan", "stefania", "stefanie", "stefano", "steffi", "steinar", "stela", "stella", "stellan", "sten",
    "stepan", "stephane", "stephanie", "stephen", "stevan", "steve", "steven", "stian", "stig", "stina", "stine", "stjepan",
    "sture", "sturla", "stylianos", "styrbjorn", "sulamith", "suleiman", "suleyman", "sulo", "sultan", "sumaya", "sune", "sunniva",
    "suresh", "susan", "susanna", "susanne", "susumu", "suzana", "suzanne", "svanhild", "svante", "svea", "svein", "sveinn",
    "sveinung", "sven", "svend", "svenja", "sverker", "sverre", "svetlana", "sviatoslav", "sybil", "sylvain", "sylvi", "sylvia",
    "sylwester", "szabolcs", "szczepan", "szilard", "szilvia", "szymon", "taavi", "tabita", "tabitha", "tadas", "tadashi", "tadej",
    "tadeusz", "tadhg", "tage", "taha", "tahar", "tahir", "taichi", "tailtiu", "taisto", "takahiro", "takashi", "takayuki",
    "takeshi", "takuya", "talha", "talitha", "tamar", "tamara", "tamas", "tanel", "taneli", "taner", "tanja", "tankred",
    "tapio", "tara", "taras", "tarcisio", "tarek", "tariq", "tarja", "tarjei", "tarkan", "tarmo", "taro", "tasha",
    "tatiana", "tatjana", "tatsuya", "tauno", "tawfik", "taylor", "tea", "teemu", "teimuraz", "tekla", "telma", "tenzin",
    "teo", "teobald", "teodor", "teodora", "teofil", "teofila", "teoman", "terence", "terenzio", "teresa", "teresia", "terez",
    "tereza", "terezia", "terje", "tessa", "tetsu", "tevfik", "thaddeus", "thalia", "thea", "thelma", "theo", "theobald",
    "theodor", "theodora", "theodore", "theodoric", "theodorus", "theophilus", "theresa", "therese", "thierry", "thomas", "thompson", "thor",
    "thoralf", "thorbjorn", "thore", "thorleif", "thorsten", "thorvald", "tiago", "tiberiu", "tiberius", "tibor", "tiffany", "tihamer",
    "tihomir", "tiia", "tiina", "tiit", "tijana", "tikhon", "tilde", "tilman", "tim", "timea", "timo", "timofey",
    "timon", "timotej", "timothee", "timotheos", "timothy", "tin", "tina", "tito", "titus", "titusz", "tivadar", "tiziano",
    "tobias", "toby", "todd", "todor", "toini", "toivo", "tolga", "tom", "tomas", "tomasz", "tomislav", "tommaso",
    "tommi", "tommy", "tomoko", "tonantzin", "toni", "tonibler", "tonis", "tonje", "tonu", "tony", "toomas", "tor",
    "tora", "toralf", "torben", "torbjorn", "tord", "tordis", "tore", "torfinn", "torgeir", "torgny", "torkel", "torleif",
    "tormod", "tornike", "torolf", "torstein", "torsten", "torsti", "toru", "torvald", "toshio", "tova", "tove", "tracy",
    "travis", "tricia", "trine", "tristan", "trond", "troy", "trude", "truls", "tryggve", "tryggvi", "trygve", "tsukasa",
    "tsutomu", "tsuyoshi", "tuba", "tugce", "tuija", "tullio", "tunde", "tuomas", "tuomo", "ture", "tuukka", "tuuli",
    "tycho", "tyko", "tyler", "tymoteusz", "tyra", "ubaldo", "udo", "ueli", "uffe", "ufuk", "ugo", "ugur",
    "ulf", "uliana", "ulla", "ulo", "ulric", "ulrica", "ulrich", "ulrik", "ulrika", "ulrike", "ulrikke", "umberto",
    "unai", "urban", "uri", "uriel", "urmas", "uros", "urpo", "ursula", "ute", "uthman", "uuno", "uwe",
    "vaclav", "vadim", "vagn", "vahe", "vaino", "valborg", "valdar", "valdas", "valdemar", "valdemaras", "valdis", "valentin",
    "valentina", "valentino", "valeria", "valerian", "valerie", "valerio", "valery", "valfrid", "valter", "valtteri", "vanda", "vanessa",
    "vanja", "varahi", "vardan", "varuni", "vasco", "vasil", "vasilisa", "vasily", "vaso", "vedran", "vegard", "veikko",
    "veli", "velibor", "vendelin", "veniamin", "venla", "vera", "verena", "verner", "veronica", "veronika", "veronique", "vesa",
    "veselin", "vesna", "vibeke", "vicente", "victor", "victoria", "vid", "vidar", "vigdis", "viggo", "vijay", "viktor",
    "viktoria", "viktorija", "vilem", "vilhelm", "vilho", "viliam", "vilibald", "vilis", "vilja", "viljar", "viljo", "ville",
    "vilma", "vilmos", "vinayaki", "vincas", "vince", "vincenc", "vincent", "vincenzo", "vinod", "vinzenz", "viola", "violante",
    "violet", "violeta", "violetta", "viorel", "viorica", "virgilio", "virginia", "vita", "vitalii", "vitalijus", "vito", "vitomir",
    "vitor", "vittorio", "vitus", "viveca", "vivian", "viviana", "vladan", "vladimir", "vladimiro", "vladislav", "vladlen", "vlado",
    "vlasta", "vlastimil", "vojislav", "voldemars", "volkan", "volkmar", "volodymyr", "vratislav", "vsevolod", "vuk", "vukasin", "vyacheslav",
    "vytautas", "walburga", "waldemar", "waleed", "walenty", "waleran", "wallace", "walter", "waltraud", "wanda", "warren", "wawrzyniec",
    "wayne", "wenche", "wendy", "werner", "widukind", "wiebke", "wiktor", "wiktoria", "wilfrid", "wilfried", "wilhelm", "wilhelmina",
    "will", "willem", "william", "willy", "wilma", "wim", "winfried", "winifred", "winnie", "winona", "winston", "witold",
    "wladimir", "wojciech", "wolfgang", "wolfhard", "wouter", "wyatt", "xabier", "xaver", "xavier", "xenia", "ximena", "xiomara",
    "yael", "yair", "yakub", "yann", "yannick", "yara", "yaroslav", "yasmin", "yasser", "yaw", "yegor", "yelena",
    "yelisey", "yelizaveta", "yemelyan", "yeshu", "yeshua", "yevdokiya", "yevgeny", "yevhen", "yitzhak", "ylva", "yngvar", "yngve",
    "yogamaya", "yohanan", "yoko", "yolanda", "yoshihiro", "yrjo", "yuji", "yukio", "yumi", "yunus", "yurika", "yuriko",
    "yury", "yusuf", "yusuke", "yves", "yvette", "yvonne", "zacharie", "zachary", "zahra", "zaira", "zaki", "zara",
    "zarko", "zaynab", "zbigniew", "zbynek", "zdenek", "zdenko", "zdravko", "ze'ev", "zelda", "zeljko", "zenaida", "zenobia",
    "zenon", "zephaniah", "zeynep", "zhanna", "zina", "zinaida", "zinoviy", "zita", "zivile", "ziya", "zlata", "zlatan",
    "zlatko", "zoe", "zoey", "zofia", "zoltan", "zora", "zoran", "zorica", "zoticus", "zsanett", "zsofia", "zsolt",
    "zsombor", "zsuzsanna", "zulfiya", "zurab", "zuzana", "zuzanna", "zvezdan", "zvonimir", "zvonko", "zygmunt",
]
private let ambiguousWords: Set<String> = [
    // 2026-10-29 expansion — generated from moderation.js (see its comment); keep in parity.
    "amber", "angel", "april", "art", "august", "autumn", "baby", "baker", "bay", "bell", "best", "bill",
    "bishop", "black", "bright", "brook", "brown", "bush", "candy", "carter", "cash", "chance", "charity", "chase",
    "cherry", "christian", "cliff", "cole", "cook", "crystal", "dale", "dawn", "day", "dean", "dear", "destiny",
    "don", "duke", "earl", "eve", "faith", "field", "fields", "fisher", "ford", "fox", "frank", "frost",
    "genesis", "ginger", "glen", "gold", "grace", "grant", "gray", "green", "grey", "guy", "harmony", "heath",
    "heaven", "hill", "holly", "honey", "hope", "hunter", "iris", "ivy", "jade", "joy", "june", "justice",
    "king", "knight", "lake", "lance", "lane", "liberty", "lily", "long", "love", "major", "mark", "mason",
    "max", "may", "melody", "mercy", "miles", "miller", "misty", "moon", "norm", "olive", "pace", "page",
    "park", "parker", "pat", "patience", "pearl", "penny", "precious", "price", "ray", "read", "reed", "rex",
    "rich", "rivers", "rock", "rod", "rose", "ruby", "sage", "sandy", "serenity", "sharp", "silver", "skip",
    "sky", "snow", "spring", "star", "stone", "storm", "stormy", "sue", "summer", "sun", "sunny", "taylor",
    "trinity", "turner", "van", "violet", "wade", "walker", "wells", "white", "will", "winter", "wolf", "wood",
    "young",
]

// Owner decision 2026-10-30 (mirror of moderation.js NUDGE_ONLY_NAMES): given names that are also
// ordinary words. They stay in ambiguousWords so no HOLD rule treats them as a name, but they still
// drive the soft compose nudge when Capitalized or right after a relationship prefix. "don't" is
// stripped before matching so the contraction never reads as the name Don.
private let nudgeOnlyNames: Set<String> = ["christian", "cole", "dean", "don", "earl"]

// "my ex [Name]", "my friend [Name]", "my sister [Name]" etc.
private let relationshipPrefixes = ["my ex ", "my friend ", "my bf ", "my gf ",
    "my boyfriend ", "my girlfriend ", "my sister ", "my brother ",
    "my mom ", "my dad ", "my mother ", "my father ",
    "my coworker ", "my boss ", "my roommate ", "my neighbor ",
    "this girl ", "this guy ", "this boy ", "this man ", "this woman "]

// ── likelyFirstName (owner decision 2026-10-29) ──────────────────────────────
// A SOFT signal, never a hold: "does this text mention a likely first name?"
// Drives the non-blocking compose nudge. Bare first names stay ALLOWED (N-17).
// Rule (mirror of moderation.js likelyFirstName, pinned by detector-parity):
// a token whose folded lowercase form is in commonNames and not in
// ambiguousWords / safeCapitalizedWords, and that is Capitalized in the
// original text, or lowercase but directly after a relationship prefix.
func likelyFirstName(_ raw: String) -> Bool {
    if raw.isEmpty { return false }
    let text = raw.count > 2000 ? String(raw.prefix(2000)) : raw
    let canon = foldLetterformsKeepCase(text)
        .replacingOccurrences(of: "\\b[Dd]on['’]t\\b", with: " ", options: .regularExpression)
    let safeCapitalizedWords: Set<String> = ["i", "im", "ive", "ill", "id", "god", "christmas", "easter", "halloween", "valentines"]
    // Capitalized tokens: first letter uppercase, rest lowercase ASCII letters, length >= 2.
    var current = ""
    var tokens: [String] = []
    for ch in canon {
        if ch.isLetter { current.append(ch) } else { if !current.isEmpty { tokens.append(current); current = "" } }
    }
    if !current.isEmpty { tokens.append(current) }
    for tok in tokens {
        guard tok.count >= 2, let first = tok.first, first.isUppercase, first.isASCII else { continue }
        let rest = tok.dropFirst()
        guard rest.allSatisfy({ $0.isLowercase && $0.isASCII }) else { continue }
        let w = tok.lowercased()
        if nudgeOnlyNames.contains(w) { return true }
        if !commonNames.contains(w) { continue }
        if ambiguousWords.contains(w) || safeCapitalizedWords.contains(w) { continue }
        return true
    }
    let lowered = canon.lowercased()
    for prefix in relationshipPrefixes {
        var searchStart = lowered.startIndex
        while let r = lowered.range(of: prefix, range: searchStart..<lowered.endIndex) {
            let after = lowered[r.upperBound...]
            let tok = after.split(whereSeparator: { !($0.isLetter && $0.isASCII) }).first.map(String.init) ?? ""
            if !tok.isEmpty && nudgeOnlyNames.contains(tok) { return true }
            if !tok.isEmpty && commonNames.contains(tok) && !ambiguousWords.contains(tok) { return true }
            searchStart = r.upperBound
        }
    }
    return false
}

func containsNameOrIdentifyingInfo(_ text: String) -> Bool {
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

    // Full-name shape: two consecutive Capitalized words ("Vera Marchetti").
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
    // 2026-10-07 review: NO availability pre-read. The old users-by-handle
    // query was ALWAYS permission-denied (a list query can't satisfy the
    // per-doc users read rule), so the catch branch fired on every signup
    // and silently replaced every word-pair handle with the anonymous_ UUID
    // fallback — the generator below this line was dead code in production.
    // (handles/{h} point gets are now admin-only too — de-anon fix.) No read
    // is needed: commitUserDocClaimingHandle's batched create is the arbiter;
    // a collision just fails that commit and draws a fresh candidate.
    return "\(adj)_\(noun)_\(num)"
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
    /// A2 (2026-10-28): explicit sexual detail (mirror of server MOD_SEXUAL_REVIEW).
    /// Same message as .sexual, but overridable ("post anyway") — the server
    /// HOLDS it for review rather than hard-deleting.
    case sexualReview
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

// 2026-07-28 (server A.5 #2 parity): mirror of server collapseRepeats — 3+
// identical chars → ONE, restoring vowel-padded words ("spiiiic" → "spic")
// that the keep-two collapse above can't ("spiic" misses \bsp[i1]ck?\b).
// Both collapsed forms are checked; this one covers padding inside the
// single-letter parts of a pattern, collapseForModeration covers patterns
// that REQUIRE a doubled letter ("nigggger" → "nigger").
private func collapseSinglesForModeration(_ text: String) -> String {
    text.replacingOccurrences(of: "(.)\\1{2,}", with: "$1", options: .regularExpression)
}

// 2026-07-28: mirror of server deLeetCrisisExtra — glyphs NOT in the shared
// homoglyph map: 6/9 → g ("9ook"), ( and < → c ("(oon"). Applied before the
// collapse passes, same order as the server.
private func deLeetExtraForModeration(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    for ch in text {
        switch ch {
        case "6", "9": result.append("g")
        case "(", "<": result.append("c")
        default: result.append(ch)
        }
    }
    return result
}

private func stripSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: " ", with: "")
}

func contentViolation(in text: String) -> ContentViolationType? {
    let normalized = normalizeForModeration(text)
    // 2026-07-28 (server A.5 #2 parity): the collapsed forms are built from
    // the extra-de-leeted text (6/9→g, (/<→c) and a 3+→1 collapsed form is
    // added, so leet+padding combos ("ni999er", "spiiiic", "9ook") are caught
    // at compose time — matching the server, which would otherwise silently
    // hold the post / hard-delete the reply.
    let deLeeted = deLeetExtraForModeration(normalized)
    let collapsed = collapseForModeration(deLeeted)
    let collapsedSingle = collapseSinglesForModeration(deLeeted)
    let noSpaces = stripSpaces(normalized)
    let collapsedNoSpaces = stripSpaces(collapsed)

    // Check all forms for maximum evasion resistance
    let forms = [normalized, collapsed, collapsedSingle, noSpaces, collapsedNoSpaces]

    // --- Slurs and hate speech ---
    // Word-boundary-anchored slurs mirror the server MOD_HATE fix: unanchored,
    // "sp[i1]ck?" matched "suspicious"/"auspicious", "c[o0][o0]n" matched
    // "cocoon"/"raccoon"/"tycoon", "g[o0][o0]k" matched "gobbledygook" — all
    // routing routine writing to .slur (blocks compose; server hard-deletes the
    // reply). The (?!... armor) exclusion spares "a chink in the/his armor".
    // A2: shared with the server's DEHUMANIZING_GROUP / DEHUMANIZING_WORD (moderationLogic.js).
    let dehumanizingGroup = "(women|men|girls|boys|females|males|gays|gay people|lesbians|trans people|trans folks|jews|jewish people|muslims|christians|catholics|hindus|blacks|black people|whites|white people|asians|mexicans|latinos|arabs|indians|chinese|africans|immigrants|migrants|refugees|foreigners|feminists|liberals|conservatives|republicans|democrats|boomers|zoomers|autistic people|disabled people|fat people|poor people|homeless people)"
    let dehumanizingWord = "(worthless|trash|garbage|subhuman|vermin|animals|scum|parasites|filth|filthy|disgusting|a disease|a plague|cockroaches|rats)"
    let slurPatterns = [
        "n[i1!*]gg", "f[a@*]gg", "r[e3]t[a@]rd", "tr[a@]nny", "d[yi1]ke",
        "\\bch[i1]nks?\\b(?!\\s+in\\s+\\w+\\s+armou?r)", "\\bsp[i1]ck?s?\\b", "\\bk[i1]kes?\\b", "\\bw[e3]tb[a@]cks?\\b", "\\bg[o0][o0]ks?\\b",
        "\\bc[o0][o0]ns?\\b", "towelhead", "raghead", "beaner", "zipperhead",
        // A2 (2026-10-28 audit): group-dehumanizing hate (mirror of server
        // MOD_DEHUMANIZING — keep the group/word lists identical). "all women are
        // worthless trash", "men are subhuman and should be exterminated" published
        // live. Hard-blocked at compose like slurs; the server HOLDS (never deletes).
        "\\b(all|every|most)\\s+" + dehumanizingGroup + "\\s+(are|is|r)\\s+(just\\s+|nothing but\\s+|literally\\s+)?" + dehumanizingWord + "\\b",
        "\\b" + dehumanizingGroup + "\\s+(are|is|r)\\s+(all\\s+)?(just\\s+|nothing but\\s+|literally\\s+)?" + dehumanizingWord + "\\b",
        "\\b" + dehumanizingGroup + "\\s+(should|need to|ought to|deserve to|must)\\s+(all\\s+)?(be\\s+)?(exterminated|wiped out|put down|gassed|eradicated|killed|erased|eliminated|slaughtered|die|hang)\\b",
        "\\bexterminate\\s+(all\\s+|the\\s+)?" + dehumanizingGroup + "\\b",
        "\\bsubhumans?\\b",
        "\\b(should|need to|ought to|deserve to|must) be exterminated\\b",
    ]
    for form in forms {
        for pattern in slurPatterns {
            if form.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return .slur }
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
        // A2 (2026-10-28 audit): third-person PHYSICAL forms (mirror of server
        // MOD_THREAT). Plain "hurt him/her" stays out — emotional hurt is routine.
        "going to hurt him so bad", "gonna hurt him so bad", "going to hurt her so bad", "gonna hurt her so bad",
        "going to hurt them so bad", "gonna hurt them so bad", "want to hurt him so bad", "want to hurt her so bad",
        "beat him up", "beat her up", "beat them up",
        "break his legs", "break her legs", "break his jaw", "break her jaw", "break his face", "break her face",
        "smash his face", "smash her face", "bash his head", "bash her head",
        "make him bleed", "make her bleed", "put him in the hospital", "put her in the hospital",
    ]
    // Route through crisisPhraseMatch (2026-07-19 audit) so threat detection has
    // the SAME de-leet/de-confusable/de-space normalization the server applies via
    // matchesCrisisPhrase(MOD_THREAT) — otherwise obfuscated threats the server
    // holds ("k i l l you", leet forms) passed the client with no warning.
    if crisisPhraseMatch(text, threatPhrases) { return .threat }

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
        // 2026-07-27 NCII / revenge-porn threats (mirror of index.js MOD_HARASSMENT).
        "leak your nudes", "post your nudes", "share your nudes", "expose your nudes",
        "post your nudes online", "send your nudes to everyone", "leak your pics",
        "leak your photos", "post your private pics", "still have your nudes",
        "everyone will see your nudes", "revenge porn", "post the pics you sent",
        // 2026-07-27 doxxing / expose-an-ex threats.
        "dox you", "doxx you", "expose you online", "expose you to everyone",
        "post your address", "share your address", "post your number",
        "post your real name", "reveal your identity", "expose your identity",
        "everyone will know where you live", "tell everyone where you live",
        "post where you work", "everyone will know who you really are",
    ]
    // Same parity fix as threat above: matchesCrisisPhrase(MOD_HARASSMENT) on the
    // server de-leets/de-spaces, so "ky5" / "k i l l yourself" were held server-
    // side but slipped the client's plain contains(). crisisPhraseMatch mirrors it.
    if crisisPhraseMatch(text, harassmentPhrases) { return .harassment }

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
    // Checked across all four forms (2026-07-22 M2): the server's MOD_SEXUAL now
    // runs through matchesEvasionRegex (H2 fix), so "p o r n" / leet forms are
    // held server-side — the client must warn on the same inputs or the user
    // posts something that silently never goes live.
    for form in forms {
        for pattern in sexualPatterns {
            if form.range(of: pattern, options: .regularExpression) != nil { return .sexual }
        }
    }
    // A2 (2026-10-28 audit): explicit sexual detail → .sexualReview (overridable;
    // server HOLDS, never deletes). Mirror of server MOD_SEXUAL_REVIEW incl. the
    // guards: "fucked me over/up/around/off" and the exclamation "fuck me, i miss
    // him" must NOT match; bare "sex"/"dick" are deliberately absent.
    let sexualReviewPatterns = [
        "\\bhis dick\\b", "\\bmy dick\\b", "\\bher pussy\\b", "\\bmy pussy\\b",
        "\\bsuck my\\b", "\\beat me out\\b", "\\bate me out\\b",
        "\\bfucked me\\b(?!\\s+(over|up|around|off)\\b)",
        "\\bfuck me\\b(?=\\s+(hard|harder|now|again|like|in the|on the|daddy|baby|so good|good|right|slow|senseless|all night|tonight|till|until)\\b)",
        "\\bcock in\\b", "\\bhis cock\\b", "\\btits out\\b", "\\bfinger(ed|ing) me\\b",
    ]
    for form in forms {
        for pattern in sexualReviewPatterns {
            if form.range(of: pattern, options: .regularExpression) != nil { return .sexualReview }
        }
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
    case .sexual, .sexualReview:
        return "this contains sexual content that isn't appropriate for toska."
    case .spam:
        return "this looks like it might be spam or promotional content."
    case .harassment:
        return "this looks like it's directed at hurting someone. toska is for expressing your own feelings, not tearing others down."
    case .link:
        return "toska doesn't allow links. this is an anonymous space — keep it about the words."
    }
}

