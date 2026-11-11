// Pin: webapp/js/coalesce.js — one desired end state per tap target (iOS build 126 parity).
// Latest tap wins, at most one follow-up write per landing, then a server read reconciles.
import { settle, resetCoalesce } from "../webapp/js/coalesce.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fail = 0;
function check(name, cond, detail = "") {
    if (cond) console.log(`  ok   ${name}`);
    else { fail++; console.log(`  FAIL ${name} ${detail}`); }
}

// A fake server: `state` is the truth, each write takes `latency` ms.
function server(latency = 60, { failOn = () => false } = {}) {
    const s = { state: false, writes: [], reads: 0 };
    s.write = async (wanted) => {
        await sleep(latency);
        if (failOn(wanted, s.writes.length)) throw new Error("unavailable");
        s.writes.push(wanted); s.state = wanted;
    };
    s.read = async () => { s.reads++; return s.state; };
    return s;
}

async function run() {
    console.log("web tap coalescing");
    {   // like → unlike → like, all within one in-flight write: ends liked, ONE write, no follow-up.
        resetCoalesce(); const s = server();
        const p1 = settle("k", true, s.write, s.read);
        await sleep(5); const p2 = settle("k", false, s.write, s.read);
        await sleep(5); const p3 = settle("k", true, s.write, s.read);
        const [r1, r2, r3] = await Promise.all([p1, p2, p3]);
        check("quick like/unlike/like ends liked", r1?.state === true, JSON.stringify(r1));
        check("queued taps return null", r2 === null && r3 === null);
        check("no follow-up when the last wish matches what landed", s.writes.length === 1, `writes=${s.writes}`);
        check("server read once", s.reads === 1);
    }
    {   // like → unlike quickly: ends unliked, exactly one follow-up.
        resetCoalesce(); const s = server();
        const p1 = settle("k", true, s.write, s.read);
        await sleep(5); const p2 = settle("k", false, s.write, s.read);
        const [r1, r2] = await Promise.all([p1, p2]);
        check("quick like/unlike ends unliked", r1?.state === false && r2 === null, JSON.stringify(r1));
        check("exactly one follow-up write", s.writes.join(",") === "true,false", `writes=${s.writes}`);
    }
    {   // five alternating taps during one write: ends on the LAST tap (false), ≤ 2 writes.
        resetCoalesce(); const s = server(80);
        const ps = [true, false, true, false, true, false].map(async (w, i) => { await sleep(i * 4); return settle("k", w, s.write, s.read); });
        const rs = await Promise.all(ps);
        check("six taps end on the last one", rs[0]?.state === false, JSON.stringify(rs[0]));
        check("at most one follow-up for the burst", s.writes.length <= 2, `writes=${s.writes}`);
    }
    {   // tap during the FOLLOW-UP: the chain keeps going, one hop at a time.
        resetCoalesce(); const s = server(60);
        const p1 = settle("k", true, s.write, s.read);          // write 1: true
        await sleep(5); settle("k", false, s.write, s.read);     // pending false → follow-up
        await sleep(80); settle("k", true, s.write, s.read);     // lands during the follow-up → one more hop
        const r1 = await p1;
        check("tap during the follow-up still wins", r1?.state === true && s.state === true, `writes=${s.writes}`);
        check("hops stay bounded", s.writes.length === 3, `writes=${s.writes}`);
    }
    {   // the write fails: state comes from the server read, error is reported.
        resetCoalesce(); const s = server(20, { failOn: () => true });
        const r = await settle("k", true, s.write, s.read);
        check("failed write reports the error", r?.error instanceof Error);
        check("failed write reconciles to the server state", r?.state === false);
    }
    {   // first write fails, a queued opposite tap succeeds: no error (superseded), ends on the tap.
        resetCoalesce(); const s = server(30, { failOn: (w, n) => n === 0 && w === true });
        const p1 = settle("k", true, s.write, s.read);
        await sleep(5); settle("k", false, s.write, s.read);
        const r1 = await p1;
        check("later successful tap clears an earlier failure", r1?.error === null && r1?.state === false, JSON.stringify(r1));
    }
    {   // independent keys never block each other.
        resetCoalesce(); const a = server(40), b = server(40);
        const [ra, rb] = await Promise.all([settle("a", true, a.write, a.read), settle("b", true, b.write, b.read)]);
        check("separate targets run in parallel", ra?.state === true && rb?.state === true);
    }
    {   // the slot clears after settling: a later tap owns a new write.
        resetCoalesce(); const s = server(10);
        await settle("k", true, s.write, s.read);
        const r = await settle("k", false, s.write, s.read);
        check("slot released after landing", r?.state === false && s.writes.length === 2);
    }
    console.log(fail ? `\n${fail} FAILED` : "\nall passed");
    process.exit(fail ? 1 : 0);
}
run();
