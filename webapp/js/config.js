// Environment picks itself by hostname: the prod hosting site (and later
// app.toskaapp.com) talks to prod; everything else — staging site, localhost,
// emulator — talks to staging. Firebase web API keys are public identifiers;
// security lives in rules + App Check.
const PROD = {
    apiKey: "AIzaSyBrw_EFSHD2lMr7RqQd7sM9-2jMnr2tzdQ",
    authDomain: "toska-4ebf4.firebaseapp.com",
    projectId: "toska-4ebf4",
    storageBucket: "toska-4ebf4.firebasestorage.app",
    messagingSenderId: "183467627187",
    appId: "1:183467627187:web:fd3f93867a2a54f90756c6",
};

const STAGING = {
    apiKey: "AIzaSyCTGuUzy9maPF84fZh5gD_-eZ2qkie75OQ",
    authDomain: "toskastaging.firebaseapp.com",
    projectId: "toskastaging",
    messagingSenderId: "260913424323",
    appId: "1:260913424323:ios:a6631554b2614bed01ff76",
};

const PROD_HOSTS = ["toska-4ebf4.web.app", "toska-4ebf4.firebaseapp.com", "app.toskaapp.com"];

export const IS_PROD = PROD_HOSTS.includes(location.hostname);
export const FIREBASE_CONFIG = IS_PROD ? PROD : STAGING;

// reCAPTCHA Enterprise site key — App Check (prod only; staging is unenforced).
export const RECAPTCHA_SITE_KEY = "6LfKrQUtAAAAAIMrSCA0WW4UoY1cPe9iONaQLHBP";

// Keep in lockstep with the iOS app's currentPolicyVersion.
// v2 (2026-07-17): legal v1.0 shipped (17+, Texas, liability cap, no-AI-
// training). The signup consent links to the CURRENT terms/privacy pages, so
// stamping the current number is correct — lagging at 1 made every web signup
// redundantly re-accept the same policy on their first iOS launch.
export const POLICY_VERSION = 2;
