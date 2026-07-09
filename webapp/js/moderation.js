// Browser bridge for the server's shared moderation classifiers.
//
// webapp/js/vendor/{moderation,moderationLogic}.js are VERBATIM copies of
// functions/{moderation,moderationLogic}.js (pre-commit enforces byte
// parity), loaded through a minimal CommonJS shim so the web client's gates
// are exactly the server's — the "client must stay a subset of server"
// invariant holds with equality, and can never drift.
function runCJS(src, registry) {
    const module = { exports: {} };
    new Function("module", "exports", "require", src)(
        module, module.exports, (name) => {
            const m = registry[name];
            if (!m) throw new Error(`unshimmed require: ${name}`);
            return m;
        });
    return module.exports;
}

// Fetch both sources in parallel (they used to load back-to-back at the tail
// of the module waterfall); execution order still matters — moderationLogic
// requires ./moderation, so that goes into the registry first.
const [modSrc, logicSrc] = await Promise.all([
    fetch("/js/vendor/moderation.js").then(r => r.text()),
    fetch("/js/vendor/moderationLogic.js").then(r => r.text()),
]);
const registry = {};
registry["./moderation"] = runCJS(modSrc, registry);
const logic = runCJS(logicSrc, registry);

export const {
    computePostFlagReason,
    computeReplyFlagReason,
    isPostExplicitCrisis,
    isPostConcerning,
    matchesCrisisPhrase,
} = logic;
export const {
    containsNameOrIdentifyingInfo,
    containsURL,
} = registry["./moderation"];
