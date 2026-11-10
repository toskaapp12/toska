import Foundation

// One row per original in any list (owner 2026-11-03, list-integrity review F1).
//
// A repost is its own post document (isRepost + originalPostId), so a flat
// createdAt query returns the original AND every repost of it. This collapses
// a batch of rows so each original appears once:
//   • the repost wins (it carries the "reposted" label and sits where its own
//     time puts it); the original row is dropped; a second repost of the same
//     original is dropped too (first seen stays);
//   • own-original exception: when the VIEWER authored the original, their own
//     row wins and every repost of it is dropped — they never see
//     "x reposted" above their own words (if their original isn't in the batch
//     the reposts are still dropped; the post is on their profile);
//   • across pages: `seen` holds the keys already on screen; a later row with a
//     seen key is dropped rather than re-ordering rows already rendered.
// Mirrored byte-for-byte by webapp/js/repostCollapse.js; pinned by
// firestore-tests/repost-collapse-parity.mjs.
enum RepostCollapse {
    struct Item {
        let id: String
        let authorId: String
        let originalPostId: String?
        let originalAuthorId: String?

        var isRepost: Bool { originalPostId != nil }
        var key: String { originalPostId ?? id }
        /// Who wrote the words on this row.
        var wordsAuthor: String { originalAuthorId ?? authorId }
    }

    /// Indices of `items` to keep, in their original order. `seen` is updated
    /// with the keys of the kept rows.
    static func keptIndices(_ items: [Item], viewer: String, seen: inout Set<String>) -> [Int] {
        // Pass 1: pick a winner per key within this batch.
        var winner: [String: Int] = [:]

        // Build 125: keys the VIEWER reposted in this batch — order-independent, so the original wins
        // whether the viewer's repost comes before or after it (and over other people's reposts).
        let viewerReposted = Set(items.filter { $0.isRepost && $0.authorId == viewer }.map { $0.key })
        for (i, item) in items.enumerated() {
            let k = item.key
            if seen.contains(k) { continue }
            let ownOriginal = item.wordsAuthor == viewer
            // Build 125 (X-like): YOUR repost of someone's words never replaces their original row
            // when that row is present — the original stays where it is and shows "you reposted"
            // from the interaction store (iOS) / the viewer's reposted set (web).
            let preferOriginal = ownOriginal || viewerReposted.contains(k)
            if let current = winner[k] {
                let cur = items[current]
                if preferOriginal {
                    // viewer's own words: the original row wins over any repost
                    if !item.isRepost && cur.isRepost { winner[k] = i }
                } else {
                    // repost wins over the original; first repost stays
                    if item.isRepost && !cur.isRepost { winner[k] = i }
                }
            } else {
                winner[k] = i
            }
        }
        // Own-original exception: if only reposts of the viewer's own words are
        // in the batch, drop them (their row is on their profile / an older page).
        for (k, i) in winner where items[i].isRepost && items[i].wordsAuthor == viewer {
            winner[k] = nil
        }
        var kept: [Int] = []
        for (i, item) in items.enumerated() where winner[item.key] == i {
            kept.append(i)
            seen.insert(item.key)
        }
        return kept
    }
}
