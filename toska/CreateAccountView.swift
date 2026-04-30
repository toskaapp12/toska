import SwiftUI
import FirebaseAuth
import FirebaseFirestore

@MainActor
struct CreateAccountView: View {
    @Environment(\.dismiss) var dismiss
    
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage = ""
    @State private var isLoading = false
    @State private var assignedHandle = ""
    // Age + policy gates are run after the user taps "create account" but
    // before we call Auth.auth().createUser. If they decline either step we
    // never create a Firebase account — keeping us from collecting credentials
    // from underage / non-agreeing users.
    @State private var showAgeGate = false
    @State private var showPolicyAcceptance = false
    
    var body: some View {
        ZStack {
            Color(hex: "f0f1f3").ignoresSafeArea()
            
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
                
                Text("create account")
                    .font(.custom("Georgia-Italic", size: 28))
                    .foregroundColor(Color.toskaTextDark)
                    .padding(.bottom, 4)
                
                Text("no names. no faces. just feelings.")
                    .font(.system(size: 11))
                    .foregroundColor(Color.toskaTextLight)
                    .padding(.bottom, 16)
                
                VStack(alignment: .leading, spacing: 8) {
                                    Text("your anonymous handle")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(Color.toskaTextLight)
                                    
                                    HStack {
                                        Text(assignedHandle)
                                            .font(.custom("Georgia", size: 16))
                                            .foregroundColor(Color.toskaTextDark)
                                        
                                        Spacer()
                                        
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                assignedHandle = "..."
                                            }
                                            // Same timeout shape as loadUniqueHandle so a flaky
                                            // network never strands the shuffle on "..." with no
                                            // recovery. Caps the user-visible spinner at 5s.
                                            Task { @MainActor in
                                                let handle: String
                                                do {
                                                    handle = try await withTimeout(seconds: 5) {
                                                        await generateUniqueHandleAsync()
                                                    }
                                                } catch {
                                                    handle = "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
                                                }
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    assignedHandle = handle
                                                }
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "arrow.triangle.2.circlepath")
                                                    .font(.system(size: 11))
                                                Text("shuffle")
                                                    .font(.system(size: 11, weight: .medium))
                                            }
                                            .foregroundColor(Color.toskaBlue)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color.toskaBlue.opacity(0.08))
                                            .cornerRadius(8)
                                        }
                                    }
                                    
                                    Text("tap shuffle until you find one that feels right")
                                        .font(.system(size: 9))
                                        .foregroundColor(Color.toskaTimestamp)
                                }
                                .padding(.bottom, 12)
                
                Rectangle()
                    .fill(Color(hex: "e4e6ea"))
                    .frame(height: 0.5)
                    .padding(.bottom, 16)
                
                Text("EMAIL")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color.toskaTextLight)
                    .tracking(1.2)
                    .padding(.bottom, 4)
                
                TextField("your@email.com", text: $email)
                    .font(.system(size: 13))
                    .padding(11)
                    .background(Color.white)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: "e4e6ea"), lineWidth: 0.5)
                    )
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("createEmailField")
                    .accessibilityLabel("email address")
                
                Text("PASSWORD")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color.toskaTextLight)
                    .tracking(1.2)
                    .padding(.bottom, 4)
                
                SecureField("••••••••", text: $password)
                                    .font(.system(size: 13))
                                    .padding(11)
                                    .background(Color.white)
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color(hex: "e4e6ea"), lineWidth: 0.5)
                                    )
                                    .padding(.bottom, 12)
                                    // `.newPassword` signals iOS to offer the Keychain-backed
                                    // strong-password suggestion and routes 3rd-party password
                                    // managers through the right autofill path. `.oneTimeCode`
                                    // (the previous value) is for SMS/email verification codes
                                    // and breaks both — new accounts would get no autofill
                                    // assistance at all.
                                    .textContentType(.newPassword)
                                    .accessibilityIdentifier("createPasswordField")
                                    .accessibilityLabel("new password")
                
                Text("CONFIRM PASSWORD")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color.toskaTextLight)
                    .tracking(1.2)
                    .padding(.bottom, 4)
                
                SecureField("••••••••", text: $confirmPassword)
                                    .font(.system(size: 13))
                                    .padding(11)
                                    .background(Color.white)
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color(hex: "e4e6ea"), lineWidth: 0.5)
                                    )
                                    .padding(.bottom, 20)
                                    .textContentType(.newPassword)
                                    .accessibilityIdentifier("createConfirmPasswordField")
                                    .accessibilityLabel("confirm password")
                
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "c45c5c"))
                        .padding(.bottom, 10)
                }
                
                Button {
                    attemptCreateAccount()
                } label: {
                    ZStack {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("create account")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(isLoading ? Color.toskaBlue.opacity(0.5) : Color.toskaBlue)
                    .cornerRadius(12)
                }
                .disabled(isLoading)
                .accessibilityIdentifier("createAccountButton")
                
                Spacer()
                
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text("already have an account? sign in")
                            .font(.system(size: 11))
                            .foregroundColor(Color.toskaBlue)
                    }
                    Spacer()
                }
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            if assignedHandle.isEmpty {
                loadUniqueHandle()
            }
        }
        .fullScreenCover(isPresented: $showAgeGate) {
            AgeGateView(
                onConfirmAdult: {
                    showAgeGate = false
                    showPolicyAcceptance = true
                },
                onDecline: {
                    showAgeGate = false
                }
            )
        }
        .fullScreenCover(isPresented: $showPolicyAcceptance) {
            PolicyAcceptanceView(
                onAccept: {
                    showPolicyAcceptance = false
                    createAccount()
                },
                onDecline: {
                    showPolicyAcceptance = false
                }
            )
        }
    }

    /// Validates the form, then runs the age + policy gates. Only if both are
    /// passed do we call `createAccount()` which touches Firebase Auth.
    func attemptCreateAccount() {
        guard !isLoading else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmedEmail.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil else {
            errorMessage = "please enter a valid email"
            return
        }
        guard password == confirmPassword else {
            errorMessage = "passwords don't match"
            return
        }
        guard password.count >= 8 else {
            errorMessage = "password must be at least 8 characters"
            return
        }
        errorMessage = ""
        showAgeGate = true
    }
    
    func loadUniqueHandle() {
        // 5s timeout matches Apple/Google sign-up paths. Without this,
        // a hung Firestore call leaves the handle field showing "" or
        // "..." indefinitely on the create-account screen and the user
        // sees no way forward. Falls back to a UUID handle on timeout.
        Task { @MainActor in
            let handle: String
            do {
                handle = try await withTimeout(seconds: 5) {
                    await generateUniqueHandleAsync()
                }
            } catch {
                handle = "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
            }
            assignedHandle = handle
        }
    }
    
    /// Actually calls Firebase Auth. Must not be invoked directly — use
    /// attemptCreateAccount() which enforces the age + policy gates first.
    func createAccount() {
        guard !isLoading else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isLoading = true

        Auth.auth().createUser(withEmail: trimmedEmail, password: password) { result, error in
            Task { @MainActor in
                if let error = error {
                    isLoading = false
                    errorMessage = friendlyAuthErrorMessage(error)
                    return
                }

                guard let uid = result?.user.uid else {
                    // createUser returned no error but also no user — this
                    // shouldn't happen per Firebase's contract, but without
                    // an error message the button just becomes usable again
                    // with no explanation and the user is stuck.
                    isLoading = false
                    errorMessage = "account creation failed — please try again"
                    return
                }

                // If the assigned handle never resolved (loadUniqueHandle ran
                // but Firestore was unreachable, leaving "..." or empty), fall
                // back to a UUID handle here so we never write a malformed
                // handle to the user doc. The shuffle button uses the callback
                // version which can also leave "..." on screen if the user
                // taps create-account immediately after shuffling. This guard
                // catches both cases without making the user wait.
                let resolvedHandle: String
                if assignedHandle.isEmpty || assignedHandle == "..." {
                    resolvedHandle = "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
                } else {
                    resolvedHandle = assignedHandle
                }

                let db = Firestore.firestore()
                do {
                    try await db.collection("users").document(uid).setData([
                                            "handle": resolvedHandle,
                                            "followerCount": 0,
                        "followingCount": 0,
                        "totalLikes": 0,
                        "allowSharing": true,
                        "showFollowerCount": false,
                        "hasCompletedOnboarding": false,
                        "createdAt": FieldValue.serverTimestamp(),
                        // Policy acceptance fields. The matching adult-confirmation
                        // fields (`confirmedAdult` / `confirmedAdultAt`) are
                        // server-owned and written by the confirmAdult Cloud
                        // Function below — firestore.rules denies these fields
                        // from any client write at create or update.
                        "acceptedPolicyVersion": currentPolicyVersion,
                        "acceptedPolicyAt": FieldValue.serverTimestamp()
                    ])
                    try? await db.collection("users").document(uid)
                        .collection("private").document("data")
                        .setData(["email": trimmedEmail], merge: true)
                    // Mark the user adult-confirmed via the server before
                    // we transition to onboarding. We `try?` here so a
                    // network blip doesn't block signup — OnboardingView's
                    // checkAcceptanceStatus will re-show the age gate on
                    // next launch if the server write didn't land.
                    // Awaiting (rather than fire-and-forget) prevents the
                    // race where OnboardingView reads the user doc before
                    // confirmedAdult propagates and re-shows the age gate
                    // a second time for a user who already passed it here.
                    try? await confirmAdultServerSide(uid: uid)
                    isLoading = false
                                        UserHandleCache.shared.startListening()
                                        Telemetry.signupCompleted(method: .email)
                                        NotificationCenter.default.post(name: .showOnboarding, object: nil)
                                        NotificationCenter.default.post(
                                            name: .userDidSignIn,
                                            object: nil,
                                            userInfo: ["uid": uid]
                                        )
                                        dismiss()
                } catch {
                    print("⚠️ CreateAccount: user doc write failed: \(error)")
                    Telemetry.recordError(error, context: "CreateAccount.userDocWrite")
                    isLoading = false
                    errorMessage = "account creation failed — please try again"
                    do {
                        try await Auth.auth().currentUser?.delete()
                    } catch let deleteError {
                        print("⚠️ CreateAccount: auth rollback delete failed: \(deleteError); falling back to signOut")
                        Telemetry.recordError(deleteError, context: "CreateAccount.rollbackDelete")
                        try? Auth.auth().signOut()
                    }
                    // If both delete() and signOut() failed we'd have a
                    // Firebase-authenticated user with no Firestore user doc;
                    // downstream screens assume the doc exists and wedge the
                    // app. Force a sign-out notification so BlockedUsersCache,
                    // UserHandleCache, and any listeners tear down, and log
                    // a critical error so this surfaces in Crashlytics.
                    if Auth.auth().currentUser != nil {
                        Telemetry.recordError(
                            error,
                            context: "CreateAccount.rollbackFailed.stillAuthenticated"
                        )
                        NotificationCenter.default.post(name: .userDidSignOut, object: nil)
                    }
                }
            }
        }
    }
}
