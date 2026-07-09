// toska web — Stage A: sign in / sign up + read-only feed, posts, profiles.
// Query shapes deliberately mirror the iOS client 1:1 (see FeedViewModel /
// PostDetailView / ProfileView) — the rules deny any broader read.
import { FIREBASE_CONFIG, IS_PROD, RECAPTCHA_SITE_KEY, POLICY_VERSION } from "./config.js";
import { initializeApp } from "https://www.gstatic.com/firebasejs/11.0.1/firebase-app.js";
import {
    getAuth, onAuthStateChanged, signInWithEmailAndPassword,
    createUserWithEmailAndPassword, signOut,
} from "https://www.gstatic.com/firebasejs/11.0.1/firebase-auth.js";
import {
    getFirestore, collection, collectionGroup, doc, getDoc, getDocs,
    getCountFromServer, query, where, orderBy, limit, startAfter,
    writeBatch, setDoc, serverTimestamp, onSnapshot, documentId,
} from "https://www.gstatic.com/firebasejs/11.0.1/firebase-firestore.js";
import { getFunctions, httpsCallable } from "https://www.gstatic.com/firebasejs/11.0.1/firebase-functions.js";

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
        snap => { blocked = new Set(snap.docs.map(d => d.id)); },
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
function postRow(id, d) {
    const meta = el("div", { class: "post-meta" },
        el("span", { class: "handle" }, d.isRepost ? (d.originalHandle ?? "anonymous") : (d.authorHandle ?? "anonymous")),
        el("span", {}, relTime(d.createdAt)),
        tagChip(d.tag),
    );
    return el("a", { class: "post-row", href: `#/post/${id}` },
        d.isRepost ? el("div", { class: "repost-strip" }, `${d.authorHandle ?? "anonymous"} reposted`) : null,
        meta,
        el("div", { class: "post-text" }, d.text ?? ""),
        d.gifUrl ? el("img", { src: d.gifUrl, style: "max-width:100%; border-radius:12px; margin-top:12px;", alt: "gif" }) : null,
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

// ---------------------------------------------------------------- auth views
function viewSignIn() {
    header.hidden = true;
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
    mount.replaceChildren(
        el("div", { class: "auth-card" },
            el("h1", { style: "color:var(--plum);" }, "toska"),
            el("p", { class: "note tagline" }, "an anonymous space for heartbreak."),
            el("div", { class: "field" }, el("label", {}, "email"), email),
            el("div", { class: "field" }, el("label", {}, "password"), pw),
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
    header.hidden = true;
    const email = el("input", { type: "email", autocomplete: "email", placeholder: "you@example.com" });
    const pw = el("input", { type: "password", autocomplete: "new-password", placeholder: "at least 6 characters" });
    const adult = el("input", { type: "checkbox", id: "adultCk", style: "width:auto;" });
    const err = el("div");
    const btn = el("button", { class: "btn", style: "width:100%; margin-top:8px;" }, "create account");
    btn.onclick = async () => {
        err.replaceChildren();
        if (!adult.checked) { err.replaceChildren(errorBox("toska is for adults — please confirm you're 18 or older.")); return; }
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
            startBlockedListener(uid);
            startNotifBadge(uid);
            location.hash = "#/";
            route();
        } catch (e) {
            signupInProgress = false;
            if (created && auth.currentUser) { try { await auth.currentUser.delete(); } catch {} }
            const m = e?.code === "auth/email-already-in-use" ? "that email already has an account — sign in instead."
                : e?.code === "auth/weak-password" ? "password needs at least 6 characters."
                : GENERIC_ERR;
            err.replaceChildren(errorBox(m)); btn.disabled = false;
        }
    };
    mount.replaceChildren(
        el("div", { class: "auth-card" },
            el("h1", { style: "font-size:28px;" }, "create your account"),
            el("p", { class: "note tagline" },
                "no real names. you'll get an anonymous handle."),
            el("div", { class: "field" }, el("label", {}, "email"), email),
            el("div", { class: "field" }, el("label", {}, "password"), pw),
            el("label", { class: "note", style: "display:flex; gap:8px; align-items:center; margin:14px 0;", for: "adultCk" },
                adult, "i confirm i'm 18 or older"),
            el("p", { class: "note", style: "margin:10px 0;" },
                "by continuing you accept the ",
                el("a", { class: "plain", href: "https://www.toskaapp.com/terms.html", target: "_blank" }, "terms"),
                " and ",
                el("a", { class: "plain", href: "https://www.toskaapp.com/privacy.html", target: "_blank" }, "privacy policy"),
                "."),
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
async function viewFeed() {
    header.hidden = false;
    const list = el("div");
    const tabs = el("div", { class: "tabs" },
        ["for you", "following"].map(t =>
            el("button", { class: `tab ${feedTab === t ? "active" : ""}`, onclick: () => { feedTab = t; viewFeed(); } }, t)),
    );
    mount.replaceChildren(tabs, list, spinner());
    try {
        const rows = feedTab === "for you" ? await fetchForYou() : await fetchFollowing();
        mount.querySelector(".spinner")?.remove();
        if (!rows.length) {
            list.append(emptyState("it's quiet here right now."));
            return;
        }
        for (const [id, d] of rows) list.append(postRow(id, d));
        if (feedTab === "for you" && rows.length >= 60) {
            const more = el("button", { class: "btn quiet", style: "display:block; margin:20px auto;" }, "more");
            more.onclick = async () => {
                more.disabled = true;
                const next = await fetchForYou(rows._cursor);
                for (const [id, d] of next) list.append(postRow(id, d));
                rows._cursor = next._cursor;
                more.disabled = false;
                if (next.length < 20) more.remove();
            };
            list.append(more);
        }
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
    const fl = await getDocs(query(collection(db, "users", me.uid, "following"), limit(200)));
    const uids = fl.docs.map(d => d.id);
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

// ---------------------------------------------------------------- most felt
// Mirrors TopView: today/week = createdAt-windowed limit 100 ranked by likes
// client-side; all-time = likeCount DESC directly (composite index exists).
// Only posts with ≥1 felt make the board; top 10.
let topPeriod = "today";
const TOP_CUTOFF = { today: 86400e3, "this week": 7 * 86400e3 };
async function viewTop() {
    header.hidden = false;
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
};
async function viewNotifications() {
    header.hidden = false;
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
    header.hidden = false;
    mount.replaceChildren(el("a", { class: "back", href: "#/" }, "← feed"), spinner());
    try {
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
                tagChip(d.tag)),
            (d.moderationStatus ?? "live") !== "live" && own ? pendingBanner() : null,
            el("div", { class: "post-text", style: "font-size:19px;" }, d.text ?? ""),
            d.gifUrl ? el("img", { src: d.gifUrl, style: "max-width:100%; border-radius:10px; margin-top:10px;", alt: "gif" }) : null,
            el("div", { class: "post-stats" },
                el("span", {}, `${d.replyCount ?? 0} replies`),
                el("span", {}, `${d.likeCount ?? 0} felt this`)),
        );
        const repliesBox = el("div");
        mount.append(body, el("h3", { style: "margin:22px 0 4px; font-weight:500;" }, "replies"), repliesBox, spinner());
        const replies = await fetchReplies(postId);
        mount.querySelector(".spinner")?.remove();
        if (!replies.length) repliesBox.append(emptyState("no replies yet. someone will find this."));
        renderThread(repliesBox, replies, null, 0);
    } catch (e) {
        mount.querySelector(".spinner")?.remove();
        mount.append(emptyState("this post isn't available."));
        console.error(e);
    }
}

async function fetchReplies(postId) {
    // Two queries like iOS (rules deny a mixed list): live for everyone,
    // own-authored any-status for the pending banner.
    const live = await getDocs(query(collection(db, "posts", postId, "replies"),
        where("moderationStatus", "==", "live"), orderBy("createdAt", "desc"), limit(500)));
    let mine = { docs: [] };
    try {
        mine = await getDocs(query(collection(db, "posts", postId, "replies"),
            where("authorId", "==", me.uid), orderBy("createdAt", "asc")));
    } catch {}
    const byId = new Map();
    for (const d of [...live.docs, ...mine.docs]) byId.set(d.id, d);
    const rows = [...byId.values()].map(d => ({ id: d.id, ...d.data() }))
        .filter(r => !blocked.has(r.authorId))
        .sort((a, b) => (a.createdAt?.toMillis() ?? 0) - (b.createdAt?.toMillis() ?? 0));
    return rows;
}

function renderThread(container, all, parentId, depth) {
    for (const r of all.filter(r => (r.parentReplyId ?? null) === parentId)) {
        const isPending = (r.moderationStatus ?? "live") !== "live";
        container.append(el("div", {
            class: `post-row reply-row ${depth > 0 ? "thread-child" : ""}`,
            style: `cursor:default; margin-left:${Math.min(depth, 3) * 18}px;` },
            el("div", { class: "post-meta" },
                el("a", { class: "handle plain", href: `#/u/${r.authorId}` }, r.authorHandle ?? "anonymous"),
                el("span", {}, relTime(r.createdAt))),
            isPending ? pendingBanner() : null,
            el("div", { class: "post-text" }, r.text ?? ""),
            el("div", { class: "post-stats" }, el("span", {}, `${r.likeCount ?? 0} felt this`)),
        ));
        renderThread(container, all, r.id, depth + 1);
    }
}

// ---------------------------------------------------------------- profiles
async function viewProfile(uid) {
    header.hidden = false;
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

// ---------------------------------------------------------------- router
function setActiveNav(key) {
    for (const a of document.querySelectorAll("#mainNav a"))
        a.classList.toggle("active", a.dataset.nav === key);
}
function route() {
    const h = location.hash || "#/";
    if (!me) {
        if (h === "#/signup") viewSignUp();
        else viewSignIn();
        return;
    }
    if (h === "#/" || h === "" || h === "#/signin" || h === "#/signup") { setActiveNav("feed"); viewFeed(); }
    else if (h === "#/top") { setActiveNav("top"); viewTop(); }
    else if (h === "#/notifications") { setActiveNav("notifications"); viewNotifications(); }
    else if (h.startsWith("#/post/")) { setActiveNav(""); viewPost(h.slice(7)); }
    else if (h === "#/me") { setActiveNav("me"); viewProfile(me.uid); }
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
    await signOut(auth);
    location.hash = "#/signin";
};

onAuthStateChanged(auth, async (user) => {
    me = user;
    if (!user) { stopBlockedListener(); route(); return; }
    if (signupInProgress) return; // signup completes its own routing
    // Mirror ContentView.verifyUserDocumentAsync: the users doc must exist.
    try {
        const u = await getDoc(doc(db, "users", user.uid));
        if (!u.exists()) {
            mount.replaceChildren(el("div", { class: "empty" },
                "we couldn't find your account. ",
                el("a", { class: "plain", href: "#/signin", onclick: () => signOut(auth) }, "sign out")));
            return;
        }
    } catch (e) { console.warn("verify failed, continuing", e?.code); }
    startBlockedListener(user.uid);
    startNotifBadge(user.uid);
    route();
});
