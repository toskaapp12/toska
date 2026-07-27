// ============================================================
// Pure moderation classifiers (no Firestore)
//
// Extracted from index.js — these are the phrase-list constants and pure
// text classifiers that decide WHAT a piece of content trips on. They do not
// touch Firestore (`db`/FieldValue/Timestamp), Auth, or Messaging; the Cloud
// Function triggers in index.js compose them. Kept self-contained so the test
// suite and the crisis-parity test can exercise the classifiers in isolation.
//
// Detector primitives (URL detection, name/identifying-info detection, and the
// evasion-resistant normalizer) live in ./moderation and are imported below.
// ============================================================

const {
  containsNameOrIdentifyingInfo,
  aggressiveNormalizeForNameMatch,
  containsURL,
} = require("./moderation");

// ============================================================
// PII and URL detection helpers (shared across moderation triggers)
// ============================================================

const socialPatterns = [
  /\b(instagram|insta|snapchat|tiktok|twitter|facebook|linkedin|discord|reddit|telegram|whatsapp|signal|bluesky|threads)\b/i,
  /@[a-zA-Z][a-zA-Z0-9._]{2,}/,
];

function hasPhoneNumber(text) {
  // N-13 (2026-06-10 re-review): the original stripped ALL separators and counted
  // total digits >= 10, so any text with 10+ digits across independent short
  // tokens false-positived as a phone — year lists ("we dated 2019 2020 2021
  // 2022 2023"), score/duration/weight lists ("21 19 23 17 25"), etc. (the M-2
  // phone-FP class, fixed only in the parallel moderation.js detector). A first
  // pass keyed on "few digit groups" still FP'd 4-element lists AND dropped
  // many-group international numbers ("+33 6 12 34 56 78"). The robust model:
  // match phone-SHAPED patterns, not digit totals. A LIST of independent numbers
  // matches none of these shapes; real phones (incl. +CC international) do.
  // T-10 (2026-06-11): corrected a stale claim here. Fully-spaced single digits
  // ("5 5 5 1 2 3 4 5 6 7") are NOT caught by the downstream
  // containsNameOrIdentifyingInfo either — its digit heuristic strips
  // `\b\d{1,3}\b` single/short tokens, so a fully-spaced phone reaches zero
  // digits. This is a shared, accepted blind spot (both detectors agree on real
  // and formatted phones, incl. +CC); a fully-letter-spaced-out phone is rare
  // and not worth the FP cost of matching arbitrary single-digit runs.
  const patterns = [
    /\+\d[\d\s().\-]{7,}\d/g,                 // international, leading +
    /\b00\d[\d\s().\-]{7,}\d/g,               // international, leading 00
    /\(?\d{3}\)?[\s.\-]\d{3}[\s.\-]\d{4}\b/g, // NANP 3-3-4 with separators
    /\b\d{10,11}\b/g,                          // bare contiguous 10–11 digit run
  ];
  // Crisis hotlines (digits only, with the US long-distance 1 stripped) must NOT
  // read as a personal number — e.g. "text 1-800-273-8255 if you're struggling".
  const crisis = new Set(['988', '741741', '8002738255', '8007997233', '8006564673']);
  for (const re of patterns) {
    const matches = text.match(re);
    if (!matches) continue;
    for (const cand of matches) {
      const digits = cand.replace(/\D/g, '');
      if (digits.length < 10) continue;
      if (crisis.has(digits) || crisis.has(digits.replace(/^1/, ''))) continue;
      return true;
    }
  }
  return false;
}

const emailPattern = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/;
const addressPattern = /\d+\s+[A-Za-z]+\s+(street|st|avenue|ave|boulevard|blvd|drive|dr|lane|ln|road|rd|way|place|pl|court|ct|circle|cir|terrace|trail|parkway|pkwy)\b/i;

// Phrases that strongly indicate someone is sharing identifying info.
// We deliberately removed the looser entries that produced false positives
// on benign sentences:
//   "her/his/their name is" → matches "his name is mud", "her name is karen"
//   "lives in/on" → matches "lives in fear", "lives on hope"
//   "works at" → matches "works at the heart of it"
//   "find me" → matches "find me a reason to..."
//   "goes to" → matches "goes to show that..."
// What remains is wording that is much harder to use innocently in a post.
const identifyingPhrases = [
  "lives at",
  "school name",
  "phone number", "my number", "text me", "call me",
  "dm me", "follow me", "look me up",
  "last name", "full name",
  // N-15 (2026-06-10 re-review): removed "apartment"/"apt "/"suite " — loose
  // substrings that flagged "adapt to change", "the suite life", etc. Real unit
  // numbers are caught by moderation.js's gated regex (apt/unit/suite + number),
  // reached via containsNameOrIdentifyingInfo below.
];

function containsPII(text) {
  const lower = text.toLowerCase();
  if (socialPatterns.some((p) => p.test(text))) return true;
  if (hasPhoneNumber(text)) return true;
  if (emailPattern.test(text)) return true;
  if (addressPattern.test(text)) return true;
  if (identifyingPhrases.some((phrase) => lower.includes(phrase))) return true;
  // Defense in depth: validatePost / validateReply already delete on the
  // create trigger, but onPostUpdated / onReplyUpdated / onMessageCreated
  // moderation runs through this helper. Without delegation here, an editor
  // (or a tampered client editing into an existing doc) could slip a name
  // past the soft-flag pipeline. The delegated detector is a strict
  // superset of the checks above; the redundant calls above are kept for
  // clarity and because they run cheaply on early returns.
  if (containsNameOrIdentifyingInfo(text)) return true;
  return false;
}

// containsURL is imported from ./moderation (T-10, 2026-06-11) — the single
// shared URL detector, so the moderation HOLD decision (moderation.js Layer-1)
// and the pii-vs-abuse_link LABEL decision here consult the exact same matcher.

// ============================================================
// Shared moderation patterns
//
// Previously duplicated inside onPostCreated, onReplyCreatedModerate,
// and onMessageCreatedModerate — three near-identical copies meant any
// new slur, threat phrase, or harassment pattern had to be edited in
// three places. Drift was a real risk. These constants are the single
// source; the three triggers compose them (with surface-specific
// extras like spamPatterns for posts only).
//
// Adding a new pattern: extend the relevant array here. To make it
// surface-specific, keep it inline in the trigger that needs it.
// ============================================================

const MOD_HATE = [
  /n[i1!]gg/i, /f[a@]gg/i, /r[e3]t[a@]rd/i, /tr[a@]nny/i, /d[yi1]ke/i,
  // Word-boundary-anchored so a slur substring inside an innocent word no
  // longer flags: unanchored these matched "suspicious"/"auspicious" (spic),
  // "cocoon"/"raccoon"/"tycoon" (coon), "scum on" (cum on) — routing routine
  // grief writing to hate_speech/sexual_content, which HARD-DELETES a reply
  // (irrecoverable). The narrow (?!... armor) exclusion spares the common
  // idiom "a chink in the/his/her armor" while still catching the slur.
  /\bch[i1]nks?\b(?!\s+in\s+\w+\s+armou?r)/i, /\bsp[i1]ck?s?\b/i, /\bk[i1]kes?\b/i, /\bw[e3]tb[a@]cks?\b/i, /\bg[o0][o0]ks?\b/i,
  /\bc[o0][o0]ns?\b/i, /towelhead/i, /raghead/i, /beaner/i, /zipperhead/i,
];

// Kept in parity with the client threatPhrases (ContentModeration.swift). Bare
// "blow up"/"beat you"/"burn down"/"shoot up" were removed: they substring-match
// grief/venting ("blow up at him", "don't beat yourself up", "life is burning
// down", "growth shot up") and were silently HOLDING those posts server-side
// while the (narrowed) client passed them with no "under review" notice. The
// targeted forms below catch real threats and are mirrored on the client so the
// user is warned on exactly what the server holds.
const MOD_THREAT = [
  "kill you", "kill him", "kill her", "kill them",
  "shoot you", "shoot him", "shoot her", "shoot them",
  // 2026-07-01: the bare-phrase removal above over-narrowed to single fixed
  // strings ("shoot up the", "burn your house") and dropped classic
  // determiner/possessive phrasings — "burn down your house", "shoot up her
  // school" published live with no hold. Enumerate the determiner/possessive
  // continuations instead: still immune to the venting false-positives the
  // narrowing targeted ("life is burning down", "growth shot up" match none
  // of these), but no longer blind to who/whose.
  "shoot up the", "shoot up your", "shoot up his", "shoot up her",
  "shoot up their", "shoot up my", "shoot up a school",
  "stab you", "stab him", "stab her", "stab them",
  "bomb you", "bomb your", "blow you up", "blow up your",
  "burn your house", "burn his house", "burn her house", "burn their house",
  "burn down your", "burn down his", "burn down her", "burn down their",
  "rape you", "rape her", "rape him",
  "find you and", "find where you live", "know where you live",
  // "coming for you" instead of bare "come for you": the substring matcher
  // flagged routine breakup logistics ("come for your things/stuff") as a
  // targeted_threat. The present-continuous form keeps the threat coverage
  // without colliding with "come for your…".
  "hunt you down", "coming for you",
  "gonna hurt you", "going to hurt you",
  "beat you up", "beat the shit",
  "curb stomp", "slit your throat", "bash your head",
  "put a bullet", "put you in the ground",
];

const MOD_SEXUAL = [
  /porn/i, /hentai/i, /\bxxx\b/i,
  /\bnudes\b/i, /send nudes/i, /dick pic/i, /pussy pic/i,
  /jerk off/i, /jack off/i, /masturbat/i,
  /\bcum on\b/i, /\bcum in\b/i, /creampie/i,
  /blowjob/i, /blow job/i, /handjob/i, /hand job/i,
  /anal sex/i, /oral sex/i,
  /sex tape/i, /sextape/i, /sext me/i, /sexting/i,
  /onlyfans/i, /only fans/i, /nsfw/i,
  // Parity with client sexualPatterns (ContentModeration.swift): these were
  // client-only, so the abuse they name published live past the server gate.
  /choke me/i, /f[u*]ck me daddy/i,
  /\br34\b/i, /rule ?34/i,
  /hook ?up/i, /booty ?call/i,
];

// Kept a SUPERSET of the client harassmentPhrases (ContentModeration.swift).
// The server is the real trust boundary (the client is bypassable and posts
// can be edited after publish); a server list narrower than the client let
// directed abuse ("everyone hates you", "no one will miss you", "jump off a
// bridge") pass auto-detection while the client merely warned. Now at parity.
const MOD_HARASSMENT = [
  "kill yourself", "kys", "go die", "you should die",
  "hope you die", "go hang yourself", "neck yourself",
  "drink bleach", "jump off a bridge",
  "nobody likes you", "everyone hates you",
  "the world is better without you",
  "youre worthless", "you're worthless",
  "youre pathetic", "you're pathetic",
  "you deserve to suffer", "you deserve to die",
  "go away and never come back",
  "no one will miss you", "noone will miss you",
  // 2026-07-27 NCII / revenge-porn threats (breakup-specific harm). Threatening
  // to leak/post an ex's intimate images. Distinctive multi-word phrases, so
  // substring-safe. Held for review like other harassment.
  "leak your nudes", "post your nudes", "share your nudes", "expose your nudes",
  "post your nudes online", "send your nudes to everyone", "leak your pics",
  "leak your photos", "post your private pics", "still have your nudes",
  "everyone will see your nudes", "revenge porn", "post the pics you sent",
  // 2026-07-27 doxxing / expose-an-ex threats. The PII detector catches actual
  // addresses/numbers/socials; these catch the THREAT-to-expose intent.
  "dox you", "doxx you", "expose you online", "expose you to everyone",
  "post your address", "share your address", "post your number",
  "post your real name", "reveal your identity", "expose your identity",
  "everyone will know where you live", "tell everyone where you live",
  "post where you work", "everyone will know who you really are",
];

// Explicit, high-urgency crisis statements — held AND page admins
// (onPostCreatedAlertAdmins). 2026-06-01: expanded with direct vocabulary,
// common slang/euphemisms, contractions, and frequent misspellings. Matching
// runs through matchesCrisisPhrase, which normalizes leet/unicode/spaced
// evasions, so we list canonical lowercase forms here.
const MOD_CRISIS_EXPLICIT = [
  // direct suicide vocabulary + common misspellings
  "suicidal", "suicide", "suicidel", "sucide", "sucidal", "suiside", "suacide",
  // self-killing intent
  "kill myself", "killing myself", "kill my self", "want to kill myself",
  "wanna kill myself", "going to kill myself", "gonna kill myself",
  "off myself", "end myself", "delete myself", "unalive", "unalive myself",
  // 2026-07-17 red-team extension: gerund form — word-boundary matching means
  // "unalive" does NOT match "unaliving" ("thinking about unaliving tonight").
  "unaliving",
  // 2026-07-27 algospeak extension (explicit — unambiguous suicide references):
  // "sewerslide" (suicide), "self deletion"/"self delete" (self-deletion coded
  // form). Distinctive multi-char forms, safe as substrings.
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
  // Non-English explicit crisis (2026-06-11): the detector was English-only, so
  // a non-English user in crisis got NO hold/banner/admin page — the biggest
  // clinical gap for an app that already ships curated foreign hotlines. This
  // is a curated STARTER set for the highest-volume languages (Spanish,
  // Portuguese, French) covering direct suicidal intent + self-harm. It is NOT
  // comprehensive — a full i18n crisis effort needs native-speaker review per
  // language. Both accented and unaccented forms are included since not all
  // input is normalized identically.
  //
  // T-4 (2026-06-11 re-review): the reflexive self-harm verbs (hacerse daño,
  // lastimarse, se faire du mal) are RELATIONAL when prefixed with a 2nd/3rd
  // person — "tu vas me faire du mal" / "va a hacerme daño" = "[you/he] will
  // hurt ME", a normal statement about an ex, NOT self-harm. Substring-matching
  // the bare verb explicit-paged admins on those. Fix: require first-person
  // self-intent framing here (quiero/voy a … / je veux/vais … / envie de me …).
  // Genuinely-ambiguous hyperbole ("envie de mourir de honte", "voy a matarme a
  // trabajar", "mejor muerto" about a 3rd party) is moved to MOD_CRISIS_SOFT
  // below — still HELD for review, just not paging a human. A native speaker
  // should do a final pass per language.
  // Spanish — unambiguous self-directed intent
  "quiero morir", "no quiero vivir", "ya no quiero vivir", "quiero suicidarme",
  "voy a suicidarme", "quiero matarme", "me quiero matar",
  "acabar con mi vida", "terminar con mi vida", "quitarme la vida",
  "quiero hacerme dano", "quiero hacerme daño", "voy a hacerme dano", "voy a hacerme daño",
  "quiero lastimarme", "voy a lastimarme",
  // Portuguese
  "quero morrer", "nao quero viver", "não quero viver", "vou me matar",
  "tirar minha vida", "acabar com minha vida",
  // French — first-person self-intent framing (excludes relational "tu vas /
  // il va me faire du mal")
  "je veux mourir", "me suicider", "je vais me suicider",
  "mettre fin a mes jours", "mettre fin à mes jours",
  "veux me faire du mal", "vais me faire du mal", "envie de me faire du mal",
];

// Softer distress / hopelessness — held for review (concerningContent) but
// NOT paged, to avoid fatiguing the admin alert with everyday venting.
const MOD_CRISIS_SOFT = [
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
  // T-4 (2026-06-11): non-English phrases demoted here from the explicit tier
  // because they false-positive on hyperbole/3rd-party speech and were paging
  // admins. Still HELD for review (over-hold = the safe direction), just not
  // paged. "envie de mourir" → also "envie de mourir de honte/rire" (die of
  // shame/laughter); "voy a matarme" → also "matarme a trabajar" (work myself
  // to death); "mejor muerto/muerta" → can describe a 3rd party/character.
  "envie de mourir", "voy a matarme", "mejor muerto", "mejor muerta",
  // #5 (2026-06-11 crisis red-team): real soft-tier disclosures that slipped
  // through entirely (no hold, no check-in). Added to the soft tier — held +
  // gentle check-in, never paged (over-hold is the safe direction here).
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
  // 2026-07-27 algospeak extension (SOFT — held for review + gentle check-in,
  // never paged; over-hold is the safe direction). These are matched as
  // standalone word-boundary tokens by matchesCrisisPhrase (pNoSpace <= 3), so
  // they do NOT fire inside innocent words:
  //   "sa"/"s.a." (sexual assault), "csa" (childhood SA), "dv" (domestic
  //   violence) — survivor DISCLOSURES: routed here (support + review), never
  //   to the abuse-takedown lane. "sh" (self-harm) shorthand.
  //   ("si" for suicidal ideation deliberately EXCLUDED — collides with the
  //   very common Spanish "si"/"sí".)
  // "yeet myself" (flippant kms shorthand) + "grippy sock" (psych-ward
  // hospitalization reference) are distinctive multi-char coded forms.
  // (pro-ED tags proana/thinspo etc. were considered but EXCLUDED: the
  // space-stripped fallback collides them with "pro analyst"/"thin spot".)
  "sa", "csa", "dv", "sh", "yeet myself", "grippy sock",
];

// Derived so MOD_EXPLICIT_CRISIS is, by construction, a subset of
// MOD_CONCERNING — preventing the 2026-06-01 class of bug where an explicit
// phrase ("suicidal") was paged-worthy but absent from the hold list.
const MOD_EXPLICIT_CRISIS = MOD_CRISIS_EXPLICIT;
const MOD_CONCERNING = [...MOD_CRISIS_EXPLICIT, ...MOD_CRISIS_SOFT];

// Evasion-resistant crisis matcher (2026-06-01). A plain lowercase
// `includes` misses leetspeak ("su1c1dal"), unicode confusables/fullwidth
// ("𝐬𝐮𝐢𝐜𝐢𝐝𝐚𝐥"), and spaced-out letters ("s u i c i d e"). We reuse the PII
// detector's aggressiveNormalizeForNameMatch (canonicalize → fold unicode →
// de-leet → collapse single-letter chains) and also test a punctuation/space-
// stripped form so "kill myself" matches "k i l l m y s e l f" → "killmyself".
// Crisis posts are HELD for review (not deleted), so leaning toward
// over-detection is the intended, safe direction.
// Ambiguous-glyph fold: "1", "!", "|" commonly stand in for BOTH "i" and "l"
// ("k1ll", "ki11", "su1c1dal", "ki||"), and real text mixes positions freely
// ("k1ll myse1f" has an i-position AND an l-position "1"). Substituting the
// whole class uniformly (an all-i form and an all-l form, the previous
// approach) misses every mixed-position case, so instead we collapse the
// entire ambiguous class — including literal "i" and "l" — to one symbol in
// BOTH the text and the phrase, making the match position-independent.
// Crisis-only (kept OUT of the name/PII path, where !/| and i↔l collapsing
// would false-positive); over-detection is the accepted-safe direction here.
function foldAmbiguousIL(s) {
  return s.replace(/[1!|il]/g, "l");
}

// 2026-07-27 algospeak hardening — evasions the normalizer didn't defeat:
// (a) repeated-character padding ("suuuuicide", "kmsss", "dieee"); collapse 3+
//     identical chars to one. 3+ (not 2+) leaves real doubles ("kill","really")
//     untouched.
// (b) crisis-only extra de-leet for glyphs NOT in the shared NAME_LEET_MAP
//     (kept out of the name/PII path to avoid FP there): 6/9->g and (/<->c, so
//     "9rippy sock" / "sui(ide" normalize. Deliberately NOT 2 (means "to"/"too"
//     far more than "z") or + (rare, ambiguous).
function collapseRepeats(s) {
  return s.replace(/(.)\1{2,}/g, "$1");
}
function deLeetCrisisExtra(s) {
  return s.replace(/[69]/g, "g").replace(/[(<]/g, "c");
}

function matchesCrisisPhrase(rawText, list) {
  const raw = rawText || "";
  const lowered = raw.toLowerCase();
  const normalized = aggressiveNormalizeForNameMatch(raw);
  const noSpace = normalized.replace(/[^a-z0-9]/g, "");
  // Fold the raw text too (not just the normalized form): normalization's
  // NAME_LEET_MAP already committed "1"->"i" before we can fold, which is why
  // both inputs go through foldAmbiguousIL from their own starting points.
  const folded = foldAmbiguousIL(aggressiveNormalizeForNameMatch(foldAmbiguousIL(raw)));
  const foldedNoSpace = folded.replace(/[^a-z0-9]/g, "");
  // Algospeak forms: repeated-char + extra-leet collapsed (normalized already
  // de-spaced initialisms like "s . a" -> "sa", so word-boundary checks below
  // can find them).
  const collapsed = collapseRepeats(deLeetCrisisExtra(normalized));
  return list.some((phrase) => {
    const pNoSpace = phrase.replace(/[^a-z0-9]/g, "");
    // Short tokens / initialisms (sa, sh, dv, csa, kms, kys) are matched ONLY as
    // standalone word-boundary tokens — a bare substring "sa" fires inside
    // "salsa/visa/usa", "sh" inside "wish", "kys" inside "sky's"->"skys". The
    // \b anchor makes them safe; the normalized + collapsed forms let "s.a."
    // and "s a" reach the same token. (This also FIXES the pre-existing
    // "sky's -> skys" harassment false positive the old substring path had.)
    if (pNoSpace.length <= 3) {
      const re = new RegExp("\\b" + pNoSpace + "\\b");
      return re.test(lowered) || re.test(normalized) || re.test(collapsed);
    }
    if (lowered.includes(phrase) || normalized.includes(phrase)) return true;
    if (folded.includes(foldAmbiguousIL(phrase))) return true;
    // Padding/leet-collapsed form for longer coded words ("unaliiive",
    // "sewersl1de" -> handled via folded, "9rippy sock").
    if (collapsed.includes(phrase)) return true;
    // Space/punct-insensitive fallback, length-guarded so short tokens
    // don't false-positive against arbitrary letter runs.
    if (pNoSpace.length < 6) return false;
    return noSpace.includes(pNoSpace) ||
      foldedNoSpace.includes(foldAmbiguousIL(pNoSpace)) ||
      collapseRepeats(noSpace).includes(pNoSpace);
  });
}

// H2 (2026-07-22 deep audit): MOD_HATE / MOD_SEXUAL are REGEX lists (not phrase
// strings), so they can't be passed to matchesCrisisPhrase directly. Previously
// they only ran against bare lowercased text, so spaced ("n i g g e r"),
// homoglyph ("nіgger", Cyrillic і), and zero-width-split slurs — which the iOS
// client hard-blocks — slipped past the SERVER (the real trust boundary) and
// the edit re-moderation path, publishing live. Run the regex against the same
// normalized forms the crisis matcher uses: lowercased raw AND
// aggressiveNormalizeForNameMatch (unicode-fold + de-leet + zero-width strip +
// single-letter-chain collapse). The regex stay \b-anchored, so matching the
// normalized form does NOT reintroduce the "spic inside suspicious" false
// positives (the normalized form preserves word structure).
function matchesEvasionRegex(rawText, regexList) {
  const raw = rawText || "";
  const forms = [raw.toLowerCase(), aggressiveNormalizeForNameMatch(raw)];
  return regexList.some((re) => forms.some((f) => re.test(f)));
}

function isPostExplicitCrisis(rawText) {
  return matchesCrisisPhrase(rawText, MOD_EXPLICIT_CRISIS);
}

const SPAM_PATTERNS = [
  /\b(buy|sell|discount|promo|click here|free money|crypto|bitcoin|investment)\b/i,
  /https?:\/\//i,
  /\b(www\.)\b/i,
  /\b(buy now|act now|limited time|earn money|make money)\b/i,
  /\b(ethereum|nft)\b/i,
  /\b(follow my|check my bio|link in bio)\b/i,
  /\b(discount code|promo code|use code)\b/i,
  /\b(dm me for|dm for)\b/i,
  /\b(cashapp|venmo me|paypal me)\b/i,
  /\b(onlyfans|only fans)\b/i,
];

// 2026-07-27 minor-safety: first-person underage self-disclosure on a 17+ app.
// Held for review (NOT deleted) so an admin can verify and act per the ToS
// ("we remove accounts we discover to be underage"). Tight, first-person,
// FP-guarded — "im 15 minutes late", "relationship is 9 years old", "im 25",
// high-school reminiscing all stay clear. NOTE: this is detection only; the
// account-removal POLICY and any legal reporting pipeline are owner decisions.
function isUnderageDisclosure(rawText) {
  const t = (rawText || "").toLowerCase();
  if (/\b(i'?m|i am)\s+(a\s+)?(minor|underage)\b/.test(t)) return true;
  if (/\bi'?m\s+not\s+(even\s+)?(18|eighteen)\b/.test(t)) return true;
  if (/\b(i'?m|i am)\s+(1[0-6])\s*(years?\s*old|yo\b|yrs?\s*old)/.test(t)) return true;
  if (/\b(i'?m|i am)\s+in\s+(middle school|junior high|[678](th)?\s*grade)\b/.test(t)) return true;
  return false;
}

function computePostFlagReason(rawText) {
  const text = (rawText || "").toLowerCase();
  // Minor-safety FIRST — it takes precedence over every other category so an
  // underage disclosure (esp. co-occurring with anything sexual) surfaces as
  // the urgent review reason, not a milder label.
  if (isUnderageDisclosure(rawText)) return "minor_safety";
  if (SPAM_PATTERNS.some((p) => p.test(text))) return "spam_or_commercial";
  if (matchesEvasionRegex(rawText, MOD_HATE)) return "hate_speech";
  // 2026-05-31: added MOD_HARASSMENT for posts. Previously only replies
  // checked it (computeReplyFlagReason at line 2350), so a user could
  // publish a top-level post with "kys" / "drink bleach" and have it
  // bypass auto-detection entirely. Ordered AFTER threat so a post
  // containing both ("im gonna kill you, kys") routes to the more
  // severe "targeted_threat" reason instead of "harassment".
  // IMPROVE (2026-06-11): route threat/harassment through matchesCrisisPhrase
  // (the same normalize + de-leet + de-space matcher crisis uses) so obfuscated
  // abuse ("ky5", "k i l l yourself") is caught, not just literal substrings.
  if (matchesCrisisPhrase(rawText, MOD_THREAT)) return "targeted_threat";
  if (matchesCrisisPhrase(rawText, MOD_HARASSMENT)) return "harassment";
  if (matchesEvasionRegex(rawText, MOD_SEXUAL)) return "sexual_content";
  if (containsPII(rawText || "")) return "personal_information";
  if (containsURL(rawText || "")) return "contains_link";
  return null;
}

function isPostConcerning(rawText) {
  return matchesCrisisPhrase(rawText, MOD_CONCERNING);
}

function computeReplyFlagReason(rawText) {
  const text = (rawText || "").toLowerCase();
  if (isUnderageDisclosure(rawText)) return "minor_safety";
  if (matchesEvasionRegex(rawText, MOD_HATE)) return "hate_speech";
  // Threat BEFORE harassment, same as computePostFlagReason: identical text
  // must triage to the same (more severe) category on both surfaces.
  if (matchesCrisisPhrase(rawText, MOD_THREAT)) return "targeted_threat";
  if (matchesCrisisPhrase(rawText, MOD_HARASSMENT)) return "harassment";
  if (matchesEvasionRegex(rawText, MOD_SEXUAL)) return "sexual_content";
  if (containsPII(rawText || "")) return "personal_information";
  if (containsURL(rawText || "")) return "contains_link";
  return null;
}

module.exports = {
  socialPatterns,
  hasPhoneNumber,
  emailPattern,
  addressPattern,
  identifyingPhrases,
  containsPII,
  MOD_HATE,
  MOD_THREAT,
  MOD_SEXUAL,
  MOD_HARASSMENT,
  MOD_CRISIS_EXPLICIT,
  MOD_CRISIS_SOFT,
  MOD_EXPLICIT_CRISIS,
  MOD_CONCERNING,
  matchesCrisisPhrase,
  isPostExplicitCrisis,
  SPAM_PATTERNS,
  computePostFlagReason,
  isPostConcerning,
  computeReplyFlagReason,
  isUnderageDisclosure,
};
