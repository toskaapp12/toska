// toska web — Stage A: sign in / sign up + read-only feed, posts, profiles.
// Query shapes deliberately mirror the iOS client 1:1 (see FeedViewModel /
// PostDetailView / ProfileView) — the rules deny any broader read.
import { FIREBASE_CONFIG, IS_PROD, RECAPTCHA_SITE_KEY, POLICY_VERSION } from "./config.js";
import { initializeApp } from "https://www.gstatic.com/firebasejs/11.0.1/firebase-app.js";
import {
    getAuth, onAuthStateChanged, signInWithEmailAndPassword,
    createUserWithEmailAndPassword, signOut, sendPasswordResetEmail,
} from "https://www.gstatic.com/firebasejs/11.0.1/firebase-auth.js";
import {
    getFirestore, collection, collectionGroup, doc, getDoc, getDocs,
    getCountFromServer, query, where, orderBy, limit, startAfter,
    writeBatch, setDoc, serverTimestamp, onSnapshot, documentId,
} from "https://www.gstatic.com/firebasejs/11.0.1/firebase-firestore.js";
import { getFunctions, httpsCallable } from "https://www.gstatic.com/firebasejs/11.0.1/firebase-functions.js";
import {
    initWrites, resetWriteCaches, createPost, createReply, postRateLimited,
    toggleLike, toggleSave, toggleRepost, isLiked, isSaved, isReposted,
    submitReport, blockUser, unblockUser, isRestricted,
    editPost, editReply, deletePost, deleteReply,
    POST_TAGS, REPORT_REASONS,
} from "./writes.js";
import { runGates } from "./gates.js";

const app = initializeApp(FIREBASE_CONFIG);

// App Check: prod enforces on Firestore + Auth + callables; staging only on
// callables (handled by tolerating confirmAdult failure there, like the iOS
// simulator path). Failure to init must not brick the page.
if (IS_PROD) {
    try {
        const { initializeAppCheck, ReCaptchaEnterpriseProvider } =
            await import("https://www.gstatic.com/firebasejs/11.0.1/firebase-app-check.js");
        initializeAppCheck(app, {
            provider: new ReCaptchaEnterpriseProvider(RECAPTCHA_SITE_KEY),
            isTokenAutoRefreshEnabled: true,
        });
    } catch (e) { console.warn("app check init failed", e); }
}

const auth = getAuth(app);
const db = getFirestore(app);
const functions = getFunctions(app);

// Late night: mirror LateNightTheme — device hour < 5 flips the whole app.
if (new Date().getHours() < 5) document.documentElement.dataset.theme = "night";

// ---------------------------------------------------------------- helpers
const mount = document.getElementById("mount");
const header = document.getElementById("appHeader");
const mainNav = document.getElementById("mainNav");
const writeFab = document.getElementById("writeFab");
// Bound here, not inline in index.html: the hosting CSP has no
// 'unsafe-inline' for scripts, so attribute handlers never execute.
writeFab.addEventListener("click", () => { location.hash = "#/compose"; });
function setChrome(hidden) { header.hidden = hidden; mainNav.hidden = hidden; writeFab.hidden = hidden; }

function toast(msg, ms = 3200) {
    const t = el("div", { class: "toast" }, msg);
    document.body.append(t);
    setTimeout(() => t.remove(), ms);
}

function menuSheet(items) { // [{label, danger, onclick}]
    const overlay = el("div", { class: "modal-overlay" });
    const card = el("div", { class: "modal-card menu-sheet" });
    overlay.addEventListener("click", (e) => { if (e.target === overlay) overlay.remove(); });
    for (const it of items) {
        card.append(el("button", { class: it.danger ? "danger" : "", onclick: () => { overlay.remove(); it.onclick(); } }, it.label));
    }
    overlay.append(card);
    document.body.append(overlay);
}

function el(tag, attrs = {}, ...children) {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
        if (k === "class") n.className = v;
        else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
        else if (v !== null && v !== undefined) n.setAttribute(k, v);
    }
    for (const c of children.flat()) {
        if (c === null || c === undefined) continue;
        n.append(c.nodeType ? c : document.createTextNode(c));
    }
    return n;
}
const spinner = () => el("span", { class: "spinner" });

function relTime(ts) {
    if (!ts?.toDate) return "";
    const s = (Date.now() - ts.toDate().getTime()) / 1000;
    if (s < 60) return "now";
    if (s < 3600) return `${Math.floor(s / 60)}m`;
    if (s < 86400) return `${Math.floor(s / 3600)}h`;
    if (s < 604800) return `${Math.floor(s / 86400)}d`;
    if (s < 31536000) return `${Math.floor(s / 604800)}w`;
    return `${Math.floor(s / 31536000)}y`;
}
const chunk = (arr, n) => Array.from({ length: Math.ceil(arr.length / n) }, (_, i) => arr.slice(i * n, i * n + n));

// ---------------------------------------------------------------- state
let me = null;               // firebase user
let blocked = new Set();     // uids I blocked (client-side filtering, like iOS)
let blockedUnsub = null;
let signupInProgress = false; // auth fires before the users doc exists — defer routing

function startBlockedListener(uid) {
    stopBlockedListener();
    blockedUnsub = onSnapshot(collection(db, "users", uid, "blocked"),
        snap => {
            const next = new Set(snap.docs.map(d => d.id));
            // F-P3-1 (2026-07-09 full-audit): if a block was ADDED while a feed
            // is on screen, re-render so the newly-blocked author's rows drop
            // now (postVisible re-filters against the live set). Without this, a
            // block made on another device — or the cold-start initial load
            // landing AFTER the feed rendered — left blocked content visible
            // until the next navigation. Only re-render on GROWTH (an unblock
            // never needs to strip rows), and only when a feed is mounted.
            let grew = false;
            for (const id of next) if (!blocked.has(id)) { grew = true; break; }
            blocked = next;
            if (grew && activeFeedTab) viewFeed();
        },
        () => {});
}
function stopBlockedListener() { if (blockedUnsub) { blockedUnsub(); blockedUnsub = null; } blocked = new Set(); }

let notifUnsub = null;
function startNotifBadge(uid) {
    stopNotifBadge();
    notifUnsub = onSnapshot(
        query(collection(db, "users", uid, "notifications"), where("isRead", "==", false), limit(1)),
        snap => { document.getElementById("notifDot").hidden = snap.empty; },
        () => {});
}
function stopNotifBadge() {
    if (notifUnsub) { notifUnsub(); notifUnsub = null; }
    document.getElementById("notifDot").hidden = true;
}

// ---------------------------------------------------------------- drafts
// localStorage, keyed per-uid so an account switch can't leak text (the iOS
// sign-out draft-leak bug class). Writes are guarded on auth; sign-out and
// token-revocation both purge every draft_{uid}_* key for that uid.
const draftKey = (kind) => me ? `draft_${me.uid}_${kind}` : null;
function loadDraft(kind) {
    const k = draftKey(kind);
    try { return k ? (localStorage.getItem(k) ?? "") : ""; } catch { return ""; }
}
function saveDraft(kind, text) {
    const k = draftKey(kind);
    if (!k) return;
    try { text.trim() ? localStorage.setItem(k, text) : localStorage.removeItem(k); } catch {}
}
function clearDrafts(uid) {
    try {
        const prefix = `draft_${uid}_`;
        for (const k of Object.keys(localStorage))
            if (k.startsWith(prefix)) localStorage.removeItem(k);
    } catch {}
}
const debounce = (fn, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };

// ---------------------------------------------------------------- daily prompt
// Verbatim mirror of FeedViewModel.dailyPrompts (text, tag) — client-static
// on iOS too; dayOfYear % count picks today's. F-P5-1 (2026-07-09 full-audit):
// resynced to the FULL 395-entry iOS list — it had drifted to 40, so
// `dayOfYear % 40` picked a DIFFERENT prompt than iOS's `% 395` every day.
// KEEP THIS THE SAME LENGTH + ORDER as FeedViewModel.dailyPrompts (regenerate
// from the Swift source when either changes; a parity pin is the durable fix).
const DAILY_PROMPTS = [
    ["its 2am and you cant sleep. what are you thinking about.", "longing"],
    ["type out the text you almost sent last night", "unsent"],
    ["what do you miss that has nothing to do with them as a person. like their dog. or their car. or their kitchen.", "regret"],
    ["are you actually healing or just getting quieter about it", "confusion"],
    ["what would you say if they called right now. no thinking just say it.", "still love you"],
    ["i dont want to start over with someone new and explain all my shit again. do you feel that.", "moving on"],
    ["do you think they feel guilty or are you not even something to feel guilty about", "anger"],
    ["what are you pretending is fine right now", "acceptance"],
    ["whats the thing you cant tell anyone because theyd say youre crazy", "longing"],
    ["write the letter youll never send. start with dear you.", "unsent"],
    ["whats something small that still ruins you. a song. a street. a food.", "regret"],
    ["do you miss them or do you miss not being alone. its okay if you dont know.", "confusion"],
    ["say the thing you pretend you dont feel anymore", "still love you"],
    ["what would it take to feel like a beginning instead of an aftermath.", "moving on"],
    ["whats the thing you cant forgive them for", "anger"],
    ["did you eat today. did you sleep. are you drinking water. be honest.", "acceptance"],
    ["do you still check their social media. be honest.", "longing"],
    ["say something you havent said out loud to anyone. not even yourself.", "unsent"],
    ["what did they say that you still hear on repeat", "regret"],
    ["i keep thinking maybe if i was different. not even better just different. do you do that too.", "confusion"],
    ["be honest. would you take them back right now if they asked.", "still love you"],
    ["name the first day you noticed you thought about them less. did it scare you.", "moving on"],
    ["are you angry or just really really sad. or both.", "anger"],
    ["you got out of bed today. thats not nothing. say it like it counts.", "acceptance"],
    ["what song do you skip now because it ruins you", "longing"],
    ["type out the message thats been sitting in your drafts for weeks", "unsent"],
    ["whats the most pathetic thing youve done since it ended. no judgment here.", "regret"],
    ["the thing nobody understands about what happened is", "confusion"],
    ["do you still love them. you dont have to answer that. but do you.", "still love you"],
    ["who are you when youre not orbiting them. be honest.", "moving on"],
    ["say it. the one thing you wouldve screamed if you werent so busy being calm and reasonable", "anger"],
    ["what is the first thing that tasted good again. even a little.", "acceptance"],
    ["whats the thought you have every single morning before you can stop it", "longing"],
    ["write what you wouldve said if youd picked up the last time they called", "unsent"],
    ["whats the last thing that made you cry about it. like actually cry.", "regret"],
    ["how are you. and not the version you tell people.", "confusion"],
    ["if they walked back in tonight. no questions asked. would you let them.", "still love you"],
    ["i dont want to be brave. i just want to wake up and not reach for my phone first.", "moving on"],
    ["whats the lie they told that still makes your face hot when you remember it", "anger"],
    ["name one small thing you did today that you didnt think youd manage.", "acceptance"],
    ["do you think about them every day still or just most days", "longing"],
    ["the apology you never gave. write it now.", "unsent"],
    ["whats the thing you wish youd said before they walked out the door", "regret"],
    ["do you even know what you miss anymore. them. or the shape they left.", "confusion"],
    ["be honest. how many of your thoughts still end with them.", "still love you"],
    ["finish this: the version of me that comes after this is", "moving on"],
    ["you were so patient with them. who is gonna be patient with you", "anger"],
    ["youre still here. say what got you through the worst hour.", "acceptance"],
    ["finish this: i just want someone to", "longing"],
    ["finish this: i never told you that", "unsent"],
    ["theres a text you never sent. whats in it", "regret"],
    ["some days im fine and i cant tell if thats progress or if i just stopped feeling it.", "confusion"],
    ["you tell people youre over it. who are you actually trying to convince.", "still love you"],
    ["what do you want to keep, and what are you finally allowed to put down.", "moving on"],
    ["do you think they ever lie awake feeling sick about it or do they just sleep", "anger"],
    ["what are you carrying that you could set down just for tonight.", "acceptance"],
    ["i think the worst feeling is being forgotten by someone you still remember everything about", "longing"],
    ["write the text you typed and deleted at 3am", "unsent"],
    ["what would you give to have one more ordinary tuesday with them", "regret"],
    ["i keep waiting to understand what went wrong like its a sentence ill finish someday.", "confusion"],
    ["theres a version of you still waiting by the phone. say hi to her.", "still love you"],
    ["there was a whole life you planned around them. what gets to be yours now.", "moving on"],
    ["name the thing you forgave that you shouldnt have", "anger"],
    ["did you go outside today. even to the door. thats allowed to count.", "acceptance"],
    ["write the text you typed out and never sent. the one still sitting in drafts.", "longing"],
    ["say the thing you swallowed so the fight would end", "unsent"],
    ["whats the apology you keep rehearsing for no one", "regret"],
    ["youre not sad today. is that healing or is that just monday.", "confusion"],
    ["if love really left. why does their name still do that to your chest.", "still love you"],
    ["i caught myself laughing today and didnt feel guilty after. is that what this is.", "moving on"],
    ["youre allowed to be furious. you dont have to be the bigger person tonight", "anger"],
    ["what felt almost normal today. dont rush past it.", "acceptance"],
    ["what would you give for one more ordinary tuesday with them. nothing special. just there.", "longing"],
    ["if they read your mind right now, what would they find", "unsent"],
    ["finish this: i should never have", "regret"],
    ["the last thing they said keeps changing meaning depending on the hour. which version is true.", "confusion"],
    ["would you take the bad days back too. all of them. to have them again.", "still love you"],
    ["what would you do this week if you werent waiting for them to come back.", "moving on"],
    ["what did they take that they didnt even want. they just didnt want you to have it", "anger"],
    ["youve been holding it together for everyone. who holds it for you.", "acceptance"],
    ["i still reach for my phone to tell them things. then i remember.", "longing"],
    ["the goodbye you never got to say. say it.", "unsent"],
    ["what did you pretend not to care about that you actually cared about so much", "regret"],
    ["do you miss them or do you miss who you were when they looked at you.", "confusion"],
    ["what part of them do you still defend in your head when no ones around.", "still love you"],
    ["the thought of explaining my history to someone new makes me tired. tell me it gets lighter.", "moving on"],
    ["the apology you got was for the wrong thing wasnt it. what did they actually need to say", "anger"],
    ["what did you let yourself feel today instead of pushing it down.", "acceptance"],
    ["whats the smell that brings them back instantly. cologne. their pillow. rain.", "longing"],
    ["write what you wish youd answered when they asked if you were okay", "unsent"],
    ["whats the last thing you lied to them about. and why", "regret"],
    ["i replay the part where it was still good and i cant find the exact second it wasnt.", "confusion"],
    ["youve forgiven them already havent you. you just havent told them.", "still love you"],
    ["what is one thing thats yours again that used to be ours.", "moving on"],
    ["how many times did you make excuses for them out loud to people who were trying to warn you", "anger"],
    ["name the smallest kindness you gave yourself this week.", "acceptance"],
    ["be honest. would you take them back tonight if they asked. no questions.", "longing"],
    ["finish this: the truth is i", "unsent"],
    ["theres a version of you that fought harder. what would they have done", "regret"],
    ["are you over it or did you just run out of ways to say youre not.", "confusion"],
    ["if they called and only said your name. what would you do.", "still love you"],
    ["i dont want a clean slate. i just want to stop flinching at their name.", "moving on"],
    ["whats the sentence of theirs you replay just to stay angry enough not to text back", "anger"],
    ["what part of your day didnt hurt. start there.", "acceptance"],
    ["what part of their body do you miss the most. not the obvious one.", "longing"],
    ["type the message youll never have the nerve to send", "unsent"],
    ["what do you reread late at night that you know you shouldnt", "regret"],
    ["they texted back warm and then nothing. tell me what that was supposed to mean.", "confusion"],
    ["the feelings you say are gone. where do they go at 2am.", "still love you"],
    ["when did the silence in your apartment stop sounding like loss.", "moving on"],
    ["do they get to keep the version of you that was soft. or are you taking her back", "anger"],
    ["you made it to right now. what helped, honestly.", "acceptance"],
    ["finish this: the worst part of the day is", "longing"],
    ["what did you want to say at the door but didnt", "unsent"],
    ["what did you take for granted right up until it was gone", "regret"],
    ["im not crying anymore and i dont know if thats relief or something worse.", "confusion"],
    ["would you ruin all this peace just to feel them next to you once more.", "still love you"],
    ["finish this: i used to dread the mornings, but lately", "moving on"],
    ["you gave them the benefit of the doubt every single time. tally it up now", "anger"],
    ["what are you still pretending you dont miss.", "acceptance"],
    ["do you still know their number by heart. do you ever almost dial it.", "longing"],
    ["write the version of i love you you couldnt say back then", "unsent"],
    ["finish this: if id only", "regret"],
    ["do you want them back or do you just want the not-knowing to stop.", "confusion"],
    ["be honest. do you still say goodnight to them in your head.", "still love you"],
    ["what would it take to stop measuring time in how long since they left.", "moving on"],
    ["what would you say to their face if you knew theyd actually have to sit there and hear it", "anger"],
    ["did you laugh today. even once. it doesnt mean youre okay but its something.", "acceptance"],
    ["what did their laugh sound like. try to write it before you forget.", "longing"],
    ["the question you were too scared to ask them. ask it here.", "unsent"],
    ["whats the thing they asked you for that you didnt give them", "regret"],
    ["theres a version of me from before that i cant get back to. do you ever look for yours.", "confusion"],
    ["if they were happy without you. could you actually be glad. could you.", "still love you"],
    ["youre allowed to want a future that doesnt include them. say it out loud.", "moving on"],
    ["theyre out there telling their side. whats the part theyre leaving out", "anger"],
    ["what would it look like to be gentle with yourself for the next ten minutes.", "acceptance"],
    ["i keep their side of the bed cold and untouched like theyre coming back.", "longing"],
    ["type out what you rehearsed in the shower but never said", "unsent"],
    ["what street do you go out of your way to avoid now", "regret"],
    ["i thought i knew them. now i dont know which year was the lie.", "confusion"],
    ["you stopped texting them. you didnt stop writing the texts though.", "still love you"],
    ["name a small forward thing you did today that nobody would even notice.", "moving on"],
    ["how dare they be fine. say that. how dare they", "anger"],
    ["name one thing your body needs that you keep ignoring.", "acceptance"],
    ["whats the last thing they said to you. is it the last thing youll ever hear.", "longing"],
    ["finish this: what i really meant was", "unsent"],
    ["whats the smell that drops you straight back into their bed", "regret"],
    ["how do you grieve something youre not even sure is over.", "confusion"],
    ["what would you give to be the one they think of first again.", "still love you"],
    ["i dont want to start dating. i dont want to be alone either. where does that leave me.", "moving on"],
    ["whats the thing they did that you laughed off then that you want to throw across the room now", "anger"],
    ["whats the first song you could listen to again without crying.", "acceptance"],
    ["do you talk to them in your head still. what do you tell them.", "longing"],
    ["write the confession you keep behind your teeth", "unsent"],
    ["what did you say in the last fight that you cant take back", "regret"],
    ["the mixed signals werent confusing to them. only to me. i think.", "confusion"],
    ["if loving them was a mistake. why would you make it again. you would.", "still love you"],
    ["what part of yourself did you bury for them that you want back.", "moving on"],
    ["did they ever once choose you when it cost them something. or only when it was free", "anger"],
    ["you cleaned one thing. you answered one text. what got done. be proud quietly.", "acceptance"],
    ["what date is burned into you. the day it ended or the day it was good.", "longing"],
    ["say what you couldnt say while they were still listening", "unsent"],
    ["theres a moment you keep going back to. which one. what would you change", "regret"],
    ["am i healing or have i just gotten good at the days when nobody asks.", "confusion"],
    ["theres a sentence youve never said to them. say it here. just once.", "still love you"],
    ["the day you stop checking if theyve seen it. what does that day look like.", "moving on"],
    ["youre not crazy. you were never crazy. who made you doubt that and do you still let them", "anger"],
    ["what are you tired of pretending youre over.", "acceptance"],
    ["finish this: i wish i could go back to the moment before", "longing"],
    ["the words you saved for a conversation that never happened. write them.", "unsent"],
    ["what part of them do you still talk to when no ones around", "regret"],
    ["i dont miss them at noon. at 2am im not so sure. which one is real.", "confusion"],
    ["would you still pick them. knowing exactly how it ends. knowing all of it.", "still love you"],
    ["i keep waiting to feel ready. what if i just go before im ready.", "moving on"],
    ["what promise of theirs do you want to read back to them word for word", "anger"],
    ["did you rest today or just stop moving. theres a difference. be honest.", "acceptance"],
    ["describe the way they said your name. who says it like that now.", "longing"],
    ["type the reply you wrote in your head a hundred times", "unsent"],
    ["whats the gift of theirs you still keep in a drawer", "regret"],
    ["they said it wasnt about me and i still cant figure out who it was about.", "confusion"],
    ["be honest. is there anyone you compare to them. does anyone win.", "still love you"],
    ["what would you tell the next person about you, if you werent afraid of scaring them.", "moving on"],
    ["they got to leave clean and you got the wreckage. wheres the fairness in that", "anger"],
    ["what small routine is keeping you upright right now.", "acceptance"],
    ["do you wonder if theyre lying awake too. or if its just you.", "longing"],
    ["finish this: i should have told you", "unsent"],
    ["what did you stop doing for them that you wish you hadnt", "regret"],
    ["do you actually feel better or did you just lower what better has to mean.", "confusion"],
    ["if they asked for nothing. just to sit with you. would you say yes.", "still love you"],
    ["finish this: the song that used to wreck me now just feels like", "moving on"],
    ["whats the comeback you thought of three days too late. say it here instead", "anger"],
    ["name a moment today you forgot to be sad. let yourself have had it.", "acceptance"],
    ["whats the place you avoid now because youll see them there in your head.", "longing"],
    ["write what you wanted them to know before they walked away", "unsent"],
    ["finish this: i was too proud to", "regret"],
    ["i keep rereading the last conversation for a clue i already know isnt there.", "confusion"],
    ["the love didnt leave when they did. what do you do with it now.", "still love you"],
    ["you survived the version of you that didnt think youd survive. what now.", "moving on"],
    ["did they make you small so they could feel big. how long did it work", "anger"],
    ["whats one thing you used to dread that felt okay today.", "acceptance"],
    ["i found their hair on a sweater i havent worn in months and i lost it.", "longing"],
    ["the thing you almost confessed and then changed the subject. confess it now.", "unsent"],
    ["whats the order you cant place anymore because it was theirs too", "regret"],
    ["part of me is relieved and i dont know what that says about all of it.", "confusion"],
    ["you keep their old messages. youre not gonna delete them. why.", "still love you"],
    ["what does a tuesday look like when it isnt about them anymore.", "moving on"],
    ["what are you still defending them for and who are you protecting really", "anger"],
    ["you survived the day you didnt think youd survive. how does that sit.", "acceptance"],
    ["say the thing you wish you could tell them right now at this exact hour.", "longing"],
    ["type out the last thing you wish theyd heard from you", "unsent"],
    ["what did you almost tell them and then didnt", "regret"],
    ["youre quieter now. is that peace or did you just stop reaching for them.", "confusion"],
    ["if you saw them tomorrow. what would your hands want to do first.", "still love you"],
    ["i dont miss them today. i miss missing them, which is somehow worse. is it.", "moving on"],
    ["the worst part isnt that they did it. its that they knew exactly what it would do to you and did it anyway. didnt they", "anger"],
    ["what are you doing just to get through, and is it kind enough.", "acceptance"],
    ["do you still sleep on your side of the bed. why.", "longing"],
    ["write the message you keep starting and never finishing", "unsent"],
    ["whats the date on the calendar that still wrecks you", "regret"],
    ["i cant tell if i forgive them or if i just forgot to keep being angry.", "confusion"],
    ["would you tell them you still love them. if it changed nothing. would you.", "still love you"],
    ["what are you slowly becoming that they never got to meet.", "moving on"],
    ["you kept the receipts in your chest for months. dump them out", "anger"],
    ["did anyone check on you today. did you let them in.", "acceptance"],
    ["what habit of theirs do you catch yourself doing now.", "longing"],
    ["say the part you left out of the goodbye", "unsent"],
    ["what would past you be furious at present you for", "regret"],
    ["they were everything and now i cant remember why. that scares me more than missing them.", "confusion"],
    ["be honest. when you say you miss them. do you mean you still want them.", "still love you"],
    ["the idea of someone new touching the parts they touched. terrifying or freeing. which.", "moving on"],
    ["what did they call closure that was really just them needing you to be okay so they could feel less guilty", "anger"],
    ["name the thing that felt like yours again. even for a second.", "acceptance"],
    ["be honest. how many times have you typed their name into the search bar tonight.", "longing"],
    ["finish this: if i had been braver id have said", "unsent"],
    ["whats the song you put on just to feel it open back up", "regret"],
    ["do you still love them or is it just the muscle memory of having.", "confusion"],
    ["theres a part of you that never agreed to the breakup. let it speak.", "still love you"],
    ["name the moment you realized you stopped editing texts you were never going to send.", "moving on"],
    ["how many of your own needs did you shrink so they wouldnt feel crowded", "anger"],
    ["what hurts a little less than it did last week. notice it out loud.", "acceptance"],
    ["whats the inside joke nobody else will ever understand. who do you tell it to now.", "longing"],
    ["write what you would text right now if you knew theyd never see it", "unsent"],
    ["what did they warn you about that you ignored", "regret"],
    ["nothing they did adds up to leaving and yet here we are.", "confusion"],
    ["if they were standing outside right now. would you open the door.", "still love you"],
    ["what would it take to walk past their old street without holding your breath.", "moving on"],
    ["they get to be the one who left. what story did that let them tell about you", "anger"],
    ["youre allowed to not be fine and still be doing this right.", "acceptance"],
    ["i keep waiting for a text that isnt coming and i hate that i still check.", "longing"],
    ["the words stuck in your throat the whole time. let them out.", "unsent"],
    ["whats the chore you used to hate that you miss doing with them", "regret"],
    ["i feel okay and i keep waiting for the okay to turn out fake.", "confusion"],
    ["you pretend it was just a season. but you still water it. dont you.", "still love you"],
    ["i dont want to forget them. i just want to stop being haunted. is there a difference.", "moving on"],
    ["whats the thing you bit back every time. let it out, no one here is grading your tone", "anger"],
    ["what did you make it through without checking their name. say it gently.", "acceptance"],
    ["what did it feel like to be wanted by them. do you remember.", "longing"],
    ["type the truth you hid inside im fine", "unsent"],
    ["what did you assume youd have more time for. and then you didnt", "regret"],
    ["which is worse. that they changed. or that maybe they didnt and i just stopped seeing it.", "confusion"],
    ["what would you say if they asked were you ever really over me.", "still love you"],
    ["finish this: starting over sounds exhausting, but staying here sounds like", "moving on"],
    ["did they ever say sorry or did they just say they felt bad that you were hurt", "anger"],
    ["name one thing you can control tonight. just one. start small.", "acceptance"],
    ["finish this: the version of me that knew them is", "longing"],
    ["write what you wanted to scream but said nothing", "unsent"],
    ["finish this: the last thing i ever said to them was", "regret"],
    ["im not waiting for them to come back. i think. ask me again tomorrow.", "confusion"],
    ["would you wait. if they asked you to wait. how long. be honest.", "still love you"],
    ["what habit did you build around them that youre quietly letting die.", "moving on"],
    ["you werent too much. you were exactly enough and they couldnt handle being seen by someone who was. say it meaner than that", "anger"],
    ["what are you white-knuckling that you could just let be hard.", "acceptance"],
    ["do you miss them. or do you miss who you were when they loved you.", "longing"],
    ["finish this: theres something i never admitted to you", "unsent"],
    ["what do you still buy at the store out of habit for two", "regret"],
    ["the silence felt like an answer for a while. now im not sure it was one.", "confusion"],
    ["the song comes on and you let it play the whole way through. why.", "still love you"],
    ["youll have to tell someone everything again one day. who do you want them to meet.", "moving on"],
    ["what did loving them cost you that you only see the bill for now", "anger"],
    ["did you drink water today. did you take the meds. did you breathe. be honest.", "acceptance"],
    ["whats the photo you cant delete but cant look at either.", "longing"],
    ["say the thing you were saving for the right moment that never came", "unsent"],
    ["whats the thing you broke that you cant fix now", "regret"],
    ["do you remember who you were going to be before all of this rerouted you.", "confusion"],
    ["if i love you still lives in you. who is it waiting to reach.", "still love you"],
    ["when does their absence stop being a wound and start being just a fact.", "moving on"],
    ["they want to be friends. whats the laugh you held back when they asked", "anger"],
    ["whats the first plan you made that didnt include them.", "acceptance"],
    ["describe the last good night you had together before you knew it was the last.", "longing"],
    ["type out the message you almost sent and then turned your phone off", "unsent"],
    ["what side of the bed do you still not sleep on", "regret"],
    ["some nights i dont miss them at all and that absence is its own kind of strange.", "confusion"],
    ["be honest. do you want them back. or do you want who you were with them.", "still love you"],
    ["i moved their stuff into a box today. didnt cry. didnt feel good either. what is this.", "moving on"],
    ["whats the favor you did at 2am that they never even thanked you for", "anger"],
    ["what did you let yourself enjoy today without guilt.", "acceptance"],
    ["i wonder if they kept the thing i gave them. or if its in a drawer somewhere.", "longing"],
    ["write what you wish youd said instead of okay", "unsent"],
    ["whats the night you wish you had just stayed", "regret"],
    ["they apologized for the wrong thing and i never figured out what i was actually owed.", "confusion"],
    ["if they apologized. really apologized. would the love come rushing back.", "still love you"],
    ["what would you do with the hours you used to spend keeping them happy.", "moving on"],
    ["you were loyal to someone who was auditioning replacements. how does that sit tonight", "anger"],
    ["you woke up and chose to keep going. name what that took.", "acceptance"],
    ["whats the time of day that hits the hardest. morning. dusk. 2am.", "longing"],
    ["the sentence you couldnt finish out loud. finish it here.", "unsent"],
    ["what did you let get cold and small instead of saying it out loud", "regret"],
    ["am i moving on or just moving. theres a difference and i lost it somewhere.", "confusion"],
    ["you keep saying it was for the best. say what you actually feel.", "still love you"],
    ["name something you want now that you wouldnt have let yourself want with them.", "moving on"],
    ["did they break it slow so they could pretend it wasnt them. catch them in it", "anger"],
    ["what part of you is starting to come back. dont scare it off. just notice.", "acceptance"],
    ["do you still wear the thing that smells like them. or did you have to stop.", "longing"],
    ["type the confession you only make when its dark", "unsent"],
    ["what number do you still know by heart that you cant call", "regret"],
    ["i cant tell if i want them or if i just want to not be the one who lost.", "confusion"],
    ["would you trade being right for having them. tonight. yes or no.", "still love you"],
    ["the future used to have their face in it. whats there now when you squint.", "moving on"],
    ["what excuse of theirs do you want to set on fire right now", "anger"],
    ["name the bare minimum you did today and call it enough. because it is.", "acceptance"],
    ["say it. you would still pick up if they called right now.", "longing"],
    ["write what you held back the night everything changed", "unsent"],
    ["what did you do the day after that you still cringe about", "regret"],
    ["everyone keeps saying youll understand it later. its later. i dont.", "confusion"],
    ["theres a name your heart still calls home. you dont have to say it. but.", "still love you"],
    ["i dont want closure. i want to wake up one day and find it already closed. can i.", "moving on"],
    ["they cried too. but whose tears were performance and whose were the real wound", "anger"],
    ["what are you pretending doesnt still ache on the quiet days.", "acceptance"],
    ["what season reminds you of them and is it coming back around.", "longing"],
    ["finish this: i never got to tell you that you", "unsent"],
    ["whats the plan you two made that you cant unmake in your head", "regret"],
    ["do you miss the person or the future you already lived in your head with them.", "confusion"],
    ["if they reached for your hand right now. would you pull away. would you.", "still love you"],
    ["finish this: i used to be theirs, and now im slowly becoming", "moving on"],
    ["how long did you confuse their carelessness for something youd done wrong", "anger"],
    ["did you eat something real today or just whatever was closest. no judgment.", "acceptance"],
    ["i practice what id say if i ran into them. ive practiced it a hundred times.", "longing"],
    ["say what you wanted to whisper but kept quiet", "unsent"],
    ["finish this: i keep thinking if id picked up the phone", "regret"],
    ["i went a whole day without it hurting and then i felt guilty. explain that one to me.", "confusion"],
    ["be honest. how much of moving on is just acting until they cant tell.", "still love you"],
    ["what is the smallest sign that youre healing that you almost didnt notice.", "moving on"],
    ["whats the version of events theyll tell their next person about you. correct the record here", "anger"],
    ["whats one thing that felt steady when everything else didnt.", "acceptance"],
    ["whats the food you cant order anymore because it was yours together.", "longing"],
    ["type the message your hands wrote that your heart deleted", "unsent"],
    ["whats the show you still cant watch the rest of without them", "regret"],
    ["is this acceptance or have i just made a home out of being unsure.", "confusion"],
    ["the love you swore you killed. its still breathing isnt it. quietly.", "still love you"],
    ["you dont have to be over it to start walking. which direction faces away from them.", "moving on"],
    ["you held the whole thing up alone and they called it a partnership. whats the word you actually want to use", "anger"],
    ["you got through dinner. through the night. through the morning. what helped.", "acceptance"],
    ["do you imagine them happy without you. does it gut you or do you want it for them.", "longing"],
    ["write the thing you wish theyd known before it was too late", "unsent"],
    ["what did you blame on them that was really on you", "regret"],
    ["i dont know if i loved them or loved being chosen. those felt the same until they werent.", "confusion"],
    ["if they said i never stopped. what would you say back. dont think.", "still love you"],
    ["when did you last make a plan that stretched past the part of your life that had them.", "moving on"],
    ["did they ever fight for it or did they just let you do all the bleeding", "anger"],
    ["name a small thing you looked forward to today. it doesnt have to be big.", "acceptance"],
    ["finish this: nobody warned me that missing someone could feel like", "longing"],
    ["the words you owe yourself, not them. write those.", "unsent"],
    ["whats the seat at the table thats still theirs in your head", "regret"],
    ["the relationship made sense from the inside. now i cant rebuild the logic of it.", "confusion"],
    ["would you give up the closure just to keep the hope. some of you would.", "still love you"],
    ["i practiced their name in past tense today. it didnt break me. when did that happen.", "moving on"],
    ["whats the kindness you showed them that they used as a weapon later", "anger"],
    ["what are you surviving right now that you wont always have to survive.", "acceptance"],
    ["what would you say if you got thirty seconds and they had to listen.", "longing"],
    ["finish this: what i was too proud to say is", "unsent"],
    ["what would you say if they walked in right now and you had ten seconds", "regret"],
    ["do you feel free or just untethered. i keep mixing those two up.", "confusion"],
    ["you still set a place for them somehow. in your head. dont you.", "still love you"],
    ["what would it take to believe the next chapter isnt just an apology for this one.", "moving on"],
    ["theyre sleeping fine tonight. that should make you angrier than it makes you sad. does it", "anger"],
    ["did you let yourself sit still today without filling the quiet. how was it.", "acceptance"],
    ["i still set out two mugs sometimes. by accident. by habit. by hope.", "longing"],
    ["type out the letter you read to no one and then closed", "unsent"],
    ["what did you wait too long to forgive them for", "regret"],
    ["i stopped checking their profile and i cant tell if thats strength or surrender.", "confusion"],
    ["if love is a choice. why does it keep choosing them without asking you.", "still love you"],
    ["what would younger you say if she saw how long you let them stay", "anger"],
    ["what felt like the first easy breath in a while. hold onto that one.", "acceptance"],
    ["whats the word or phrase only they used. do you still hear it.", "longing"],
    ["write what you couldnt say without breaking, so you said nothing", "unsent"],
    ["they came back warm for a week then vanished. i never got to ask which one was them.", "confusion"],
    ["be honest. if they came back changed and real. would you risk it all again.", "still love you"],
    ["say the thing you keep softening for everyone else. dont soften it here", "anger"],
    ["do you reread old messages knowing it makes it worse. why do you do it.", "longing"],
    ["how are you. really. not better, not worse. just whatever this in-between is.", "confusion"],
    ["the thing you most want them to know. youre not over it. write it anyway.", "still love you"],
    ["what does their absence sound like in your apartment at night.", "longing"],
    ["be honest. are you waiting for them. how long will you wait.", "longing"],
    ["whats the dream you keep having where theyre back. how do you feel when you wake.", "longing"],
    ["i would trade almost anything for the weight of their head on my chest one more time.", "longing"],
];
function dayOfYear(d = new Date()) {
    return Math.floor((d - new Date(d.getFullYear(), 0, 0)) / 86400e3);
}
const todaysPrompt = () => DAILY_PROMPTS[dayOfYear() % DAILY_PROMPTS.length];
const todaysPromptDate = () => {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
};
// Set by the prompt card's "respond" click; consumed by the next compose.
let promptContext = null; // {promptDate, tag}

// Post visible on read surfaces: mirrors iOS filterBlocked + expiry + flagged.
function postVisible(d) {
    if (d.flagged === true) return false;
    if (d.expiresAt?.toDate && d.expiresAt.toDate() < new Date()) return false;
    if (blocked.has(d.authorId)) return false;
    if (d.originalAuthorId && blocked.has(d.originalAuthorId)) return false;
    return true;
}

// ---------------------------------------------------------------- shared UI
// Tag palette from the marketing site — muted, tag-specific ink.
const TAG_COLORS = {
    "longing": "#7a6fc0", "anger": "#c0736f", "acceptance": "#6f9c8a",
    "regret": "#a58a6f", "confusion": "#8a8a9c", "still love you": "#b07a8a",
    "moving on": "#6f9c8a", "numb": "#8a8a9c",
};
function tagChip(tag) {
    if (!tag) return null;
    const c = TAG_COLORS[tag] ?? "var(--plum-soft)";
    return el("span", { class: "tag", style: `color:${c};` }, tag);
}
function statsRow(d) {
    const bits = [];
    if ((d.replyCount ?? 0) > 0) bits.push(el("span", {}, `${d.replyCount} ${d.replyCount === 1 ? "reply" : "replies"}`));
    if ((d.likeCount ?? 0) > 0) bits.push(el("span", {}, `${d.likeCount} felt this`));
    if ((d.repostCount ?? 0) > 0) bits.push(el("span", {}, `${d.repostCount} reposts`));
    return bits.length ? el("div", { class: "post-stats" }, bits) : null;
}
// "whisper · fades in 42m" / "midnight · fades at midnight" chips on
// ephemeral posts (web-only affordance; iOS shows the state in compose).
function ephemeralChip(d) {
    if (d.isWhisper !== true && d.isMidnightPost !== true) return null;
    let fade = "";
    const exp = d.expiresAt?.toDate?.();
    if (exp) {
        const mins = Math.max(1, Math.round((exp - Date.now()) / 60e3));
        fade = d.isWhisper ? ` · fades in ${mins}m` : " · fades at midnight";
    }
    return el("span", { class: "tag ephemeral" }, (d.isWhisper ? "whisper" : "midnight") + fade);
}
function postRow(id, d) {
    const meta = el("div", { class: "post-meta" },
        el("span", { class: "handle" }, d.isRepost ? (d.originalHandle ?? "anonymous") : (d.authorHandle ?? "anonymous")),
        el("span", {}, relTime(d.createdAt)),
        tagChip(d.tag),
        ephemeralChip(d),
    );
    return el("a", { class: "post-row", href: `#/post/${id}` },
        d.isRepost ? el("div", { class: "repost-strip" }, `${d.authorHandle ?? "anonymous"} reposted`) : null,
        meta,
        el("div", { class: "post-text" }, d.text ?? ""),
        d.gifUrl ? el("img", { src: d.gifUrl, loading: "lazy", style: "max-width:100%; border-radius:12px; margin-top:12px;", alt: "gif" }) : null,
        statsRow(d),
    );
}

function emptyState(msg) {
    return el("div", { class: "empty" }, el("span", { class: "glyph" }, "☾"), msg);
}

function pendingBanner(reasonLabel) {
    return el("div", { class: "pending-banner" },
        `under review${reasonLabel ? " — " + reasonLabel : ""}. only you can see this right now.`);
}

function errorBox(msg) { return el("div", { class: "error" }, msg); }
const GENERIC_ERR = "something went wrong. try again in a moment.";

const EYE_SVG = '<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7-11-7-11-7z"/><circle cx="12" cy="12" r="3"/></svg>';
const EYE_OFF_SVG = '<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 19c-7 0-11-7-11-7a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 7 11 7a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/></svg>';

// password input wrapped with a show/hide eye toggle
function pwField(pw) {
    const toggle = el("button", { type: "button", class: "pw-toggle", "aria-label": "show password", "aria-pressed": "false" });
    toggle.innerHTML = EYE_SVG;
    toggle.onclick = () => {
        const show = pw.type === "password";
        pw.type = show ? "text" : "password";
        toggle.innerHTML = show ? EYE_OFF_SVG : EYE_SVG;
        toggle.setAttribute("aria-label", show ? "hide password" : "show password");
        toggle.setAttribute("aria-pressed", String(show));
        pw.focus();
    };
    return el("div", { class: "pw-wrap" }, pw, toggle);
}

// ---------------------------------------------------------------- auth views
function viewSignIn() {
    setChrome(true);
    const email = el("input", { type: "email", autocomplete: "email", placeholder: "you@example.com" });
    const pw = el("input", { type: "password", autocomplete: "current-password", placeholder: "password" });
    const err = el("div");
    const btn = el("button", { class: "btn", style: "width:100%; margin-top:8px;" }, "sign in");
    btn.onclick = async () => {
        err.replaceChildren(); btn.disabled = true;
        try {
            await signInWithEmailAndPassword(auth, email.value.trim(), pw.value);
        } catch (e) {
            const m = /invalid-credential|wrong-password|user-not-found/.test(e.code ?? "")
                ? "that email and password don't match." : GENERIC_ERR;
            err.replaceChildren(errorBox(m)); btn.disabled = false;
        }
    };
    const resetNote = el("div");
    const forgot = el("a", { class: "plain", href: "#", style: "font-size:13px;" }, "forgot your password?");
    forgot.onclick = async (ev) => {
        ev.preventDefault();
        resetNote.replaceChildren();
        const addr = email.value.trim();
        if (!addr) { resetNote.replaceChildren(errorBox("type your email above first, then tap this again.")); return; }
        try {
            await sendPasswordResetEmail(auth, addr);
            resetNote.replaceChildren(el("p", { class: "note", style: "margin:10px 0; color:var(--plum);" },
                "if that email has an account, a reset link is on its way. check your inbox."));
        } catch {
            resetNote.replaceChildren(el("p", { class: "note", style: "margin:10px 0; color:var(--plum);" },
                "if that email has an account, a reset link is on its way. check your inbox."));
        }
    };
    mount.replaceChildren(
        el("div", { class: "auth-card" },
            el("h1", { style: "color:var(--plum);" }, "toska"),
            el("p", { class: "note tagline" }, "an anonymous space for heartbreak."),
            el("div", { class: "field" }, el("label", {}, "email"), email),
            el("div", { class: "field" }, el("label", {}, "password"), pwField(pw)),
            el("div", { style: "margin:2px 0 4px;" }, forgot),
            resetNote,
            err, el("div", { style: "margin-top:6px;" }, btn),
            el("p", { class: "note", style: "margin-top:20px;" },
                "new here? ", el("a", { class: "plain", href: "#/signup" }, "create an account")),
        )
    );
}

// Sign-up mirrors CreateAccountView: auth user → claim handle + users doc in
// ONE batch (retried with fresh handles) → private email → confirmAdult
// callable → verified. Any failure rolls the auth user back.
function viewSignUp() {
    setChrome(true);
    const email = el("input", { type: "email", autocomplete: "email", placeholder: "you@example.com" });
    const pw = el("input", { type: "password", autocomplete: "new-password", placeholder: "at least 6 characters" });
    const adult = el("input", { type: "checkbox", id: "adultCk", style: "width:auto;" });
    const terms = el("input", { type: "checkbox", id: "termsCk", style: "width:auto;" });
    const err = el("div");
    const btn = el("button", { class: "btn", style: "width:100%; margin-top:8px;" }, "create account");
    btn.onclick = async () => {
        err.replaceChildren();
        if (!adult.checked) { err.replaceChildren(errorBox("toska is for adults — please confirm you're 18 or older.")); return; }
        if (!terms.checked) { err.replaceChildren(errorBox("please read and accept the terms and privacy policy to continue.")); return; }
        btn.disabled = true;
        signupInProgress = true;
        let created = false;
        try {
            const cred = await createUserWithEmailAndPassword(auth, email.value.trim(), pw.value);
            created = true;
            const uid = cred.user.uid;
            await claimHandleAndCreateUserDoc(uid);
            await setDoc(doc(db, "users", uid, "private", "data"), { email: email.value.trim() }, { merge: true });
            try {
                await httpsCallable(functions, "confirmAdult")({});
            } catch (e) {
                // Staging web has no App Check attestation; the app re-fires
                // confirmAdult on later sign-ins, matching iOS behavior.
                console.warn("confirmAdult deferred", e?.code);
            }
            signupInProgress = false;
            initWrites(db, uid);
            startBlockedListener(uid);
            startNotifBadge(uid);
            location.hash = "#/";
            route();
        } catch (e) {
            signupInProgress = false;
            const m = e?.code === "auth/email-already-in-use" ? "that email already has an account — sign in instead."
                : e?.code === "auth/weak-password" ? "password needs at least 6 characters."
                : GENERIC_ERR;
            // toast survives the re-render that the rollback's auth event triggers
            toast(m, 5000);
            err.replaceChildren(errorBox(m)); btn.disabled = false;
            if (created && auth.currentUser) { try { await auth.currentUser.delete(); } catch {} }
        }
    };
    mount.replaceChildren(
        el("div", { class: "auth-card" },
            el("h1", { style: "font-size:28px;" }, "create your account"),
            el("p", { class: "note tagline" },
                "no real names. you'll get an anonymous handle."),
            el("div", { class: "field" }, el("label", {}, "email"), email),
            el("div", { class: "field" }, el("label", {}, "password"), pwField(pw)),
            el("label", { class: "note", style: "display:flex; gap:9px; align-items:flex-start; margin:16px 0 4px; cursor:pointer;", for: "adultCk" },
                adult, el("span", {}, "i confirm i'm 18 or older")),
            el("label", { class: "note", style: "display:flex; gap:9px; align-items:flex-start; margin:10px 0 14px; cursor:pointer;", for: "termsCk" },
                terms, el("span", {},
                    "i have read and agree to the ",
                    el("a", { class: "plain", href: "https://www.toskaapp.com/terms.html", target: "_blank" }, "terms of service"),
                    " and ",
                    el("a", { class: "plain", href: "https://www.toskaapp.com/privacy.html", target: "_blank" }, "privacy policy"))),
            err, el("div", { style: "margin-top:6px;" }, btn),
            el("p", { class: "note", style: "margin-top:20px;" },
                "already have an account? ", el("a", { class: "plain", href: "#/signin" }, "sign in")),
        )
    );
}

async function claimHandleAndCreateUserDoc(uid) {
    for (let attempt = 0; attempt < 4; attempt++) {
        const handle = "anonymous_" + crypto.randomUUID().replaceAll("-", "").slice(0, 8);
        try {
            const taken = await getDoc(doc(db, "handles", handle.toLowerCase()));
            if (taken.exists()) continue;
        } catch { /* availability check is best-effort; the batch is the arbiter */ }
        const batch = writeBatch(db);
        batch.set(doc(db, "users", uid), {
            handle,
            followerCount: 0, followingCount: 0, totalLikes: 0,
            allowSharing: true, showFollowerCount: false,
            hasCompletedOnboarding: false,
            createdAt: serverTimestamp(),
            acceptedPolicyVersion: POLICY_VERSION,
            acceptedPolicyAt: serverTimestamp(),
        });
        batch.set(doc(db, "handles", handle.toLowerCase()), { uid });
        try { await batch.commit(); return handle; }
        catch (e) { if (attempt === 3) throw e; }
    }
    throw new Error("could not claim a handle");
}

// ---------------------------------------------------------------- feed
let feedTab = "for you";
// Feed cache (§ perf): a route hit within TTL re-renders the last fetch and
// restores scroll instead of re-burning a 60-doc query. Tapping the active
// tab forces a refresh (the web stand-in for pull-to-refresh). Cached rows
// re-run postVisible at render, so blocks and whisper expiry still apply.
const FEED_TTL = 120e3;
const feedCache = new Map(); // tab -> {rows, cursor, noMore, scrollY, at}
let activeFeedTab = null;    // which tab's list is on screen (for scroll save)
function saveFeedScroll() {
    const c = activeFeedTab ? feedCache.get(activeFeedTab) : null;
    if (c) c.scrollY = window.scrollY;
}
function invalidateFeedCache() { feedCache.clear(); }
let followingUids = null; // {uids, at} — the follow graph only changes via block on web
function onSocialGraphChange() { followingUids = null; feedCache.delete("following"); }
async function viewFeed() {
    setChrome(false);
    saveFeedScroll(); // tab switches re-enter here without passing through route()
    activeFeedTab = null;
    const list = el("div");
    const tabs = el("div", { class: "tabs" },
        ["for you", "following"].map(t =>
            el("button", { class: `tab ${feedTab === t ? "active" : ""}`, onclick: () => {
                if (feedTab === t) feedCache.delete(t);
                feedTab = t; viewFeed();
            } }, t)),
    );
    // Daily prompt card — same client-static list + dayOfYear pick as iOS.
    const [pText, pTag] = todaysPrompt();
    const respond = el("button", { class: "btn quiet" }, "respond");
    respond.onclick = () => {
        promptContext = { text: pText, tag: pTag, promptDate: todaysPromptDate() };
        location.hash = "#/compose";
    };
    const promptCard = el("div", { class: "prompt-card" },
        el("div", { class: "eyebrow" }, "today's prompt"),
        el("div", { class: "post-text", style: "font-size:16.5px;" }, pText),
        el("div", { style: "display:flex; align-items:center; gap:10px; margin-top:10px;" },
            tagChip(pTag), respond));
    // Search — honest scope, same as FeedView: filters only what's already
    // fetched (text + handle), no extra Firestore round-trip.
    const search = el("input", {
        type: "search", class: "feed-search", placeholder: "search what's been said here…",
    });
    mount.replaceChildren(promptCard, search, tabs, list, spinner());
    const applyFilter = () => {
        const q = search.value.trim().toLowerCase();
        let any = false;
        for (const row of list.querySelectorAll(".post-row")) {
            const hit = !q || row.textContent.toLowerCase().includes(q);
            row.hidden = !hit;
            any = any || hit;
        }
        list.querySelector(".search-empty")?.remove();
        if (!any) list.append(el("div", { class: "empty search-empty" },
            el("span", { class: "glyph" }, "☾"), `nothing here matches "${q}" — it only searches what's loaded.`));
    };
    search.addEventListener("input", debounce(applyFilter, 250));
    const tab = feedTab;
    const finish = (cache) => {
        // A slow fetch can land after the user moved on — never touch the
        // screen (or scroll the window) for a view that's no longer mounted.
        if (feedTab !== tab || !list.isConnected) return;
        mount.querySelector(".spinner")?.remove();
        const rows = cache.rows.filter(([, d]) => postVisible(d));
        if (!rows.length) {
            list.append(emptyState("it's quiet here right now."));
            return;
        }
        for (const [id, d] of rows) list.append(postRow(id, d));
        if (tab === "for you" && cache.rows.length >= 60 && cache.cursor && !cache.noMore) {
            const more = el("button", { class: "btn quiet", style: "display:block; margin:20px auto;" }, "more");
            more.onclick = async () => {
                more.disabled = true;
                const next = await fetchForYou(cache.cursor);
                for (const [id, d] of next) list.append(postRow(id, d));
                cache.rows.push(...next);
                cache.cursor = next._cursor;
                more.disabled = false;
                if (next.length < 20) { cache.noMore = true; more.remove(); }
            };
            list.append(more);
        }
        activeFeedTab = tab;
        requestAnimationFrame(() => window.scrollTo(0, cache.scrollY ?? 0));
    };
    const cached = feedCache.get(tab);
    if (cached && Date.now() - cached.at < FEED_TTL) { finish(cached); return; }
    try {
        const rows = tab === "for you" ? await fetchForYou() : await fetchFollowing();
        const cache = { rows, cursor: rows._cursor, noMore: false, scrollY: 0, at: Date.now() };
        feedCache.set(tab, cache);
        finish(cache);
    } catch (e) {
        mount.querySelector(".spinner")?.remove();
        list.append(emptyState(GENERIC_ERR));
        console.error(e);
    }
}

async function fetchForYou(cursor) {
    // Mirrors FeedViewModel.fetchPosts / loadMorePosts. createdAt DESC render
    // order (client-side ranking is an iOS nicety, skipped here).
    const base = [where("moderationStatus", "==", "live"), orderBy("createdAt", "desc")];
    const q = cursor
        ? query(collection(db, "posts"), ...base, startAfter(cursor), limit(20))
        : query(collection(db, "posts"), ...base, limit(60));
    const snap = await getDocs(q);
    const rows = snap.docs.filter(d => postVisible(d.data())).map(d => [d.id, d.data()]);
    rows._cursor = snap.docs.at(-1);
    return rows;
}

async function fetchFollowing() {
    // Mirrors fetchFollowingPosts: following limit 200 → authorId IN chunks of 30.
    // The uid list is cached 5 min (web has no follow UI; blocks invalidate it).
    if (!followingUids || Date.now() - followingUids.at > 300e3) {
        const fl = await getDocs(query(collection(db, "users", me.uid, "following"), limit(200)));
        followingUids = { uids: fl.docs.map(d => d.id), at: Date.now() };
    }
    const uids = followingUids.uids;
    if (!uids.length) return [];
    const chunks = await Promise.all(chunk(uids, 30).map(c =>
        getDocs(query(collection(db, "posts"),
            where("moderationStatus", "==", "live"),
            where("authorId", "in", c),
            orderBy("createdAt", "desc"), limit(30)))));
    const all = chunks.flatMap(s => s.docs).filter(d => postVisible(d.data()));
    all.sort((a, b) => (b.data().createdAt?.toMillis() ?? 0) - (a.data().createdAt?.toMillis() ?? 0));
    return all.slice(0, 50).map(d => [d.id, d.data()]);
}

// ---------------------------------------------------------------- gif picker
// Giphy through the giphyProxy callable (App Check enforced server-side, so
// this works on prod; on staging web the callable 403s and we show the same
// gentle copy iOS shows on any failure). fixed_width rendition, like iOS.
function gifPicker(onPick) {
    const overlay = el("div", { class: "modal-overlay" });
    const grid = el("div", { class: "gif-grid" });
    const note = el("p", { class: "modal-hint" }, "");
    const input = el("input", { type: "search", placeholder: "search gifs…" });
    const card = el("div", { class: "modal-card gif-card" },
        el("h3", {}, "add a gif"), input, note, grid);
    overlay.addEventListener("click", (e) => { if (e.target === overlay) overlay.remove(); });
    overlay.append(card);
    document.body.append(overlay);
    async function load(q) {
        grid.replaceChildren(spinner());
        note.textContent = "";
        try {
            const payload = q ? { mode: "search", q, limit: 30 } : { mode: "trending", limit: 30 };
            const res = await httpsCallable(functions, "giphyProxy")(payload);
            const items = (res.data?.data ?? []).map(it => {
                const im = it.images ?? {};
                const url = im.fixed_width?.url ?? im.downsized?.url ?? im.original?.url;
                return url && it.id ? { id: it.id, url } : null;
            }).filter(Boolean);
            grid.replaceChildren();
            if (!items.length) { note.textContent = "nothing found — try another word."; return; }
            for (const g of items) {
                const img = el("img", { src: g.url, loading: "lazy", alt: "gif result" });
                img.onclick = () => { overlay.remove(); onPick(g.url); };
                grid.append(img);
            }
        } catch (e) {
            console.warn("giphyProxy failed", e?.code);
            grid.replaceChildren();
            note.textContent = "couldn't load gifs — try again.";
        }
    }
    input.addEventListener("input", debounce(() => load(input.value.trim()), 400));
    load("");
}

// ---------------------------------------------------------------- compose
function viewCompose() {
    setChrome(false);
    writeFab.hidden = true;
    let isLetter = false;
    let isWhisper = false;
    let isMidnight = false;
    let selectedTag = null;
    let gifUrl = null;
    // A prompt respond-click seeds the tag + promptDate for this compose only.
    const prompt = promptContext;
    promptContext = null;
    if (prompt?.tag) selectedTag = prompt.tag;
    const ta = el("textarea", { placeholder: "say it how it actually feels…", maxlength: "2100" });
    const count = el("span", { class: "char-count" }, "0 / 500");
    const err = el("div");
    const limit = () => isLetter ? 2000 : 500;
    // draft restore + debounced save (guarded on auth by draftKey)
    ta.value = loadDraft("compose");
    const persistDraft = debounce(() => saveDraft("compose", ta.value), 400);
    ta.addEventListener("input", () => {
        const n = ta.value.length;
        count.textContent = `${n} / ${limit()}`;
        count.classList.toggle("over", n > limit());
        persistDraft();
    });
    if (ta.value) queueMicrotask(() => ta.dispatchEvent(new Event("input")));
    const mkToggle = (label, get, set) => {
        const b = el("button", { class: "tab" }, label);
        b.onclick = () => { set(!get()); render(); };
        return () => { const x = el("button", { class: `tab ${get() ? "active" : ""}` }, label); x.onclick = b.onclick; return x; };
    };
    const letterT = mkToggle("✉ letter", () => isLetter, v => { isLetter = v; });
    const whisperT = mkToggle("◌ whisper", () => isWhisper, v => { isWhisper = v; if (v) isMidnight = false; });
    const midnightT = mkToggle("☾ midnight", () => isMidnight, v => { isMidnight = v; if (v) isWhisper = false; });
    const modeNote = () => {
        if (isWhisper) return "whisper · disappears in 1 hour · can't be shared or reposted";
        if (isMidnight) return "midnight · disappears at midnight";
        return null;
    };
    const gifBtn = el("button", { class: "tab" }, "gif");
    gifBtn.onclick = () => gifPicker((url) => { gifUrl = url; render(); });
    const toggleRow = el("div", { class: "compose-toggles" });
    const gifBox = el("div");
    const noteBox = el("div");
    function render() {
        toggleRow.replaceChildren(letterT(), whisperT(), midnightT(), gifBtn);
        noteBox.replaceChildren(modeNote() ? el("p", { class: "note mode-note" }, modeNote()) : "");
        gifBox.replaceChildren(gifUrl ? el("div", { class: "gif-attach" },
            el("img", { src: gifUrl, alt: "attached gif" }),
            el("button", { class: "tab", onclick: () => { gifUrl = null; render(); } }, "remove")) : "");
        ta.dispatchEvent(new Event("input"));
    }
    const tagRow = el("div", { class: "tag-picker" },
        POST_TAGS.map(t => {
            const b = el("button", { class: `tab ${selectedTag === t ? "active" : ""}` }, t);
            b.onclick = () => {
                selectedTag = selectedTag === t ? null : t;
                for (const x of tagRow.children) x.classList.toggle("active", x.textContent === selectedTag);
            };
            return b;
        }));
    const share = el("button", { class: "btn" }, "share it");
    share.onclick = async () => {
        err.replaceChildren();
        const text = ta.value.trim();
        if (!text) return;
        if (text.length > limit()) { err.replaceChildren(errorBox(`keep it under ${limit()} characters${isLetter ? "" : " — or make it a letter"}.`)); return; }
        if (!navigator.onLine) { err.replaceChildren(errorBox("you're offline. your words deserve to actually land — try again when you're back.")); return; }
        if (postRateLimited()) { err.replaceChildren(errorBox("one moment between posts — breathe, then share.")); return; }
        if (await isRestricted()) { err.replaceChildren(errorBox("your account is under review. you cannot post right now.")); return; }
        share.disabled = true;
        try {
            const gate = await runGates(text);
            if (!gate.ok) { share.disabled = false; return; }
            await createPost({
                text, tag: selectedTag, isLetter, isWhisper, isMidnight, gifUrl,
                promptDate: prompt?.promptDate,
            });
            invalidateFeedCache(); // the new post should show on the next feed visit
            saveDraft("compose", "");
            toast(gate.willBeHeld ? "shared — it'll be looked over first." : "shared, quietly.");
            location.hash = "#/me";
        } catch (e) {
            console.error(e);
            err.replaceChildren(errorBox(GENERIC_ERR));
            share.disabled = false;
        }
    };
    // NB: replaceChildren stringifies a raw null (unlike el()'s child filter)
    mount.replaceChildren(...[
        el("a", { class: "back", href: "#/" }, "← feed"),
        prompt ? el("p", { class: "note", style: "padding:0 6px;" }, `responding to today's prompt — "${prompt.text}"`) : null,
        el("div", { class: "compose-card" },
            ta,
            gifBox,
            tagRow,
            toggleRow,
            noteBox,
            el("div", { class: "compose-meta" },
                el("div", { style: "display:flex; gap:8px; align-items:center;" }, count),
                share),
            err),
        el("p", { class: "note", style: "padding:0 6px;" },
            "no names, no photos, no links. letters can run long (2000); everything else stays short (500)."),
    ].filter(Boolean));
    render();
}

// ---------------------------------------------------------------- most felt
// Mirrors TopView: today/week = createdAt-windowed limit 100 ranked by likes
// client-side; all-time = likeCount DESC directly (composite index exists).
// Only posts with ≥1 felt make the board; top 10.
let topPeriod = "today";
const TOP_CUTOFF = { today: 86400e3, "this week": 7 * 86400e3 };
async function viewTop() {
    setChrome(false);
    const list = el("div");
    const tabs = el("div", { class: "tabs" },
        ["today", "this week", "all time"].map(t =>
            el("button", { class: `tab ${topPeriod === t ? "active" : ""}`, onclick: () => { topPeriod = t; viewTop(); } }, t)),
    );
    mount.replaceChildren(tabs, list, spinner());
    try {
        let q;
        if (topPeriod === "all time") {
            q = query(collection(db, "posts"),
                where("moderationStatus", "==", "live"),
                orderBy("likeCount", "desc"), orderBy("createdAt", "desc"), limit(100));
        } else {
            const cutoff = new Date(Date.now() - TOP_CUTOFF[topPeriod]);
            q = query(collection(db, "posts"),
                where("moderationStatus", "==", "live"),
                where("createdAt", ">", cutoff),
                orderBy("createdAt", "desc"), limit(100));
        }
        const snap = await getDocs(q);
        mount.querySelector(".spinner")?.remove();
        const ranked = snap.docs
            .map(d => [d.id, d.data()])
            .filter(([, d]) => postVisible(d) && (d.likeCount ?? 0) > 0)
            .sort(([, a], [, b]) =>
                ((b.likeCount ?? 0) + (b.createdAt?.toMillis() ?? 0) / 1e15) -
                ((a.likeCount ?? 0) + (a.createdAt?.toMillis() ?? 0) / 1e15))
            .slice(0, 10);
        if (!ranked.length) {
            list.append(emptyState("nothing has been felt enough yet. it takes one."));
            return;
        }
        const [heroId, hero] = ranked[0];
        list.append(el("a", { class: "hero-card post-row", href: `#/post/${heroId}`, style: "display:block;" },
            el("div", { class: "eyebrow" },
                `most felt ${topPeriod === "all time" ? "of all time" : topPeriod}`),
            el("div", { class: "post-meta" },
                el("span", { class: "handle" }, hero.isRepost ? (hero.originalHandle ?? "anonymous") : (hero.authorHandle ?? "anonymous")),
                el("span", {}, relTime(hero.createdAt)),
                tagChip(hero.tag)),
            el("div", { class: "post-text" }, hero.text ?? ""),
            el("div", { class: "post-stats" },
                el("span", {}, `${hero.likeCount ?? 0} felt this`),
                el("span", {}, `${hero.replyCount ?? 0} replies`)),
        ));
        ranked.slice(1).forEach(([id, d], i) => {
            const row = postRow(id, d);
            row.prepend(el("span", { class: "rank-num" }, `${i + 2}.`));
            list.append(row);
        });
    } catch (e) {
        mount.querySelector(".spinner")?.remove();
        list.append(emptyState(GENERIC_ERR));
        console.error(e);
    }
}

// ---------------------------------------------------------------- notifications
// users/{uid}/notifications, createdAt DESC limit 50 (owner-only read).
// Visiting marks everything read in one batch, like the iOS sweep.
const NOTIF_ACTION = {
    like: "felt this", reply: "replied to your moment",
    follow: "followed you", repost: "shared your words",
    save: "kept your words close",
};
async function viewNotifications() {
    setChrome(false);
    const list = el("div");
    mount.replaceChildren(el("h2", { class: "section-title" }, "notifications"), list, spinner());
    try {
        const snap = await getDocs(query(collection(db, "users", me.uid, "notifications"),
            orderBy("createdAt", "desc"), limit(50)));
        mount.querySelector(".spinner")?.remove();
        const rows = snap.docs.map(d => ({ id: d.id, ...d.data() }))
            .filter(n => !blocked.has(n.fromUserId));
        if (!rows.length) { list.append(emptyState("nothing yet. when someone feels your words, it lands here.")); return; }
        for (const n of rows) {
            const action = NOTIF_ACTION[n.type] ?? (n.message || n.type);
            const preview = n.type === "reply" && n.message?.trim() ? n.message.trim() : null;
            list.append(el("a", {
                class: "post-row notif-row",
                href: n.postId ? `#/post/${n.postId}` : (n.type === "follow" && n.fromUserId ? `#/u/${n.fromUserId}` : "#/"),
                style: n.isRead === false ? "border-left: 3px solid var(--plum);" : "",
            },
                el("div", { class: "post-meta" },
                    el("span", { class: "handle" }, n.fromHandle ?? "anonymous"),
                    el("span", {}, relTime(n.createdAt))),
                el("div", { class: "post-text", style: "font-size:15.5px;" },
                    n.type === "milestone" ? (n.message || "a milestone") : action),
                preview ? el("div", { class: "note", style: "margin-top:6px;" }, `"${preview}"`) : null,
            ));
        }
        // mark-read sweep (best effort; owner-scoped update)
        const unread = snap.docs.filter(d => d.data().isRead === false);
        if (unread.length) {
            const batch = writeBatch(db);
            for (const d of unread.slice(0, 400)) batch.update(d.ref, { isRead: true });
            batch.commit().catch(() => {});
        }
    } catch (e) {
        mount.querySelector(".spinner")?.remove();
        list.append(emptyState(GENERIC_ERR));
        console.error(e);
    }
}

// ---------------------------------------------------------------- post detail
async function viewPost(postId) {
    setChrome(false);
    mount.replaceChildren(el("a", { class: "back", href: "#/" }, "← feed"), spinner());
    try {
        // Replies almost always live under this same doc id — fetch them in
        // parallel with the post doc instead of after it (a repost's target
        // differs and refetches below; reposts are the rare case).
        const earlyReplies = fetchReplies(postId).catch(() => null);
        const ps = await getDoc(doc(db, "posts", postId));
        mount.querySelector(".spinner")?.remove();
        if (!ps.exists() || !postVisible(ps.data())) {
            mount.append(emptyState("this post has disappeared."));
            return;
        }
        const d = ps.data();
        const own = d.authorId === me.uid;
        const body = el("div", { class: "post-row", style: "cursor:default;" },
            d.isRepost ? el("div", { class: "repost-strip" }, `${d.authorHandle} reposted`) : null,
            el("div", { class: "post-meta" },
                el("a", { class: "handle plain", href: `#/u/${d.isRepost ? (d.originalAuthorId ?? d.authorId) : d.authorId}` },
                    d.isRepost ? (d.originalHandle ?? "anonymous") : (d.authorHandle ?? "anonymous")),
                el("span", {}, relTime(d.createdAt)),
                tagChip(d.tag),
                ephemeralChip(d)),
            (d.moderationStatus ?? "live") !== "live" && own ? pendingBanner() : null,
            el("div", { class: "post-text", style: "font-size:19px;" }, d.text ?? ""),
            d.gifUrl ? el("img", { src: d.gifUrl, style: "max-width:100%; border-radius:10px; margin-top:10px;", alt: "gif" }) : null,
            statsRow(d),
        );

        // ---- action row: like / save / repost / overflow
        const targetPostId = d.isRepost ? (d.originalPostId ?? postId) : postId;
        const targetAuthorId = d.isRepost ? (d.originalAuthorId ?? d.authorId) : d.authorId;
        const icon = (path) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${path}</svg>`;
        const HEART = icon('<path d="M12 20.5s-7.5-4.7-9.3-9.3C1.4 7.9 3.6 4.5 7 4.5c2.2 0 3.9 1.3 5 3 1.1-1.7 2.8-3 5-3 3.4 0 5.6 3.4 4.3 6.7-1.8 4.6-9.3 9.3-9.3 9.3z"/>');
        const BOOKMARK = icon('<path d="M6.5 3.5h11a1 1 0 011 1v16l-6.5-4.2L5.5 20.5v-16a1 1 0 011-1z"/>');
        const CYCLE = icon('<path d="M4 7h11a4 4 0 014 4v1M20 17H9a4 4 0 01-4-4v-1"/><path d="M16.5 4.5L19 7l-2.5 2.5M7.5 19.5L5 17l2.5-2.5"/>');
        const mkAction = (svg, label, cls) => {
            const b = el("button", { class: "action-btn" });
            b.innerHTML = svg;
            b.append(el("span", {}, label));
            b.dataset.on = cls;
            return b;
        };
        const likeBtn = mkAction(HEART, "felt", "on-like");
        const saveBtn = mkAction(BOOKMARK, "save", "on-save");
        const repostBtn = mkAction(CYCLE, "repost", "on-repost");
        const moreBtn = el("button", { class: "action-btn overflow" }, "⋯");
        const setOn = (btn, on, onLabel, offLabel) => {
            btn.classList.toggle(btn.dataset.on, on);
            btn.querySelector("span").textContent = on ? onLabel : offLabel;
        };
        // Repost allowed unless the target is your own ORIGINAL post — from
        // your own repost row the button still works (as un-repost).
        if (targetAuthorId === me.uid) repostBtn.disabled = true;
        if (d.isWhisper === true || d.isMidnightPost === true) repostBtn.disabled = true;
        // F-P2-1: no self-felt — same rule as repost above. The isLiked()
        // read below re-enables it only if a legacy self-like exists, so
        // un-felting still works; it re-disables after that unlike.
        if (targetAuthorId === me.uid) likeBtn.disabled = true;

        likeBtn.onclick = async () => {
            const on = likeBtn.classList.contains("on-like");
            setOn(likeBtn, !on, "felt this", "felt"); // optimistic
            const r = await toggleLike(targetPostId, on, targetAuthorId).catch((e) => { console.error("like failed", e); return null; });
            if (r === null || r === "own_post") setOn(likeBtn, on, "felt this", "felt"); // revert
            else if (r === false && targetAuthorId === me.uid) likeBtn.disabled = true; // legacy self-like removed
        };
        saveBtn.onclick = async () => {
            const on = saveBtn.classList.contains("on-save");
            setOn(saveBtn, !on, "saved", "save");
            const r = await toggleSave(targetPostId, on, targetAuthorId).catch((e) => { console.error("save failed", e); return null; });
            if (r === null) setOn(saveBtn, on, "saved", "save");
        };
        repostBtn.onclick = async () => {
            const on = repostBtn.classList.contains("on-repost");
            setOn(repostBtn, !on, "reposted", "repost");
            const r = await toggleRepost(targetPostId).catch((e) => { console.error("repost failed", e); return null; });
            if (r === "blocked_ephemeral") { setOn(repostBtn, false, "reposted", "repost"); toast("whispers stay ephemeral — they can't be reposted."); }
            else if (r === "own_post" || r === null) setOn(repostBtn, on, "reposted", "repost");
            else invalidateFeedCache(); // a repost row appeared or vanished from the feed
        };
        moreBtn.onclick = () => {
            const handle = d.isRepost ? (d.originalHandle ?? "anonymous") : (d.authorHandle ?? "anonymous");
            const items = [];
            if (own) {
                // Edit only on ORIGINAL own posts — a repost's text is pinned
                // to the original at create; editing it would break that tie.
                if (!d.isRepost) items.push({
                    label: "edit",
                    onclick: () => editSheet({ text: d.text, isReply: false, onSave: (t) => editPost(postId, t) }),
                });
                items.push({
                    label: "delete", danger: true,
                    onclick: () => confirmDelete(d.isRepost ? "repost" : "post", async () => {
                        await deletePost(postId);
                        invalidateFeedCache(); // a cached feed may still hold the row
                        location.hash = "#/me";
                    }),
                });
            }
            // Public share link — same gate as the server's /p/{id} render rule
            // (sharePage.js): strict isShareable, never letters/whispers/
            // midnight. A repost's isShareable is pinned to the original at
            // create, so d.isShareable speaks for the target; the link uses
            // targetPostId because the repost id would just 301 anyway.
            if (d.isShareable === true && d.isLetter !== true && d.isWhisper !== true && d.isMidnightPost !== true) {
                items.push({
                    label: "copy link",
                    onclick: async () => {
                        try {
                            await navigator.clipboard.writeText(`https://app.toskaapp.com/p/${targetPostId}`);
                            toast("link copied — the page carries the words only, never the writer.");
                        } catch { toast(GENERIC_ERR); }
                    },
                });
            }
            items.push({
                label: "report this post",
                onclick: () => reportSheet({ type: "post", postId: targetPostId, reportedUserId: targetAuthorId, reportedHandle: handle, text: d.text }),
            });
            if (targetAuthorId !== me.uid) items.push({
                label: `block ${handle}`, danger: true,
                onclick: async () => {
                    try { await blockUser(targetAuthorId, handle); onSocialGraphChange(); toast(`${handle} is blocked. you won't see them again.`); location.hash = "#/"; }
                    catch { toast(GENERIC_ERR); }
                },
            });
            menuSheet(items);
        };
        const actions = el("div", { class: "action-row" }, likeBtn, saveBtn, repostBtn, moreBtn);

        // ---- reply composer
        const repliesBox = el("div");
        let replyingTo = null; // {id, handle}
        const replyingStrip = el("div", { class: "replying-strip" });
        const renderStrip = () => {
            replyingStrip.replaceChildren();
            if (replyingTo) {
                replyingStrip.append(`replying to ${replyingTo.handle}`,
                    el("button", { onclick: () => { replyingTo = null; renderStrip(); } }, "cancel"));
            }
        };
        const rta = el("textarea", { placeholder: "say something gently…", rows: "1", maxlength: "520" });
        let replyGif = null;
        const replyGifBox = el("div");
        const renderReplyGif = () => replyGifBox.replaceChildren(replyGif ? el("div", { class: "gif-attach" },
            el("img", { src: replyGif, alt: "attached gif" }),
            el("button", { class: "tab", onclick: () => { replyGif = null; renderReplyGif(); } }, "remove")) : "");
        // reply draft, per post, debounced; keyed per-uid like compose
        const rDraftKind = `reply_${targetPostId}`;
        rta.value = loadDraft(rDraftKind);
        const persistReplyDraft = debounce(() => saveDraft(rDraftKind, rta.value), 400);
        rta.addEventListener("input", () => {
            rta.style.height = "auto"; rta.style.height = rta.scrollHeight + "px";
            persistReplyDraft();
        });
        const rGifBtn = el("button", { class: "reply-gif", "aria-label": "add a gif" }, "gif");
        rGifBtn.onclick = () => gifPicker((url) => { replyGif = url; renderReplyGif(); });
        const send = el("button", { class: "reply-send", "aria-label": "send reply" }, "↑");
        send.onclick = async () => {
            const text = rta.value.trim();
            if (text.length < 2) return;
            if (text.length > 500) { toast("replies stay under 500 characters."); return; }
            if (!navigator.onLine) { toast("you're offline — try again when you're back."); return; }
            send.disabled = true;
            try {
                const gate = await runGates(text, { isReply: true });
                if (!gate.ok) { send.disabled = false; return; }
                await createReply(targetPostId, {
                    text, parentReplyId: replyingTo?.id,
                    parentPostText: d.text,
                    // reply lands on the ORIGINAL post — snapshot its author,
                    // not the reposter, as the parent context
                    parentPostHandle: d.isRepost ? (d.originalHandle ?? "") : d.authorHandle,
                    postAuthorId: targetAuthorId,
                    gifUrl: replyGif,
                });
                rta.value = ""; rta.style.height = "auto";
                saveDraft(rDraftKind, "");
                replyGif = null; renderReplyGif();
                replyingTo = null; renderStrip();
                toast(gate.willBeHeld ? "sent — it'll be looked over first." : "sent, gently.");
                const rows = await fetchReplies(targetPostId);
                repliesBox.replaceChildren();
                renderThread(repliesBox, rows, null, 0, onReplyTo);
            } catch (e) { console.error(e); toast(GENERIC_ERR); }
            send.disabled = false;
        };
        const composer = el("div", {},
            replyingStrip,
            replyGifBox,
            el("div", { class: "reply-composer" }, rta, rGifBtn, send));
        const onReplyTo = (r) => { replyingTo = { id: r.id, handle: r.authorHandle ?? "anonymous" }; renderStrip(); rta.focus(); };

        mount.append(body, actions, composer,
            el("h3", { style: "margin:18px 0 4px; font-weight:500;" }, "replies"), repliesBox, spinner());
        // Interaction-state reads fire after the body is on screen (§ perf):
        // three exists() doc reads that shouldn't contend with first paint.
        isLiked(targetPostId).then(v => {
            setOn(likeBtn, v, "felt this", "felt");
            if (v) likeBtn.disabled = false; // legacy self-like — allow un-felt
        });
        isSaved(targetPostId).then(v => setOn(saveBtn, v, "saved", "save"));
        if (!repostBtn.disabled) isReposted(targetPostId).then(v => setOn(repostBtn, v, "reposted", "repost"));
        const replies = (targetPostId === postId ? await earlyReplies : null)
            ?? await fetchReplies(targetPostId);
        mount.querySelector(".spinner")?.remove();
        if (!replies.length) repliesBox.append(emptyState("no replies yet. someone will find this."));
        renderThread(repliesBox, replies, null, 0, onReplyTo);
    } catch (e) {
        mount.querySelector(".spinner")?.remove();
        mount.append(emptyState("this post isn't available."));
        console.error(e);
    }
}

// Edit sheet for own posts/replies. Mirrors PostDetailView.attemptSave: the
// full gate set runs on the edited text, restriction blocks the save, and the
// char cap floors at the current length (a legacy over-cap post stays
// editable without forced truncation).
function editSheet({ text, isReply, onSave }) {
    const baseCap = isReply ? 500 : 2000;
    const cap = Math.max(baseCap, (text ?? "").length);
    const overlay = el("div", { class: "modal-overlay" });
    const ta = el("textarea", { maxlength: String(cap) }, );
    ta.value = text ?? "";
    const count = el("span", { class: "char-count" }, `${ta.value.length} / ${cap}`);
    ta.addEventListener("input", () => {
        count.textContent = `${ta.value.length} / ${cap}`;
        count.classList.toggle("over", ta.value.length > cap);
    });
    const err = el("div");
    const save = el("button", { class: "btn" }, "save");
    save.onclick = async () => {
        err.replaceChildren();
        const t = ta.value.trim();
        if (!t) { err.replaceChildren(errorBox("it can't be empty — delete it instead if you want it gone.")); return; }
        if (t.length > cap) { err.replaceChildren(errorBox(`keep it under ${cap} characters.`)); return; }
        if (!navigator.onLine) { err.replaceChildren(errorBox("you're offline — try again when you're connected.")); return; }
        if (await isRestricted()) { err.replaceChildren(errorBox("your account is under review. you cannot edit right now.")); return; }
        save.disabled = true;
        try {
            const gate = await runGates(t, { isReply });
            if (!gate.ok) { save.disabled = false; return; }
            await onSave(t);
            invalidateFeedCache(); // cached feed rows may hold the old text
            overlay.remove();
            toast(gate.willBeHeld ? "saved — it'll be looked over first." : "saved.");
            route();
        } catch (e) {
            console.error(e);
            err.replaceChildren(errorBox(GENERIC_ERR));
            save.disabled = false;
        }
    };
    const card = el("div", { class: "modal-card edit-card" },
        el("h3", {}, isReply ? "edit your reply" : "edit your post"),
        ta, err,
        el("div", { class: "modal-actions" },
            save,
            el("button", { class: "btn quiet", onclick: () => overlay.remove() }, "cancel"),
            count),
    );
    overlay.addEventListener("click", (e) => { if (e.target === overlay) overlay.remove(); });
    overlay.append(card);
    document.body.append(overlay);
    ta.focus();
}

// Quiet, honest delete confirm. Cloud Functions cascade the cleanup.
function confirmDelete(what, onConfirm) {
    const overlay = el("div", { class: "modal-overlay" });
    const card = el("div", { class: "modal-card" },
        el("h3", {}, `delete this ${what}?`),
        el("p", { class: "modal-body" }, "it's gone for good. no archive, no undo."),
        el("div", { class: "modal-actions" },
            el("button", { class: "btn danger", onclick: async () => {
                overlay.remove();
                try { await onConfirm(); toast("deleted."); }
                catch (e) { console.error(e); toast(GENERIC_ERR); }
            } }, "delete"),
            el("button", { class: "btn quiet", onclick: () => overlay.remove() }, "keep it")),
    );
    overlay.addEventListener("click", (e) => { if (e.target === overlay) overlay.remove(); });
    overlay.append(card);
    document.body.append(overlay);
}

function reportSheet(target) { // {type, postId?, replyId?, reportedUserId, reportedHandle, text?}
    const overlay = el("div", { class: "modal-overlay" });
    const card = el("div", { class: "modal-card" });
    overlay.addEventListener("click", (e) => { if (e.target === overlay) overlay.remove(); });
    card.append(el("h3", {}, "what's wrong here?"),
        el("p", { class: "modal-hint", style: "margin-bottom:10px;" }, "reports are anonymous. a human looks at every one."));
    for (const r of REPORT_REASONS) {
        card.append(el("button", {
            class: "tab", style: "display:block; width:100%; text-align:left; margin:7px 0; border-radius:12px; padding:13px 15px;",
            onclick: async () => {
                overlay.remove();
                try { await submitReport({ ...target, reason: r.code, reasonLabel: r.label }); toast("thank you. we'll look at it."); }
                catch (e) { console.error(e); toast(GENERIC_ERR); }
            },
        }, r.label));
    }
    overlay.append(card);
    document.body.append(overlay);
}

async function fetchReplies(postId) {
    // Two queries like iOS (rules deny a mixed list), in parallel: live for
    // everyone, own-authored any-status for the pending banner.
    const [live, mine] = await Promise.all([
        getDocs(query(collection(db, "posts", postId, "replies"),
            where("moderationStatus", "==", "live"), orderBy("createdAt", "desc"), limit(500))),
        getDocs(query(collection(db, "posts", postId, "replies"),
            where("authorId", "==", me.uid), orderBy("createdAt", "asc"))).catch(() => ({ docs: [] })),
    ]);
    const byId = new Map();
    for (const d of [...live.docs, ...mine.docs]) byId.set(d.id, d);
    const rows = [...byId.values()].map(d => ({ id: d.id, postId, ...d.data() }))
        .filter(r => !blocked.has(r.authorId))
        .sort((a, b) => (a.createdAt?.toMillis() ?? 0) - (b.createdAt?.toMillis() ?? 0));
    return rows;
}

function renderThread(container, all, parentId, depth, onReplyTo) {
    for (const r of all.filter(r => (r.parentReplyId ?? null) === parentId)) {
        const isPending = (r.moderationStatus ?? "live") !== "live";
        const own = r.authorId === me.uid;
        const stats = el("div", { class: "post-stats" });
        if ((r.likeCount ?? 0) > 0) stats.append(el("span", {}, `${r.likeCount} felt this`));
        if (onReplyTo && !isPending) {
            const rb = el("span", {});
            rb.append(el("a", { class: "plain", href: "#", style: "font-size:12.5px;", onclick: (ev) => { ev.preventDefault(); onReplyTo(r); } }, "reply"));
            stats.append(rb);
        }
        {
            const mb = el("span", {});
            mb.append(el("a", { class: "plain", href: "#", style: "font-size:12.5px; color:var(--faint);", onclick: (ev) => {
                ev.preventDefault();
                menuSheet(own ? [
                    { label: "edit", onclick: () => editSheet({ text: r.text, isReply: true, onSave: (t) => editReply(r.postId, r.id, t) }) },
                    { label: "delete", danger: true, onclick: () => confirmDelete("reply", async () => { await deleteReply(r.postId, r.id); route(); }) },
                ] : [
                    { label: "report this reply", onclick: () => reportSheet({ type: "reply", postId: r.postId ?? null, replyId: r.id, reportedUserId: r.authorId, reportedHandle: r.authorHandle, text: r.text }) },
                    { label: `block ${r.authorHandle ?? "anonymous"}`, danger: true, onclick: async () => {
                        try { await blockUser(r.authorId, r.authorHandle); onSocialGraphChange(); toast("blocked. you won't see them again."); route(); }
                        catch { toast(GENERIC_ERR); }
                    } },
                ]);
            } }, "⋯"));
            stats.append(mb);
        }
        container.append(el("div", {
            class: `post-row reply-row ${depth > 0 ? "thread-child" : ""}`,
            style: `cursor:default; margin-left:${Math.min(depth, 3) * 18}px;` },
            el("div", { class: "post-meta" },
                el("a", { class: "handle plain", href: `#/u/${r.authorId}` }, r.authorHandle ?? "anonymous"),
                el("span", {}, relTime(r.createdAt))),
            isPending ? pendingBanner() : null,
            el("div", { class: "post-text" }, r.text ?? ""),
            r.gifUrl ? el("img", { src: r.gifUrl, loading: "lazy", style: "max-width:100%; border-radius:10px; margin-top:8px;", alt: "gif" }) : null,
            stats,
        ));
        renderThread(container, all, r.id, depth + 1, onReplyTo);
    }
}

// ---------------------------------------------------------------- profiles
async function viewProfile(uid) {
    setChrome(false);
    const own = uid === me.uid;
    // Own profile is a top-level tab — no back link; others get one.
    mount.replaceChildren(own ? el("span") : el("a", { class: "back", href: "#/" }, "← feed"), spinner());
    let u = null;
    try { u = await getDoc(doc(db, "users", uid)); }
    catch { // rules: a user who blocked me denies this read
        mount.querySelector(".spinner")?.remove();
        mount.append(emptyState("this profile isn't available."));
        return;
    }
    mount.querySelector(".spinner")?.remove();
    if (!u.exists()) { mount.append(emptyState("this profile isn't available.")); return; }
    const ud = u.data();
    const joined = ud.createdAt?.toDate ?
        ud.createdAt.toDate().toLocaleDateString("en-US", { month: "long", year: "numeric" }) : "";
    const showFollowers = own || ud.showFollowerCount === true;
    const stat = (n, label) => el("span", {}, el("b", {}, String(n ?? 0)), ` ${label}`);
    const head = el("div", { class: "profile-head" },
        el("h2", {}, ud.handle ?? "anonymous"),
        joined ? el("div", { class: "joined" }, `here since ${joined}`) : null,
        el("div", { class: "stat-line" },
            showFollowers ? stat(ud.followerCount, "followers") : null,
            own ? stat(ud.followingCount, "following") : null,
            stat(ud.totalLikes, "felt")),
        own ? el("a", { class: "plain", href: "#/blocked", style: "font-size:13px;" }, "blocked users") : null,
    );
    const list = el("div");
    if (own) {
        let tab = "posts";
        const tabsRow = () => el("div", { class: "tabs" },
            ["posts", "liked", "saved", "replies"].map(t =>
                el("button", { class: `tab ${tab === t ? "active" : ""}`, onclick: () => { tab = t; refresh(); } }, t)));
        const tabsMount = el("div", {}, tabsRow());
        const refresh = async () => {
            tabsMount.replaceChildren(tabsRow());
            list.replaceChildren(spinner());
            try {
                if (tab === "posts") renderPostDocs(list, await fetchOwnPosts(),
                    { showPending: true, emptyMsg: "no posts yet. the app is where words begin." });
                else if (tab === "liked") renderPostDocs(list, await fetchRefTab("liked"),
                    { emptyMsg: "nothing felt yet. it finds you." });
                else if (tab === "saved") renderPostDocs(list, await fetchRefTab("saved"),
                    { emptyMsg: "nothing saved yet. keep what helps." });
                else renderReplyDocs(list, await fetchUserReplies(uid),
                    "no replies yet. someone's words will need yours.");
            } catch (e) { list.replaceChildren(emptyState(GENERIC_ERR)); console.error(e); }
        };
        mount.append(head, tabsMount, list);
        refresh();
    } else {
        mount.append(head, list, spinner());
        try {
            const posts = await fetchOtherPosts(uid);
            mount.querySelector(".spinner")?.remove();
            renderPostDocs(list, posts, { emptyMsg: "nothing shared yet." });
        } catch (e) {
            mount.querySelector(".spinner")?.remove();
            list.append(emptyState(GENERIC_ERR)); console.error(e);
        }
    }
}

function renderPostDocs(list, rows, opts = {}) {
    list.replaceChildren();
    if (!rows.length) { list.append(emptyState(opts.emptyMsg ?? "nothing here yet.")); return; }
    for (const [id, d] of rows) {
        const row = postRow(id, d);
        if (opts.showPending && (d.moderationStatus ?? "live") !== "live") row.prepend(pendingBanner());
        list.append(row);
    }
}
function renderReplyDocs(list, rows, emptyMsg) {
    list.replaceChildren();
    if (!rows.length) { list.append(emptyState(emptyMsg ?? "nothing here yet.")); return; }
    for (const r of rows) {
        list.append(el("a", { class: "post-row reply-row", href: r.postId ? `#/post/${r.postId}` : "#/" },
            el("div", { class: "post-meta" },
                el("span", { class: "handle" }, r.authorHandle ?? "anonymous"),
                el("span", {}, relTime(r.createdAt))),
            el("div", { class: "post-text" }, r.text ?? ""),
        ));
    }
}

async function fetchOwnPosts() {
    // No moderationStatus filter: owner sees own pending posts (rules author leg).
    const snap = await getDocs(query(collection(db, "posts"),
        where("authorId", "==", me.uid), orderBy("createdAt", "desc"), limit(50)));
    return snap.docs.filter(d => {
        const x = d.data();
        return !(x.expiresAt?.toDate && x.expiresAt.toDate() < new Date());
    }).map(d => [d.id, d.data()]);
}
async function fetchOtherPosts(uid) {
    const snap = await getDocs(query(collection(db, "posts"),
        where("moderationStatus", "==", "live"), where("authorId", "==", uid),
        orderBy("createdAt", "desc"), limit(50)));
    return snap.docs.filter(d => postVisible(d.data())).map(d => [d.id, d.data()]);
}
async function fetchRefTab(sub) {
    // users/{uid}/liked|saved refs → hydrate via documentId IN chunks of 30.
    const refs = await getDocs(query(collection(db, "users", me.uid, sub),
        orderBy("createdAt", "desc"), limit(50)));
    const ids = refs.docs.map(d => d.id);
    if (!ids.length) return [];
    const snaps = await Promise.all(chunk(ids, 30).map(c =>
        getDocs(query(collection(db, "posts"), where(documentId(), "in", c)))));
    const byId = new Map(snaps.flatMap(s => s.docs).map(d => [d.id, d]));
    return ids.filter(id => byId.has(id))
        .map(id => [id, byId.get(id).data()])
        .filter(([, d]) => (d.moderationStatus ?? "live") === "live" && postVisible(d));
}
async function fetchUserReplies(uid) {
    const snap = await getDocs(query(collectionGroup(db, "replies"),
        where("authorId", "==", uid), orderBy("createdAt", "desc"), limit(30)));
    return snap.docs.map(d => ({ id: d.id, postId: d.ref.parent.parent?.id, ...d.data() }));
}

// ---------------------------------------------------------------- blocked users
// Settings-lite: the block docs store handle when it was known at block time.
async function viewBlocked() {
    setChrome(false);
    const list = el("div");
    mount.replaceChildren(
        el("a", { class: "back", href: "#/me" }, "← profile"),
        el("h2", { class: "section-title" }, "blocked"),
        el("p", { class: "note", style: "padding:0 6px 10px;" },
            "people you've blocked. you don't see them; they can't reply to you."),
        list, spinner());
    try {
        const snap = await getDocs(query(collection(db, "users", me.uid, "blocked"), limit(200)));
        mount.querySelector(".spinner")?.remove();
        if (snap.empty) { list.append(emptyState("no one. may it stay that way.")); return; }
        for (const b of snap.docs) {
            const handle = b.data().handle ?? "anonymous";
            const row = el("div", { class: "post-row blocked-row", style: "cursor:default;" },
                el("span", { class: "handle" }, handle));
            const btn = el("button", { class: "btn quiet" }, "unblock");
            btn.onclick = async () => {
                btn.disabled = true;
                try { await unblockUser(b.id); onSocialGraphChange(); row.remove(); toast(`${handle} is unblocked.`); }
                catch (e) { console.error(e); btn.disabled = false; toast(GENERIC_ERR); }
            };
            row.append(btn);
            list.append(row);
        }
    } catch (e) {
        mount.querySelector(".spinner")?.remove();
        list.append(emptyState(GENERIC_ERR));
        console.error(e);
    }
}

// ---------------------------------------------------------------- router
function setActiveNav(key) {
    for (const a of document.querySelectorAll("#mainNav a"))
        a.classList.toggle("active", a.dataset.nav === key);
}
function route() {
    // Navigation kills any open modal — a gate dialog must never outlive its
    // compose view (M1: a stuck "post anyway" could publish an abandoned post).
    document.querySelectorAll(".modal-overlay").forEach(o => o.remove());
    // Remember where the feed was scrolled to, then start the new view at the
    // top (viewFeed restores its own saved position when serving from cache).
    saveFeedScroll();
    activeFeedTab = null;
    window.scrollTo(0, 0);
    const h = location.hash || "#/";
    if (!me) {
        if (h === "#/signup") viewSignUp();
        else viewSignIn();
        return;
    }
    if (h === "#/" || h === "" || h === "#/signin" || h === "#/signup") { setActiveNav("feed"); viewFeed(); }
    else if (h === "#/compose") { setActiveNav(""); viewCompose(); }
    else if (h === "#/top") { setActiveNav("top"); viewTop(); }
    else if (h === "#/notifications") { setActiveNav("notifications"); viewNotifications(); }
    else if (h.startsWith("#/post/")) { setActiveNav(""); viewPost(h.slice(7)); }
    else if (h === "#/me") { setActiveNav("me"); viewProfile(me.uid); }
    else if (h === "#/blocked") { setActiveNav("me"); viewBlocked(); }
    else if (h.startsWith("#/u/")) {
        const uid = h.slice(4);
        setActiveNav(uid === me.uid ? "me" : "");
        viewProfile(uid);
    }
    else { setActiveNav("feed"); viewFeed(); }
}
window.addEventListener("hashchange", route);

document.getElementById("signOutBtn").onclick = async () => {
    stopBlockedListener();
    stopNotifBadge();
    resetWriteCaches();
    if (me) clearDrafts(me.uid); // drafts never outlive the session that wrote them
    await signOut(auth);
    location.hash = "#/signin";
};

// Policy re-acceptance gate (2026-07-18 re-audit): web parity for
// ContentView's blocking fullScreenCover. A signed-in account whose stored
// acceptedPolicyVersion is behind POLICY_VERSION must re-accept before the
// app routes anywhere. Signup stamps the current version, so this only fires
// for accounts that predate a policy bump. Declining signs out — the account
// and content persist so they can return and accept later.
function renderPolicyReacceptGate(uid) {
    const ck = el("input", { type: "checkbox", id: "reacceptCk" });
    const err = el("div", {});
    const btn = el("button", { class: "btn", style: "width:100%; margin-top:8px;", disabled: "" }, "i agree and continue");
    ck.onchange = () => { if (ck.checked) btn.removeAttribute("disabled"); else btn.setAttribute("disabled", ""); };
    btn.onclick = async () => {
        if (!ck.checked) return;
        btn.disabled = true;
        try {
            await setDoc(doc(db, "users", uid), {
                acceptedPolicyVersion: POLICY_VERSION,
                acceptedPolicyAt: serverTimestamp(),
            }, { merge: true });
            // Full re-boot so listeners/badges start on the normal path.
            location.reload();
        } catch (e) {
            err.replaceChildren(errorBox("couldn't save your acceptance — check your connection and try again."));
            btn.disabled = false;
        }
    };
    mount.replaceChildren(
        el("div", { class: "auth-card" },
            el("h1", { style: "font-size:28px;" }, "our terms have changed"),
            el("p", { class: "note" },
                "please review and accept the updated ",
                el("a", { class: "plain", href: "https://www.toskaapp.com/terms.html", target: "_blank" }, "terms of service"),
                " and ",
                el("a", { class: "plain", href: "https://www.toskaapp.com/privacy.html", target: "_blank" }, "privacy policy"),
                " to keep using toska."),
            el("label", { class: "note", style: "display:flex; gap:9px; align-items:flex-start; margin:16px 0 4px; cursor:pointer;", for: "reacceptCk" },
                ck, el("span", {}, "i confirm i'm 17 or older and i accept the updated terms and privacy policy")),
            err,
            el("div", { style: "margin-top:6px;" }, btn),
            el("p", { class: "note", style: "margin-top:20px;" },
                el("a", { class: "plain", href: "#/signin", onclick: async () => { await signOut(auth); } }, "i don't agree — sign me out")),
        )
    );
}

onAuthStateChanged(auth, async (user) => {
    const prev = me;
    me = user;
    if (!user) {
        // Token revocation lands here without the sign-out button — purge the
        // previous account's drafts so they can't leak into the next session.
        if (prev) clearDrafts(prev.uid);
        feedCache.clear(); activeFeedTab = null; followingUids = null;
        stopBlockedListener(); stopNotifBadge(); resetWriteCaches(); route(); return;
    }
    if (signupInProgress) return; // signup completes its own routing
    // Mirror ContentView.verifyUserDocumentAsync: the users doc must exist,
    // and confirmAdult re-fires on every sign-in until it sticks (a failed
    // signup callable must not permanently brick publishing — H1).
    try {
        const u = await getDoc(doc(db, "users", user.uid));
        if (!u.exists()) {
            mount.replaceChildren(el("div", { class: "empty" },
                "we couldn't find your account. ",
                el("a", { class: "plain", href: "#/signin", onclick: () => signOut(auth) }, "sign out")));
            return;
        }
        if (u.data().confirmedAdult !== true) {
            httpsCallable(functions, "confirmAdult")({}).catch(e => console.warn("confirmAdult deferred", e?.code));
        }
        // Block routing until the stored policy version catches up (see
        // renderPolicyReacceptGate). Missing field reads as 0 → gated.
        if ((u.data().acceptedPolicyVersion ?? 0) < POLICY_VERSION) {
            renderPolicyReacceptGate(user.uid);
            return;
        }
    } catch (e) { console.warn("verify failed, continuing", e?.code); }
    initWrites(db, user.uid);
    startBlockedListener(user.uid);
    startNotifBadge(user.uid);
    route();
});
