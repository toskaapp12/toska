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
// A2 (2026-10-28 audit): group-dehumanizing hate. MOD_HATE above is a SLUR list
// (hard-deletes a reply); these catch "all women are worthless trash" / "men are
// subhuman and should be exterminated", which published live. Broader by nature,
// so they route to a distinct flag reason ("dehumanizing") that is HELD for
// review everywhere — never hard-deleted. Run through matchesEvasionRegex.
const DEHUMANIZING_GROUP = "(women|men|girls|boys|females|males|gays|gay people|lesbians|trans people|trans folks|jews|jewish people|muslims|christians|catholics|hindus|blacks|black people|whites|white people|asians|mexicans|latinos|arabs|indians|chinese|africans|immigrants|migrants|refugees|foreigners|feminists|liberals|conservatives|republicans|democrats|boomers|zoomers|autistic people|disabled people|fat people|poor people|homeless people)";
const DEHUMANIZING_WORD = "(worthless|trash|garbage|subhuman|vermin|animals|scum|parasites|filth|filthy|disgusting|a disease|a plague|cockroaches|rats)";
const MOD_DEHUMANIZING = [
  new RegExp("\\b(all|every|most)\\s+" + DEHUMANIZING_GROUP + "\\s+(are|is|r)\\s+(just\\s+|nothing but\\s+|literally\\s+)?" + DEHUMANIZING_WORD + "\\b", "i"),
  new RegExp("\\b" + DEHUMANIZING_GROUP + "\\s+(are|is|r)\\s+(all\\s+)?(just\\s+|nothing but\\s+|literally\\s+)?" + DEHUMANIZING_WORD + "\\b", "i"),
  new RegExp("\\b" + DEHUMANIZING_GROUP + "\\s+(should|need to|ought to|deserve to|must)\\s+(all\\s+)?(be\\s+)?(exterminated|wiped out|put down|gassed|eradicated|killed|erased|eliminated|slaughtered|die|hang)\\b", "i"),
  new RegExp("\\bexterminate\\s+(all\\s+|the\\s+)?" + DEHUMANIZING_GROUP + "\\b", "i"),
  /\bsubhumans?\b/i,
  /\b(should|need to|ought to|deserve to|must) be exterminated\b/i,
];

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
  // A2 (2026-10-28 audit): third-person PHYSICAL forms. "going to hurt him so
  // badly when i see him" published live because every hurt-phrase was 2nd
  // person. Plain "hurt him/her" stays OUT (emotional hurt is routine breakup
  // writing); the "so bad" + physical-verb forms below are the threat shapes.
  "going to hurt him so bad", "gonna hurt him so bad", "going to hurt her so bad", "gonna hurt her so bad",
  "going to hurt them so bad", "gonna hurt them so bad", "want to hurt him so bad", "want to hurt her so bad",
  "beat him up", "beat her up", "beat them up",
  "break his legs", "break her legs", "break his jaw", "break her jaw", "break his face", "break her face",
  "smash his face", "smash her face", "bash his head", "bash her head",
  "make him bleed", "make her bleed", "put him in the hospital", "put her in the hospital",
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

// A2 (2026-10-28 audit): explicit sexual detail that published live ("explicit
// details about his dick"). Distinct flag reason "sexual_explicit" → HELD for
// review on posts AND replies (never the hard-delete the slur-tier MOD_SEXUAL
// reply path takes), and overridable at compose ("post anyway — it'll be
// reviewed"). Guards (owner 2026-10-28): "fucked me over/up/around" and the
// exclamation "fuck me, i miss him" are everyday breakup phrasing and must NOT
// match; bare "sex" ("the sex was good") and bare "dick" ("he's a dick") are
// deliberately absent. Runs through matchesEvasionRegex.
const MOD_SEXUAL_REVIEW = [
  /\bhis dick\b/i, /\bmy dick\b/i, /\bher pussy\b/i, /\bmy pussy\b/i,
  /\bsuck my\b/i, /\beat me out\b/i, /\bate me out\b/i,
  /\bfucked me\b(?!\s+(over|up|around|off)\b)/i,
  /\bfuck me\b(?=\s+(hard|harder|now|again|like|in the|on the|daddy|baby|so good|good|right|slow|senseless|all night|tonight|till|until)\b)/i,
  /\bcock in\b/i, /\bhis cock\b/i, /\btits out\b/i, /\bfinger(ed|ing) me\b/i,
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
  // 2026-07-28 method-language extension (A.5 #3, EXPLICIT — unambiguous
  // self-directed intent, same precedent as "hang myself"/"cut myself"; the
  // hyperbole profile of "shoot myself" matches the accepted one of "kill
  // myself"). Ambiguous/idiom-prone method language went to the SOFT tier.
  "shoot myself", "blow my brains out",
  "slit my wrists", "cut my wrists", "slitting my wrists",
  "want to overdose", "going to overdose", "gonna overdose",
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
  // 2026-07-28 method/planning/goodbye extension (A.5 #3 — SOFT: real signal
  // but hyperbole/idiom/third-person-capable; held + gentle check-in, never
  // paged). "od" is a <=3-char token so it word-boundary matches like "kms".
  // Pills phrases are soft because "took all my pills" is also literal
  // medication-compliance talk; "drown myself" is soft because "drowning
  // myself in work/wine" is common grief prose. Deliberate EXCLUSIONS:
  // "gun to my head" (dominant use is the idiom), "goodbye note"/"goodbye
  // letter" (writing a goodbye letter to an ex is a core use-case of this
  // app), bare "drowning in" (pure idiom), "whole bottle" (wine posts),
  // "end it tonight" ("end it" = the relationship here).
  "overdose", "overdosing", "od",
  "bottle of pills", "take all my pills", "took all my pills", "swallow all my pills",
  "drown myself", "noose",
  "jump off a bridge", "jump off the roof", "jump in front of a",
  "tonights the night", "tonight's the night", "wrote my note", "writing my note",
  "last night on earth", "wont be here tomorrow", "won't be here tomorrow",
  "by the time you read this", "goodbye forever",
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
// 2026-07-28 (A.5 #2): 3+ repeats → 2, not 1. Needed by the regex lane where
// several slur patterns REQUIRE a doubled letter (n[i1!]gg, f[a@]gg):
// collapsing "nigggger" to one g ("niger") makes those regexes MISS, while
// keeping two ("nigger") matches. Same rule iOS collapseForModeration uses.
function collapseRepeatsKeepDouble(s) {
  return s.replace(/(.)\1{2,}/g, "$1$1");
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
  // 2026-10-07 pentest: padding the DOUBLE letter itself ("killl myself",
  // "betttter off dead") defeated the 3+→1 collapse — it destroys the double
  // the phrase needs ("kil myself"), the exact failure mode A.5 #2 already
  // fixed for the slur-regex lane with collapseRepeatsKeepDouble but never
  // wired into THIS matcher. Run a 3+→2 form through the same lanes.
  const collapsedKeep = collapseRepeatsKeepDouble(deLeetCrisisExtra(normalized));
  // Padding mixed WITH i/l substitution ("kiilll myself") survives both
  // collapse forms because the pad spans two letters; inside the ambiguous-
  // class fold the i/l run becomes one character class, so collapsing the
  // folded form catches every mix. Crisis-only; over-detection is the
  // accepted-safe direction here.
  const foldedCollapsed = collapseRepeats(folded);
  const foldedCollapsedNoSpace = foldedCollapsed.replace(/[^a-z0-9]/g, "");
  return list.some((phrase) => {
    const pNoSpace = phrase.replace(/[^a-z0-9]/g, "");
    // Short tokens / initialisms (sa, sh, dv, csa, kms, kys) are matched ONLY as
    // standalone word-boundary tokens — a bare substring "sa" fires inside
    // "salsa/visa/usa", "sh" inside "wish", "kys" inside "sky's"->"skys". The
    // \b anchor makes them safe; the normalized + collapsed forms let "s.a."
    // and "s a" reach the same token. (This also FIXES the pre-existing
    // "sky's -> skys" harassment false positive the old substring path had.)
    if (pNoSpace.length <= 3) {
      // A2 (2026-10-28 audit): test ONLY the raw lowercased text. The
      // normalized/de-leeted forms fold digits into letters ("54" → "sa",
      // "5h" → "sh", "0d" → "od"), which held "54 days since" and "i have 54
      // photos" as crisis. Punctuated/spaced initialisms ("k.m.s", "k m s",
      // "s.a.") still match through the joiner between letters.
      const joined = pNoSpace.split("").join("[\\s.\\-_*·]*");
      const re = new RegExp("(?<![a-z0-9])" + joined + "(?![a-z0-9])");
      return re.test(lowered);
    }
    if (lowered.includes(phrase) || normalized.includes(phrase)) return true;
    if (folded.includes(foldAmbiguousIL(phrase))) return true;
    // Padding/leet-collapsed form for longer coded words ("unaliiive",
    // "sewersl1de" -> handled via folded, "9rippy sock"). BOTH collapse
    // depths, same as matchesEvasionRegex: 3+→1 restores vowel padding,
    // 3+→2 restores a padded double letter ("killl"→"kill").
    if (collapsed.includes(phrase)) return true;
    if (collapsedKeep.includes(phrase)) return true;
    // Fold-then-collapse for pads inside the ambiguous i/l class.
    if (foldedCollapsed.includes(collapseRepeats(foldAmbiguousIL(phrase)))) return true;
    // Space/punct-insensitive fallback, length-guarded so short tokens
    // don't false-positive against arbitrary letter runs.
    if (pNoSpace.length < 6) return false;
    return noSpace.includes(pNoSpace) ||
      foldedNoSpace.includes(foldAmbiguousIL(pNoSpace)) ||
      collapseRepeats(noSpace).includes(pNoSpace) ||
      collapseRepeatsKeepDouble(noSpace).includes(pNoSpace) ||
      foldedCollapsedNoSpace.includes(collapseRepeats(foldAmbiguousIL(pNoSpace)));
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
// 2026-07-28 (A.5 #2): align with the crisis/threat matcher — apply the same
// algospeak pass (deLeetCrisisExtra + repeat-collapse) so padded ("spiiiic",
// "nigggger", "nuuuudes") and extra-leet ("9ook", "(oon") evasion can't slip
// the hate/sexual lane the way it already can't slip crisis/threat. TWO
// collapsed forms are required: 3+→1 restores vowel padding ("spiiiic"→
// "spic") but breaks doubled-letter slur regexes when the double itself is
// padded, so a 3+→2 form covers those (see collapseRepeatsKeepDouble).
// Extra forms only ADD detection; word structure is preserved and the
// patterns stay \b-anchored, so the idiom/substring FP guards above hold.
function matchesEvasionRegex(rawText, regexList) {
  const raw = rawText || "";
  const normalized = aggressiveNormalizeForNameMatch(raw);
  const deLeeted = deLeetCrisisExtra(normalized);
  const forms = [
    raw.toLowerCase(),
    normalized,
    collapseRepeats(deLeeted),
    collapseRepeatsKeepDouble(deLeeted),
  ];
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

// 2026-07-27 minor-safety: first-person underage self-disclosure on an 18+ app.
// Held for review (NOT deleted) so an admin can verify and act per the ToS
// ("we remove accounts we discover to be underage"). Tight, first-person,
// FP-guarded — "im 15 minutes late", "relationship is 9 years old", "im 25",
// high-school reminiscing all stay clear. NOTE: this is detection only; the
// account-removal POLICY and any legal reporting pipeline are owner decisions.
//
// 2026-07-28 hardening (system-review A.5 #1): added spelled-out ages,
// "turning / just turned / i turn X next..." framings, freshman/sophomore
// (college forms excluded), 9th–10th grade + "Nth grader", and first-person
// birth-year disclosure with a dynamic cutoff. Past-tense reminiscing ("when
// i was 16", "i had just turned 15") stays clear because every framing
// requires present-tense first-person adjacency.
//
// 2026-08-06: the floor moved 17 → 18, so the threshold moved with it —
// otherwise the detector would miss exactly the users the new policy
// excludes. A stated "i'm 17" now flags; "i'm 18" does not.
//   - 11th grade / junior ADDED: juniors are ~16-17, essentially never 18.
//   - 12th grade / senior / "i'm in high school" still EXCLUDED: seniors are
//     commonly 18, so flagging them would hold legitimate adult posts and
//     spend moderator attention for no safety gain. Do not "fix" this.
// The college guard on freshman/sophomore/junior stays for the same reason.
const UNDERAGE_AGE =
  "(?:1[0-7]|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen)";
// A2 (2026-10-28 audit): "i[’']?m" so a curly apostrophe (iOS keyboard default)
// and the bare "im" both match; bare age at a clause boundary ("i am 15 and my
// first boyfriend…", "im 16, he was 19"); age+gender shorthand ("16f", "16 m",
// "f16"); over-holding possible minors is the owner's stated preference.
const UNDERAGE_BARE_AGE_RE = new RegExp(
  "\\b(i[’']?m|i am)\\s+(only\\s+|just\\s+)?" + UNDERAGE_AGE +
  "\\s*(?=(,|\\.|!|\\?|;|$|\\band\\b|\\bbut\\b|\\bso\\b|\\bnow\\b|\\brn\\b|\\blol\\b|\\btho\\b|\\bthough\\b|\\bbtw\\b|\\btoo\\b|\\bhere\\b|\\bhonestly\\b|\\bbtw\\b))");
const UNDERAGE_AGE_GENDER_RE = /\b(1[0-7])\s?[fm]\b|\b[fm]\s?(1[0-7])\b/;
const UNDERAGE_PATTERNS = [
  /\b(i[’']?m|i am)\s+(a\s+)?(minor|underage)\b/,
  /\bi[’']?m\s+not\s+(even\s+)?(18|eighteen)\b/,
  UNDERAGE_BARE_AGE_RE,
  UNDERAGE_AGE_GENDER_RE,
  new RegExp(
    "\\b(i[’']?m|i am)\\s+(only\\s+|just\\s+)?" + UNDERAGE_AGE +
    "\\s*(years?\\s*old|yo\\b|yrs?\\s*old)"),
  /\b(i[’']?m|i am)\s+in\s+(middle school|junior high|[6-9](th)?\s*grade|1[01](th)?\s*grade|(sixth|seventh|eighth|ninth|tenth|eleventh)\s*grade)\b/,
  new RegExp("\\b(i[’']?m|i am)\\s+turning\\s+" + UNDERAGE_AGE + "\\b"),
  new RegExp("\\bi\\s+just\\s+turned\\s+" + UNDERAGE_AGE + "\\b"),
  new RegExp("\\bi\\s+turn\\s+" + UNDERAGE_AGE + "\\s+(next|this|in|on)\\b"),
  /\b(i[’']?m|i am)\s+an?\s+(freshman|sophomore|junior)\b(?!\s+(in|at)\s+(community\s+)?(college|university|uni)\b)/,
  /\b(i[’']?m|i am)\s+an?\s+([6-9]|10|11)(th)?[\s-]*grader\b/,
];
// A2: bare "born in YEAR" (no pronoun) counts unless a possessive/determiner
// names someone else ("my daughter born in 2012", "a dog born in 2012").
const UNDERAGE_BORN_RE = /\b(?:(i\s+was|i[’']?m|i\s+am)\s+born\s+in|(?<!\b(my|his|her|their|our|your|the|a|an|kids?|son|daughter|dog|cat|baby|niece|nephew|sister|brother)\s)born\s+in)\s+((19|20)\d{2})\b/;

function isUnderageDisclosure(rawText) {
  const t = (rawText || "").toLowerCase();
  if (UNDERAGE_PATTERNS.some((re) => re.test(t))) return true;
  // Birth year >= (currentYear - 17) guarantees age <= 17 even after this
  // year's birthday — never goes stale, never flags a possible 18-year-old.
  const born = UNDERAGE_BORN_RE.exec(t);
  if (born && Number(born[3]) >= new Date().getFullYear() - 17) return true;
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
  if (matchesEvasionRegex(rawText, MOD_DEHUMANIZING)) return "dehumanizing"; // A2: held, never deleted
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
  if (matchesEvasionRegex(rawText, MOD_SEXUAL_REVIEW)) return "sexual_explicit"; // A2: held, overridable at compose
  if (containsPII(rawText || "")) return "personal_information";
  if (containsURL(rawText || "")) return "contains_link";
  return null;
}

function isPostConcerning(rawText) {
  return matchesCrisisPhrase(rawText, MOD_CONCERNING);
}

// Item 3 (2026-10-28 audit follow-up): crisis REPLIES. Explicit-tier crisis
// text in a reply is HELD for review (pending_review / "crisis") like a post —
// UNLESS it reads as a supportive reach-out to the poster, which stays live and
// queued for admin review as before. Soft-tier replies ("i can't do this
// anymore either") are often empathy and stay live + queued (owner decision).
// The supportive guard is deliberately NARROW: it needs BOTH a negation AND a
// help signal, so "don't kill yourself" alone (no help signal) and "i want to
// kill myself, call me" (no negation) are still held.
// Negation must be tied to the self-harm verb ("don't kill yourself", "never do
// it", "please do not hurt yourself") — a stray "don't" elsewhere does not count.
const SUPPORT_NEGATION_RE = /\b(please\s+)?(don'?t|do\s+not|never|dont)\s+(ever\s+)?(kill|hurt|harm|unalive|end|hang|do|go through with|take)\s+(yourself|urself|it|this|that|your|those|the|all)/;
// Any hard directed-abuse token disqualifies the supportive reading outright.
const SUPPORT_DISQUALIFY_RE = /\b(kys|go die|you should die|hope you die|neck yourself|drink bleach|go hang yourself|go kill yourself|you should kill yourself|just die|nobody likes you|no one will miss you)\b/;
const SUPPORT_HELP_RE = /\b(988|741741|crisis\s+line|crisis\s+text\s+line|lifeline|samaritans|hotline|helpline|call\s+(someone|a\s+friend|them|the|your|me|988)|text\s+(home|someone|me|741741|the)|reach\s+out|talk\s+to\s+(someone|a|your|me)|you\s+matter|you'?re\s+not\s+alone|youre\s+not\s+alone|not\s+alone|here\s+for\s+you|please\s+stay|stay\s+with\s+us|get\s+help|seek\s+help)\b/;
function isSupportiveReachOut(rawText) {
  const t = aggressiveNormalizeForNameMatch(rawText || "");
  const lower = (rawText || "").toLowerCase();
  if (SUPPORT_DISQUALIFY_RE.test(lower) || SUPPORT_DISQUALIFY_RE.test(t)) return false;
  return (SUPPORT_NEGATION_RE.test(lower) || SUPPORT_NEGATION_RE.test(t))
    && (SUPPORT_HELP_RE.test(lower) || SUPPORT_HELP_RE.test(t));
}
// True when a reply's crisis text should HOLD the reply (explicit tier, not a
// supportive reach-out). Directed abuse ("go kill yourself", "kys") is routed by
// computeReplyFlagReason → harassment BEFORE this is consulted (see index.js),
// so it is never treated as the author's own crisis.
function shouldHoldCrisisReply(rawText) {
  return isPostExplicitCrisis(rawText) && !isSupportiveReachOut(rawText);
}

function computeReplyFlagReason(rawText) {
  const text = (rawText || "").toLowerCase();
  if (isUnderageDisclosure(rawText)) return "minor_safety";
  // A2 (2026-10-28 audit): replies never ran the spam check, so "buy my crypto
  // course, link in bio" replies went live. Held (abuse_spam) via applyReplyModeration.
  if (SPAM_PATTERNS.some((p) => p.test(text))) return "spam_or_commercial";
  if (matchesEvasionRegex(rawText, MOD_HATE)) return "hate_speech";
  if (matchesEvasionRegex(rawText, MOD_DEHUMANIZING)) return "dehumanizing";
  // Threat BEFORE harassment, same as computePostFlagReason: identical text
  // must triage to the same (more severe) category on both surfaces.
  // Item 3 (2026-10-28): a supportive reach-out ("please don't kill yourself,
  // call 988, you matter") substring-matches "kill you"/"kill yourself" and was
  // held as a threat/harassment. With the narrow isSupportiveReachOut guard
  // (negation tied to the self-harm verb + a help signal + no hard directed-
  // abuse token) those replies skip the two directed-abuse lanes and stay live
  // + crisis-queued for admin review.
  const supportive = isSupportiveReachOut(rawText);
  if (!supportive && matchesCrisisPhrase(rawText, MOD_THREAT)) return "targeted_threat";
  if (!supportive && matchesCrisisPhrase(rawText, MOD_HARASSMENT)) return "harassment";
  if (matchesEvasionRegex(rawText, MOD_SEXUAL)) return "sexual_content";
  if (matchesEvasionRegex(rawText, MOD_SEXUAL_REVIEW)) return "sexual_explicit";
  if (containsPII(rawText || "")) return "personal_information";
  if (containsURL(rawText || "")) return "contains_link";
  return null;
}

module.exports = {
  MOD_DEHUMANIZING, MOD_SEXUAL_REVIEW, isSupportiveReachOut, shouldHoldCrisisReply,
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
