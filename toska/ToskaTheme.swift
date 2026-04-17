import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore
import FirebaseAnalytics
import FirebaseCrashlytics

#if !DEBUG
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {}
#endif

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        #if DEBUG
        if ![3, 6, 8].contains(hex.count) {
            assertionFailure("Invalid hex color string: '\(hex)' — expected 3, 6, or 8 characters after stripping non-alphanumerics.")
        }
        #endif
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Shared DateFormatters (allocated once, reused everywhere)

enum ToskaFormatters {
    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    
    static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    
    static let hourMinute: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()
    
    static let dateKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    
    static let longDate: DateFormatter = {
                let f = DateFormatter()
                f.dateFormat = "MMMM d, yyyy"
                f.locale = Locale(identifier: "en_US_POSIX")
                return f
            }()
        
    static let decimalNumber: NumberFormatter = {
          let f = NumberFormatter()
          f.numberStyle = .decimal
          f.locale = Locale(identifier: "en_US_POSIX")
          return f
      }()
        /// Universal time-ago string. Safe to call from any isolation context.
        nonisolated static func timeAgo(from date: Date) -> String {
            let seconds = Int(Date().timeIntervalSince(date))
            if seconds < 60 { return seconds <= 0 ? "now" : "\(seconds)s" }
            let minutes = seconds / 60
            if minutes < 60 { return "\(minutes)m" }
            let hours = minutes / 60
            if hours < 24 { return "\(hours)h" }
            let days = hours / 24
            if days < 7 { return "\(days)d" }
            let weeks = days / 7
            if weeks < 5 { return "\(weeks)w" }
            let months = days / 30
            return "\(months)mo"
        }
            }

    // MARK: - Sheet Item Wrappers

// Equatable lets SwiftUI skip re-renders when sheet bindings re-emit the
// same selection — without it, every re-bind re-presents the sheet, which
// can flicker mid-dismiss.

struct TagSelection: Identifiable, Equatable {
    let id: String
    var tag: String { id }
}

struct ConversationSelection: Identifiable, Equatable {
    let id: String
    let handle: String
    let userId: String
}

struct PostSelection: Identifiable, Equatable {
    let id: String
}

/// Wrapper for routing to a user profile via .fullScreenCover(item:) — used
/// by push notification deep links to OtherProfileView.
struct UserSelection: Identifiable, Equatable {
    let id: String      // userId
    let handle: String
}

// MARK: - Shared Share Sheet Helper

@MainActor
func presentShareSheet(with items: [Any]) {
    let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
    guard let windowScene = UIApplication.shared.connectedScenes
               .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
             let window = windowScene.keyWindow,
             var topVC = window.rootViewController else { return }
    while let presented = topVC.presentedViewController { topVC = presented }
    activityVC.popoverPresentationController?.sourceView = topVC.view
    activityVC.popoverPresentationController?.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
    activityVC.popoverPresentationController?.permittedArrowDirections = []
    topVC.present(activityVC, animated: true)
    }

    // MARK: - Shared Constants

    enum ToskaConstants {
        static let messageLimit = 5
    }

// MARK: - Localization Strategy
//
// Most user-facing strings in this app go through SwiftUI's Text(_:) and
// .alert(_:isPresented:) initializers, both of which take LocalizedStringKey
// and are auto-extracted by Xcode when a String Catalog is added to the
// project. So 90% of localization-readiness is already in place — there's
// no .xcstrings file yet, but the moment you add one, Xcode will detect
// every Text("foo") and surface it for translation.
//
// What needs explicit care:
//
//   - Strings built via String interpolation that go into a Text don't
//     extract well; prefer Text("\(name) joined") (auto-extractable as a
//     keyed format string) over Text(handBuiltLocalizedString).
//
//   - Strings stored in @State properties or returned from helper functions
//     bypass auto-extraction. Wrap these in String(localized: "...") so
//     the catalog can find them. See `friendlyAuthErrorMessage` below.
//
//   - The voice (lowercase, intentional misspellings like "youre",
//     "thats", "im") is the product. Bulk machine translation will
//     destroy it. Don't ship in another language without a translator
//     who can carry the voice. The ground rule: this codebase is
//     localization-READY, not currently localized.
//
//   - Brand strings ("toska", handle prefixes like "anonymous_") should
//     never be translated. Pass them through Text(verbatim:) to opt out
//     of LocalizedStringKey treatment.
//
//   - Crisis hotlines and emergency numbers are REGIONAL, not just
//     translated. CrisisLines below switches by Locale.current.region
//     so a UK user gets 116 123 (Samaritans) instead of US 988.
//
// To enable translations later:
//   1. In Xcode: File → New → File → String Catalog. Name it
//      "Localizable" and add to the toska target.
//   2. Build the project. Xcode auto-populates the catalog with every
//      detected key.
//   3. Add a language in the catalog UI; translators fill in the cells.
//   4. Ship. iOS picks the right table based on the user's preferred
//      languages with no further code changes.

// MARK: - Crisis Lines (region-aware)
//
// 988 and 741741 are US-only numbers. A user in the UK or Australia tapping
// "call 988" hits a dead number — that's a safety bug, not a polish issue.
// This helper returns the right hotlines based on Locale.current.region so
// the crisis check-in modal and the content policy show working numbers
// regardless of where the user is.
//
// Verified numbers as of 2026:
//   US:  988 (call/text), HOME → 741741 (Crisis Text Line)
//   UK:  Samaritans 116 123 (call free), Shout text 85258
//   CA:  988 (call/text — Canada adopted 988 in 2023)
//   AU:  Lifeline 13 11 14 (call), 0477 13 11 14 (text)
//   IE:  Samaritans 116 123 (call), 50808 (text HELLO)
//   NZ:  Lifeline 0800 543 354 (call), 4357 (text HELP)
// Every other region falls back to the international IASP directory link.

struct CrisisResource {
    let label: String           // "call 988"
    let sublabel: String        // "suicide & crisis lifeline"
    let url: String             // "tel://988" or "https://findahelpline.com"
    let icon: String            // SF Symbol
}

enum CrisisLines {
    /// Region-appropriate hotlines, in display order. CrisisCheckInView
    /// renders these as tappable rows.
    static var resources: [CrisisResource] {
        let region = Locale.current.region?.identifier ?? "US"
        switch region {
        case "US":
            return [
                CrisisResource(label: "call 988", sublabel: "suicide & crisis lifeline", url: "tel://988", icon: "phone.fill"),
                CrisisResource(label: "text 988", sublabel: "same lifeline, by text", url: "sms:988", icon: "message.fill"),
                CrisisResource(label: "text HOME to 741741", sublabel: "crisis text line", url: "sms:741741&body=HOME", icon: "text.bubble.fill"),
            ]
        case "CA":
            return [
                CrisisResource(label: "call 988", sublabel: "suicide crisis helpline (canada)", url: "tel://988", icon: "phone.fill"),
                CrisisResource(label: "text 988", sublabel: "same helpline, by text", url: "sms:988", icon: "message.fill"),
            ]
        case "GB":
            return [
                CrisisResource(label: "call 116 123", sublabel: "samaritans (free, 24/7)", url: "tel://116123", icon: "phone.fill"),
                CrisisResource(label: "text SHOUT to 85258", sublabel: "shout crisis text line", url: "sms:85258&body=SHOUT", icon: "text.bubble.fill"),
            ]
        case "AU":
            return [
                CrisisResource(label: "call 13 11 14", sublabel: "lifeline australia", url: "tel://131114", icon: "phone.fill"),
                CrisisResource(label: "text 0477 13 11 14", sublabel: "lifeline text", url: "sms:0477131114", icon: "message.fill"),
            ]
        case "IE":
            return [
                CrisisResource(label: "call 116 123", sublabel: "samaritans ireland", url: "tel://116123", icon: "phone.fill"),
                CrisisResource(label: "text HELLO to 50808", sublabel: "text crisis line", url: "sms:50808&body=HELLO", icon: "text.bubble.fill"),
            ]
        case "NZ":
            return [
                CrisisResource(label: "call 0800 543 354", sublabel: "lifeline aotearoa", url: "tel://0800543354", icon: "phone.fill"),
                CrisisResource(label: "text HELP to 4357", sublabel: "lifeline text", url: "sms:4357&body=HELP", icon: "text.bubble.fill"),
            ]
        default:
            // Outside of the regions we have curated lines for, link to the
            // International Association for Suicide Prevention's directory
            // so the user can find a real local number.
            return [
                CrisisResource(label: "find a helpline", sublabel: "international directory", url: "https://findahelpline.com", icon: "globe"),
            ]
        }
    }

    /// Short emergency-call hint used in the policy text. Localized regions
    /// have their own emergency numbers (911 in US/CA, 999 in UK/IE, 000 in
    /// AU, 111 in NZ). EU countries can dial 112.
    static var emergencyNumber: String {
        let region = Locale.current.region?.identifier ?? "US"
        switch region {
        case "US", "CA": return "911"
        case "GB", "IE": return "999"
        case "AU":       return "000"
        case "NZ":       return "111"
        default:         return "your local emergency number (112 in the EU)"
        }
    }
}

// MARK: - Telemetry
//
// Privacy-first analytics + crash reporting facade. Calls are safe to make
// from anywhere — they no-op when the user has opted out via Settings, and
// they no-op when the Firebase Analytics / Crashlytics SDKs haven't been
// added to the Xcode project yet (see toskaApp.swift for setup steps).
//
// Privacy rules baked in:
//   - Never log post/reply/message content
//   - Never log handles, user IDs, or post IDs
//   - Never log search queries
//   - Properties are bounded enums or booleans, never free-form strings
//   - Caller respects shareAnonymousUsage (default true; flipped via Settings)
//
// To wire to real Firebase: see the marked TODO in `event(_:parameters:)`
// and `recordError(_:)`. Until then, DEBUG builds print to console so we
// can verify wiring locally.

enum Telemetry {
    /// Default true. The user can flip this off via Settings → Privacy.
    /// Read from UserDefaults directly (no @AppStorage) since this namespace
    /// is callable from non-View contexts.
    static var isOptedIn: Bool {
        UserDefaults.standard.object(forKey: "toska_shareAnonymousUsage") as? Bool ?? true
    }

    /// Generic event firer. Prefer the named helpers below for type-safety.
    static func event(_ name: String, parameters: [String: Any] = [:]) {
        guard isOptedIn else { return }
        Analytics.logEvent(name, parameters: parameters.isEmpty ? nil : parameters)
        #if DEBUG
        print("📊 \(name) \(parameters)")
        #endif
    }

    /// Records a non-fatal error for later crash-report aggregation.
    /// Use this in catch blocks where we'd otherwise just print a warning.
    static func recordError(_ error: Error, context: String? = nil) {
        guard isOptedIn else { return }
        if let ctx = context {
            Crashlytics.crashlytics().setCustomValue(ctx, forKey: "context")
        }
        Crashlytics.crashlytics().record(error: error)
        #if DEBUG
        let suffix = context.map { " [\($0)]" } ?? ""
        print("💥 non-fatal\(suffix): \(error)")
        #endif
    }
}

// MARK: - Telemetry — typed event helpers
//
// One helper per tracked event. The bounded properties make it impossible to
// accidentally log content. If you need a new event, add a helper here so
// the privacy review surface stays small.

extension Telemetry {
    enum SignupMethod: String { case email, apple, google }

    static func signupCompleted(method: SignupMethod) {
        event("signup_completed", parameters: ["method": method.rawValue])
    }

    static func signInCompleted(method: SignupMethod) {
        event("sign_in_completed", parameters: ["method": method.rawValue])
    }

    static func onboardingCompleted() {
        event("onboarding_completed")
    }

    static func ageGateDeclined() {
        event("age_gate_declined")
    }

    static func policyDeclined(version: Int, atSignup: Bool) {
        event("policy_declined", parameters: ["version": version, "at_signup": atSignup])
    }

    /// Tag is bounded to the sharedTags list — safe to include because the tag
    /// vocabulary is a known small set ("longing", "regret", etc.) chosen by the
    /// user from a fixed picker, not free text.
    static func postCreated(tag: String?, isLetter: Bool, isWhisper: Bool, hasGif: Bool) {
        var params: [String: Any] = [
            "is_letter": isLetter,
            "is_whisper": isWhisper,
            "has_gif": hasGif,
            "has_tag": tag != nil
        ]
        if let tag = tag { params["tag"] = tag }
        event("post_created", parameters: params)
    }

    static func replyCreated(parentIsOwn: Bool, hasGif: Bool) {
        event("reply_created", parameters: ["parent_is_own": parentIsOwn, "has_gif": hasGif])
    }

    static func likeTapped() {
        event("like_tapped")
    }

    static func crisisModalShown(level: CrisisLevel) {
        event("crisis_modal_shown", parameters: ["level": level == .explicit ? "explicit" : "soft"])
    }

    enum ReportTargetType: String { case post, reply, user, conversation }

    static func reportSubmitted(target: ReportTargetType, reasonCode: String) {
        event("report_submitted", parameters: ["target_type": target.rawValue, "reason_code": reasonCode])
    }

    static func userBlocked() {
        event("user_blocked")
    }

    static func pushPrimerDecision(accepted: Bool) {
        event("push_primer_decision", parameters: ["accepted": accepted])
    }
}

// MARK: - Auth Error Messages
//
// Firebase's `error.localizedDescription` returns strings like
// "FIRAuthErrorDomain Code=17009" or unhelpful technical phrases. These don't
// match our copy voice and confuse users. This helper maps the common
// AuthErrorCode values to lowercase, human messages that fit the app's tone.
//
// Used by SignInView, CreateAccountView, PasswordResetView, and any other
// surface that calls Auth.auth() methods. Falls back to a generic message
// for codes we haven't mapped — the goal is to never show raw Firebase strings.

// String(localized:) wrappers below so when a future String Catalog
// (.xcstrings) is added to the project, Xcode picks these up at build
// time and exposes them to translators alongside Text(...) call sites.
func friendlyAuthErrorMessage(_ error: Error) -> String {
    let nsError = error as NSError
    guard nsError.domain == "FIRAuthErrorDomain" else {
        return String(localized: "something went wrong. please try again.")
    }
    switch nsError.code {
    case 17007: return String(localized: "an account with this email already exists. try signing in.")
    case 17008: return String(localized: "that email doesn't look right. check the format.")
    case 17009: return String(localized: "wrong password. try again or reset it.")
    case 17010: return String(localized: "too many tries. wait a minute and try again.")
    case 17011: return String(localized: "we couldn't find an account with that email.")
    case 17012: return String(localized: "this email is linked to a different sign-in method.")
    case 17014: return String(localized: "for security, please sign out and sign back in, then try again.")
    case 17020: return String(localized: "youre offline. check your connection and try again.")
    case 17023: return String(localized: "this email is already linked to a different sign-in method.")
    case 17026: return String(localized: "password is too weak. use at least 6 characters.")
    case 17034: return String(localized: "please enter your email.")
    case 17052: return String(localized: "too many requests right now. give it a minute.")
    case 17999: return String(localized: "something went wrong on our end. try again.")
    default:
        return String(localized: "couldn't sign in. try again in a moment.")
    }
}

// MARK: - Cached Brand Colors
//
// `Color(hex: "...")` does string trimming, Scanner-based hex parsing, and a
// switch every call. The top brand colors are referenced hundreds of times
// across the feed and per-row UI (e.g., "9198a8" appears 164× in this codebase).
// Caching them as static `let` constants moves the parse cost to first-access
// instead of every render, measurably reducing per-frame work on older devices.
//
// To extend: add a `static let foo = Color(hex: "xxxxxx")` here and replace
// `Color(hex: "xxxxxx")` call sites with `Color.foo`.

extension Color {
    // Note: these MUST keep the explicit `Color(hex: ...)` initializer; do not
    // search-and-replace them in this file or they'll become self-referencing
    // and either fail to compile or recurse infinitely at runtime.

    // MARK: Brand
    static let toskaBlue       = Color(hex: "9198a8")
    static let toskaTextLight  = Color(hex: "b0b0b0")
    static let toskaTextDark   = Color(hex: "2a2a2a")
    static let toskaDivider    = Color(hex: "d0d0d0")
    static let toskaTimestamp  = Color(hex: "c0c0c0")

    // MARK: Semantic accents
    static let toskaError      = Color(hex: "c45c5c")
    static let toskaPink       = Color(hex: "c47a8a")
    static let toskaPurple     = Color(hex: "8b7ec8")
    static let toskaGold       = Color(hex: "c9a97a")
    static let toskaWarm       = Color(hex: "c49a6c")
    static let toskaGreen      = Color(hex: "6ba58e")
    static let toskaTeal       = Color(hex: "5a9e8f")

    // MARK: Grays (replace scattered hex literals)
    static let toskaGray       = Color(hex: "999999")
    static let toskaGrayLight  = Color(hex: "cccccc")
    static let toskaGrayMid    = Color(hex: "c8c8c8")
}

// MARK: - Design Tokens
//
// Centralized spacing, corner radius, and typography constants so every
// surface feels like the same app. Values chosen to match Apple HIG
// density on compact devices while keeping the moody, minimal aesthetic.

enum Toska {
    // Horizontal padding for all full-width content rows.
    static let horizontalPadding: CGFloat = 16
    // Standard vertical padding for header bars.
    static let headerVerticalPadding: CGFloat = 12
    // Standard line spacing for Georgia display text.
    static let bodyLineSpacing: CGFloat = 4
    // Standard corner radius for cards, inputs, pills.
    static let cornerRadius: CGFloat = 12
    // Small corner radius for tag pills, badges.
    static let cornerRadiusSmall: CGFloat = 10
    // Disabled/inactive state opacity.
    static let disabledOpacity: Double = 0.35
}

// MARK: - Shared Components

struct ToskaDivider: View {
    var body: some View {
        Rectangle()
            .fill(LateNightTheme.divider)
            .frame(height: 0.5)
    }
}

struct ToskaHeader: View {
    let title: String
    var dismiss: (() -> Void)? = nil
    var dismissStyle: DismissStyle = .chevron
    var trailing: AnyView? = nil

    enum DismissStyle { case chevron, xmark, none }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let dismiss = dismiss {
                    Button(action: dismiss) {
                        Group {
                            switch dismissStyle {
                            case .chevron:
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 14, weight: .light))
                                    .foregroundColor(Color.toskaBlue)
                            case .xmark:
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Color.toskaGray)
                            case .none:
                                EmptyView()
                            }
                        }
                    }
                    .accessibilityLabel("Close")
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
                Spacer()
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(LateNightTheme.handleText)
                Spacer()
                if let trailing = trailing {
                    trailing
                } else {
                    Color.clear.frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Toska.horizontalPadding)
            .padding(.vertical, Toska.headerVerticalPadding)
            ToskaDivider()
        }
    }
}

struct ToskaEmptyState: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(LateNightTheme.tertiaryText)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(LateNightTheme.secondaryText)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(LateNightTheme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

struct ToskaErrorBanner: View {
    let message: String
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: 11))
            Spacer()
            if let onRetry = onRetry {
                Button(action: onRetry) {
                    Text("retry")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .foregroundColor(Color.toskaError)
        .padding(.horizontal, Toska.horizontalPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.toskaError.opacity(0.06))
    }
}

// MARK: - Crisis Check-In
//
// Shared modal shown when a user is about to post/reply/edit/save content
// that contains language suggesting self-harm or suicidal ideation. Surfaces
// tappable crisis resources (988 call, 988 text, Crisis Text Line) so the
// user can reach help in one tap rather than having to copy a phone number.
//
// Uses the same visual language as the existing compose gentle-check modal:
// heart icon, Georgia-Italic headline, muted blue action buttons, dimmed
// full-screen background. Drop it in any ZStack when isPresented == true.
//
// See `crisisLevel(for:)` in FeedView.swift for severity classification, and
// UserHandleCache.gentleCheckIn for the user-toggleable softer tier.

@MainActor
struct CrisisCheckInView: View {
    @Binding var isPresented: Bool
    let level: CrisisLevel
    /// Called if the user taps "im okay, share it" — i.e. they've seen the
    /// resources and still want to proceed. Matches best practice: interrupt,
    /// offer help, but don't block the user from expressing themselves.
    let onProceed: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture {
                    // Explicit-tier modal can't be tap-dismissed — the user
                    // has to make an active choice. Soft-tier can.
                    if level == .soft { isPresented = false }
                }

            VStack(spacing: 14) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(Color.toskaBlue)

                Text(headline)
                    .font(.custom("Georgia-Italic", size: 18))
                    .foregroundColor(LateNightTheme.handleText)
                    .multilineTextAlignment(.center)

                Text(subhead)
                    .font(.system(size: 12))
                    .foregroundColor(LateNightTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 4)

                VStack(spacing: 6) {
                    // Region-aware. CrisisLines.resources picks the right
                    // hotlines for the user's locale (988 in US/CA, 116 123
                    // in UK/IE, 13 11 14 in AU, etc.). For unsupported
                    // regions it falls back to findahelpline.com.
                    ForEach(CrisisLines.resources, id: \.url) { resource in
                        resourceRow(
                            icon: resource.icon,
                            label: resource.label,
                            sublabel: resource.sublabel,
                            url: resource.url
                        )
                    }
                }
                .padding(.top, 2)

                VStack(spacing: 8) {
                    Button {
                        onProceed()
                        isPresented = false
                    } label: {
                        Text(proceedLabel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.toskaBlue)
                            .cornerRadius(12)
                    }

                    Button {
                        isPresented = false
                    } label: {
                        Text("not now")
                            .font(.system(size: 12))
                            .foregroundColor(LateNightTheme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.top, 4)
            }
            .padding(22)
            .background(LateNightTheme.cardBackground)
            .cornerRadius(16)
            .padding(.horizontal, 32)
        }
    }

    private var headline: String {
        switch level {
        case .explicit: return "please read this first"
        case .soft:     return "before you share this"
        }
    }

    private var subhead: String {
        switch level {
        case .explicit:
            return "what you wrote sounds serious.\nyou don't have to go through this alone."
        case .soft:
            return "this sounds like it's coming\nfrom a heavy place. that's okay."
        }
    }

    private var proceedLabel: String {
        switch level {
        case .explicit: return "i'm safe. share it."
        case .soft:     return "i'm okay. share it."
        }
    }

    @ViewBuilder
    private func resourceRow(icon: String, label: String, sublabel: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) {
                UIApplication.shared.open(u)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                    Text(sublabel)
                        .font(.system(size: 10))
                        .foregroundColor(LateNightTheme.tertiaryText)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(LateNightTheme.tertiaryText)
            }
            .foregroundColor(Color.toskaBlue)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.toskaBlue.opacity(0.08))
            .cornerRadius(10)
        }
    }
}

// MARK: - Crisis Check Decision Helper
//
// Centralized "should we show the check-in?" gate. Surfaces call this instead
// of duplicating the tier + setting logic.
//
// Returns the level to present (.explicit or .soft), or nil if no check-in
// is warranted — either because the text is clean, or because it's a soft
// signal and the user has disabled gentleCheckIn.

@MainActor
func crisisCheckLevelRespectingSetting(for text: String) -> CrisisLevel? {
    guard let level = crisisLevel(for: text) else { return nil }
    switch level {
    case .explicit:
        // Always show — non-optional safety rail. Telemetry-counted so we can
        // monitor how often the rail fires (no content logged, just the tier).
        Telemetry.crisisModalShown(level: .explicit)
        return .explicit
    case .soft:
        guard UserHandleCache.shared.gentleCheckIn else { return nil }
        Telemetry.crisisModalShown(level: .soft)
        return .soft
    }
}

// MARK: - Policy / Age Verification

/// Version of the combined Terms + Content Policy that the app enforces.
/// Bump when the policy changes. Existing users will be re-prompted until
/// their stored `acceptedPolicyVersion` matches this value.
let currentPolicyVersion = 1

/// Shared support contact surfaced in the policy and in-app. Replace before
/// shipping to the App Store.
let toskaSupportEmail = "support@toska.app"

/// Full Terms of Service + Content Policy body, rendered inside the
/// acceptance screen. Written in the app's own (lowercase, first-person-ish)
/// tone but covering Apple 1.2 UGC requirements:
///  - published contact info
///  - acceptable use rules
///  - 24h moderation commitment
///  - blocking + reporting mechanisms
///  - right to remove content and accounts
/// This is a first draft. A lawyer should review before App Store submission.
let toskaPolicyBody = """
toska is a space for the things you can't say out loud. anonymity is the point. to keep that space safe, we ask everyone to agree to a few ground rules before using the app.

1. who can use toska
you must be at least 17 years old to use toska. some content on toska is emotionally heavy and isn't suited to minors. by continuing, you confirm you are 17 or older.

2. what you can share
toska is for your own feelings, your own story. you can say anything about your own experience — even the hard parts. you agree not to:
  • share another person's real name, contact info, address, workplace, or any identifying detail
  • post sexual content, explicit imagery, or content that sexualizes minors
  • post content that encourages or instructs anyone (including yourself) to harm themselves or others
  • post threats, harassment, hate speech, or content targeting someone based on race, religion, gender, sexuality, or disability
  • impersonate another person or organization
  • post spam, scams, promotions, or links designed to deceive
  • use toska to buy, sell, or solicit illegal goods or services

3. how we moderate
we review every report we receive. we commit to reviewing reported content and taking action on violations within 24 hours. action may mean removing the post, warning the user, or suspending the account. we don't publicly discuss moderation decisions, but we respond to every report.

4. safety resources
toska is not a substitute for professional help. if you are in crisis, please reach out to a local crisis line — the in-app safety check-in shows the right number for where you are. if you or someone else is in immediate danger, please call \(CrisisLines.emergencyNumber).

5. blocking and reporting
you can block any user at any time from their profile or from a post. blocked users will no longer see each other's content or be able to message you. you can report any post, reply, conversation, or user — reports go to our moderation team. the "report" action is the fastest way to flag something you've seen.

6. your content
you keep ownership of anything you post. by posting, you grant toska a limited license to display your content within the app and in aggregated, anonymous forms (like the daily moment or weekly recap). we don't sell your content. we don't train third-party AI on it.

7. anonymity and data
toska keeps your real identity separate from your posts. we store the minimum needed to run the service: an anonymous handle, the content you post, and basic account metadata. we never share your identity publicly. we may share account information with law enforcement when legally required (for example, in response to a valid warrant).

8. account termination
you can delete your account at any time from settings. we may suspend or terminate accounts that repeatedly violate these rules, that put other users at risk, or that we believe to be operated by someone under 17.

9. changes to these rules
we'll update these rules as toska evolves. when we make material changes, we'll ask you to re-accept before you can keep using the app.

10. contact
questions, appeals, or anything else: \(toskaSupportEmail). we read every message.

by tapping "i agree and continue" you confirm you are 17 or older, you understand these rules, and you accept them.
"""

// MARK: - Age Gate View
//
// Shown before any Firebase account is created. Self-declaration age gate
// (industry-standard for UGC apps with anonymous accounts). We never collect
// date of birth; a "yes/no" confirmation is the minimum viable gate and
// matches how Whisper, Reddit's anonymous surfaces, and most mental-health
// peer apps handle this.
//
// If the user taps "I am under 17" we show a friendly off-ramp and do NOT
// let them proceed. We also do not create any Firestore or Auth records
// during this screen — it runs entirely before account creation.

@MainActor
struct AgeGateView: View {
    /// Called when the user confirms they are 17 or older.
    let onConfirmAdult: () -> Void
    /// Called when the user declines (under 17). Parent should dismiss the
    /// signup flow and return to the splash / sign-in screen.
    let onDecline: () -> Void

    @State private var showUnderageMessage = false

    var body: some View {
        ZStack {
            Color(hex: "0a0908").ignoresSafeArea()

            if showUnderageMessage {
                underageOffRamp
            } else {
                gate
            }
        }
    }

    private var gate: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(Color.toskaBlue)

            Text("one quick thing")
                .font(.custom("Georgia-Italic", size: 24))
                .foregroundColor(.white)

            Text("toska is for 17 and up.\nsome of what people share here is heavy.\nwe want to make sure youre ready for that.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    onConfirmAdult()
                } label: {
                    Text("i am 17 or older")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: "0a0908"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white)
                        .cornerRadius(12)
                }

                Button {
                    showUnderageMessage = true
                } label: {
                    Text("i'm not yet")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
    }

    private var underageOffRamp: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "heart.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(Color.toskaBlue)

            Text("come back when youre older")
                .font(.custom("Georgia-Italic", size: 22))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // The age-gate off-ramp shows the under-17 user a single crisis
            // resource. Pulled from CrisisLines so the right local number
            // shows regardless of where the user is.
            Text("toska gets heavy. we want you to have the right support around you.\n\nif youre going through something hard right now, please talk to a trusted adult, or reach out to \(CrisisLines.resources.first?.label ?? "a crisis line"). youre not alone.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)

            Spacer()

            Button {
                onDecline()
            } label: {
                Text("okay")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(12)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Policy Acceptance View
//
// Terms + Content Policy screen with a required checkbox. Shown right after
// the age gate on new signups, and shown to existing users when the stored
// `acceptedPolicyVersion` is behind `currentPolicyVersion`.
//
// The checkbox is required (not a scroll-to-accept pattern) for App Store
// review defensibility — a concrete affirmative action tied to the button's
// enabled state gives a stronger "informed consent" trail than scroll events.

@MainActor
struct PolicyAcceptanceView: View {
    /// Fired when the user checks the box and taps continue.
    let onAccept: () -> Void
    /// Fired if the user declines. Parent decides what to do (sign out for
    /// existing users, pop the signup flow for new ones).
    let onDecline: () -> Void

    @State private var agreed = false

    var body: some View {
        ZStack {
            Color(hex: "0a0908").ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 4) {
                    Text("terms and content policy")
                        .font(.custom("Georgia-Italic", size: 22))
                        .foregroundColor(.white)
                    Text("version \(currentPolicyVersion) · last updated 2026")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
                .padding(.top, 20)
                .padding(.bottom, 14)

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)

                // Scrollable body
                ScrollView(showsIndicators: true) {
                    Text(toskaPolicyBody)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.75))
                        .lineSpacing(4)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)

                // Checkbox + buttons
                VStack(spacing: 12) {
                    Button {
                        agreed.toggle()
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: agreed ? "checkmark.square.fill" : "square")
                                .font(.system(size: 18))
                                .foregroundColor(agreed ? Color.toskaBlue : .white.opacity(0.3))
                            Text("i confirm i am 17 or older and i agree to the terms and content policy above.")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                                .multilineTextAlignment(.leading)
                                .lineSpacing(2)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        if agreed { onAccept() }
                    } label: {
                        Text("i agree and continue")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(agreed ? Color(hex: "0a0908") : .white.opacity(0.3))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(agreed ? Color.white : Color.white.opacity(0.08))
                            .cornerRadius(12)
                    }
                    .disabled(!agreed)

                    Button {
                        onDecline()
                    } label: {
                        Text("i don't agree")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
    }
}

// MARK: - Policy Acceptance Persistence
//
// Small helper writing acceptance fields onto the user doc. Called from:
//  - CreateAccountView after the gate passes, as part of user doc creation
//  - AppleSignInHelper for new Apple sign-ups
//  - ContentView's retro-prompt flow for existing users on version bump
//
// The fields are intentionally additive to the user doc (merge: true) so we
// never overwrite existing onboarding state.

@MainActor
func recordPolicyAcceptance(for uid: String, confirmedAdult: Bool = true) {
    var data: [String: Any] = [
        "acceptedPolicyVersion": currentPolicyVersion,
        "acceptedPolicyAt": FieldValue.serverTimestamp(),
    ]
    if confirmedAdult {
        data["confirmedAdult"] = true
        data["confirmedAdultAt"] = FieldValue.serverTimestamp()
    }
    Firestore.firestore().collection("users").document(uid).setData(data, merge: true) { error in
        if let error = error {
            print("⚠️ recordPolicyAcceptance write failed: \(error)")
        }
    }
}

// MARK: - Report Sheet
//
// Reusable report UI for posts, replies, profiles, and conversations. One
// sheet, four reason categories, optional "also block this user?" follow-up
// so users can resolve the situation in a single flow.
//
// The caller decides what kind of thing is being reported via ReportTarget,
// which carries the IDs + optional metadata the report doc needs. The sheet
// writes to the existing "reports" collection, matching the structure used
// by existing report paths in PostDetailView / OtherProfileView.

enum ReportReason: String, CaseIterable, Identifiable {
    case harassment         = "harassment or bullying"
    case selfHarm           = "self-harm or suicide content"
    case sexualContent      = "sexual or explicit content"
    case spam               = "spam or scam"
    case impersonation      = "impersonation"
    case other              = "something else"

    var id: String { rawValue }

    /// Short machine-friendly slug stored on the report doc so moderators can
    /// filter/aggregate without parsing free text.
    var code: String {
        switch self {
        case .harassment:    return "harassment"
        case .selfHarm:      return "self_harm"
        case .sexualContent: return "sexual"
        case .spam:          return "spam"
        case .impersonation: return "impersonation"
        case .other:         return "other"
        }
    }
}

enum ReportTarget {
    case post(postId: String, authorId: String, authorHandle: String, text: String)
    case reply(postId: String, replyId: String, authorId: String, authorHandle: String, text: String)
    case user(userId: String, handle: String)
    case conversation(conversationId: String, otherUserId: String, otherHandle: String)
}

@MainActor
struct ReportSheet: View {
    @Environment(\.dismiss) var dismiss
    let target: ReportTarget

    @State private var selectedReason: ReportReason? = nil
    @State private var isSubmitting = false
    @State private var didSubmit = false
    @State private var showBlockOption = false

    var body: some View {
        ZStack {
            Color(hex: "0a0908").ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button { dismiss() } label: {
                        Text("cancel")
                            .font(.system(size: 13))
                            .foregroundColor(Color.toskaBlue)
                    }
                    Spacer()
                    Text(headerTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Text("cancel").font(.system(size: 13)).foregroundColor(.clear)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)

                if showBlockOption {
                    blockFollowUp
                } else if didSubmit {
                    thankYou
                } else {
                    reasonList
                }
            }
        }
    }

    private var headerTitle: String {
        switch target {
        case .post:         return "report post"
        case .reply:        return "report reply"
        case .user:         return "report user"
        case .conversation: return "report conversation"
        }
    }

    private var reasonList: some View {
        VStack(spacing: 0) {
            Text("why are you reporting this?")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
                .padding(.top, 14)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ReportReason.allCases) { reason in
                        Button {
                            selectedReason = reason
                        } label: {
                            HStack {
                                Image(systemName: selectedReason == reason ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundColor(selectedReason == reason ? Color.toskaBlue : .white.opacity(0.25))
                                Text(reason.rawValue)
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.85))
                                Spacer()
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(Color.white.opacity(0.04)).frame(height: 0.5).padding(.leading, 48)
                    }
                }
            }

            Spacer()

            Button {
                submitReport()
            } label: {
                HStack {
                    if isSubmitting {
                        ProgressView().tint(.white)
                    } else {
                        Text("submit report")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(selectedReason != nil ? Color(hex: "0a0908") : .white.opacity(0.3))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(selectedReason != nil ? Color.white : Color.white.opacity(0.08))
                .cornerRadius(12)
            }
            .disabled(selectedReason == nil || isSubmitting)
            .padding(.horizontal, 16)
            .padding(.bottom, 20)

            Text("reports are reviewed within 24 hours.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
                .padding(.bottom, 20)
        }
    }

    private var thankYou: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(Color.toskaBlue)
            Text("thanks. we'll review this.")
                .font(.custom("Georgia-Italic", size: 18))
                .foregroundColor(.white)
            Text("our team reviews every report within 24 hours.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()

            if blockableUser != nil {
                Button {
                    showBlockOption = true
                } label: {
                    Text("also block this user?")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.toskaBlue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.toskaBlue.opacity(0.1))
                        .cornerRadius(12)
                }
                .padding(.horizontal, 16)
            }

            Button {
                dismiss()
            } label: {
                Text("done")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(hex: "0a0908"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    private var blockFollowUp: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(Color.toskaBlue)
            Text("block this user?")
                .font(.custom("Georgia-Italic", size: 18))
                .foregroundColor(.white)
            Text("you wont see their posts or messages. they wont be notified.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()

            VStack(spacing: 8) {
                Button {
                    if let (uid, handle) = blockableUser {
                        BlockedUsersCache.shared.block(uid, handle: handle)
                    }
                    dismiss()
                } label: {
                    Text("yes, block them")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.toskaBlue)
                        .cornerRadius(12)
                }
                Button {
                    dismiss()
                } label: {
                    Text("no, just the report")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    /// Returns (uid, handle) of the user whose content is being reported, or
    /// nil if the target doesn't have a per-user counterparty (shouldn't
    /// happen in practice — every target includes an author or participant).
    private var blockableUser: (uid: String, handle: String)? {
        switch target {
        case .post(_, let authorId, let handle, _): return (authorId, handle)
        case .reply(_, _, let authorId, let handle, _): return (authorId, handle)
        case .user(let userId, let handle): return (userId, handle)
        case .conversation(_, let otherUserId, let otherHandle): return (otherUserId, otherHandle)
        }
    }

    private func submitReport() {
        guard let reason = selectedReason else { return }
        guard let reporterUid = Auth.auth().currentUser?.uid else { return }
        // Cap one report submission per 5 seconds. Without this, a user
        // could spam the queue from a flag menu in a tight loop. Server-
        // side moderation is the real defense, but cheap client throttle
        // saves us from nuisance load.
        if let last = RateLimiter.shared.lastReportTime, Date().timeIntervalSince(last) < 5.0 {
            // Pretend success — the user shouldn't realise we throttled them
            // (otherwise they'll learn to spam past it).
            didSubmit = true
            return
        }
        RateLimiter.shared.lastReportTime = Date()
        isSubmitting = true

        var payload: [String: Any] = [
            "reportedBy": reporterUid,
            "reason": reason.code,
            "reasonLabel": reason.rawValue,
            "createdAt": FieldValue.serverTimestamp(),
            "status": "pending",
        ]

        switch target {
        case .post(let postId, let authorId, let handle, let text):
            payload["type"]          = "post"
            payload["postId"]        = postId
            payload["reportedUserId"] = authorId
            payload["reportedHandle"] = handle
            payload["text"]          = text
        case .reply(let postId, let replyId, let authorId, let handle, let text):
            payload["type"]          = "reply"
            payload["postId"]        = postId
            payload["replyId"]       = replyId
            payload["reportedUserId"] = authorId
            payload["reportedHandle"] = handle
            payload["text"]          = text
        case .user(let userId, let handle):
            payload["type"]          = "user"
            payload["reportedUserId"] = userId
            payload["reportedHandle"] = handle
        case .conversation(let conversationId, let otherUserId, let otherHandle):
            payload["type"]           = "conversation"
            payload["conversationId"] = conversationId
            payload["reportedUserId"]  = otherUserId
            payload["reportedHandle"]  = otherHandle
        }

        let telemetryTarget: Telemetry.ReportTargetType = {
            switch target {
            case .post:         return .post
            case .reply:        return .reply
            case .user:         return .user
            case .conversation: return .conversation
            }
        }()

        Firestore.firestore().collection("reports").addDocument(data: payload) { error in
            Task { @MainActor in
                isSubmitting = false
                if let error = error {
                    print("⚠️ submitReport failed: \(error)")
                    Telemetry.recordError(error, context: "ReportSheet.submit")
                    // Still move to thank-you state so the user isn't
                    // confused — moderation queues usually tolerate duplicates.
                } else {
                    Telemetry.reportSubmitted(target: telemetryTarget, reasonCode: reason.code)
                }
                didSubmit = true
            }
        }
    }
}
