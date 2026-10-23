# Known bugs — backlog

Format: severity · surface · status. "Pre-existing" = present before the
2026-10 launch-audit work; not a regression from it.

---

## B94-1 — Feed GIF doesn't render until the row is re-laid-out (tap-in / scroll)

- **Severity:** LOW (cosmetic; GIF always shows in the post detail view and after any scroll/refresh)
- **Surface:** iOS feed (`toska/FeedView.swift`, `toska/FeedViewModel.swift`)
- **Status:** OPEN — targeted for build 94
- **Reported:** 2026-10-23, owner device test on build 93
- **Regression?** No. Pre-existing on 91/92 (established by code reading, not by running those builds — build 93's only iOS deltas were logging/wording/comments, which don't touch this path).

**Repro:**
1. Post a GIF, or open a fresh feed containing a just-created GIF post.
2. The post row appears with text but no GIF.
3. Tap into the post → the GIF shows. Back out → it now shows in the feed too. (Scrolling the row off/on screen also makes it appear.)

**Diagnosis:**
The feed row renders GIFs via `StableGifPreview` (FeedView.swift ~868), but the
row receives its URL *by value* at construction: `gifUrl: vm.postGifUrls[post.id]`
(FeedView.swift ~1880). `postGifUrls` is filled by
`FeedViewModel.extractPostMetadata(from:)` (FeedViewModel.swift ~1169-1171) from
the feed snapshot — which can populate *after* the rows first lay out. Because
the URL is captured at row-build time (nil then), the row doesn't rebuild when
`postGifUrls` later gains the entry, until SwiftUI re-lays the row for another
reason (scroll, or returning from PostDetailView, which reads the doc directly).

**Proposed fix (build 94):**
Make the row read `gifUrl` reactively instead of by captured value — e.g. have
`FeedPostRow` take the `postId` and look up `vm.postGifUrls[id]` inside its own
`body` with `vm` as an `@ObservedObject`, so a `@Published` change to
`postGifUrls` re-renders it. Alternatively, carry `gifUrl` on the `FeedPost`
model itself and set it during the same snapshot parse that builds the row data
(single source of truth), avoiding the side-dictionary timing entirely. Verify
with a GIF post appearing in a live feed without any tap/scroll.

---

## B94-2 — Repost not reflected in the feed until manual refresh

- **Severity:** LOW–MED (functionally correct — the repost IS created and persists; only the immediate UI feedback lags)
- **Surface:** iOS repost action + feed (`toska/PostInteractionManager.swift`, `toska/FeedViewModel.swift`)
- **Status:** OPEN — targeted for build 94
- **Reported:** 2026-10-23, owner device test on build 93
- **Regression?** No. Pre-existing on 91/92 (same basis as B94-1).

**Repro:**
1. Repost a post.
2. The feed doesn't show the repost / updated state immediately.
3. Pull-to-refresh → it appears.

**Diagnosis:**
Reposting writes a new post doc (`{uid}_repost_{postId}`). The feed uses a
snapshot listener (FeedViewModel `addSnapshotListener`, ~1021/1038/1057), so the
new doc *does* arrive on the next snapshot — but the **optimistic** UI update at
action time isn't applied, so there's a visible gap until the listener delivers
(or the user refreshes). The reposted-state set (`repostedPostIds`,
InteractionStateStore) and/or the inserted repost row aren't updated in the same
turn as the tap.

**Proposed fix (build 94):**
On a successful repost, optimistically (a) add the id to `repostedPostIds` so the
button flips immediately, and (b) insert/refresh the repost entry locally rather
than waiting for the snapshot — mirroring how like/save optimistic updates are
handled. Reconcile with the listener's authoritative copy when it arrives (guard
against a double-insert when the snapshot delivers the same doc). Verify a repost
shows in the feed with no manual refresh, and that the count/state stays correct
after the listener catches up.

---

*Both found during the build-93 production verification pass. Critical paths
(sign-in, feed load, GIF post, crisis detection + 988 + crisis page push,
moderation) all confirmed working on 93; these two are cosmetic/feedback polish.*

---

## B94-W — Full web sharing-consent UI (checkbox at sign-up + web settings toggle)

- **Severity:** MED (consent/privacy) · **Status:** OPEN — build 94 / web
- **Context:** As of 2026-10-23 web sign-up sets `allowSharing: false` (opt-in; stops the silent opt-in that had no wording and no control). But web still has NO way for a user to turn sharing *on* later, and no wording is shown. iOS has a Settings toggle; web has nothing.
- **Proposed:** (a) add an optional checkbox at web sign-up with the SEO-01 wording ("share publicly — your post may be featured on the toska website and appear in Google search. your handle is never shown."), unchecked by default, writing `allowSharing` accordingly; (b) add a sharing toggle to the web app (settings/profile) so web users can see and change it, matching iOS. Reuse `showSharing` wording verbatim from iOS SettingsView.
- **Do not** change existing accounts.

## B94-iOS — Sharing opt-in on iOS (defaults done; sign-up choice pending)

- **Severity:** MED (consent/privacy) · **Status:** PARTIAL — defaults flipped 2026-10-23 (rides next build); sign-up checkbox pending
- **Done (2026-10-23):** creation default flipped to `allowSharing: false` at all three paths — CreateAccountView, AppleSignInHelper, SplashView. Settings toggle unchanged (still the opt-in control). Read-fallbacks (`?? true`) deliberately left so existing/legacy accounts are unchanged.
- **Pending (build 94):** add an optional choice at sign-up (CreateAccountView + Apple/Splash onboarding) showing the SEO-01 wording, unchecked by default, that sets `allowSharing` at creation. Keep the Settings toggle.
- **Do not** change existing accounts.
