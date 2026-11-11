// Pin: webapp/js/feedOrder.js pinOwnFresh mirrors FeedViewModel.pinOwnFresh (iOS build 126):
// the viewer's own original posts under 10 minutes old lead their for-you feed, newest first;
// reposts, other authors' posts and older own posts keep their order; other viewers see no change.
import { pinOwnFresh, OWN_FRESH_MS } from "../webapp/js/feedOrder.js";

const NOW = 1_800_000_000_000;
const ts = (agoMs) => ({ toMillis: () => NOW - agoMs });
const row = (id, authorId, agoMs, extra = {}) => [id, { authorId, createdAt: ts(agoMs), ...extra }];
const V = "viewer", A = "alice";

const CASES = [
    { name: "own 2-minute-old post behind two newer ones → first",
      rows: [row("a1", A, 30e3), row("a2", A, 60e3), row("v1", V, 120e3)], expect: ["v1", "a1", "a2"] },
    { name: "two own fresh posts → newest first, then the rest",
      rows: [row("a1", A, 10e3), row("v-old", V, 300e3), row("v-new", V, 200e3)], expect: ["v-new", "v-old", "a1"] },
    { name: "own post at 10 minutes exactly → not pinned",
      rows: [row("a1", A, 10e3), row("v1", V, OWN_FRESH_MS)], expect: ["a1", "v1"] },
    { name: "own post just under 10 minutes → pinned",
      rows: [row("a1", A, 10e3), row("v1", V, OWN_FRESH_MS - 1)], expect: ["v1", "a1"] },
    { name: "own fresh REPOST → not pinned",
      rows: [row("a1", A, 10e3), row("viewer_repost_p9", V, 20e3, { isRepost: true, originalPostId: "p9" })], expect: ["a1", "viewer_repost_p9"] },
    { name: "no own fresh post → order untouched",
      rows: [row("a1", A, 10e3), row("a2", A, 20e3), row("v1", V, 3600e3)], expect: ["a1", "a2", "v1"] },
    { name: "someone else's fresh post → not pinned for this viewer",
      rows: [row("v1", V, 3600e3), row("a1", A, 5e3)], expect: ["v1", "a1"] },
    { name: "no viewer (signed out) → untouched",
      viewer: null, rows: [row("a1", A, 10e3), row("v1", V, 5e3)], expect: ["a1", "v1"] },
    { name: "missing createdAt → treated as old",
      rows: [row("a1", A, 10e3), ["v1", { authorId: V }]], expect: ["a1", "v1"] },
    { name: "empty", rows: [], expect: [] },
];

let fail = 0;
for (const c of CASES) {
    const got = pinOwnFresh(c.rows, c.viewer === undefined ? V : c.viewer, NOW).map(([id]) => id);
    const ok = JSON.stringify(got) === JSON.stringify(c.expect);
    if (!ok) fail++;
    console.log(`  ${ok ? "ok  " : "FAIL"} ${c.name}${ok ? "" : ` → got ${JSON.stringify(got)}`}`);
}
console.log(fail ? `\n${fail} FAILED` : "\nall passed");
process.exit(fail ? 1 : 0);
