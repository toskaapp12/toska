// One row per original in any list (owner 2026-11-03, list-integrity review F1).
// Mirror of toska/RepostCollapse.swift — keep the two in step; the parity pin
// (firestore-tests/repost-collapse-parity.mjs) runs both on the same cases.
//
// rows: [[id, data]] in list order; data has authorId, originalPostId?, originalAuthorId?.
// viewer: my uid. seen: Set of keys already on screen (mutated with the kept keys).
// Returns the kept rows in their original order.
//   • the repost wins (label + its own time); the original and later reposts are dropped;
//   • own-original exception: the viewer's own words keep their original row and every
//     repost of them is dropped;
//   • across pages: a row whose key is already in `seen` is dropped.
export function collapseReposts(rows, { viewer, seen }) {
    const key = ([id, d]) => d.originalPostId ?? id;
    const isRepost = ([, d]) => d.originalPostId != null;
    const wordsAuthor = ([, d]) => d.originalAuthorId ?? d.authorId;
    const winner = new Map(); // key -> index
    rows.forEach((row, i) => {
        const k = key(row);
        if (seen.has(k)) return;
        const ownOriginal = wordsAuthor(row) === viewer;
        if (winner.has(k)) {
            const cur = rows[winner.get(k)];
            if (ownOriginal) { if (!isRepost(row) && isRepost(cur)) winner.set(k, i); }
            else if (isRepost(row) && !isRepost(cur)) winner.set(k, i);
        } else {
            winner.set(k, i);
        }
    });
    for (const [k, i] of [...winner]) if (isRepost(rows[i]) && wordsAuthor(rows[i]) === viewer) winner.delete(k);
    const kept = [];
    rows.forEach((row, i) => { if (winner.get(key(row)) === i) { kept.push(row); seen.add(key(row)); } });
    return kept;
}
