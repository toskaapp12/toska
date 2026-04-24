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
                                            generateUniqueHandle { handle in
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
                                    .textContentType(.oneTimeCode)
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
                                    .textContentType(.oneTimeCode)
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
        generateUniqueHandle { handle in
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
                    isLoading = false
                    return
                }
                
                let db = Firestore.firestore()
                do {
                    try await db.collection("users").document(uid).setData([
                                            "handle": assignedHandle,
                                            "followerCount": 0,
                        "followingCount": 0,
                        "totalLikes": 0,
                        "allowSharing": true,
                        "showFollowerCount": false,
                        "hasCompletedOnboarding": false,
                        "createdAt": FieldValue.serverTimestamp(),
                        // Age + policy acceptance fields. We reach this path only
                        // after both gates passed, so we record it atomically
                        // with user-doc creation.
                        "confirmedAdult": true,
                        "confirmedAdultAt": FieldValue.serverTimestamp(),
                        "acceptedPolicyVersion": currentPolicyVersion,
                        "acceptedPolicyAt": FieldValue.serverTimestamp()
                    ])
                    try? await db.collection("users").document(uid)
                        .collection("private").document("data")
                        .setData(["email": trimmedEmail], merge: true)
                    isLoading = false
                                        UserHandleCache.shared.startListening()
                                        Telemetry.signupCompleted(method: .email)
                                        NotificationCenter.default.post(name: NSNotification.Name("ShowOnboarding"), object: nil)
                                        NotificationCenter.default.post(
                                            name: NSNotification.Name("UserDidSignIn"),
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
                }
            }
        }
    }
}
