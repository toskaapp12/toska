import SwiftUI
import FirebaseAuth

@MainActor
struct SignInView: View {
    @Environment(\.dismiss) var dismiss
    
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var errorMessage = ""
    @State private var isLoading = false
    @State private var showReset = false
    
    var body: some View {
        // NavigationStack so showReset can push PasswordResetView instead
        // of sheet-presenting it (consistency with the rest of the app's
        // navigation flow). dismiss() at the root level still dismisses
        // the fullScreenCover from SplashView because @Environment(\.dismiss)
        // is captured at SignInView's level (above the NavigationStack);
        // dismiss() inside PasswordResetView (a child view) captures its
        // own @Environment(\.dismiss) and pops the navigation stack.
        NavigationStack {
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
                            .font(ToskaFont.sans(13))
                    }
                    .foregroundColor(Color.toskaBlue)
                }
                .padding(.top, 16)
                .padding(.bottom, 20)
                
                Text("welcome back.")
                    .font(ToskaFont.serifItalic(28))
                    .foregroundColor(Color(hex: "111111"))
                    .padding(.bottom, 4)
                
                Text("its still here when youre ready.")
                    .font(ToskaFont.sans(11))
                    .foregroundColor(Color.toskaTextLight)
                    .padding(.bottom, 24)
                
                Text("EMAIL")
                    .font(ToskaFont.sans(11, weight: .medium))
                    .foregroundColor(Color(hex: "bbbbbb"))
                    .tracking(1.2)
                    .padding(.bottom, 4)
                
                TextField("your@email.com", text: $email)
                    .font(ToskaFont.sans(13))
                    .padding(11)
                    .background(Color.white)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: "e8e2d9"), lineWidth: 0.5)
                    )
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("emailField")
                    .accessibilityLabel("email address")
                
                Text("PASSWORD")
                    .font(ToskaFont.sans(11, weight: .medium))
                    .foregroundColor(Color(hex: "bbbbbb"))
                    .tracking(1.2)
                    .padding(.bottom, 4)
                
                Group {
                    if showPassword {
                        TextField("••••••••", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("••••••••", text: $password)
                    }
                }
                    .font(ToskaFont.sans(13))
                    .padding(11)
                    .padding(.trailing, 38)   // room for the eye toggle
                    .background(Color.white)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: "e8e2d9"), lineWidth: 0.5)
                    )
                    // Eye as an overlay (constrained to the field's own height) so it
                    // can't stretch the field vertically the way a maxHeight button did.
                    .overlay(alignment: .trailing) {
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Color(hex: "999999"))
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                    .textContentType(.password)
                    .accessibilityIdentifier("passwordField")
                    .accessibilityLabel("password")
                    .padding(.bottom, 8)
                
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
                        .font(ToskaFont.sans(11))
                        .foregroundColor(.red)
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
                                .font(ToskaFont.sans(13, weight: .medium))
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
                            .font(ToskaFont.sans(11))
                            .foregroundColor(Color.toskaBlue)
                    }
                    Spacer()
                }
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
        .navigationDestination(isPresented: $showReset) {
            PasswordResetView().navigationBarHidden(true)
        }
        }
    }

    func signIn() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmedEmail.isValidEmail else {
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
        // 30s timeout. The previous shape used the bare callback API with no
        // ceiling — if Firebase Auth never called back (network blip, server
        // outage, abandoned cellular handoff), the spinner stayed forever and
        // the user couldn't even tap the back button without force-closing the
        // sheet. withTimeout cancels the wrapping Task on overrun and surfaces
        // a friendly retry message instead.
        Task { @MainActor in
            do {
                // Extract uid inside the timeout closure — AuthDataResult is
                // not Sendable so it can't cross the @Sendable boundary that
                // withTimeout's closure imposes. String is Sendable, which
                // is all we actually need from the result.
                let uid = try await withTimeout(seconds: 30) {
                    let result = try await Auth.auth().signIn(withEmail: trimmedEmail, password: password)
                    return result.user.uid
                }
                isLoading = false
                Telemetry.signInCompleted(method: .email)
                UserHandleCache.shared.startListening()
                NotificationCenter.default.post(
                    name: .userDidSignIn,
                    object: nil,
                    userInfo: ["uid": uid]
                )
                dismiss()
            } catch is TimeoutError {
                isLoading = false
                // withTimeout stops awaiting, but Firebase's signIn isn't
                // cancellation-aware, so it may have SUCCEEDED just after the
                // timer fired — currentUser is then set while we'd otherwise show
                // "timed out" and never post .userDidSignIn, leaving the user
                // authenticated but stranded on the sign-in screen. If auth
                // actually landed, complete the sign-in instead of erroring.
                if let uid = Auth.auth().currentUser?.uid {
                    Telemetry.signInCompleted(method: .email)
                    UserHandleCache.shared.startListening()
                    NotificationCenter.default.post(
                        name: .userDidSignIn, object: nil, userInfo: ["uid": uid]
                    )
                    dismiss()
                } else {
                    errorMessage = "request timed out — please try again"
                    // The one-shot check above still leaves a window: signIn is
                    // not cancellation-aware and can land seconds after it. Keep
                    // sweeping briefly and complete the sign-in if it does —
                    // otherwise the device is authenticated while the UI shows
                    // "timed out" and .userDidSignIn (which the caches and feed
                    // key off) never fires until a retry or relaunch.
                    Task { @MainActor in
                        for _ in 0..<15 {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            if let uid = Auth.auth().currentUser?.uid {
                                errorMessage = ""
                                Telemetry.signInCompleted(method: .email)
                                UserHandleCache.shared.startListening()
                                NotificationCenter.default.post(
                                    name: .userDidSignIn, object: nil, userInfo: ["uid": uid]
                                )
                                dismiss()
                                return
                            }
                        }
                    }
                }
            } catch {
                isLoading = false
                Telemetry.recordError(error, context: "SignInView.emailSignIn")
                errorMessage = friendlyAuthErrorMessage(error)
            }
        }
    }
}
