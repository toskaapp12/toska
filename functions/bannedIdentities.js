// Block-re-signup (built 2026-07-29; design approved 2026-07-28): identity
// hashing shared by adminDeleteAccount (capture at ban time) and the
// blockBannedSignups blocking function (check at signup).
//
// ONE-WAY hashes only — no plaintext identity is ever stored. Each banned
// identity is keyed HMAC-SHA256(pepper, "kind:value"); the pepper
// (BANNED_ID_PEPPER secret, Secret Manager) keeps low-entropy identities
// (email addresses) from being reversed by dictionary hashing if the
// collection contents ever leaked. Privacy Policy discloses this retention.
const crypto = require("crypto");

function identityHash(pepper, kind, value) {
  return crypto.createHmac("sha256", pepper).update(`${kind}:${value}`).digest("hex");
}

// Extract the durable sign-in identities from an Auth user record (Admin SDK
// UserRecord or the beforeUserCreated event payload — both carry email +
// providerData[{providerId, uid, email}]).
//   - email: normalized lowercase. Covers email/password signups.
//   - google.com / apple.com provider uid: the durable identity even when the
//     email is a relay (Sign in with Apple) or later rotated.
function extractIdentities(user) {
  const ids = [];
  const email = (user.email || "").trim().toLowerCase();
  if (email) ids.push({ kind: "email", value: email });
  for (const p of user.providerData || []) {
    if (!p) continue;
    if ((p.providerId === "google.com" || p.providerId === "apple.com") && p.uid) {
      ids.push({ kind: p.providerId, value: String(p.uid) });
    }
    const pEmail = (p.email || "").trim().toLowerCase();
    if (pEmail && pEmail !== email) ids.push({ kind: "email", value: pEmail });
  }
  const seen = new Set();
  return ids.filter((i) => {
    const k = `${i.kind}:${i.value}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

module.exports = { identityHash, extractIdentities };
