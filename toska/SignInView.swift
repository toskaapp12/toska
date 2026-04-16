import SwiftUI
import FirebaseAuth

@MainActor
struct SignInView: View {
    @Environment(\.dismiss) var dismiss
    
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage = ""
    @State private var isLoading = false
    @State private var showReset = false
    
    var body: some View {
        ZStack {
            Color(hex: "faf8f5").ignoresSafeArea()
            
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13))
                        Text("back")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(Color.toskaBlue)
                }
                .padding(.top, 16)
                .padding(.bottom, 20)
                
                Text("welcome back.")
                    .font(.custom("Georgia-Italic", size: 28))
                    .foregroundColor(Color(hex: "111111"))
                    .padding(.bottom, 4)
                
                Text("sign in to continue to toska.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "aaaaaa"))
                    .padding(.bottom, 24)
                
                Text("EMAIL")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(hex: "bbbbbb"))
                    .tracking(1.2)
                    .padding(.bottom, 4)
                
                TextField("your@email.com", text: $email)
                    .font(.system(size: 13))
                    .padding(11)
                    .background(Color.white)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: "e8e2d9"), lineWidth: 0.5)
                    )
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("emailField")
                
                Text("PASSWORD")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(hex: "bbbbbb"))
                    .tracking(1.2)
                    .padding(.bottom, 4)
                
                SecureField("••••••••", text: $password)
                    .font(.system(size: 13))
                    .padding(11)
                    .background(Color.white)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: "e8e2d9"), lineWidth: 0.5)
                    )
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("passwordField")
                
                HStack {
                    Spacer()
                    Button("forgot password?") {
                        showReset = true
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Color.toskaBlue)
                }
                .padding(.bottom, 20)
                
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "c45c5c"))
                        .padding(.bottom, 10)
                }
                
                Button {
                    signIn()
                } label: {
                    ZStack {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("sign in")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.toskaBlue)
                    .cornerRadius(12)
                    .accessibilityIdentifier("signInButton")
                }
                .disabled(isLoading)
                .padding(.bottom, 16)
                
                Spacer()
                
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text("no account? create one")
                            .font(.system(size: 11))
                            .foregroundColor(Color.toskaBlue)
                    }
                    Spacer()
                }
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $showReset) {
            PasswordResetView()
        }
    }
    
    func signIn() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmedEmail.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil else {
            errorMessage = "please enter a valid email"
            return
        }
        // Guard the empty-password case before sending the request — the
        // server rejects it anyway, but a client-side check saves a round
        // trip and shows a more useful message than Firebase's generic
        // "missing password" code.
        guard !password.isEmpty else {
            errorMessage = "please enter your password"
            return
        }
        isLoading = true
        errorMessage = ""
        Auth.auth().signIn(withEmail: trimmedEmail, password: password) { result, error in
            Task { @MainActor in
                isLoading = false
                if let error = error {
                    Telemetry.recordError(error, context: "SignInView.emailSignIn")
                    errorMessage = friendlyAuthErrorMessage(error)
                } else if let uid = result?.user.uid {
                    Telemetry.signInCompleted(method: .email)
                    NotificationCenter.default.post(
                        name: NSNotification.Name("UserDidSignIn"),
                        object: nil,
                        userInfo: ["uid": uid]
                    )
                    dismiss()
                }
            }
        }
    }
}
