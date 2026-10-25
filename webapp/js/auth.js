// toska — Firebase Auth email-action handler (/auth). External module because
// the site CSP is `script-src 'self' …` (no 'unsafe-inline'), so an inline
// <script> is blocked and the page would hang on the loading state.
import { FIREBASE_CONFIG, IS_PROD, RECAPTCHA_SITE_KEY } from "./config.js";
import { initializeApp } from "https://www.gstatic.com/firebasejs/11.0.1/firebase-app.js";
import {
  getAuth, verifyPasswordResetCode, confirmPasswordReset, sendPasswordResetEmail,
  applyActionCode, checkActionCode,
} from "https://www.gstatic.com/firebasejs/11.0.1/firebase-auth.js";

// Mirror the app's late-night theme (styles.css [data-theme=night]).
if (new Date().getHours() < 5) document.documentElement.dataset.theme = "night";

const app = initializeApp(FIREBASE_CONFIG);
// App Check mirrors app.js: prod enforces on Auth, so init before any Auth call.
if (IS_PROD) {
  try {
    const { initializeAppCheck, ReCaptchaEnterpriseProvider } =
      await import("https://www.gstatic.com/firebasejs/11.0.1/firebase-app-check.js");
    initializeAppCheck(app, {
      provider: new ReCaptchaEnterpriseProvider(RECAPTCHA_SITE_KEY),
      isTokenAutoRefreshEnabled: true,
    });
  } catch (e) { console.warn("app check init failed", e); }
}
const auth = getAuth(app);

// Same names as app.js's pwField so the web-security-audit SAFE_INNERHTML
// allowlist recognizes these as the known constant-SVG assignments.
const EYE_SVG = '<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7-11-7-11-7z"/><circle cx="12" cy="12" r="3"/></svg>';
const EYE_OFF_SVG = '<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 19c-7 0-11-7-11-7a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 7 11 7a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/></svg>';
const $ = (id) => document.getElementById(id);
const STATES = ["loading", "form", "done", "info", "expired", "fallback"];
const show = (id) => { for (const s of STATES) $(s).hidden = (s !== id); };
const showInfo = (t, b) => { $("infoTitle").textContent = t; $("infoBody").textContent = b; show("info"); };
const isExpired = (e) => e?.code === "auth/expired-action-code" || e?.code === "auth/invalid-action-code";

function wireToggle(btnId, inputId) {
  const btn = $(btnId), input = $(inputId);
  btn.innerHTML = EYE_SVG;
  btn.onclick = () => {
    const show = input.type === "password";
    input.type = show ? "text" : "password";
    btn.innerHTML = show ? EYE_OFF_SVG : EYE_SVG;
    btn.setAttribute("aria-label", show ? "hide password" : "show password");
    btn.setAttribute("aria-pressed", String(show));
  };
}

const params = new URLSearchParams(location.search);
const mode = params.get("mode");
const oobCode = params.get("oobCode");
const MIN = 8;

if (!oobCode) {
  show("fallback");
} else if (mode === "resetPassword") {
  verifyPasswordResetCode(auth, oobCode)
    .then(() => { show("form"); wireToggle("t1", "pw1"); wireToggle("t2", "pw2"); wireForm(); })
    .catch((e) => { console.warn("verifyPasswordResetCode:", e?.code || e); show(isExpired(e) ? "expired" : "fallback"); });
} else if (mode === "verifyEmail") {
  applyActionCode(auth, oobCode)
    .then(() => showInfo("email confirmed", "your email address is verified. you're good to head back to toska."))
    .catch((e) => { console.warn("verifyEmail:", e?.code || e); show(isExpired(e) ? "expired" : "fallback"); });
} else if (mode === "verifyAndChangeEmail") {
  applyActionCode(auth, oobCode)
    .then(() => showInfo("email updated", "your sign-in email has been changed. use the new address next time you sign in."))
    .catch((e) => { console.warn("verifyAndChangeEmail:", e?.code || e); show(isExpired(e) ? "expired" : "fallback"); });
} else if (mode === "recoverEmail") {
  checkActionCode(auth, oobCode)
    .then((info) => applyActionCode(auth, oobCode).then(() => info))
    .then((info) => {
      const restored = info?.data?.email ? ` (${info.data.email})` : "";
      showInfo("email change undone", `your original email${restored} is back on the account. if that change wasn't you, reset your password too, just to be safe.`);
    })
    .catch((e) => { console.warn("recoverEmail:", e?.code || e); show(isExpired(e) ? "expired" : "fallback"); });
} else {
  show("fallback");
}

function validate() {
  const a = $("pw1").value, b = $("pw2").value, hint = $("hint");
  if (a.length > 0 && a.length < MIN) {
    hint.textContent = `a little longer — ${MIN} characters minimum (you have ${a.length}).`;
    hint.classList.add("bad"); $("submit").disabled = true; return;
  }
  if (b.length > 0 && a !== b) {
    hint.textContent = "those don't match yet."; hint.classList.add("bad");
    $("submit").disabled = true; return;
  }
  hint.textContent = "at least 8 characters."; hint.classList.remove("bad");
  $("submit").disabled = !(a.length >= MIN && a === b);
}

function wireForm() {
  $("pw1").addEventListener("input", validate);
  $("pw2").addEventListener("input", validate);
  $("submit").addEventListener("click", async () => {
    const pw = $("pw1").value;
    if (pw.length < MIN || pw !== $("pw2").value) { validate(); return; }
    $("submit").disabled = true; $("submit").textContent = "saving…";
    try {
      await confirmPasswordReset(auth, oobCode, pw);
      show("done");
    } catch (e) {
      console.warn("confirmPasswordReset:", e?.code || e);
      if (isExpired(e)) { show("expired"); return; }
      $("hint").textContent = "couldn't save that just now — give it another try.";
      $("hint").classList.add("bad");
      $("submit").disabled = false; $("submit").textContent = "set new password";
    }
  });
}

$("resendBtn").addEventListener("click", async () => {
  const email = $("resend").value.trim();
  if (!email) return;
  $("resendBtn").disabled = true;
  try { await sendPasswordResetEmail(auth, email); } catch (e) { console.warn("resend:", e?.code || e); }
  $("resendMsg").hidden = false;
});
