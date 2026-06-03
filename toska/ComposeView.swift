import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import ImageIO
import UIKit

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
    // Draft persistence keys. AppStorage survives force-quit so a user mid-
    // compose doesn't lose their words if iOS terminates the app or they
    // accidentally swipe it away. Cleared on successful post.
    @AppStorage(UserDefaultsKeys.composeDraftText) private var draftText: String = ""
    @AppStorage(UserDefaultsKeys.composeDraftTag) private var draftTag: String = ""
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
    /// Disabled when offline so the user gets visible feedback instead of
    /// the silent Firestore-offline-queue behavior. The offline banner
    /// already explains the state; the inert button reinforces it.
    var canPost: Bool {
        (!trimmedText.isEmpty || selectedGifUrl != nil)
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
            LateNightTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: - Top bar
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Text("cancel")
                            .font(.system(size: 14))
                            .foregroundColor(LateNightTheme.secondaryText)
                    }

                    Spacer()

                    // Save-as-draft. Soft secondary-styled button so the
                    // primary "post" still reads as the default action.
                    // Wording shifts to "update" when editing an existing
                    // draft so the user knows whether they're creating
                    // a new entry or revising the open one.
                    Button { saveAsDraft() } label: {
                        Text(editingDraftId == nil ? "save" : "update")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(canSave ? ToskaColor.text : ToskaColor.text3)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.clear)
                            .overlay(
                                Capsule().stroke(ToskaColor.divider, lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                    .disabled(!canSave)
                    .accessibilityLabel(editingDraftId == nil ? "Save as draft" : "Update draft")

                    Button { attemptPost() } label: {
                        Text(isPosting ? "posting..." : "post")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(canPost ? .white : ToskaColor.text2)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(canPost ? ToskaColor.accent : ToskaColor.input)
                            .clipShape(Capsule())
                    }
                    .disabled(!canPost)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // MARK: - Toolbar (formerly at the bottom; moved to sit right
                // under the cancel/save/post header so the modifiers are
                // within easy reach without scrolling past the text editor).
                Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)

                HStack(spacing: 20) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showTagPicker.toggle() }
                    } label: {
                        Image(systemName: showTagPicker ? "tag.fill" : "tag")
                            .font(.system(size: 16, weight: .light))
                            .foregroundColor(showTagPicker ? ToskaColor.accent : ToskaColor.text2)
                    }
                    .accessibilityLabel("Tag")

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isWhisper.toggle()
                            if isWhisper { expiresAtMidnight = false }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: isWhisper ? "eye.slash.fill" : "eye.slash")
                                .font(.system(size: 13, weight: .light))
                            if isWhisper {
                                Text("1hr")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .foregroundColor(isWhisper ? Color(hex: "c47a8a") : LateNightTheme.secondaryText)
                    }
                    .accessibilityLabel(isWhisper ? "Whisper on, disappears in 1 hour" : "Whisper")

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expiresAtMidnight.toggle()
                            if expiresAtMidnight { isWhisper = false }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: expiresAtMidnight ? "moon.fill" : "moon")
                                .font(.system(size: 13, weight: .light))
                            if expiresAtMidnight {
                                Text("midnight")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .foregroundColor(expiresAtMidnight ? Color(hex: "8b7ec8") : LateNightTheme.secondaryText)
                    }
                    .accessibilityLabel(expiresAtMidnight ? "Midnight post on, disappears at midnight" : "Midnight post")

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isLetter.toggle() }
                    } label: {
                        Image(systemName: isLetter ? "envelope.open.fill" : "envelope")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(isLetter ? Color(hex: "c9a97a") : LateNightTheme.secondaryText)
                    }
                    .accessibilityLabel(isLetter ? "Letter mode on" : "Letter mode")

                    Button { showGifPicker = true } label: {
                        Text("GIF")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(selectedGifUrl != nil ? ToskaColor.accent : ToskaColor.text2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(selectedGifUrl != nil ? ToskaColor.accent : ToskaColor.divider, lineWidth: 1)
                            )
                    }
                    .accessibilityLabel("Add GIF")

                    Spacer()

                    if text.count > 0 {
                        HStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .stroke(LateNightTheme.divider, lineWidth: 2)
                                    .frame(width: 24, height: 24)
                                Circle()
                                    .trim(from: 0, to: CGFloat(effectiveCharCount) / CGFloat(activeCharLimit))
                                    .stroke(
                                        isNearLimit ? Color(hex: "c45c5c") : ToskaColor.accent,
                                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                                    )
                                    .frame(width: 24, height: 24)
                                    .rotationEffect(.degrees(-90))
                            }
                            if isNearLimit {
                                Text("\(charRemaining)")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(charRemaining < 0 ? Color(hex: "c45c5c") : LateNightTheme.secondaryText)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(LateNightTheme.cardBackground)

                // Tag picker expansion now drops DOWN from the toolbar above
                // (was originally pinned to the bottom toolbar with a
                // .move(edge: .bottom) transition).
                if showTagPicker {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("how does this feel")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(LateNightTheme.secondaryText)
                            .tracking(0.5)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(tags, id: \.name) { tag in
                                    Button {
                                        selectedTag = tag.name
                                        withAnimation(.easeOut(duration: 0.2)) { showTagPicker = false }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: tag.icon)
                                                .font(.system(size: 10))
                                            Text(tag.name)
                                                .font(.system(size: 11, weight: .medium))
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
                        .padding(.bottom, 10)
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
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10))
                        Text("dont have to share it. tap save and it stays just for you.")
                            .font(.system(size: 11))
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
                                    // force-quit doesn't lose the user's
                                    // words. Cleared when the post succeeds.
                                    draftText = newValue
                                }
                            // Char counter — shows remaining chars as the user
                            // types, switches to a soft warning color at <100
                            // remaining so the boundary doesn't surprise them.
                            // utf16.count matches the Firestore rule's size()
                            // check + the onChange truncation above.
                            HStack {
                                Spacer()
                                Text("\(activeCharLimit - text.utf16.count)")
                                    .font(.system(size: 10, weight: .light, design: .monospaced))
                                    .foregroundColor(
                                        text.utf16.count >= activeCharLimit
                                            ? Color(hex: "c45c5c")
                                            : (activeCharLimit - text.utf16.count < 100
                                                ? Color(hex: "c47a8a")
                                                : Color.toskaDivider)
                                    )
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 2)
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
                                .offset(x: -6, y: 6)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                        }

                        // Selected tag pill
                        if let tag = selectedTag {
                            HStack(spacing: 6) {
                                let tagData = tags.first(where: { $0.name == tag })
                                Image(systemName: tagData?.icon ?? "tag")
                                    .font(.system(size: 10))
                                Text(tag)
                                    .font(.system(size: 11, weight: .medium))
                                Button { withAnimation { selectedTag = nil } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(hex: tagData?.colorHex ?? "9198a8").opacity(0.4))
                                }
                            }
                            .foregroundColor(Color(hex: tags.first(where: { $0.name == tag })?.colorHex ?? "9198a8"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(hex: tags.first(where: { $0.name == tag })?.colorHex ?? "9198a8").opacity(0.08))
                            .cornerRadius(16)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                        }
                    }
                }

                // Letter mode banner
                if isLetter {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope.open")
                            .font(.system(size: 11))
                        Text("writing a letter · up to 2,000 characters")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button { isLetter = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Color(hex: "c9a97a").opacity(0.5))
                        }
                    }
                    .foregroundColor(Color(hex: "c9a97a"))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(hex: "c9a97a").opacity(0.06))
                }

                // Whisper mode banner
                if isWhisper {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 11))
                        Text("whisper · disappears in 1 hour")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button { isWhisper = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Color(hex: "c47a8a").opacity(0.5))
                        }
                    }
                    .foregroundColor(Color(hex: "c47a8a"))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(hex: "c47a8a").opacity(0.06))
                }

                // Midnight mode banner
                if expiresAtMidnight {
                    HStack(spacing: 6) {
                        Image(systemName: "moon.stars")
                            .font(.system(size: 11))
                        Text("this post disappears at midnight")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button { expiresAtMidnight = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Color(hex: "8b7ec8").opacity(0.5))
                        }
                    }
                    .foregroundColor(Color(hex: "8b7ec8"))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(hex: "8b7ec8").opacity(0.06))
                }

            }

            // MARK: - Gentle check dialog
            if showGentleCheck {
                CrisisCheckInView(
                    isPresented: $showGentleCheck,
                    level: gentleCheckLevel,
                    onProceed: { postNow() }
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
                        .foregroundColor(Color(hex: "c45c5c"))

                    Text("hold on")
                        .font(ToskaFont.serifItalic(18))
                        .foregroundColor(LateNightTheme.handleText)

                    Text(contentWarningMessage)
                        .font(.system(size: 12))
                        .foregroundColor(LateNightTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    Button { showContentWarning = false } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "pencil").font(.system(size: 13))
                            Text("edit my post").font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.toskaBlue)
                        .cornerRadius(12)
                    }
                    .padding(.top, 4)
                }
                .padding(28)
                .background(LateNightTheme.cardBackground)
                .cornerRadius(20)
                .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
                .padding(.horizontal, 28)
            }

            // MARK: - Name warning dialog
            if showNameWarning {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { showNameWarning = false }

                VStack(spacing: 16) {
                    Image(systemName: "theatermasks")
                        .font(.system(size: 32))
                        .foregroundColor(Color(hex: "c9a97a"))

                    Text("keep it anonymous")
                        .font(ToskaFont.serifItalic(18))
                        .foregroundColor(LateNightTheme.handleText)

                    Text("your post might include a name or identifying info.\n\neveryone here is anonymous. including the people in your story. thats what makes it safe.")
                        .font(.system(size: 12))
                        .foregroundColor(LateNightTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    VStack(spacing: 8) {
                        Button { showNameWarning = false } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "pencil").font(.system(size: 13))
                                Text("edit my post").font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.toskaBlue)
                            .cornerRadius(12)
                        }

                        Button {
                            showNameWarning = false
                            if let level = crisisCheckLevelRespectingSetting(for: text) {
                                gentleCheckLevel = level
                                showGentleCheck = true
                            } else {
                                postNow()
                            }
                        } label: {
                            Text("post anyway")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(LateNightTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(LateNightTheme.divider.opacity(0.5))
                                .cornerRadius(12)
                        }
                    }
                    .padding(.top, 4)

                    Text("try \"he\", \"she\", \"they\", or just \"you\"")
                        .font(.system(size: 9))
                        .foregroundColor(LateNightTheme.tertiaryText)
                        .padding(.top, 2)
                }
                .padding(28)
                .background(LateNightTheme.cardBackground)
                .cornerRadius(20)
                .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
                .padding(.horizontal, 28)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
        .onChange(of: selectedTag) { _, newValue in
            // Persist tag selection alongside text draft so a kill mid-
            // compose restores both. Empty string when nil since
            // @AppStorage doesn't accept Optional<String>.
            draftTag = newValue ?? ""
        }
        // Drives the fade/scale transition on the gentle-check overlay
        // regardless of which surface (button, tap-outside, etc.) flips it.
        .animation(.easeOut(duration: 0.2), value: showGentleCheck)
        .simultaneousGesture(
            TapGesture().onEnded {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        )
        .onAppear {
                    HapticManager.play(.compose)
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
                    }
                    if selectedTag == nil, let tag = initialTag {
                        selectedTag = tag
                    } else if selectedTag == nil, !draftTag.isEmpty {
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
        } // close NavigationStack
    }

    // MARK: - Warning Banner

    func warningBanner(icon: String, text: String, color: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11))
        }
        .foregroundColor(Color(hex: color))
        .padding(.horizontal, 18)
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
        guard (!trimmedText.isEmpty || selectedGifUrl != nil) else { return }
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
        if !trimmedText.isEmpty, let violation = contentViolation(in: trimmedText) {
            contentWarningMessage = contentViolationMessage(for: violation)
            showContentWarning = true
            return
        }
        if !trimmedText.isEmpty && containsNameOrIdentifyingInfo(trimmedText) { showNameWarning = true; return }
        if !trimmedText.isEmpty, let level = crisisCheckLevelRespectingSetting(for: trimmedText) {
            gentleCheckLevel = level
            showGentleCheck = true
        } else {
            postNow()
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
        let allowSharing = UserHandleCache.shared.allowSharing

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
                        if let onPostSuccess = self.onPostSuccess {
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
                                .font(.system(size: 10))
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
            guard let url = URL(string: urlString) else {
                failed = true
                return
            }
            failed = false
            do {
                let (downloaded, _) = try await URLSession.shared.data(from: url)
                withAnimation(.easeIn(duration: 0.2)) { data = downloaded }
            } catch is CancellationError {
                // URL changed or view torn down — don't flip to failed.
            } catch {
                failed = true
            }
        }
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

        var frames: [UIImage] = []
        var totalDuration: Double = 0
        for i in 0..<count {
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
