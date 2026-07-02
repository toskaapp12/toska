import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import ImageIO
import UIKit

/// One-time explainer shown the first time a user turns on a compose option
/// that isn't self-evident from its icon (whisper / midnight / letter).
enum ComposeHint: String, Identifiable {
    case whisper, midnight, letter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .whisper:  return "whisper"
        case .midnight: return "midnight post"
        case .letter:   return "letter"
        }
    }
    var message: String {
        switch self {
        case .whisper:  return "your post quietly disappears in 1 hour — say it out loud, then let it go."
        case .midnight: return "your post disappears tonight at midnight — just a thought for today."
        case .letter:   return "letter mode gives you up to 2,000 characters — room to say more than a short post."
        }
    }
}

@MainActor
struct ComposeView: View {
    @Environment(\.dismiss) var dismiss
    var initialText: String = ""
    var initialTag: String? = nil
    // When this compose was opened from the daily-prompt "respond" button,
    // FeedView passes today's promptDate (yyyy-MM-dd). It's stamped onto the
    // resulting post doc so the FeedHeaderCard can detect that the user has
    // already responded today and flip the card to show their response with
    // edit/delete. nil for non-prompt posts (the regular + compose path).
    var promptDate: String? = nil
    var onPostSuccess: (() -> Void)? = nil
    // When opened from DraftsView, the id of the draft being edited.
    // The Save button updates that doc instead of creating a new draft;
    // a successful Publish deletes the draft so the user ends up with
    // one published post instead of a stranded draft + post pair.
    var editingDraftId: String? = nil
    // Draft persistence survives force-quit so a user mid-compose doesn't lose
    // their words if iOS terminates the app or they swipe it away. Cleared on
    // successful post. N-4 (2026-06-09 re-review): persisted via DraftStore
    // (NSFileProtectionComplete + backup-excluded) instead of UserDefaults
    // plaintext. These @State vars mirror the on-disk value — onAppear loads
    // them, the .onChange handlers below write through.
    @State private var draftText: String = ""
    @State private var draftTag: String = ""
    @State private var draftSaveTask: Task<Void, Never>? = nil   // debounces the encrypted draft write
    @State private var text = ""
    @State private var selectedTag: String? = nil
    @State private var showTagPicker = false
    @State private var isPosting = false
    @State private var showGentleCheck = false
    // Severity tier chosen when the check-in is opened, so the modal can
    // adapt its copy/behavior. Explicit tier shows even if gentleCheckIn is off.
    @State private var gentleCheckLevel: CrisisLevel = .soft
    @State private var showNameWarning = false
    @State private var showContentWarning = false
    // Set when a post will be held for review server-side (pending_review), so
    // after the write lands we tell the user instead of leaving them wondering
    // why it isn't in the feed. Set by: the name/PII "post anyway", the
    // content-violation "post anyway", AND crisis/concerning content (which the
    // server ALWAYS holds — the previous "crisis is not held" note was wrong).
    @State private var postWillBeHeld = false
    @State private var showUnderReview = false
    // The content-violation category from the last contentViolation() check,
    // so the warning dialog can decide whether to offer a "post anyway" override
    // (lower-severity categories only — slurs/sexual/harassment stay hard-blocked).
    @State private var contentViolationType: ContentViolationType?
    @State private var contentWarningMessage = ""
    @State private var userHandle = "anonymous"
    @State private var showRateLimitWarning = false
    @State private var showOfflineWarning = false
    @State private var postError = ""
    @State private var selectedGifUrl: String? = nil
    @State private var showGifPicker = false
    @State private var expiresAtMidnight = false
    @State private var isWhisper = false
    @State private var isLetter = false
    private let letterCharLimit = 2000

    // First-time explainer for the compose options people don't recognize at a
    // glance (whisper / midnight / letter). Shown once per option the first time
    // it's turned on, then remembered so it never nags again.
    @State private var activeHint: ComposeHint? = nil
    @AppStorage("toska_hint_whisper") private var whisperHintSeen = false
    @AppStorage("toska_hint_midnight") private var midnightHintSeen = false
    @AppStorage("toska_hint_letter") private var letterHintSeen = false
    @State private var offlineMonitorTask: Task<Void, Never>? = nil
    @State private var focusTask: Task<Void, Never>? = nil
      @FocusState private var textFocused: Bool

    private let charLimit = 500
    let tags = sharedTags

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var activeCharLimit: Int { isLetter ? letterCharLimit : charLimit }
    /// The Firestore rule validates `text.size()` which counts UTF-16 code
    /// units, while Swift's `text.count` counts grapheme clusters. For plain
    /// text these agree; for emoji-heavy text (especially ZWJ sequences),
    /// UTF-16 count > grapheme count, and a post that looks under the limit
    /// to the user can be rejected by the server. Use the larger of the two
    /// counts so the user-visible cap matches the server's cap and the post
    /// never silently fails validation.
    var effectiveCharCount: Int { max(text.count, text.utf16.count) }
    var charRemaining: Int { activeCharLimit - effectiveCharCount }
    var isNearLimit: Bool { charRemaining < 50 }

    // Toolbar mode summary shown on the right (2026 mockup): visibility · type.
    var composeStatusText: String {
        let visibility = isWhisper ? "whisper" : (expiresAtMidnight ? "midnight" : "public")
        return isLetter ? "\(visibility) · letter" : visibility
    }

    // A single toolbar glyph: gray when off, accent-on-soft-purple when on
    // (matches the selected envelope in the mockup). Replaces the old white-on-
    // plum bar.
    @ViewBuilder func composeGlyph(_ system: String, active: Bool) -> some View {
        Image(systemName: system)
            .font(.system(size: 16, weight: .regular))
            .foregroundColor(active ? ToskaColor.accent : ToskaColor.text2)
            .frame(width: 34, height: 34)
            .background(active ? ToskaColor.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9))
    }
    /// Disabled when offline so the user gets visible feedback instead of
    /// the silent Firestore-offline-queue behavior. The offline banner
    /// already explains the state; the inert button reinforces it.
    var canPost: Bool {
        // Text is required. firestore.rules and the validatePost Cloud Function
        // both enforce `text.size() > 0`, so a GIF-only post (empty body) is
        // rejected server-side and would loop on the generic "couldnt post"
        // error forever. The GIF is a supplement to text, not a standalone post.
        !trimmedText.isEmpty
            && effectiveCharCount <= activeCharLimit   // block over-limit (e.g. toggling letter→normal with a long body) so it can't hit the server rule and fail
            && !isPosting
            && NetworkMonitor.shared.isConnected
            && !UserHandleCache.shared.isRestricted
    }

    // Save-as-draft is intentionally less gated than post:
    //   - no rate-limit (drafts don't fan out to feed / push / counters)
    //   - no restriction check (drafts never publish — even a restricted
    //     user can save private text)
    //   - GIF-only drafts skipped (a draft is text the user is wrestling
    //     with; a saved GIF without text isn't the use case here)
    // Network is still required since the write hits Firestore.
    var canSave: Bool {
        !trimmedText.isEmpty
            && !isPosting
            && NetworkMonitor.shared.isConnected
    }

    var composePlaceholder: String {
            if isLetter { return "dear you..." }
            if isWhisper { return "say it quietly..." }
            let tod = timeOfDayLabel()
            // Stage-aware overrides: the user's breakup-stage answer from
            // onboarding (UserHandleCache.shared.breakupStage) tunes the
            // afternoon prompt to where they actually are. Defaults to the
            // generic to-them prompt for nil / unmapped stages so accounts
            // that pre-date or skipped the stage step still get the right
            // breakup framing.
            let stage = UserHandleCache.shared.breakupStage
            if tod == "this afternoon" {
                switch stage {
                case "still in it":      return "say the thing you cant say to them yet..."
                case "a year or more":   return "what would you tell them now..."
                case "they left":        return "say what they didnt let you say..."
                case "i left":           return "say the thing you held back when you left..."
                case "it just happened": return "say the thing you cant text them..."
                default:                 return "say the thing you cant say to them..."
                }
            }
            if tod == "tonight" { return "whats keeping you up..." }
            else if tod == "this morning" { return "how did you sleep..." }
            else { return "how are you. honestly..." }
        }

    var body: some View {
        // NavigationStack so the GIF picker can push instead of sheet-present
        // (consistency with the rest of the app's slide-from-right pattern).
        // dismiss() at this level still dismisses the parent fullScreenCover
        // because @Environment(\.dismiss) is captured above the NavigationStack;
        // dismiss() inside GifPickerView pops the navigation stack.
        NavigationStack {
        ZStack {
            LateNightTheme.feedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: - Top bar
                HStack(spacing: 8) {
                    Button { dismiss() } label: {
                        Text("cancel")
                            .font(ToskaFont.sans(15))
                            .foregroundColor(LateNightTheme.secondaryText)
                    }

                    Spacer()

                    // Save-as-draft. Soft secondary-styled button so the
                    // primary "post" still reads as the default action.
                    // Wording shifts to "update" when editing an existing
                    // draft so the user knows whether they're creating
                    // a new entry or revising the open one.
                    Button { saveAsDraft() } label: {
                        Text(editingDraftId == nil ? "save draft" : "update")
                            .font(ToskaFont.sans(15, weight: .semibold))
                            .foregroundColor(canSave ? ToskaColor.accent : ToskaColor.text3)
                    }
                    .disabled(!canSave)
                    .accessibilityLabel(editingDraftId == nil ? "Save as draft" : "Update draft")

                    Button { attemptPost() } label: {
                        Text(isPosting ? "posting..." : "post")
                            .font(ToskaFont.sans(15, weight: .semibold))
                            .foregroundColor(canPost ? .white : ToskaColor.text2)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(canPost ? ToskaColor.accent : ToskaColor.input)
                            .clipShape(Capsule())
                    }
                    .disabled(!canPost)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // MARK: - Toolbar (formerly at the bottom; moved to sit right
                // under the cancel/save/post header so the modifiers are
                // within easy reach without scrolling past the text editor).
                Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)

                HStack(spacing: 4) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showTagPicker.toggle() }
                    } label: {
                        composeGlyph("tag", active: showTagPicker || selectedTag != nil)
                    }
                    .accessibilityLabel("Tag")

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isWhisper.toggle()
                            if isWhisper { expiresAtMidnight = false }
                        }
                        if isWhisper && !whisperHintSeen { whisperHintSeen = true; activeHint = .whisper }
                    } label: {
                        composeGlyph(isWhisper ? "eye.fill" : "eye", active: isWhisper)
                    }
                    .accessibilityLabel(isWhisper ? "Whisper on, disappears in 1 hour" : "Whisper")

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expiresAtMidnight.toggle()
                            if expiresAtMidnight { isWhisper = false }
                        }
                        if expiresAtMidnight && !midnightHintSeen { midnightHintSeen = true; activeHint = .midnight }
                    } label: {
                        composeGlyph(expiresAtMidnight ? "moon.fill" : "moon", active: expiresAtMidnight)
                    }
                    .accessibilityLabel(expiresAtMidnight ? "Midnight post on, disappears at midnight" : "Midnight post")

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isLetter.toggle() }
                        if isLetter && !letterHintSeen { letterHintSeen = true; activeHint = .letter }
                    } label: {
                        composeGlyph(isLetter ? "envelope.fill" : "envelope", active: isLetter)
                    }
                    .accessibilityLabel(isLetter ? "Letter mode on" : "Letter mode")

                    Button { showGifPicker = true } label: {
                        Text("GIF")
                            .font(ToskaFont.sans(13, weight: .bold))
                            .foregroundColor(selectedGifUrl != nil ? ToskaColor.accent : ToskaColor.text2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .accessibilityLabel("Add GIF")

                    Spacer()

                    // Mode summary (matches the 2026 mockup): "public · letter",
                    // "whisper", "midnight · letter", etc.
                    Text(composeStatusText)
                        .font(ToskaFont.sans(13))
                        .foregroundColor(ToskaColor.text3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // Tag picker expansion now drops DOWN from the toolbar above
                // (was originally pinned to the bottom toolbar with a
                // .move(edge: .bottom) transition).
                if showTagPicker {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("how does this feel")
                            .font(ToskaFont.sans(11, weight: .semibold))
                            .foregroundColor(LateNightTheme.secondaryText)
                            .tracking(0.5)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(tags, id: \.name) { tag in
                                    Button {
                                        selectedTag = tag.name
                                        withAnimation(.easeOut(duration: 0.2)) { showTagPicker = false }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: tag.icon)
                                                .font(.system(size: 10))
                                            Text(tag.name)
                                                .font(ToskaFont.sans(11, weight: .medium))
                                        }
                                        .foregroundColor(selectedTag == tag.name ? .white : Color(hex: tag.colorHex))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(selectedTag == tag.name ? Color(hex: tag.colorHex) : Color(hex: tag.colorHex).opacity(0.08))
                                        .clipShape(Capsule())
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.bottom, 8)
                    }
                    .background(LateNightTheme.cardBackground)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // MARK: - Warning banners
                if UserHandleCache.shared.isRestricted {
                    warningBanner(icon: "exclamationmark.octagon", text: "your account is under review. you cannot post right now.", color: "c45c5c")
                }
                if showRateLimitWarning {
                    warningBanner(icon: "clock", text: "slow down. the feelings will still be there in 30 seconds.", color: "c49a6c")
                }
                // Show the offline warning whenever the network is actually
                // down, not only after a failed post tap. Reading the
                // @Observable singleton inside body creates a tracked
                // dependency so this updates the moment connectivity flips.
                if showOfflineWarning || !NetworkMonitor.shared.isConnected {
                    warningBanner(icon: "wifi.slash", text: "youre offline. the words will keep.", color: "c45c5c")
                }
                if !postError.isEmpty {
                    warningBanner(icon: "exclamationmark.circle", text: postError, color: "c45c5c")
                }

                // Soft "still in it" nudge: users who picked the
                // pre-breakup stage in onboarding may not be ready to
                // post publicly (partner could see / recognize their
                // handle). Surface the save-as-draft path so they have
                // a place to write without having to ship it. Hidden
                // when editing an existing draft (the call to action
                // is already obvious there).
                if UserHandleCache.shared.breakupStage == "still in it" && editingDraftId == nil {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10))
                        Text("dont have to share it. tap save and it stays just for you.")
                            .font(ToskaFont.sans(11))
                    }
                    .foregroundColor(Color.toskaBlue.opacity(0.75))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.toskaBlue.opacity(0.06))
                }

                Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)

                // MARK: - Compose area
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer().frame(height: 8)

                        // Text input
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(composePlaceholder)
                                    .font(ToskaFont.serif(18))
                                    .foregroundColor(LateNightTheme.isLateNight ? Color(hex: "3a3835") : Color(hex: "c0c3ca"))
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                            }

                            TextEditor(text: $text)
                                                            .font(ToskaFont.serif(18))
                                                            .foregroundColor(LateNightTheme.primaryText)
                                                            .lineSpacing(5)
                                                            .scrollContentBackground(.hidden)
                                                            .padding(.horizontal, 12)
                                                            .padding(.top, 4)
                                                            .frame(minHeight: 200)
                                                            .focused($textFocused)
                                                            // Drag down inside the editor to dismiss the
                                                            // keyboard. Replaces a blanket tap-to-dismiss
                                                            // gesture on the whole screen that intercepted
                                                            // the editor's own taps and broke the
                                                            // select/paste menu + cursor placement.
                                                            .scrollDismissesKeyboard(.interactively)
                                .onChange(of: text) { _, newValue in
                                    // Truncate using the same metric the Firestore rule uses
                                    // (UTF-16 length) so heavy-emoji posts don't silently fail
                                    // the server-side check.
                                    //
                                    // Single-pass: walk the grapheme clusters, accumulate
                                    // UTF-16 units, stop at the first cluster that would push
                                    // past the cap. Previous implementation built `truncated`
                                    // via string concatenation inside a per-character loop —
                                    // O(n²) in string length, which introduced visible typing
                                    // lag on long posts (up to ~2M ops for a 2000-char letter
                                    // at the boundary).
                                    //
                                    // utf16.count is always >= count for Unicode content, so
                                    // checking utf16.count alone is equivalent to the previous
                                    // max(count, utf16.count) check.
                                    if newValue.utf16.count > activeCharLimit {
                                        var utf16Count = 0
                                        var endIdx = newValue.startIndex
                                        for ch in newValue {
                                            let chUtf16 = String(ch).utf16.count
                                            if utf16Count + chUtf16 > activeCharLimit { break }
                                            utf16Count += chUtf16
                                            endIdx = newValue.index(after: endIdx)
                                        }
                                        text = String(newValue[..<endIdx])
                                    }
                                    if showRateLimitWarning { showRateLimitWarning = false }
                                    if showOfflineWarning { showOfflineWarning = false }
                                    if !postError.isEmpty { postError = "" }
                                    // Persist draft on each keystroke so a
                                    // force-quit doesn't lose the user's words.
                                    // Cleared when the post succeeds. Only for the
                                    // NEW-post composer: when editing a saved draft
                                    // (editingDraftId != nil) this shared buffer must
                                    // not be touched, or it clobbers an in-progress
                                    // new post and resurrects the edited draft into
                                    // the next fresh compose.
                                    if editingDraftId == nil {
                                        draftText = newValue
                                    }
                                }
                            // Char counter — shows remaining chars as the user
                            // types, switches to a soft warning color at <100
                            // remaining so the boundary doesn't surprise them.
                            // utf16.count matches the Firestore rule's size()
                            // check + the onChange truncation above.
                            HStack {
                                Spacer()
                                Text("\(activeCharLimit - text.utf16.count)")
                                    .font(ToskaFont.sans(13))
                                    .foregroundColor(
                                        text.utf16.count >= activeCharLimit
                                            ? Color.toskaErrorRed
                                            : (activeCharLimit - text.utf16.count < 100
                                                ? Color.toskaAccentTan
                                                : ToskaColor.text3)
                                    )
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                        }

                        // Selected GIF preview
                        if let gifUrl = selectedGifUrl {
                            ZStack(alignment: .topTrailing) {
                                // Custom loader (not AsyncImage). ComposeView's
                                // body recomputes constantly (keyboard, focus,
                                // text edits, transitions), and AsyncImage tears
                                // down + recreates on each pass, cancelling the
                                // URLSession task with NSURLError -999 forever.
                                // .id() didn't fix it. StableGifPreview owns the
                                // load state in @State and uses .task(id:) so the
                                // image survives parent recomputes; the GIF
                                // actually appears as soon as the bytes arrive.
                                StableGifPreview(urlString: gifUrl)

                                Button {
                                    withAnimation { selectedGifUrl = nil }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(LateNightTheme.secondaryText)
                                        .background(Circle().fill(LateNightTheme.cardBackground))
                                }
                                .accessibilityLabel("Remove GIF")
                                .offset(x: -6, y: 6)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                        }

                        // Selected tag pill
                        if let tag = selectedTag {
                            HStack(spacing: 8) {
                                let tagData = tags.first(where: { $0.name == tag })
                                Image(systemName: tagData?.icon ?? "tag")
                                    .font(.system(size: 10))
                                Text(tag)
                                    .font(ToskaFont.sans(11, weight: .medium))
                                Button { withAnimation { selectedTag = nil } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(hex: tagData?.colorHex ?? "9198a8").opacity(0.4))
                                }
                            }
                            .foregroundColor(Color(hex: tags.first(where: { $0.name == tag })?.colorHex ?? "9198a8"))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .background(Color(hex: tags.first(where: { $0.name == tag })?.colorHex ?? "9198a8").opacity(0.08))
                            .cornerRadius(16)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                        }
                    }
                }

                // Letter mode banner
                if isLetter {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope.open")
                            .font(.system(size: 11))
                        Text("writing a letter · up to 2,000 characters")
                            .font(ToskaFont.sans(11, weight: .medium))
                        Spacer()
                        Button { isLetter = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Color.toskaAccentGold.opacity(0.5))
                        }
                    }
                    .foregroundColor(Color.toskaAccentGold)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.toskaAccentGold.opacity(0.06))
                }

                // Whisper mode banner
                if isWhisper {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 11))
                        Text("whisper · disappears in 1 hour")
                            .font(ToskaFont.sans(11, weight: .medium))
                        Spacer()
                        Button { isWhisper = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Color.toskaWhisperPink.opacity(0.5))
                        }
                    }
                    .foregroundColor(Color.toskaWhisperPink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.toskaWhisperPink.opacity(0.06))
                }

                // Midnight mode banner
                if expiresAtMidnight {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.stars")
                            .font(.system(size: 11))
                        Text("this post disappears at midnight")
                            .font(ToskaFont.sans(11, weight: .medium))
                        Spacer()
                        Button { expiresAtMidnight = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Color.toskaMidnightPurple.opacity(0.5))
                        }
                    }
                    .foregroundColor(Color.toskaMidnightPurple)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.toskaMidnightPurple.opacity(0.06))
                }

            }

            // MARK: - Gentle check dialog
            if showGentleCheck {
                CrisisCheckInView(
                    isPresented: $showGentleCheck,
                    level: gentleCheckLevel,
                    // Crisis/concerning content is held for review server-side, so
                    // flag it before posting to surface the "under review" notice.
                    onProceed: { postWillBeHeld = true; postNow() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            // MARK: - Content warning dialog
            if showContentWarning {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { showContentWarning = false }

                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(Color.toskaErrorRed)

                    Text("hold on")
                        .font(ToskaFont.serifItalic(18))
                        .foregroundColor(LateNightTheme.handleText)

                    Text(contentWarningMessage)
                        .font(ToskaFont.sans(12))
                        .foregroundColor(LateNightTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    VStack(spacing: 8) {
                        Button { showContentWarning = false } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "pencil").font(.system(size: 13))
                                Text("edit my post").font(ToskaFont.sans(13, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.toskaBlue)
                            .cornerRadius(12)
                        }
                        // Lower-severity categories offer "post anyway" → the post
                        // is held for review (recoverable), so a false-positive
                        // can't hard-lock a grieving user out of posting.
                        if contentViolationAllowsOverride {
                            Button {
                                showContentWarning = false
                                postWillBeHeld = true
                                // Re-run the name/PII check that attemptPost would have
                                // run NEXT — otherwise a spam/link post that ALSO
                                // contains a real name slips past the anonymity warning
                                // via this override. Then the crisis check, then post.
                                if !trimmedText.isEmpty && containsNameOrIdentifyingInfo(trimmedText) {
                                    showNameWarning = true
                                } else if let level = crisisCheckLevelRespectingSetting(for: trimmedText) {
                                    gentleCheckLevel = level
                                    showGentleCheck = true
                                } else {
                                    postNow()
                                }
                            } label: {
                                Text("post anyway — it'll be reviewed")
                                    .font(ToskaFont.sans(13, weight: .medium))
                                    .foregroundColor(LateNightTheme.secondaryText)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(ToskaSpace.xl)
                .background(LateNightTheme.cardBackground)
                .cornerRadius(20)
                .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
                .padding(.horizontal, ToskaSpace.xl)
            }

            // MARK: - Name warning dialog
            if showNameWarning {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { showNameWarning = false }

                VStack(spacing: 16) {
                    Image(systemName: "theatermasks")
                        .font(.system(size: 32))
                        .foregroundColor(Color.toskaAccentGold)

                    Text("keep it anonymous")
                        .font(ToskaFont.serifItalic(18))
                        .foregroundColor(LateNightTheme.handleText)

                    Text("your post might include a name or identifying info.\n\neveryone here is anonymous. including the people in your story. thats what makes it safe.")
                        .font(ToskaFont.sans(12))
                        .foregroundColor(LateNightTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    VStack(spacing: 8) {
                        Button { showNameWarning = false } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "pencil").font(.system(size: 13))
                                Text("edit my post").font(ToskaFont.sans(13, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.toskaBlue)
                            .cornerRadius(12)
                        }

                        Button {
                            showNameWarning = false
                            // Posting past the name/PII warning → server holds it
                            // for review. Flag so we surface "under review" once
                            // the write lands.
                            postWillBeHeld = true
                            if let level = crisisCheckLevelRespectingSetting(for: trimmedText) {
                                gentleCheckLevel = level
                                showGentleCheck = true
                            } else {
                                postNow()
                            }
                        } label: {
                            Text("post anyway")
                                .font(ToskaFont.sans(13, weight: .medium))
                                .foregroundColor(LateNightTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(LateNightTheme.divider.opacity(0.5))
                                .cornerRadius(12)
                        }
                    }
                    .padding(.top, 4)

                    Text("try \"he\", \"she\", \"they\", or just \"you\"")
                        .font(ToskaFont.sans(11))
                        .foregroundColor(LateNightTheme.tertiaryText)
                        .padding(.top, 4)
                }
                .padding(ToskaSpace.xl)
                .background(LateNightTheme.cardBackground)
                .cornerRadius(20)
                .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
                .padding(.horizontal, ToskaSpace.xl)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
        .onChange(of: selectedTag) { _, newValue in
            // Persist tag selection alongside text draft so a kill mid-
            // compose restores both. Empty string when nil.
            draftTag = newValue ?? ""
        }
        // N-4: persist drafts to the protected DraftStore. DEBOUNCED (perf pass):
        // DraftStore.set does a synchronous atomic + complete-file-protection
        // (encrypted) disk write — doing that on every keystroke caused visible
        // typing lag on longer posts. Now we wait ~0.5s after typing stops, so a
        // burst of keystrokes collapses to a single write. An empty value writes
        // immediately (clearing the draft on send/dismiss must not be deferred).
        .onChange(of: draftText) { _, newValue in
            draftSaveTask?.cancel()
            if newValue.isEmpty {
                DraftStore.set(newValue, forKey: UserDefaultsKeys.composeDraftText)
            } else {
                draftSaveTask = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    DraftStore.set(newValue, forKey: UserDefaultsKeys.composeDraftText)
                }
            }
        }
        .onChange(of: draftTag) { _, newValue in
            DraftStore.set(newValue, forKey: UserDefaultsKeys.composeDraftTag)
        }
        // Drives the fade/scale transition on the gentle-check overlay
        // regardless of which surface (button, tap-outside, etc.) flips it.
        .animation(.easeOut(duration: 0.2), value: showGentleCheck)
        // NOTE: removed the blanket .simultaneousGesture(TapGesture) that dismissed
        // the keyboard on any tap — it fired alongside the TextEditor's own taps,
        // which suppressed the select/paste edit menu and cursor placement (paste
        // didn't work while composing). Keyboard now dismisses via drag inside the
        // editor (.scrollDismissesKeyboard above) or the cancel/post buttons.
        .onAppear {
                    HapticManager.play(.compose)
                    // N-4: load any persisted draft from the protected store
                    // (migrates + scrubs a legacy UserDefaults copy on first read)
                    // before the restore logic below reads draftText/draftTag.
                    draftText = DraftStore.get(forKey: UserDefaultsKeys.composeDraftText) ?? ""
                    draftTag = DraftStore.get(forKey: UserDefaultsKeys.composeDraftTag) ?? ""
                    loadHandle()
                    if text.isEmpty && !initialText.isEmpty {
                        text = initialText
                    } else if text.isEmpty && !draftText.isEmpty {
                        // Restore draft from a prior session that was killed
                        // before the user could post. Only when we have no
                        // initialText override (e.g. tapping "say something"
                        // from the empty feed shouldn't pre-fill an old
                        // anniversary reflection draft).
                        text = draftText
                        // The draft buffer persists text+tag but NOT isLetter. A
                        // restored draft over the normal 500 cap could only have
                        // been a letter — restore letter mode so the first
                        // keystroke doesn't truncate the body to 500 (silent data
                        // loss of up to 1500 chars).
                        if text.utf16.count > charLimit {
                            isLetter = true
                        }
                    }
                    if selectedTag == nil, let tag = initialTag {
                        selectedTag = tag
                    } else if selectedTag == nil, !draftTag.isEmpty, initialText.isEmpty {
                        // Only restore the saved tag when this isn't an
                        // initialText-seeded compose (e.g. a prompt response) —
                        // otherwise a stale tag from an abandoned draft would
                        // silently attach to an unrelated new post. Mirrors the
                        // text-restore guard above.
                        selectedTag = draftTag
                    }
                    focusTask?.cancel()
                    focusTask = Task {
                        // Short delay so the focus assignment happens after the
                        // sheet's presentation animation settles. 150ms feels
                        // snappier than the previous 300ms while still
                        // reliably bringing up the keyboard on first appear.
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard !Task.isCancelled else { return }
                        textFocused = true
                    }
                }
                .onDisappear {
                    offlineMonitorTask?.cancel()
                    offlineMonitorTask = nil
                    focusTask?.cancel()
                    focusTask = nil
                    // Flush any pending debounced draft write. A quick cancel/dismiss
                    // within the 0.5s debounce window otherwise abandoned the pending
                    // Task and dropped the last keystrokes. Idempotent with the
                    // empty-clear on a successful post (draftText is "" by then).
                    draftSaveTask?.cancel()
                    draftSaveTask = nil
                    // Same guard as the keystroke write: an edit-draft session must
                    // not flush into the new-post buffer (would resurrect on cancel).
                    if editingDraftId == nil, !draftText.isEmpty {
                        DraftStore.set(draftText, forKey: UserDefaultsKeys.composeDraftText)
                    }
                }
        .navigationDestination(isPresented: $showGifPicker) {
            GifPickerView { url in
                selectedGifUrl = url
            }
            .navigationBarHidden(true)
        }
        // Tab switches post .dismissAllSheets — without this observer, the
        // GIF picker stays visible behind the new tab.
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
            showGifPicker = false
        }
        // First-time explainer for whisper / midnight / letter (set in each
        // toggle the first time it's turned on).
        .alert(activeHint?.title ?? "", isPresented: Binding(
            get: { activeHint != nil },
            set: { if !$0 { activeHint = nil } }
        )) {
            Button("got it", role: .cancel) {}
        } message: {
            Text(activeHint?.message ?? "")
        }
        .alert("under review", isPresented: $showUnderReview) {
            Button("ok", role: .cancel) {
                if let onPostSuccess = onPostSuccess { onPostSuccess() } else { dismiss() }
            }
        } message: {
            Text("your post mentions something that needs a quick check, so it'll appear once it's approved. you can still see it on your own profile in the meantime.")
        }
        } // close NavigationStack
    }

    // MARK: - Warning Banner

    func warningBanner(icon: String, text: String, color: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(ToskaFont.sans(11))
        }
        .foregroundColor(Color(hex: color))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(hex: color).opacity(0.08))
    }

    // MARK: - Functions

    func loadHandle() {
        userHandle = UserHandleCache.shared.handle
    }

    func attemptPost() {
        guard !isPosting else { return }
        // Don't re-enter while a confirmation/warning dialog from a prior tap is
        // still on screen — `isPosting` isn't set until postNow(), so a fast
        // double-tap otherwise stacked duplicate dialogs through this gap.
        guard !showContentWarning, !showNameWarning, !showGentleCheck else { return }
        // Text is required (see canPost): a GIF-only post fails the server's
        // text.size() > 0 rule. Guard here too so the path can't be reached.
        guard !trimmedText.isEmpty else { return }
        guard NetworkMonitor.shared.isConnected else {
                    showOfflineWarning = true
                    offlineMonitorTask?.cancel()
                    offlineMonitorTask = Task {
                        while !NetworkMonitor.shared.isConnected {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            guard !Task.isCancelled else { return }
                        }
                        showOfflineWarning = false
                    }
                    return
                }

#if DEBUG
       let isUITesting = ProcessInfo.processInfo.arguments.contains("UI_TESTING")
       #else
       let isUITesting = false
       #endif
       if !isUITesting,
          let last = RateLimiter.shared.lastPostTime, Date().timeIntervalSince(last) < 30 {


            showRateLimitWarning = true
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                showRateLimitWarning = false
            }
            return
        }
        // Reset the hold flag for this attempt; the paths below set it true when
        // the post will be held for review (PII / content-violation overrides,
        // or crisis content the server holds).
        postWillBeHeld = false
        if !trimmedText.isEmpty, let violation = contentViolation(in: trimmedText) {
            contentViolationType = violation
            contentWarningMessage = contentViolationMessage(for: violation)
            showContentWarning = true
            return
        }
        if !trimmedText.isEmpty && containsNameOrIdentifyingInfo(trimmedText) { showNameWarning = true; return }
        if !trimmedText.isEmpty, let level = crisisCheckLevelRespectingSetting(for: trimmedText) {
            gentleCheckLevel = level
            showGentleCheck = true
        } else {
            // A concerning post is HELD server-side even when the gentle check-in
            // is suppressed (soft signals with the check-in setting off). Flag it
            // so the "under review" notice fires — a user in crisis shouldn't
            // believe peers can see a post the server actually hides.
            if crisisLevel(for: trimmedText) != nil { postWillBeHeld = true }
            postNow()
        }
    }

    /// Lower-severity content-violation categories get a "post anyway" override
    /// (the post is then HELD for review server-side, recoverable). Slurs,
    /// sexual, and harassment stay hard-blocked. Threat is included because its
    /// substring matches ("bomb", "blow up") false-positive on common grief
    /// phrasing ("she dropped a bomb on me"), and a real threat is still caught
    /// by the server hold + moderation.
    private var contentViolationAllowsOverride: Bool {
        switch contentViolationType {
        // Only the low-severity, FP-prone categories are user-overridable into a
        // held-for-review post. .threat is hard-blocked (edit required) like
        // slur/harassment/sexual — a threat is more severe than harassment (which
        // was already hard-blocked), and letting the user override their own
        // client-detected threat risks it shipping live if the server threat
        // classifier doesn't independently catch it.
        case .spam, .link: return true
        default: return false
        }
    }

    /// Save the current text to users/{uid}/drafts/ instead of publishing.
    /// Creates a new draft when editingDraftId is nil; otherwise updates
    /// the existing one (text + updatedAt). No rate-limit / moderation
    /// triggers fire — drafts never reach feed / explore / push paths.
    func saveAsDraft() {
        guard canSave else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        let draftsRef = db.collection("users").document(uid).collection("drafts")
        Task { @MainActor in
            do {
                if let id = editingDraftId {
                    // Update existing draft. Rules permit text + updatedAt only.
                    try await draftsRef.document(id).updateData([
                        "text": trimmedText,
                        "updatedAt": FieldValue.serverTimestamp(),
                    ])
                } else {
                    // Create a new draft with the rule's required schema.
                    try await draftsRef.addDocument(data: [
                        "text": trimmedText,
                        "createdAt": FieldValue.serverTimestamp(),
                    ])
                }
                // Clear the in-progress draft cache so the next compose-open
                // doesn't re-prompt with the same words. The persisted-to-
                // Firestore version is the canonical store now.
                draftText = ""
                draftTag = ""
                Telemetry.draftSaved(isUpdate: editingDraftId != nil)
                dismiss()
            } catch {
                print("⚠️ ComposeView.saveAsDraft failed: \(error)")
                Telemetry.recordError(error, context: "ComposeView.saveAsDraft")
                postError = "couldnt save. try again."
            }
        }
    }

    func postNow() {
        guard !isPosting else { return }
        // Network guard, mirroring attemptPost. postNow is ALSO reached directly
        // from the override/confirm paths (crisis onProceed, name "post anyway",
        // content-violation "post anyway") which skip attemptPost's guard —
        // without this, addDocument's completion never fires offline and the
        // button is stuck on "posting…" with no escape.
        guard NetworkMonitor.shared.isConnected else {
            showOfflineWarning = true
            offlineMonitorTask?.cancel()
            offlineMonitorTask = Task {
                while !NetworkMonitor.shared.isConnected {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                }
                showOfflineWarning = false
            }
            return
        }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // Start the 30s rate-limit window at attempt time, not after success.
        // Previously lastPostTime was only set on the success branch below,
        // so a failed post (network hiccup, server error) left the window
        // open and the user could hammer retry — piling up duplicate posts
        // if the previous writes were actually queued and eventually landed.
        // Matches the pattern used in PostDetailView.postReplyNow.
        RateLimiter.shared.lastPostTime = Date()
        HapticManager.play(.send)
        isPosting = true
        postError = ""
        let db = Firestore.firestore()
        // Letters and whispers are never shareable at display time (the share
        // button is hidden for them in the feed), so store isShareable=false to
        // match — otherwise the flag claimed shareable for a post that isn't.
        let allowSharing = UserHandleCache.shared.allowSharing && !isLetter && !isWhisper

        Task { @MainActor in
            guard self.isPosting else { return }

            // Resolve handle — fall back to Firestore if cache hasn't loaded yet
            let freshHandle = UserHandleCache.shared.handle
            let resolvedHandle: String
            if freshHandle == "anonymous" {
                let snap = try? await db.collection("users").document(uid).getDocumentAsync()
                resolvedHandle = snap?.data()?["handle"] as? String ?? "anonymous"
            } else {
                resolvedHandle = freshHandle
            }

            var postData: [String: Any] = [
                            "authorId": uid,
                            "authorHandle": resolvedHandle,
                            "text": trimmedText,
                            "likeCount": 0,
                            "repostCount": 0,
                            "replyCount": 0,
                            "isRepost": false,
                            "isShareable": allowSharing,
                            "createdAt": FieldValue.serverTimestamp(),
                            // Start hidden (2026-06-01 audit): invisible to
                            // feeds (which query moderationStatus == "live")
                            // and to direct reads until validatePost promotes a
                            // clean post to "live". The author still sees it
                            // immediately on their own profile.
                            "moderationStatus": "pending_validation"
                        ]
            if let tag = selectedTag { postData["tag"] = tag }
            if let gifUrl = selectedGifUrl { postData["gifUrl"] = gifUrl }
            if isLetter { postData["isLetter"] = true }
            // Daily prompt marker — set only when ComposeView was opened from
            // FeedView's prompt "respond" flow. Lets the FeedHeaderCard show
            // "your response" with edit/delete instead of "respond" once a
            // user has answered today's prompt.
            if let promptDate = promptDate { postData["promptDate"] = promptDate }
            if isWhisper && !expiresAtMidnight {
                let oneHourFromNow = Date().addingTimeInterval(3600)
                postData["expiresAt"] = Timestamp(date: oneHourFromNow)
                postData["isWhisper"] = true
            }
            if expiresAtMidnight && !isWhisper {
                let calendar = Calendar.current
                var midnight = calendar.startOfDay(for: Date())
                midnight = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight
                postData["expiresAt"] = Timestamp(date: midnight)
                postData["isMidnightPost"] = true
            }

            db.collection("posts").addDocument(data: postData) { error in
                Task { @MainActor in
                    self.isPosting = false
                    if let error = error {
                        Telemetry.recordError(error, context: "ComposeView.addPost")
                        let nsError = error as NSError
                        // permission-denied on first post usually means
                        // hasConfirmedAdult() rejected the write because the
                        // confirmAdult Cloud Function call from the iOS age
                        // gate hadn't landed (network blip / App Check token
                        // race during signup). Kick off a retry of that call
                        // and surface a specific error so the user knows the
                        // retry is meaningful, not a blind retry of the same
                        // failing operation. On the next post-tap, hasConfirmedAdult()
                        // should pass.
                        if nsError.domain == "FIRFirestoreErrorDomain", nsError.code == 7 {
                            Task.detached {
                                try? await confirmAdultServerSide(uid: uid)
                            }
                            self.postError = "still setting up your account — try again in a moment"
                        } else {
                            self.postError = "couldnt post. try again. the feeling isnt going anywhere."
                        }
                        // Confirmed failure → shorten the rate-limit window
                        // so retry waits ~5s instead of the full 30s. The
                        // postError banner explicitly says "try again";
                        // making the user wait 30 seconds while staring at
                        // that message is contradictory UX. We don't clear
                        // lastPostTime entirely because the Firestore SDK's
                        // offline queue may still eventually deliver the
                        // write, and an instantly-retryable button leads to
                        // duplicate posts when both eventually land. 5s is
                        // long enough to discourage frantic mashing,
                        // short enough not to feel punitive.
                        RateLimiter.shared.lastPostTime = Date().addingTimeInterval(-25)
                    } else {
                        Telemetry.postCreated(
                            tag: self.selectedTag,
                            isLetter: self.isLetter,
                            isWhisper: self.isWhisper,
                            hasGif: self.selectedGifUrl != nil
                        )
                        // Post landed on the server — drop the draft so the
                        // next compose opens clean.
                        self.draftText = ""
                        self.draftTag = ""
                        // If we were editing an existing saved draft and the
                        // user chose to publish (rather than update), delete
                        // the draft so they don't end up with a stranded
                        // draft + the published post. Best-effort — failure
                        // here doesn't roll back the post since the post
                        // has already landed; worst case the user sees the
                        // draft still in their list and can delete it
                        // manually from DraftsView.
                        if let id = self.editingDraftId {
                            let draftRef = Firestore.firestore()
                                .collection("users").document(uid)
                                .collection("drafts").document(id)
                            // Fire-and-forget via inner Task so the success
                            // path returns immediately. Async variant of
                            // DocumentReference.delete silences the Swift 6
                            // "consider asynchronous alternative" warning.
                            Task {
                                do {
                                    try await draftRef.delete()
                                } catch {
                                    print("⚠️ ComposeView post-success draft delete failed: \(error)")
                                }
                            }
                        }
                        NotificationCenter.default.post(name: .newPostCreated, object: nil)
                        if self.postWillBeHeld {
                            // Held for review — tell the user before leaving the
                            // composer. The alert's "ok" completes the dismiss.
                            self.postWillBeHeld = false
                            self.showUnderReview = true
                        } else if let onPostSuccess = self.onPostSuccess {
                            onPostSuccess()
                        } else {
                            self.dismiss()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Stable GIF Preview
//
// Custom replacement for SwiftUI's AsyncImage. AsyncImage cancels the
// URLSession task with NSURLError -999 whenever its parent's body recomputes
// (constant in ComposeView and PostDetailView), so the load never completes.
// This view owns the GIF data in @State so it survives parent recomputes,
// and renders via AnimatedGifImageView (UIKit-backed) so animated GIFs
// actually animate — SwiftUI's Image(uiImage:) doesn't animate frames even
// when given UIImage.animatedImage(with:duration:).
@MainActor
struct StableGifPreview: View {
    let urlString: String
    var maxHeight: CGFloat = 180
    @State private var data: Data? = nil
    @State private var failed = false

    var body: some View {
        Group {
            if let data = data {
                AnimatedGifImageView(data: data)
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .cornerRadius(10)
                    .transition(.opacity)
            } else if failed {
                LateNightTheme.inputBackground
                    .frame(height: 120)
                    .cornerRadius(10)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 16, weight: .light))
                            Text("couldn't load — pick another?")
                                .font(ToskaFont.sans(11))
                        }
                        .foregroundColor(LateNightTheme.tertiaryText)
                    )
            } else {
                LateNightTheme.inputBackground
                    .frame(height: 120)
                    .cornerRadius(10)
                    .overlay(ProgressView().scaleEffect(0.7).tint(LateNightTheme.tertiaryText))
            }
        }
        .task(id: urlString) {
            guard let url = URL(string: urlString),
                  GifLoadGuard.isAllowedHost(url) else {
                // Unknown/hostile host (a post's gifUrl is attacker-controlled).
                // Don't download arbitrary URLs — show the failed placeholder.
                failed = true
                return
            }
            failed = false
            do {
                let (downloaded, _) = try await URLSession.shared.data(from: url)
                guard downloaded.count <= GifLoadGuard.maxBytes else {
                    // Oversized payload — abort before decoding to avoid OOM.
                    failed = true
                    return
                }
                withAnimation(.easeIn(duration: 0.2)) { data = downloaded }
            } catch is CancellationError {
                // URL changed or view torn down — don't flip to failed.
            } catch {
                failed = true
            }
        }
    }
}

// Shared defenses for rendering attacker-controlled gifUrl values stored on
// posts/replies. Giphy is the only legitimate source (URLs are picked via
// GifPickerView -> giphyProxy), so we host-allowlist and cap payload/frames
// to keep a hostile post from OOM-crashing viewers.
enum GifLoadGuard {
    // Cap downloaded GIF bytes before decoding (Giphy fixed_width ~700KB,
    // original ~2.5MB; 8MB leaves generous headroom for legit content).
    static let maxBytes = 8 * 1024 * 1024
    // Cap decoded frames so a many-frame GIF can't blow memory.
    static let maxFrames = 120

    static func isAllowedHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        // Matches giphy.com, media.giphy.com, media0.giphy.com, etc.
        return host == "giphy.com" || host.hasSuffix(".giphy.com")
    }
}

// UIImageView-backed view that decodes all frames of an animated GIF via
// ImageIO and lets UIImageView animate them. SwiftUI's Image doesn't iterate
// animatedImage frames, so we have to drop down to UIKit. Single-frame
// images (PNG/JPG or 1-frame GIFs) fall back to a static UIImage.
private struct AnimatedGifImageView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.clipsToBounds = true
        // Don't fight the SwiftUI frame — let the parent maxHeight decide.
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if let animated = Self.animatedImage(from: data) {
            uiView.image = animated
            uiView.startAnimating()
        } else if let still = UIImage(data: data) {
            uiView.image = still
        }
    }

    static func animatedImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }

        // Cap decoded frames so a hostile many-frame GIF can't OOM the viewer.
        let frameCount = min(count, GifLoadGuard.maxFrames)
        var frames: [UIImage] = []
        var totalDuration: Double = 0
        for i in 0..<frameCount {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            totalDuration += frameDelay(at: i, source: source)
        }
        guard !frames.isEmpty else { return nil }
        // UIImageView automatically animates an animatedImage with the given
        // duration once startAnimating() is called.
        return UIImage.animatedImage(with: frames, duration: totalDuration)
    }

    static func frameDelay(at index: Int, source: CGImageSource) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProps = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        // Prefer unclamped delay (true source value); fall back to clamped
        // (browsers historically floor very-low delays around 10ms).
        if let unclamped = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
            return unclamped
        }
        if let clamped = gifProps[kCGImagePropertyGIFDelayTime] as? Double, clamped > 0 {
            return clamped
        }
        return 0.1
    }
}
