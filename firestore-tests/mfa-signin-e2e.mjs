// LIVE STAGING e2e for the TOTP sign-in RESOLVER flow that app.js + admin.html
// (and iOS, build 94) use. Staging has App Check UNENFORCED, so a Node client
// can run the full sequence. Proves: an MFA-enrolled account throws
// multi-factor-auth-required on password sign-in, and the resolver →
// assertionForSignIn → resolveSignIn sequence completes sign-in.
//
// Self-cleaning (deletes the throwaway account). Run with staging web env.
import admin from "firebase-admin";
import crypto from "node:crypto";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword, signOut, multiFactor,
  getMultiFactorResolver, TotpMultiFactorGenerator } from "firebase/auth";

const PROJECT = "toskastaging";
const KEY = process.env.TOSKA_STAGING_WEB_API_KEY;
const APP = process.env.TOSKA_STAGING_APP_ID;
const SND = process.env.TOSKA_STAGING_SENDER_ID;
if (!KEY || !APP || !SND) { console.error("missing staging web env"); process.exit(1); }

admin.initializeApp({ projectId: PROJECT });
const web = initializeApp({ apiKey: KEY, authDomain: `${PROJECT}.firebaseapp.com`, projectId: PROJECT, appId: APP, messagingSenderId: SND });
const auth = getAuth(web);

let failures = 0;
const ok = (m) => console.log("✓ " + m);
const bad = (m) => { failures++; console.error("✗ " + m); };

// --- RFC 6238 TOTP from a base32 secret (what authenticator apps compute) ---
function base32Decode(s) {
  const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "", out = [];
  for (const c of s.replace(/=+$/, "").toUpperCase()) { const v = A.indexOf(c); if (v < 0) continue; bits += v.toString(2).padStart(5, "0"); }
  for (let i = 0; i + 8 <= bits.length; i += 8) out.push(parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(out);
}
function totp(secretB32, forTime = Date.now()) {
  const key = base32Decode(secretB32);
  const counter = Math.floor(forTime / 1000 / 30);
  const buf = Buffer.alloc(8); buf.writeUInt32BE(Math.floor(counter / 2 ** 32), 0); buf.writeUInt32BE(counter >>> 0, 4);
  const h = crypto.createHmac("sha1", key).update(buf).digest();
  const o = h[h.length - 1] & 0xf;
  const n = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return String(n % 1_000_000).padStart(6, "0");
}

const stamp = Date.now();
const EMAIL = `mfae2e_${stamp}@example.com`, PW = `mfae2epw_${stamp}`;
let uid = null;

try {
  // 1. create (pre-verified — TOTP enrollment requires a verified email), sign in, enroll
  const created = await admin.auth().createUser({ email: EMAIL, password: PW, emailVerified: true });
  uid = created.uid;
  const cred = await signInWithEmailAndPassword(auth, EMAIL, PW);
  const session = await multiFactor(cred.user).getSession();
  const secret = await TotpMultiFactorGenerator.generateSecret(session);
  const enrollAssertion = TotpMultiFactorGenerator.assertionForEnrollment(secret, totp(secret.secretKey));
  await multiFactor(cred.user).enroll(enrollAssertion, "test authenticator");
  ok("throwaway account enrolled with TOTP");

  // 2. sign out, then sign in → MUST throw multi-factor-auth-required
  await signOut(auth);
  let mfaErr = null;
  try {
    await signInWithEmailAndPassword(auth, EMAIL, PW);
    bad("password sign-in did NOT require MFA (unexpected)");
  } catch (e) {
    if (e.code === "auth/multi-factor-auth-required") { mfaErr = e; ok("password sign-in correctly throws auth/multi-factor-auth-required"); }
    else bad("unexpected sign-in error: " + e.code);
  }

  // 3. the exact app.js resolver sequence
  if (mfaErr) {
    const resolver = getMultiFactorResolver(auth, mfaErr);
    ok("getMultiFactorResolver → " + resolver.hints.length + " hint(s), factor=" + resolver.hints[0].factorId);
    // Use a NEXT-window code: enrollment consumed the current window's code and
    // a TOTP code can't be reused. +30s is a different counter, still within the
    // server's adjacentIntervals tolerance. (Real users rotate naturally.)
    const hint = resolver.hints[0];
    const assertion = TotpMultiFactorGenerator.assertionForSignIn(hint.uid, totp(secret.secretKey, Date.now() + 30000));
    await resolver.resolveSignIn(assertion);
    ok("resolveSignIn completed — auth.currentUser=" + (auth.currentUser ? auth.currentUser.uid.slice(0, 6) + "…" : "NULL"));
    if (!auth.currentUser) bad("resolveSignIn returned but no currentUser");

    // 4. wrong code is rejected
    await signOut(auth);
    try {
      await signInWithEmailAndPassword(auth, EMAIL, PW);
    } catch (e2) {
      const r2 = getMultiFactorResolver(auth, e2);
      try {
        await r2.resolveSignIn(TotpMultiFactorGenerator.assertionForSignIn(r2.hints[0].uid, "000000"));
        bad("wrong code 000000 was ACCEPTED (!)");
      } catch (e3) { ok("wrong code rejected: " + e3.code); }
    }
  }
} catch (e) {
  bad("e2e error: " + (e.code || e.message));
} finally {
  if (uid) { await admin.firestore().collection("users").doc(uid).delete().catch(() => {}); await admin.auth().deleteUser(uid).catch(() => {}); }
  console.log(failures ? "RESULT: FAIL" : "RESULT: PASS");
  process.exit(failures ? 1 : 0);
}
