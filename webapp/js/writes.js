// toska web — write paths. Shapes mirror the iOS client field-for-field:
// firestore.rules pins exact field sets, server timestamps, deterministic
// notifIds, and handle==users/{uid}.handle. Counters are server-side only.
import {
    getFirestore, collection, doc, getDoc, getDocs, addDoc, setDoc, deleteDoc,
    updateDoc, query, where, limit, runTransaction, serverTimestamp, Timestamp,
} from "https://www.gstatic.com/firebasejs/11.0.1/firebase-firestore.js";
import { settle, resetCoalesce } from "./coalesce.js";

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
export function resetWriteCaches() { cachedProfile = null; cachedPrivate = null; resetCoalesce(); }

// Tap handling (iOS build 126 parity): no in-flight drop and no time gap any
// more — every tap is kept as the latest desired end state per target and
// settled by coalesce.js (latest tap wins, one follow-up write, server read).
const lastAt = {};

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

export async function createPost({ text, tag, isLetter, isWhisper, isMidnight, gifUrl, promptDate, clientId }) {
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
        // letter/whisper/midnight all force the share affordance off.
        // D (2026-10-26): default OFF — sharing is opt-in, so a user doc
        // without allowSharing is NOT consenting (fail closed), matching the
        // ?? false reads elsewhere. E: add !isMidnight to match iOS
        // (ComposeView excludes expiresAtMidnight); a midnight post's share
        // card would outlive the post.
        isShareable: (profile.allowSharing ?? false) && !isLetter && !isWhisper && !isMidnight,
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
    // (owner 2026-11-02) a stable client-chosen id per compose session: a second submission of the
    // same words targets the same document, which the rules reject as an update — never a second post.
    let id;
    if (clientId) { await setDoc(doc(db, "posts", clientId), data); id = clientId; }
    else { const ref = await addDoc(collection(db, "posts"), data); id = ref.id; }
    lastAt.post = Date.now();
    return id;
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
// setLike / setSave / setRepost (iOS build 126 parity): `wanted` is the end
// state the tap asks for. Resolves null when the tap was queued behind an
// in-flight write for the same post (that call reconciles the button), else
// { state, error } — the SERVER state once every write landed, and the last
// write error that no later successful write superseded.
async function writeLike(postId, wanted, postAuthorId) {
    // X-parity (owner 2026-09-22): self-like allowed — rules flipped too.
    const likeRef = doc(db, "posts", postId, "likes", uid);
    const likedRef = doc(db, "users", uid, "liked", postId);
    await runTransaction(db, async (txn) => {
        // liked/saved allow create+delete but NOT update — a set on an
        // existing doc is an update and denies the whole transaction, so
        // both writes are existence-guarded (UI state can be stale).
        const cur = await txn.get(likeRef);
        const curLiked = await txn.get(likedRef);
        if (!wanted) { // unlike
            if (cur.exists()) txn.delete(likeRef);
            if (curLiked.exists()) txn.delete(likedRef);
        } else {
            if (!cur.exists()) txn.set(likeRef, { createdAt: serverTimestamp() });
            // postId field (2026-09-21): cascade-sweepable reverse ref.
            if (!curLiked.exists()) txn.set(likedRef, { createdAt: serverTimestamp(), postId });
        }
    });
    if (wanted) notify(postAuthorId, "like", postId);
}
export function setLike(postId, wanted, postAuthorId) {
    return settle(`like_${postId}`, wanted, (w) => writeLike(postId, w, postAuthorId), () => isLiked(postId, { throwOnError: true }));
}

async function writeSave(postId, wanted, postAuthorId) {
    const ref = doc(db, "users", uid, "saved", postId);
    if (!wanted) { await deleteDoc(ref); return; }
    // no update rule on saved/ — skip the set if it already exists
    const cur = await getDoc(ref);
    if (!cur.exists()) {
        // postId field (2026-09-21): cascade-sweepable reverse ref.
        await setDoc(ref, { createdAt: serverTimestamp(), postId });
        notify(postAuthorId, "save", postId);
    }
}
export function setSave(postId, wanted, postAuthorId) {
    return settle(`save_${postId}`, wanted, (w) => writeSave(postId, w, postAuthorId), () => isSaved(postId, { throwOnError: true }));
}

export async function isLiked(postId, { throwOnError = false } = {}) {
    try { return (await getDoc(doc(db, "users", uid, "liked", postId))).exists(); }
    catch (e) { if (throwOnError) throw e; return false; }
}
export async function isSaved(postId, { throwOnError = false } = {}) {
    try { return (await getDoc(doc(db, "users", uid, "saved", postId))).exists(); }
    catch (e) { if (throwOnError) throw e; return false; }
}

// ------------------------------------------------------------ repost
// A refused repost throws { code: "own_post" | "blocked_ephemeral" | "gone" }
// so the tap settles back to the server state (no repost) with that reason.
class RepostRefused extends Error { constructor(code) { super(code); this.code = code; this.refused = true; } }
async function myRepostDocs(postId) {
    return getDocs(query(collection(db, "posts"),
        where("authorId", "==", uid), where("isRepost", "==", true),
        where("originalPostId", "==", postId), limit(1)));
}
async function writeRepost(postId, wanted) {
    if (!wanted) { // undo: delete my repost row(s) of this post
        const mine = await myRepostDocs(postId);
        for (const d of mine.docs) await deleteDoc(d.ref);
        return;
    }
    const orig = await getDoc(doc(db, "posts", postId));
    if (!orig.exists()) throw new RepostRefused("gone");
    const o = orig.data();
    // No self-repost (owner re-ruling 2026-09-22 eve; self-like stays).
    if (o.authorId === uid) throw new RepostRefused("own_post");
    if (o.isWhisper === true || o.isMidnightPost === true) throw new RepostRefused("blocked_ephemeral");
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
    // Owner spec (2026-09-22): reposts show the full original, media
    // included — rules pin the copy's gifUrl to the original's exactly.
    if (o.gifUrl) data.gifUrl = o.gifUrl;
    try { // originalHandle only if it matches the live user doc; omit otherwise
        const ou = await getDoc(doc(db, "users", o.authorId));
        if (ou.exists() && ou.data().handle) data.originalHandle = ou.data().handle;
    } catch {}
    // Deterministic id: a second create of the same repost is an update the
    // rules deny — never a duplicate row.
    await setDoc(doc(db, "posts", `${uid}_repost_${postId}`), data);
    notify(o.authorId, "repost", postId);
}
export function setRepost(postId, wanted) {
    return settle(`repost_${postId}`, wanted, (w) => writeRepost(postId, w), () => isReposted(postId, { throwOnError: true }));
}
export async function isReposted(postId, { throwOnError = false } = {}) {
    try { return !(await myRepostDocs(postId)).empty; }
    catch (e) { if (throwOnError) throw e; return false; }
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
