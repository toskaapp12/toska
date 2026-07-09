// Browser bridge for the server's shared moderation classifiers.
//
// webapp/js/vendor/{moderation,moderationLogic}.js are VERBATIM copies of
// functions/{moderation,moderationLogic}.js (pre-commit enforces byte
// parity), loaded through a minimal CommonJS shim so the web client's gates
// are exactly the server's — the "client must stay a subset of server"
// invariant holds with equality, and can never drift.
async function loadCJS(path, registry) {
    const src = await (await fetch(path)).text();
    const module = { exports: {} };
    new Function("module", "exports", "require", src)(
        module, module.exports, (name) => {
            const m = registry[name];
            if (!m) throw new Error(`unshimmed require: ${name}`);
            return m;
        });
    return module.exports;
}

const registry = {};
registry["./moderation"] = await loadCJS("/js/vendor/moderation.js", registry);
const logic = await loadCJS("/js/vendor/moderationLogic.js", registry);

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
