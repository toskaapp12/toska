import SwiftUI
import FirebaseAuth
import FirebaseFirestore

@MainActor
struct ComposeView: View {
    @Environment(\.dismiss) var dismiss
    var initialText: String = ""
    var initialTag: String? = nil
    var onPostSuccess: (() -> Void)? = nil
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

    var composePlaceholder: String {
            if isLetter { return "dear you..." }
            if isWhisper { return "say it quietly..." }
            let tod = timeOfDayLabel()
            if tod == "tonight" { return "whats keeping you up..." }
            else if tod == "this morning" { return "how did you sleep..." }
            else if tod == "this afternoon" { return "say the thing you cant say out loud..." }
            else { return "how are you. honestly..." }
        }

    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: - Top bar
                HStack {
                    Button { dismiss() } label: {
                        Text("cancel")
                            .font(.system(size: 14))
                            .foregroundColor(LateNightTheme.secondaryText)
                    }

                    Spacer()

                    Button { attemptPost() } label: {
                        Text(isPosting ? "posting..." : "post")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(canPost ? Color.toskaBlue : Color.toskaBlue.opacity(0.4))
                            .clipShape(Capsule())
                    }
                    .disabled(!canPost)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

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

                Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)

                // MARK: - Compose area
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer().frame(height: 8)

                        // Text input
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(composePlaceholder)
                                    .font(.custom("Georgia", size: 18))
                                    .foregroundColor(LateNightTheme.isLateNight ? Color(hex: "3a3835") : Color(hex: "c0c3ca"))
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                            }

                            TextEditor(text: $text)
                                                            .font(.custom("Georgia", size: 18))
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
                        }

                        // Selected GIF preview
                        if let gifUrl = selectedGifUrl {
                            ZStack(alignment: .topTrailing) {
                                AsyncImage(url: URL(string: gifUrl), transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(maxHeight: 180)
                                            .cornerRadius(10)
                                            .transition(.opacity)
                                    case .failure:
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
                                    default:
                                        LateNightTheme.inputBackground
                                            .frame(height: 120)
                                            .cornerRadius(10)
                                            .overlay(ProgressView().scaleEffect(0.7).tint(LateNightTheme.tertiaryText))
                                    }
                                }

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

                // MARK: - Tag picker (expandable)
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // MARK: - Bottom toolbar
                Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)

                HStack(spacing: 20) {
                    // Tag button
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.2)) { showTagPicker.toggle() }
                                        } label: {
                                            Image(systemName: showTagPicker ? "tag.fill" : "tag")
                                                .font(.system(size: 16, weight: .light))
                                                .foregroundColor(showTagPicker ? Color.toskaBlue : LateNightTheme.secondaryText)
                                        }
                                        .accessibilityLabel("Tag")

                    // Whisper toggle (1 hour)
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

                    // Midnight toggle
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

                    // Letter mode toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isLetter.toggle() }
                    } label: {
                        Image(systemName: isLetter ? "envelope.open.fill" : "envelope")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(isLetter ? Color(hex: "c9a97a") : LateNightTheme.secondaryText)
                                                }
                                                .accessibilityLabel(isLetter ? "Letter mode on" : "Letter mode")

                    // GIF button
                                        Button { showGifPicker = true } label: {
                                            Text("GIF")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(selectedGifUrl != nil ? Color.toskaBlue : LateNightTheme.secondaryText)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .stroke(selectedGifUrl != nil ? Color.toskaBlue : LateNightTheme.tertiaryText, lineWidth: 1)
                                                )
                                        }
                                        .accessibilityLabel("Add GIF")

                    Spacer()

                    // Character counter
                    if text.count > 0 {
                        HStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .stroke(LateNightTheme.divider, lineWidth: 2)
                                    .frame(width: 24, height: 24)
                                Circle()
                                    .trim(from: 0, to: CGFloat(effectiveCharCount) / CGFloat(activeCharLimit))
                                    .stroke(
                                        isNearLimit ? Color(hex: "c45c5c") : Color.toskaBlue,
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
                        .font(.custom("Georgia-Italic", size: 18))
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
                        .font(.custom("Georgia-Italic", size: 18))
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
        .sheet(isPresented: $showGifPicker) {
            GifPickerView { url in
                selectedGifUrl = url
            }
            .presentationDetents([.medium, .large])
        }
        // Tab switches post .dismissAllSheets — without this observer, the
        // GIF picker sheet stays visible behind the new tab.
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
            showGifPicker = false
        }
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
        if !trimmedText.isEmpty, let violation = contentViolation(in: text) {
            contentWarningMessage = contentViolationMessage(for: violation)
            showContentWarning = true
            return
        }
        if !trimmedText.isEmpty && containsNameOrIdentifyingInfo(text) { showNameWarning = true; return }
        if !trimmedText.isEmpty, let level = crisisCheckLevelRespectingSetting(for: text) {
            gentleCheckLevel = level
            showGentleCheck = true
        } else {
            postNow()
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
                            "createdAt": FieldValue.serverTimestamp()
                        ]
            if let tag = selectedTag { postData["tag"] = tag }
            if let gifUrl = selectedGifUrl { postData["gifUrl"] = gifUrl }
            if isLetter { postData["isLetter"] = true }
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
                        self.postError = "couldnt post. try again. the feeling isnt going anywhere."
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
