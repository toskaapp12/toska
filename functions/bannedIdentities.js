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
  // trim(): Secret Manager values set via piped stdin can carry a trailing
  // newline, and an invisible whitespace difference silently changes every
  // hash (found the hard way on the 2026-07-29 staging probe — the deployed
  // pepper had "\n", the capture-side one didn't, and no signup ever
  // matched). Trimming at the single chokepoint makes both sides immune.
  return crypto.createHmac("sha256", String(pepper).trim()).update(`${kind}:${value}`).digest("hex");
}

// Extract the durable sign-in identities from an Auth user record (Admin SDK
// UserRecord or the beforeUserCreated event payload — both carry email +
// providerData[{providerId, uid, email}]).
//   - email: normalized lowercase. Covers email/password signups.
//   - google.com / apple.com provider uid: the durable identity even when the
//     email is a relay (Sign in with Apple) or later rotated.
// "local+anything@domain" → "local@domain" (lower-cased input expected). Only
// the plus-tag is stripped — dots and provider-specific quirks are left alone.
// 2026-10-30 bad-actor audit (#8): Gmail ignores dots in the local part and treats googlemail.com as
// gmail.com, so a banned Gmail user had unlimited aliases ("bad.actor" / "badactor" / "b.a.d.actor").
// For those two domains the dots are stripped and the domain folded; other providers keep dots
// (they are significant there).
const DOT_INSENSITIVE_DOMAINS = new Set(["gmail.com", "googlemail.com"]);
function normalizeEmailAlias(email) {
  if (!email) return "";
  const at = email.lastIndexOf("@");
  if (at <= 0) return email;
  let local = email.slice(0, at);
  let domain = email.slice(at + 1);
  const plus = local.indexOf("+");
  if (plus > 0) local = local.slice(0, plus);
  if (DOT_INSENSITIVE_DOMAINS.has(domain)) { local = local.replace(/\./g, ""); domain = "gmail.com"; }
  if (!local) return email;
  return `${local}@${domain}`;
}

function extractIdentities(user) {
  const ids = [];
  const email = (user.email || "").trim().toLowerCase();
  if (email) ids.push({ kind: "email", value: email });
  // Product decision (2026-10-28, audit B7): plus-aliases are the same
  // mailbox — "bad.actor+2@example.com" is banned as "bad.actor@example.com".
  // The normalized form is emitted as an EXTRA identity, so a ban row is
  // written for both and a later sign-up under any alias matches. Existing
  // rows (hashed raw) keep matching exactly as before.
  const norm = normalizeEmailAlias(email);
  if (norm && norm !== email) ids.push({ kind: "email", value: norm });
  for (const p of user.providerData || []) {
    if (!p) continue;
    if ((p.providerId === "google.com" || p.providerId === "apple.com") && p.uid) {
      ids.push({ kind: p.providerId, value: String(p.uid) });
    }
    const pEmail = (p.email || "").trim().toLowerCase();
    if (pEmail && pEmail !== email) ids.push({ kind: "email", value: pEmail });
    const pNorm = normalizeEmailAlias(pEmail);
    if (pNorm && pNorm !== pEmail) ids.push({ kind: "email", value: pNorm });
  }
  const seen = new Set();
  return ids.filter((i) => {
    const k = `${i.kind}:${i.value}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

module.exports = { identityHash, extractIdentities, normalizeEmailAlias };
