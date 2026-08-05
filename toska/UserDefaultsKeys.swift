import Foundation

// MARK: - UserDefaults key constants
//
// All UserDefaults keys in one place. A typo in a key string is a silent bug —
// the write succeeds, the read returns nil, and nothing tells you why.
// Using these constants makes typos a compile error instead.

enum UserDefaultsKeys {
    // Reconciliation — keyed per user so multiple accounts on one device
    // don't share a single reconcile timestamp.
    static func lastReconcileDate(uid: String) -> String {
        "lastReconcileDate_\(uid)"
    }

    // Feed scroll position preservation
    static let savedScrollPostId = "savedScrollPostId"

    // App review prompt — tracks whether the user has been asked
    static let hasBeenAskedForReview = "hasBeenAskedForReview"

    // Compose draft persistence — survives force-quit mid-typing.
    // One draft at a time (the active compose sheet); cleared on successful post.
    static let composeDraftText = "toska_composeDraftText"
    static let composeDraftTag  = "toska_composeDraftTag"
    // One-time: whether the user has been shown where saved drafts live
    // (Settings › Drafts) after their first save.
    static let hasSeenDraftLocationHint = "toska_hasSeenDraftLocationHint"

    // Push permission primer — shown once per install so the system prompt
    // doesn't fire cold. Cleared on sign-out so a different user signing in
    // on the same device gets their own primer.
    static let pushPrimerShown = "toska_pushPrimerShown"

    // Whether the previous run ended signed-in. Lets the auth-state
    // listener's INITIAL callback tell "ordinary signed-out launch" (no
    // scrub — running it rotated the FCM token on every cold start) apart
    // from "session invalidated while the app wasn't running" (per-user
    // state from the last account still on disk — scrub needed).
    static let wasSignedInAtLastRun = "toska_wasSignedInAtLastRun"

    // Analytics opt-out. Default true; flipped off via Settings → Privacy.
    // Read by the Telemetry namespace (non-View context) and written by
    // SettingsView via @AppStorage — same key string must match on both sides.
    static let shareAnonymousUsage = "toska_shareAnonymousUsage"

    // Offline drafts — keyed per surface so a kill mid-typing doesn't lose
    // the user's words. Compose drafts already use @AppStorage on a single
    // key (one draft); replies are keyed per post so drafts in different
    // threads don't clobber each other.
    static func replyDraft(postId: String) -> String {
        "toska_replyDraft_\(postId)"
    }

    // Adult-confirmation propagation flag. CreateAccountView's age gate
    // runs confirmAdultServerSide(uid:) to set `confirmedAdult: true` on
    // the user doc, but that call is `try?`-swallowed because a network
    // blip or App Check failure (common on simulator) shouldn't block
    // signup. When the server write doesn't land before OnboardingView
    // reads the user doc, OnboardingView's checkAcceptanceStatus saw
    // confirmedAdult=false and re-prompted the gate — making the user
    // confirm twice in the same signup session. This flag bridges the
    // gap: CreateAccountView sets it the moment the user passes the
    // local age gate, OnboardingView treats a set flag as "already
    // confirmed in this session," and consumes (clears) the flag so a
    // failed server confirmAdult still triggers a re-prompt on a
    // subsequent launch — preserving the long-tail server-side gate.
    // Keyed per-uid so a force-quit mid-flow doesn't leak the flag to
    // a different account that signs in on the same device.
    static func recentlyConfirmedAdult(uid: String) -> String {
        "toska_recentlyConfirmedAdult_\(uid)"
    }
}

// MARK: - DraftStore (N-4, 2026-06-09 re-review)
//
// On-device store for in-progress draft text (the new-post composer and
// per-thread reply boxes). Drafts are the rawest content in the app — "what
// I started writing but didn't send" — so they must NOT sit in UserDefaults
// plaintext (a .plist in the sandbox, protected only until first unlock and
// included in unencrypted backups).
//
// Best practice for sensitive *content* on iOS is the Data Protection API,
// not the Keychain (which is for small secrets/keys). Each draft is written
// to a file under Application Support with:
//   - NSFileProtectionComplete  → encrypted whenever the device is LOCKED,
//     even after first unlock (strictly stronger than UserDefaults today and
//     than a Keychain item using the usual AfterFirstUnlock accessibility);
//   - isExcludedFromBackup       → the draft never rides into an iCloud/Finder
//     backup, so it can't be restored/read elsewhere. For an ephemeral
//     auto-save buffer that's also the right semantics.
//
// Drafts are only ever read while the user is actively in the app (composer
// open / reply box focused), i.e. unlocked — so NSFileProtectionComplete
// never blocks a legitimate read. get() also migrates any pre-existing
// UserDefaults draft into the protected file and DELETES the plaintext copy.
enum DraftStore {
    private static let dirName = "Drafts"

    private static var directory: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent(dirName, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                    .protectionKey: FileProtectionType.complete
                ])
            } catch {
                return nil
            }
            var mutableDir = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableDir.setResourceValues(values)
        }
        return dir
    }

    // Keys can contain arbitrary postIds; percent-encode to a filesystem-safe name.
    private static func fileURL(for key: String) -> URL? {
        guard let dir = directory else { return nil }
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return dir.appendingPathComponent(safe)
    }

    static func get(forKey key: String) -> String? {
        if let url = fileURL(for: key),
           let data = try? Data(contentsOf: url),
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        // Migrate a legacy UserDefaults draft into the protected file, scrubbing
        // the plaintext copy, then return it.
        if let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty {
            set(legacy, forKey: key)
            return legacy
        }
        return nil
    }

    static func set(_ value: String, forKey key: String) {
        // Always scrub any legacy plaintext copy.
        UserDefaults.standard.removeObject(forKey: key)
        guard let url = fileURL(for: key) else { return }
        if value.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? Data(value.utf8).write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func remove(forKey key: String) {
        set("", forKey: key)
    }

    // Typed accessors (2026-08-05 draft-loss fix). A draft is more than its
    // words: the composer's letter flag (2,000-char mode) has to survive a
    // force-quit too. Before this, only text+tag were buffered, so a restored
    // letter of <=500 chars came back as a NORMAL post — and the first
    // keystroke then truncated anything the user had typed past 500. Bools
    // ride the same protected file store as the text so clearAll() and the
    // sign-out scrub cover them with zero extra plumbing.
    //
    // Encoding is deliberate: true -> "1", false -> ABSENT (set("") deletes
    // the file). That makes a MISSING key — i.e. every buffer written before
    // today — decode to `false`, which is exactly the pre-existing default
    // ("not a letter"). Backward compatibility with no migration step, and no
    // way for a legacy buffer to come back flagged as a letter by accident.
    static func getBool(forKey key: String) -> Bool {
        get(forKey: key) == "1"
    }

    // Named setBool/getBool rather than overloading set(_:forKey:) — a Bool
    // overload next to a String one invites a literal binding to the wrong
    // one at a call site and would silently persist "true"/"false" strings.
    static func setBool(_ value: Bool, forKey key: String) {
        set(value ? "1" : "", forKey: key)
    }

    // Drop every draft (used on sign-out so the next account on this device
    // inherits none of the previous user's in-progress words).
    static func clearAll() {
        guard let dir = directory else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
