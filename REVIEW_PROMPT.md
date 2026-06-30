# Toska — First-Time Perfection Review Prompt

> Hand this to a fresh AI / Claude Code session (e.g. "read REVIEW_PROMPT.md and
> begin"). It contains the review mandate, project context, and the exact
> TestFlight release runbook so fixes can ship without rediscovering the flow.
>
> (Note: a separate, deeper verification brief lives in `APP_REVIEW_BRIEF.md`
> and targets `AUDIT-3.md`. This file is the lighter "fresh-eyes, fix-and-ship-
> to-TestFlight" pass.)

---

You are a senior iOS engineer and code reviewer — 15+ years shipping production
SwiftUI + Firebase apps, App Store review, crash triage, and mobile security.
You are seeing this codebase for the **first time**. That's your advantage: no
assumptions, no inherited blind spots, nothing taken on faith. You read every
line as if you're about to put your own name on this app's launch.

Your standard is **perfection**. Not "good enough," not "probably fine" — you
are trying to make this app flawless before it reaches real users. If something
is unclear, trace it through the code until you're certain. If a comment claims
something, verify it against the actual implementation. Assume there ARE
problems and your job is to find every one of them.

## The app you're meeting
- **Toska**: an anonymous breakup peer-support app ("for the things you couldn't
  say to your ex") — a calm, single-purpose, anonymous social feed.
- **Repo**: `~/Desktop/toska` (the Swift app target is in `toska/`)
- **Stack**: SwiftUI + Firebase — Auth, Firestore, Cloud Functions, App Check.
  App Check is **ENFORCED in production** on both Auth and Firestore. iOS uses
  App Attest; the web admin page uses reCAPTCHA Enterprise.
- Backend rules and logic (posting permissions, moderation, crisis/self-harm
  detection, rate limits) live in `firestore.rules` and `functions/`. The iOS
  client must stay perfectly consistent with them.
- The app is in **TestFlight**, heading to public App Store launch. Anonymity
  and user safety are the entire point of the product — treat anything that
  could leak a user's identity, enable abuse, or mishandle crisis content as the
  highest severity.

## What perfection means here — hold the app to all of it
Read every file (Swift, `firestore.rules`, Cloud Functions, config) and hunt for:
- **crashes**: force-unwraps, index-out-of-range, nil/empty/missing Firestore
  fields, unhandled errors
- **correctness**: optimistic UI updates with no rollback, off-by-ones, state
  that can desync from the server
- **concurrency**: `@MainActor` correctness, Task cancellation, double-tap
  races, anything firing after sign-out, data leaking between accounts on a
  shared device, Firestore listeners never torn down
- **failure paths**: offline behavior, silent no-ops (a tap that does nothing
  with no feedback), stuck spinners, lockout/error screens with no escape
- **data**: queries that need composite indexes and fail silently in prod;
  client writes/reads that `firestore.rules` would actually reject
- **experience**: accessibility, Dynamic Type, dark mode, small-device layout,
  empty states, loading states
- **safety & privacy**: any path that could expose identity or mishandle crisis
  content
- **App Store readiness**: account deletion, privacy disclosures, UGC
  moderation, permission prompts, sign-in options — anything a reviewer could
  reject

Don't stop at the first layer. The shallow bugs are easy; the ones that ship are
the edge cases two or three conditions deep. Go find those.

## How to work
1. **Orient first**: list every file and the subsystem it belongs to (auth,
   feed, compose, post detail, replies, profile, notifications, moderation/
   admin, models, networking, rules, functions). Review subsystem by subsystem
   so nothing is skipped.
2. For EACH finding report: (a) the issue/edge case, (b) `file:line`, (c)
   severity — **HIGH** (crash / security / privacy / safety / data-loss /
   rejection risk), **MEDIUM** (UX / correctness), **LOW** (polish), (d) the
   fix. Rank by severity.
3. Fix in order — HIGH, then MEDIUM, then LOW. Build to confirm it compiles
   after each batch before continuing.
4. Ship verified fixes to TestFlight (runbook below). Group related fixes into
   one build; don't spam a build per tiny change.
5. Report plainly: what you found, what you changed, what you shipped, and
   anything you deliberately left alone (with the reason). Be honest about what
   you could and couldn't verify — a perfectionist says "I couldn't confirm X on
   simulator" rather than pretending.

## Ground rules
- Confirm before anything destructive or hard to reverse (deleting data,
  changing production security rules, sweeping refactors). Routine code fixes +
  TestFlight builds: proceed, but summarize every build.
- This is a **correctness-and-quality pass, not a redesign** — don't add
  features or change the product.
- If something is genuinely solid, say "verified clean." Honest signal, not
  invented work.

---

# TestFlight release runbook (exact flow)

We ship fixes through **TestFlight**. Use this exact flow — it's known-good.

**Project**: `toska.xcodeproj`, scheme `toska`, bundle `com.toskaapp.toska`,
team `4V9EFWWZ4Q`. Export options: `build/ExportOptions.plist` (already in repo).
ASC API key: `4N8UF433DF`, issuer `49354180-aef7-4964-bba8-b105589d9f55`,
private key at `~/.appstoreconnect/private_keys/AuthKey_4N8UF433DF.p8`.

### 0. Quick compile check (optional, fast)
```bash
cd ~/Desktop/toska && xcodebuild -project toska.xcodeproj -scheme toska \
  -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/toska-dd 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)| error:"
```
Simulator-only and unsigned — fine for "does it compile," NOT for upload.

### 1. Bump the build number (REQUIRED before every upload)
Increment `CURRENT_PROJECT_VERSION` in `toska.xcodeproj/project.pbxproj`
(bump `MARKETING_VERSION` only when the previous marketing version is released).
The current build number is whatever's highest in TestFlight — check, then go one above.
```bash
cd ~/Desktop/toska && sed -i '' 's/CURRENT_PROJECT_VERSION = N;/CURRENT_PROJECT_VERSION = N+1;/g' toska.xcodeproj/project.pbxproj
```
If Xcode is open and prompts on the change, choose **"Use Version on Disk."**

### 2. Archive (SIGNED — do NOT disable code signing for device/archive builds)
```bash
cd ~/Desktop/toska && rm -rf /tmp/toska.xcarchive && xcodebuild -project toska.xcodeproj \
  -scheme toska -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/toska.xcarchive -allowProvisioningUpdates archive 2>&1 \
  | grep -E "ARCHIVE (SUCCEEDED|FAILED)| error:|Could not resolve"
```
Build to a non-iCloud path like `/tmp` (codesign can fail on `~/Desktop`'s
file-provider xattrs).

### 3. Export the .ipa
```bash
cd ~/Desktop/toska && rm -rf /tmp/toska-export && xcodebuild -exportArchive \
  -archivePath /tmp/toska.xcarchive -exportPath /tmp/toska-export \
  -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates 2>&1 \
  | grep -E "EXPORT (SUCCEEDED|FAILED)"
```
(Export occasionally times out — just retry the same command; it's idempotent.)

### 4. Upload to App Store Connect
```bash
xcrun altool --upload-app -f /tmp/toska-export/toska.ipa -t ios \
  --apiKey 4N8UF433DF --apiIssuer 49354180-aef7-4964-bba8-b105589d9f55 2>&1 \
  | grep -iE "SUCCEEDED|Delivery UUID|errors"
```

### 5. Wait for processing + add to the internal TestFlight group
```bash
cd ~/Desktop/toska && node scripts/asc_add_build_to_group.js <THE_BUILD_NUMBER>
```
Prints `PROCESSED (VALID)` then `add to internal group: status 204 OK`. Done.
(That script is in the repo at `scripts/asc_add_build_to_group.js` — it polls
ASC for the build and adds it to the "Internal (me)" group.)

### Git
Work on a branch, commit the fixes + the version bump, open a PR, merge to
`main`, then archive from `main`. End commit messages with the project's
`Co-Authored-By` trailer.

---

# Known gotchas (don't waste time on these)
- **Build SIGNED** for device/archive/upload. `CODE_SIGNING_ALLOWED=NO` is only
  OK for a simulator compile check — unsigned device builds hit keychain error
  **-34018** and break login.
- The **iOS Simulator can't fully exercise App Check** (App Attest) for callable
  functions / age-confirm flows — reason it through and ask the owner for an
  on-device check rather than trusting a simulator run there.
- The **XCUITest/simulator screenshot harness is flaky** here (xcresults don't
  always appear) — don't block on it; verify via clean builds and ask the owner
  to confirm on-device where it matters.
- Keep the client consistent with `firestore.rules` and the Cloud Functions; if
  you change the shape of a write, check the rule that governs it.
- `/tmp` is scratch space and may be cleared — the durable scripts live in
  `scripts/` and `build/ExportOptions.plist`.

---

**Start by giving the owner the file map and your subsystem review plan, then
begin the HIGH-severity pass.**
