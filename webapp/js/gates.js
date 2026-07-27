// Pre-post safety gates, in the iOS ComposeView order:
// 1) content violation (hard-block or override-with-hold)
// 2) anonymity / PII warning (override-with-hold)
// 3) crisis check-in (explicit: must choose; soft: dismissable)
// The classifiers are the server's own (vendored verbatim — see moderation.js),
// so the client gate set equals the server's and can never pass what the
// server would reject.
import {
    computePostFlagReason, computeReplyFlagReason,
    isPostExplicitCrisis, isPostConcerning, containsNameOrIdentifyingInfo,
} from "./moderation.js";

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

function modal({ dismissable = true } = {}) {
    const overlay = el("div", { class: "modal-overlay" });
    const card = el("div", { class: "modal-card" });
    overlay.append(card);
    document.body.append(overlay);
    const close = () => overlay.remove();
    if (dismissable) overlay.addEventListener("click", (e) => { if (e.target === overlay) close(); });
    // Focus the first action once rendered (keyboard users land somewhere sane).
    queueMicrotask(() => card.querySelector("button")?.focus());
    return { card, close, overlay };
}

const VIOLATION_COPY = {
    hate_speech: "this contains language that could hurt people. toska is a space for everyone.",
    sexual_content: "this contains sexual content that isn't appropriate for toska.",
    harassment: "this reads like it's aimed at hurting someone. toska is for your feelings, not attacks.",
    targeted_threat: "this sounds like it could be threatening toward someone. if that's not what you meant, a small edit will fix it.",
    spam_or_commercial: "this looks like it might be spam or promotional content.",
    contains_link: "toska doesn't allow links. this is an anonymous space — keep it about the words.",
};
const HARD_BLOCK = new Set(["hate_speech", "sexual_content", "harassment"]);

function violationDialog(reason) {
    return new Promise((resolve) => {
        const { card, close, overlay } = modal({ dismissable: false });
        const overridable = !HARD_BLOCK.has(reason);
        card.append(
            el("h3", {}, "hold on"),
            el("p", { class: "modal-body" }, VIOLATION_COPY[reason] ?? VIOLATION_COPY.spam_or_commercial),
            el("div", { class: "modal-actions" },
                el("button", { class: "btn", onclick: () => { close(); resolve("edit"); } }, "edit my post"),
                overridable ? el("button", { class: "btn quiet", onclick: () => { close(); resolve("override"); } },
                    "post anyway — it'll be reviewed") : null),
        );
        void overlay;
    });
}

function anonymityDialog() {
    return new Promise((resolve) => {
        const { card, close } = modal({ dismissable: false });
        card.append(
            el("h3", {}, "keep it anonymous"),
            el("p", { class: "modal-body" },
                "your post might include a name or identifying info.",
                el("br"), el("br"),
                "everyone here is anonymous. including the people in your story. that's what makes it safe."),
            el("p", { class: "modal-hint" }, "try “he”, “she”, “they”, or just “you”"),
            el("div", { class: "modal-actions" },
                el("button", { class: "btn", onclick: () => { close(); resolve("edit"); } }, "edit my post"),
                el("button", { class: "btn quiet", onclick: () => { close(); resolve("override"); } }, "post anyway")),
        );
    });
}

// Region-aware crisis lines (mirror of CrisisLines.resources).
function crisisLines() {
    const region = (navigator.language ?? "").split("-")[1]?.toUpperCase() ?? "";
    if (["US", "CA"].includes(region)) return [["988", "call or text 988 — suicide & crisis lifeline"]];
    if (["GB", "IE"].includes(region)) return [["116 123", "call 116 123 — samaritans, free, any time"]];
    if (region === "AU") return [["13 11 14", "call 13 11 14 — lifeline australia"]];
    return [["findahelpline.com", "findahelpline.com — free support, wherever you are"]];
}

// 2026-07-27 topic-specific support (mirror of CrisisLines.topicResources /
// crisisTopic in ContentModeration.swift). When the concern is an SA/DV
// disclosure, show the matching hotline ABOVE the general lines. Word-boundary
// so "sa"/"csa"/"dv" don't fire inside innocent words. US-specific with an
// international-directory fallback. Client-only UX; no server parity pin.
function crisisTopic(text) {
    const t = (text || "").toLowerCase();
    const saRe = /\b(sa|csa|sexual assault|sexually assaulted|assaulted me|raped me|was raped|molested me)\b/;
    const dvRe = /\b(dv|domestic violence|domestic abuse|abusive relationship|he hit me|she hit me|he abused me|he beat me)\b/;
    if (saRe.test(t)) return "sexual_assault";
    if (dvRe.test(t)) return "domestic_violence";
    return null;
}
function topicLines(topic) {
    const region = (navigator.language ?? "").split("-")[1]?.toUpperCase() ?? "";
    const us = region === "US";
    if (topic === "sexual_assault") {
        return us ? ["call 800 656 4673 — RAINN, national sexual assault hotline", "chat online at hotline.rainn.org"]
                  : ["find a sexual assault helpline at findahelpline.com"];
    }
    if (topic === "domestic_violence") {
        return us ? ["call 800 799 7233 — national domestic violence hotline", "text START to 88788"]
                  : ["find a domestic abuse helpline at findahelpline.com"];
    }
    return [];
}

function crisisCheckIn(level, topic = null) {
    return new Promise((resolve) => {
        const explicit = level === "explicit";
        const { card, close, overlay } = modal({ dismissable: !explicit });
        if (!explicit) overlay.addEventListener("click", (e) => { if (e.target === overlay) resolve("pause"); });
        card.append(
            el("h3", {}, explicit ? "please read this first" : "before you share this"),
            el("p", { class: "modal-body" }, explicit
                ? "what you wrote sounds serious. you don't have to go through this alone."
                : "this sounds like it's coming from a heavy place. that's okay."),
            el("div", { class: "crisis-lines" },
                [...topicLines(topic).map((label) => el("div", { class: "crisis-line" }, label)),
                 ...crisisLines().map(([, label]) => el("div", { class: "crisis-line" }, label))]),
            el("div", { class: "modal-actions" },
                // deliberately quiet — the check-in must never feel like a wall
                el("button", { class: "btn quiet", onclick: () => { close(); resolve("proceed"); } },
                    explicit ? "i'm safe. share it." : "i'm okay. share it."),
                el("button", { class: "btn quiet", onclick: () => { close(); resolve("pause"); } }, "not now")),
        );
    });
}

/**
 * Run all gates for a piece of text.
 * @returns {Promise<{ok: boolean, willBeHeld: boolean}>}
 */
export async function runGates(text, { isReply = false } = {}) {
    let willBeHeld = false;
    const reason = isReply ? computeReplyFlagReason(text) : computePostFlagReason(text);
    // minor_safety is held silently server-side (no user-facing dialog — the
    // admin reviews the account per ToS); personal_information has its own
    // anonymity dialog below. Both skip the generic violation dialog.
    if (reason && reason !== "personal_information" && reason !== "minor_safety") {
        const r = await violationDialog(reason);
        if (r === "edit") return { ok: false, willBeHeld };
        willBeHeld = true;
    }
    if (containsNameOrIdentifyingInfo(text)) {
        const r = await anonymityDialog();
        if (r === "edit") return { ok: false, willBeHeld };
        willBeHeld = true;
    }
    const topic = crisisTopic(text);
    if (isPostExplicitCrisis(text)) {
        const r = await crisisCheckIn("explicit", topic);
        if (r !== "proceed") return { ok: false, willBeHeld };
        // Crisis REPLIES deliberately go live server-side (a reach-out
        // shouldn't be censored) — only posts are held. Don't promise a
        // review that won't happen.
        if (!isReply) willBeHeld = true;
    } else if (isPostConcerning(text)) {
        const r = await crisisCheckIn("soft", topic);
        if (r !== "proceed") return { ok: false, willBeHeld };
        if (!isReply) willBeHeld = true;
    }
    return { ok: true, willBeHeld };
}
