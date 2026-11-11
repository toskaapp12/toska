// toska web — one desired end state per tap target (parity with iOS build 126,
// RateLimiter.setPendingIntent / drainPendingIntent in PostInteractionManager).
//
// Every tap flips the button at once (the caller does that). Here: while a
// write for `key` is in flight, a new tap only records the latest wanted state
// — nothing is dropped and nothing is reordered. When the write lands, the
// latest wish is compared with what actually landed: if it differs, exactly
// one follow-up write is issued (and the same rule applies to that one). Then
// the server state is read once and returned so the caller can reconcile.
//
// Pure: no Firebase here, so it is unit-tested in firestore-tests/web-tap-coalesce.mjs.
const flying = new Map(); // key -> { pending: boolean | undefined }

/**
 * @param {string} key          one slot per target, e.g. "like_<postId>"
 * @param {boolean} wanted      the end state this tap asks for
 * @param {(wanted: boolean) => Promise<void>} write   performs the write for a state
 * @param {() => Promise<boolean>} readServer         reads the state from the server
 * @returns {Promise<null | {state: boolean, error: any}>}
 *   null  → this tap was queued behind an in-flight write; that call reconciles.
 *   state → the server state after everything landed (the write's own state if the read failed);
 *   error → the last write error that was not superseded by a later successful write.
 */
export async function settle(key, wanted, write, readServer) {
    const f = flying.get(key);
    if (f) { f.pending = wanted; return null; }
    const slot = { pending: undefined };
    flying.set(key, slot);
    let written, error = null;
    try {
        try { await write(wanted); written = wanted; }
        catch (e) { error = e; written = !wanted; }
        // latest tap wins: one follow-up per landing while the newest wish differs
        for (let hops = 0; slot.pending !== undefined && hops < 4; hops++) {
            const next = slot.pending; slot.pending = undefined;
            if (next === written) { error = null; continue; } // the latest wish already holds
            try { await write(next); written = next; error = null; }
            catch (e) { error = e; }
        }
        let state = written;
        try { state = await readServer(); } catch { /* keep the write's state */ }
        return { state, error };
    } finally { flying.delete(key); }
}

export function resetCoalesce() { flying.clear(); }
