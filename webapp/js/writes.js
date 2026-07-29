// toska web — write paths. Shapes mirror the iOS client field-for-field:
// firestore.rules pins exact field sets, server timestamps, deterministic
// notifIds, and handle==users/{uid}.handle. Counters are server-side only.
import {
    getFirestore, collection, doc, getDoc, getDocs, addDoc, setDoc, deleteDoc,
    updateDoc, query, where, limit, runTransaction, serverTimestamp, Timestamp,
} from "https://www.gstatic.com/firebasejs/11.0.1/firebase-firestore.js";

let db, uid;
export function initWrites(database, userId) {
    db = database; uid = userId;
    // A different account may sign in without the sign-out button ever firing
    // (token revocation) — a stale handle here would trip every rules pin.
    resetWriteCaches();
}

// authorHandle/fromHandle MUST equal users/{uid}.handle or rules deny.
// The cached doc also feeds isShareable (allowSharing) and the client-side
// restriction gate, mirroring iOS UserHandleCache.
let cachedProfile = null;
async function myProfile() {
    if (cachedProfile) return cachedProfile;
    const u = await getDoc(doc(db, "users", uid));
    cachedProfile = u.data() ?? {};
    return cachedProfile;
}
export async function myHandle() {
    const handle = (await myProfile()).handle;
    if (!handle) throw new Error("no handle on user doc");
    return handle;
}
// Mirrors notRestricted() in firestore.rules: restricted==true blocks unless
// restrictedUntil exists and is in the past. Reads the cached docs — a
// mid-session restriction is still caught server-side by the rules.
// A.5 #9 migration: the private/data mirror (mirrorModerationState) wins when
// it carries the field — post-flip the main-doc copy is gone. UX-only check;
// rules enforce either way, so a failed private read just falls back.
let cachedPrivate = null;
async function myPrivate() {
    if (cachedPrivate) return cachedPrivate;
    try {
        const p = await getDoc(doc(db, "users", uid, "private", "data"));
        cachedPrivate = p.exists() ? p.data() : {};
    } catch { cachedPrivate = {}; }
    return cachedPrivate;
}
export async function isRestricted() {
    const p = await myProfile();
    const priv = await myPrivate();
    const restricted = priv.restricted !== undefined ? priv.restricted : p.restricted;
    const untilRaw = priv.restricted !== undefined ? priv.restrictedUntil : p.restrictedUntil;
    if (restricted !== true) return false;
    const until = untilRaw?.toDate?.();
    return !until || until > new Date();
}
export function resetWriteCaches() { cachedProfile = null; cachedPrivate = null; inFlight.clear(); }

// in-flight + rate-limit guards, per iOS PostInteractionManager
const inFlight = new Set();
const lastAt = {};
function guard(key, minGapMs) {
    if (inFlight.has(key)) return false;
    if (lastAt[key] && Date.now() - lastAt[key] < minGapMs) return false;
    inFlight.add(key); lastAt[key] = Date.now();
    return true;
}
function done(key) { inFlight.delete(key); }

// Deterministic-id notification; never carries `message` (server enriches).
// Best-effort: recipient-blocked-me denials are expected and swallowed.
async function notify(toUserId, type, postId) {
    if (!toUserId || toUserId === uid) return;
    try {
        const handle = await myHandle();
        const id = `${type}_${postId}_${uid}`;
        await setDoc(doc(db, "users", toUserId, "notifications", id), {
            type, fromHandle: handle, fromUserId: uid, postId,
            isRead: false, createdAt: serverTimestamp(),
        });
    } catch { /* rule-denied (blocked) or transient — notification is best-effort */ }
}

// ------------------------------------------------------------ post create
export const POST_TAGS = ["longing", "numb", "anger", "regret", "acceptance",
    "confusion", "unsent", "moving on", "still love you"];

export async function createPost({ text, tag, isLetter, isWhisper, isMidnight, gifUrl, promptDate }) {
    const profile = await myProfile();
    const handle = profile.handle;
    if (!handle) throw new Error("no handle on user doc");
    const data = {
        authorId: uid,
        authorHandle: handle,
        text,
        likeCount: 0, repostCount: 0, replyCount: 0,
        isRepost: false,
        // Mirrors ComposeView: the user's allowSharing setting AND
        // letter/whisper both force the share affordance off.
        isShareable: (profile.allowSharing ?? true) && !isLetter && !isWhisper,
        createdAt: serverTimestamp(),
        moderationStatus: "pending_validation",
    };
    if (tag) data.tag = tag;
    if (isLetter) data.isLetter = true;
    if (gifUrl) data.gifUrl = gifUrl;
    if (promptDate) data.promptDate = promptDate;
    if (isWhisper && !isMidnight) {
        data.isWhisper = true;
        data.expiresAt = Timestamp.fromDate(new Date(Date.now() + 3600e3));
    }
    if (isMidnight && !isWhisper) {
        data.isMidnightPost = true;
        const midnight = new Date();
        midnight.setHours(24, 0, 0, 0); // next local midnight
        data.expiresAt = Timestamp.fromDate(midnight);
    }
    const ref = await addDoc(collection(db, "posts"), data);
    lastAt.post = Date.now();
    return ref.id;
}
export function postRateLimited() { return lastAt.post && Date.now() - lastAt.post < 30_000; }

// ------------------------------------------------------------ reply create
export async function createReply(postId, { text, parentReplyId, parentPostText, parentPostHandle, postAuthorId, gifUrl }) {
    const handle = await myHandle();
    const data = {
        authorId: uid,
        authorHandle: handle,
        text,
        likeCount: 0,
        createdAt: serverTimestamp(),
        parentPostText: parentPostText ?? "",
        parentPostHandle: parentPostHandle ?? "",
        moderationStatus: "pending_validation",
    };
    if (parentReplyId) data.parentReplyId = parentReplyId;
    if (gifUrl) data.gifUrl = gifUrl;
    const ref = await addDoc(collection(db, "posts", postId, "replies"), data);
    // Reply notifId is pinned to reply_{postId}_{uid} — after-commit, best-effort.
    notify(postAuthorId, "reply", postId);
    return ref.id;
}

// ------------------------------------------------------------ like / save
// Returns true/false (new liked state) | "own_post" | null.
export async function toggleLike(postId, liked, postAuthorId) {
    // F-P2-1: no self-like — rules deny the create; unlike (liked=true) is
    // delete-only and stays allowed for legacy self-likes.
    if (!liked && postAuthorId === uid) return "own_post";
    const key = `like_${postId}`;
    if (!guard(key, 800)) return null;
    try {
        const likeRef = doc(db, "posts", postId, "likes", uid);
        const likedRef = doc(db, "users", uid, "liked", postId);
        await runTransaction(db, async (txn) => {
            // liked/saved allow create+delete but NOT update — a set on an
            // existing doc is an update and denies the whole transaction, so
            // both writes are existence-guarded (UI state can be stale).
            const cur = await txn.get(likeRef);
            const curLiked = await txn.get(likedRef);
            if (liked) { // unlike
                if (cur.exists()) txn.delete(likeRef);
                if (curLiked.exists()) txn.delete(likedRef);
            } else {
                if (!cur.exists()) txn.set(likeRef, { createdAt: serverTimestamp() });
                if (!curLiked.exists()) txn.set(likedRef, { createdAt: serverTimestamp() });
            }
        });
        if (!liked) notify(postAuthorId, "like", postId);
        return !liked;
    } finally { done(key); }
}

export async function toggleSave(postId, saved, postAuthorId) {
    const key = `save_${postId}`;
    if (!guard(key, 1000)) return null;
    try {
        const ref = doc(db, "users", uid, "saved", postId);
        if (saved) await deleteDoc(ref);
        else {
            // no update rule on saved/ — skip the set if it already exists
            const cur = await getDoc(ref);
            if (!cur.exists()) {
                await setDoc(ref, { createdAt: serverTimestamp() });
                notify(postAuthorId, "save", postId);
            }
        }
        return !saved;
    } finally { done(key); }
}

export async function isLiked(postId) {
    try { return (await getDoc(doc(db, "users", uid, "liked", postId))).exists(); } catch { return false; }
}
export async function isSaved(postId) {
    try { return (await getDoc(doc(db, "users", uid, "saved", postId))).exists(); } catch { return false; }
}

// ------------------------------------------------------------ repost
// Returns "reposted" | "unreposted" | "blocked_ephemeral" | "own_post" | null.
export async function toggleRepost(postId) {
    const key = `repost_${postId}`;
    if (!guard(key, 2000)) return null;
    try {
        const mine = await getDocs(query(collection(db, "posts"),
            where("authorId", "==", uid), where("isRepost", "==", true),
            where("originalPostId", "==", postId), limit(1)));
        if (!mine.empty) { // un-repost
            for (const d of mine.docs) await deleteDoc(d.ref);
            return "unreposted";
        }
        const orig = await getDoc(doc(db, "posts", postId));
        if (!orig.exists()) return null;
        const o = orig.data();
        if (o.authorId === uid) return "own_post";
        if (o.isWhisper === true || o.isMidnightPost === true) return "blocked_ephemeral";
        const handle = await myHandle();
        const data = {
            authorId: uid,
            authorHandle: handle,
            text: o.text, // fresh original text — rules pin equality
            likeCount: 0, repostCount: 0, replyCount: 0,
            isShareable: o.isShareable ?? true,
            isRepost: true,
            originalPostId: postId,
            originalAuthorId: o.authorId,
            createdAt: serverTimestamp(),
            moderationStatus: "pending_validation",
        };
        if (o.tag) data.tag = o.tag;
        try { // originalHandle only if it matches the live user doc; omit otherwise
            const ou = await getDoc(doc(db, "users", o.authorId));
            if (ou.exists() && ou.data().handle) data.originalHandle = ou.data().handle;
        } catch {}
        await setDoc(doc(db, "posts", `${uid}_repost_${postId}`), data);
        notify(o.authorId, "repost", postId);
        return "reposted";
    } finally { done(key); }
}
export async function isReposted(postId) {
    try {
        const mine = await getDocs(query(collection(db, "posts"),
            where("authorId", "==", uid), where("isRepost", "==", true),
            where("originalPostId", "==", postId), limit(1)));
        return !mine.empty;
    } catch { return false; }
}

// ------------------------------------------------------------ edit / delete
// Rules pin author edits to exactly ['text','editedAt'] (posts ≤2000,
// replies ≤500, size>0) and gate them on notRestricted(); the server
// re-moderates on update (functions onPostUpdated / reply equivalent).
export async function editPost(postId, text) {
    await updateDoc(doc(db, "posts", postId),
        { text, editedAt: serverTimestamp() });
}
export async function editReply(postId, replyId, text) {
    await updateDoc(doc(db, "posts", postId, "replies", replyId),
        { text, editedAt: serverTimestamp() });
}
// Simple client path, like PostDetailView's self-delete: remove the doc,
// Cloud Functions cascade the cleanup (replies, likes, refs, counters).
export async function deletePost(postId) {
    await deleteDoc(doc(db, "posts", postId));
}
export async function deleteReply(postId, replyId) {
    await deleteDoc(doc(db, "posts", postId, "replies", replyId));
}

// ------------------------------------------------------------ report / block
export const REPORT_REASONS = [
    { label: "harassment or bullying", code: "harassment" },
    { label: "self-harm or suicide content", code: "self_harm" },
    { label: "sexual or explicit content", code: "sexual" },
    { label: "spam or scam", code: "spam" },
    { label: "impersonation", code: "impersonation" },
    { label: "something else", code: "other" },
];

export async function submitReport({ type, postId, replyId, reportedUserId, reportedHandle, text, reason, reasonLabel }) {
    const data = {
        reportedBy: uid, reason, reasonLabel,
        type, status: "pending", createdAt: serverTimestamp(),
    };
    if (postId) data.postId = postId;
    if (replyId) data.replyId = replyId;
    if (reportedUserId) data.reportedUserId = reportedUserId;
    if (reportedHandle) data.reportedHandle = reportedHandle.slice(0, 40);
    if (text) data.text = text.slice(0, 4000);
    await addDoc(collection(db, "reports"), data);
}

export async function blockUser(userId, handle) {
    const data = { blockedAt: serverTimestamp(), blockedUid: userId };
    if (handle) data.handle = handle;
    await setDoc(doc(db, "users", uid, "blocked", userId), data);
    // Mirror PostDetailView's block: sever any follow relationship in both
    // directions (best-effort — counter decrements are CF-owned; a rules
    // denial on the cross-user leg just leaves a dangling doc iOS also leaves).
    for (const [a, sub, b, sub2] of [
        [uid, "following", userId, "followers"],
        [uid, "followers", userId, "following"],
    ]) {
        try {
            const mine = doc(db, "users", a, sub, b);
            if ((await getDoc(mine)).exists()) {
                await deleteDoc(mine);
                await deleteDoc(doc(db, "users", b, sub2, a)).catch(() => {});
            }
        } catch { /* best-effort */ }
    }
}
export async function unblockUser(userId) {
    await deleteDoc(doc(db, "users", uid, "blocked", userId));
}
