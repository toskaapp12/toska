// Pin: toska/RepostCollapse.swift and webapp/js/repostCollapse.js produce identical results on the same cases
// (list-integrity review F1, 2026-11-03). Compiles the Swift file with swiftc (macOS) — skipped where swiftc is absent.
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { collapseReposts } from "../webapp/js/repostCollapse.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const V = "viewer", A = "alice", B = "bob", C = "carol";
const orig = (id, author) => [id, { authorId: author }];
const rp = (by, origId, origAuthor) => [`${by}_repost_${origId}`, { authorId: by, isRepost: true, originalPostId: origId, originalAuthorId: origAuthor }];

const CASES = [
  { name: "repost before original → repost wins", seen: [], rows: [rp(B, "p1", A), orig("p1", A), orig("p2", C)], expect: ["bob_repost_p1", "p2"] },
  { name: "original before repost → repost still wins", seen: [], rows: [orig("p1", A), orig("p2", C), rp(B, "p1", A)], expect: ["p2", "bob_repost_p1"] },
  { name: "two reposts + original → first repost only", seen: [], rows: [rp(B, "p1", A), rp(C, "p1", A), orig("p1", A)], expect: ["bob_repost_p1"] },
  { name: "own original + someone's repost → own row wins", seen: [], rows: [rp(B, "v1", V), orig("v1", V), orig("p2", A)], expect: ["v1", "p2"] },
  { name: "own words reposted, original not in batch → repost dropped", seen: [], rows: [rp(B, "v1", V), orig("p2", A)], expect: ["p2"] },
  { name: "viewer's own repost of someone else's post → repost wins", seen: [], rows: [rp(V, "p1", A), orig("p1", A)], expect: ["viewer_repost_p1"] },
  { name: "key already on an earlier page → dropped", seen: ["p1"], rows: [rp(B, "p1", A), orig("p3", C)], expect: ["p3"] },
  { name: "original on earlier page, repost later → dropped (no reorder)", seen: ["p1", "p2"], rows: [orig("p1", A), rp(C, "p2", B), orig("p4", C)], expect: ["p4"] },
  { name: "plain posts untouched", seen: [], rows: [orig("a", A), orig("b", B), orig("c", C)], expect: ["a", "b", "c"] },
  { name: "empty", seen: [], rows: [], expect: [] },
];

let fail = 0;
const jsOut = CASES.map((c) => { const seen = new Set(c.seen); const kept = collapseReposts(c.rows, { viewer: V, seen }).map(([id]) => id); return { kept, seen: [...seen].sort() }; });
CASES.forEach((c, i) => { if (JSON.stringify(jsOut[i].kept) !== JSON.stringify(c.expect)) { fail++; console.log(`✗ js: ${c.name}: got ${JSON.stringify(jsOut[i].kept)} expected ${JSON.stringify(c.expect)}`); } });

let swiftOut = null;
try { execFileSync("which", ["swiftc"], { stdio: "ignore" });
  const dir = mkdtempSync(join(tmpdir(), "rc-"));
  const main = `
import Foundation
struct In: Decodable { let seen: [String]; let rows: [Row] }
struct Row: Decodable { let id: String; let authorId: String; let originalPostId: String?; let originalAuthorId: String? }
let data = FileHandle.standardInput.readDataToEndOfFile()
let cases = try! JSONDecoder().decode([In].self, from: data)
var out: [[String: [String]]] = []
for c in cases {
  var seen = Set(c.seen)
  let items = c.rows.map { RepostCollapse.Item(id: $0.id, authorId: $0.authorId, originalPostId: $0.originalPostId, originalAuthorId: $0.originalAuthorId) }
  let kept = RepostCollapse.keptIndices(items, viewer: "${V}", seen: &seen).map { items[$0].id }
  out.append(["kept": kept, "seen": seen.sorted()])
}
print(String(data: try! JSONEncoder().encode(out), encoding: .utf8)!)
`;
  writeFileSync(join(dir, "main.swift"), main);
  execFileSync("swiftc", ["-O", "-o", join(dir, "rc"), join(root, "toska", "RepostCollapse.swift"), join(dir, "main.swift")], { stdio: "pipe" });
  const input = JSON.stringify(CASES.map((c) => ({ seen: c.seen, rows: c.rows.map(([id, d]) => ({ id, authorId: d.authorId, originalPostId: d.originalPostId ?? null, originalAuthorId: d.originalAuthorId ?? null })) })));
  swiftOut = JSON.parse(execFileSync(join(dir, "rc"), { input }).toString());
  CASES.forEach((c, i) => { if (JSON.stringify(swiftOut[i].kept) !== JSON.stringify(jsOut[i].kept) || JSON.stringify(swiftOut[i].seen) !== JSON.stringify(jsOut[i].seen)) { fail++; console.log(`✗ swift≠js: ${c.name}: swift ${JSON.stringify(swiftOut[i])} js ${JSON.stringify(jsOut[i])}`); } });
} catch (e) { if (String(e).includes("which")) console.log("repost-collapse: swiftc not found — JS cases only"); else { fail++; console.log("✗ swift harness failed:", String(e.stdout || e.message).slice(0, 400)); } }

if (fail) { console.log(`✗ repost-collapse parity: ${fail} failure(s)`); process.exit(1); }
console.log(`✓ repost-collapse parity: ${CASES.length} cases — web and iOS collapse identically${swiftOut ? " (Swift compiled)" : ""}`);
