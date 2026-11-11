// toska web — feed ordering helpers shared with iOS semantics.
//
// pinOwnFresh (iOS build 126, FeedViewModel.pinOwnFresh): the viewer's OWN
// original posts younger than 10 minutes sit at the top of their "for you"
// feed, newest first; everything else keeps its order. Only the author sees
// this — other viewers' feeds are untouched because the rule keys on viewer.
export const OWN_FRESH_MS = 600e3;

const millis = (ts) => typeof ts?.toMillis === "function" ? ts.toMillis() : (typeof ts === "number" ? ts : 0);

/** @param {[string, object][]} rows  [id, data] pairs in feed order */
export function pinOwnFresh(rows, viewer, now = Date.now()) {
    if (!viewer) return rows;
    const own = [], rest = [];
    for (const row of rows) {
        const d = row[1];
        const fresh = d.authorId === viewer && d.isRepost !== true && now - millis(d.createdAt) < OWN_FRESH_MS;
        (fresh ? own : rest).push(row);
    }
    if (!own.length) return rows;
    own.sort((a, b) => millis(b[1].createdAt) - millis(a[1].createdAt));
    return [...own, ...rest];
}
