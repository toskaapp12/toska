import Foundation

extension String {
    /// True when the string is a plausibly-valid email address.
    ///
    /// Consolidates the identical inline regex that previously lived in
    /// CreateAccountView, SignInView, PasswordResetView and SettingsView.
    /// The pattern requires a non-whitespace local part, an "@", a
    /// non-whitespace domain, and a dot-separated TLD of at least two
    /// characters — deliberately permissive (we rely on the verification
    /// email to prove deliverability) but enough to catch obvious typos.
    var isValidEmail: Bool {
        range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil
    }
}
