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
                    .foregroundColor(Color(hex: "9198a8"))
                }
                .padding(.top, 16)
                .padding(.bottom, 20)
                
                Text("reset password")
                    .font(.custom("Georgia-Italic", size: 28))
                    .foregroundColor(Color(hex: "111111"))
                    .padding(.bottom, 4)
                
                Text("we'll send you a link to reset it.")
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
                    .background(isSent ? Color(hex: "e8eaed") : Color.white)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: "e8e2d9"), lineWidth: 0.5)
                    )
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .disabled(isSent)
                    .padding(.bottom, 16)
                
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .padding(.bottom, 10)
                }
                
                if isSent {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "9198a8"))
                        Text("link sent")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(hex: "9198a8"))
                    }
                    .padding(.bottom, 12)
                    
                    Button {
                        isSent = false
                        sendReset()
                    } label: {
                        Text("didn't get it? resend")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "9198a8"))
                    }
                } else {
                    Button {
                        sendReset()
                    } label: {
                        ZStack {
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("send reset link")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color(hex: "9198a8"))
                        .cornerRadius(12)
                    }
                    .disabled(email.isEmpty || isLoading)
                }
                
                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }
    
    func sendReset() {
                let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard trimmed.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil else {
                    errorMessage = "please enter a valid email"
                    return
                }
                isLoading = true
                errorMessage = ""
                Auth.auth().sendPasswordReset(withEmail: trimmed) { error in
                Task { @MainActor in
                    isLoading = false
                    if let error = error {
                        errorMessage = error.localizedDescription
                    } else {
                        isSent = true
                    }
                }
            }
        }
}
