import SwiftUI
import FirebaseAuth

@MainActor
struct PasswordResetView: View {
    @Environment(\.dismiss) var dismiss
    @State private var email = ""
    @State private var isSent = false
    @State private var errorMessage = ""
    @State private var isLoading = false
    
    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .medium))
                        Text("back")
                            .font(ToskaFont.sans(12.5, weight: .semibold))
                    }
                    .foregroundColor(ToskaColor.body)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .padding(.top, 8)
                .padding(.bottom, 12)

                Text("reset password")
                    .font(ToskaFont.serif(28))
                    .tracking(-0.6)
                    .foregroundColor(ToskaColor.text)
                    .padding(.bottom, 8)

                Text("we'll send you a link to reset it.")
                    .font(ToskaFont.serifItalic(15))
                    .foregroundColor(ToskaColor.text2)
                    .padding(.bottom, 32)

                Text("your email")
                    .font(ToskaFont.sans(10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.74)
                    .foregroundColor(ToskaColor.text2)
                    .padding(.bottom, 8)

                TextField("your@email.com", text: $email)
                    .font(ToskaFont.serif(16))
                    .foregroundColor(ToskaColor.text)
                    .tint(ToskaColor.accent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(ToskaColor.input, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .disabled(isSent)
                    .opacity(isSent ? 0.6 : 1)
                    .padding(.bottom, 16)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(ToskaFont.sans(11.5))
                        .foregroundColor(Color.toskaErrorRed)
                        .padding(.bottom, 10)
                }

                if isSent {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                        Text("link sent")
                            .font(ToskaFont.sans(12.5, weight: .semibold))
                    }
                    .foregroundColor(ToskaColor.accentText)
                    .padding(.bottom, 12)

                    Button {
                        isSent = false
                        sendReset()
                    } label: {
                        Text("didn't get it? resend")
                            .font(ToskaFont.sans(12.5, weight: .semibold))
                            .foregroundColor(ToskaColor.accentText)
                    }
                } else {
                    Button {
                        sendReset()
                    } label: {
                        ZStack {
                            if isLoading {
                                ProgressView().tint(ToskaColor.onAccent)
                            } else {
                                Text("send reset link")
                                    .font(ToskaFont.sans(14, weight: .semibold))
                                    .foregroundColor(ToskaColor.onAccent)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(ToskaColor.accent, in: Capsule())
                    }
                    .disabled(email.isEmpty || isLoading)
                }

                Spacer()
            }
            .padding(.horizontal, 28)
        }
    }
    
    func sendReset() {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.isValidEmail else {
            errorMessage = "please enter a valid email"
            return
        }
        isLoading = true
        errorMessage = ""
        // 30s timeout — same rationale as SignInView. Without it, a stalled
        // Firebase callback leaves "send reset link" spinning indefinitely
        // and the user has no recourse but to force-quit.
        Task { @MainActor in
            do {
                try await withTimeout(seconds: 30) {
                    try await Auth.auth().sendPasswordReset(withEmail: trimmed)
                }
                isLoading = false
                isSent = true
            } catch is TimeoutError {
                isLoading = false
                errorMessage = "request timed out — please try again"
            } catch {
                isLoading = false
                errorMessage = friendlyAuthErrorMessage(error)
            }
        }
    }
}
