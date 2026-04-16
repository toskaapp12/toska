import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

struct UserSettings: Equatable {
    var allowSharing = true
    var showFollowerCount = false
    var notifyLikes = true
    var notifyReplies = true
    var notifyFollows = true
    var notifyMilestones = true
    var notifyWitness = true
    var pushEnabled = true
    var gentleCheckIn = true
}

@MainActor
struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var settings = UserSettings()
    @State private var showDeleteAlert = false
    @State private var showSignOutAlert = false
    @State private var showReauthAlert = false
    @State private var isDeleting = false
    @State private var isLoaded = false
    @State private var deleteError = ""
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var showChangeEmail = false
    @State private var showChangePassword = false
    
    var body: some View {
        ZStack {
            Color(hex: "f0f1f3").ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(hex: "999999"))
                    }
                    Spacer()
                    Text("settings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(hex: "2a2a2a"))
                    Spacer()
                    Image(systemName: "xmark").font(.system(size: 13)).foregroundColor(.clear)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        
                        // MARK: - Privacy
                        settingsGroup {
                            groupHeader("privacy")
                            VStack(spacing: 0) {
                                toggleRow("allow sharing", subtitle: "let people share your words", isOn: $settings.allowSharing)
                                Divider().padding(.leading, 14)
                                toggleRow("show follower count", subtitle: "let others see how many people follow you", isOn: $settings.showFollowerCount)
                            }
                            .background(Color.white)
                            .cornerRadius(12)
                        }
                        
                        // MARK: - Notifications
                        settingsGroup {
                            groupHeader("notifications")
                            VStack(spacing: 0) {
                                toggleRow("push notifications", subtitle: "know when someone feels what you said", isOn: $settings.pushEnabled)
                                if settings.pushEnabled {
                                    Divider().padding(.leading, 14)
                                    miniToggle("likes", isOn: $settings.notifyLikes)
                                    Divider().padding(.leading, 28)
                                    miniToggle("replies", isOn: $settings.notifyReplies)
                                    Divider().padding(.leading, 28)
                                    miniToggle("new followers", isOn: $settings.notifyFollows)
                                    Divider().padding(.leading, 28)
                                    miniToggle("milestones", isOn: $settings.notifyMilestones)
                                    Divider().padding(.leading, 28)
                                    miniToggle("witness mode", isOn: $settings.notifyWitness)
                                }
                            }
                            .background(Color.white)
                            .cornerRadius(12)
                        }
                        
                        // MARK: - Content
                        settingsGroup {
                            groupHeader("content")
                            VStack(spacing: 0) {
                                toggleRow("gentle check-in", subtitle: "we'll check in on softer signals. crisis language always shows resources.", isOn: $settings.gentleCheckIn)
                                Divider().padding(.leading, 14)
                                NavigationLink(destination: BlockedUsersListView()) {
                                    HStack {
                                        Text("blocked users")
                                            .font(.system(size: 14))
                                            .foregroundColor(Color(hex: "2a2a2a"))
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .light))
                                            .foregroundColor(Color(hex: "d0d0d0"))
                                    }
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 14)
                                }
                            }
                            .background(Color.white)
                            .cornerRadius(12)
                        }
                        
                        // MARK: - Account
                                                settingsGroup {
                                                    groupHeader("account")
                                                    VStack(spacing: 0) {
                                                        actionRow("change email") { showChangeEmail = true }
                                                        if Auth.auth().currentUser?.providerData.contains(where: { $0.providerID == "password" }) == true {
                                                            Divider().padding(.leading, 14)
                                                            actionRow("change password") { showChangePassword = true }
                                                        }
                                                    }
                                                    .background(Color.white)
                                                    .cornerRadius(12)
                                                }
                        
                        // MARK: - Sign Out
                        Button {
                            showSignOutAlert = true
                        } label: {
                            Text("sign out")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(hex: "999999"))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        
                        // MARK: - Delete Account
                        Button {
                            showDeleteAlert = true
                        } label: {
                            Text(isDeleting ? "deleting..." : "delete account")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "c45c5c").opacity(0.7))
                        }
                        .disabled(isDeleting)
                        
                        if !deleteError.isEmpty {
                            Text(deleteError)
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "c45c5c"))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        
                        // MARK: - Why toska exists
                                                VStack(spacing: 12) {
                                                    Rectangle()
                                                        .fill(Color(hex: "dfe1e5"))
                                                        .frame(width: 32, height: 0.5)
                                                    
                                                    Text("why this exists")
                                                        .font(.system(size: 10, weight: .semibold))
                                                        .foregroundColor(Color(hex: "b0b0b0"))
                                                    
                                                    Text("i went through a breakup. talked to everyone. they ran out of things to say and i ran out of people to say it to. everyone had moved on but i was still sad. i was on reddit at 2am, downloading random apps, watching sad tiktoks. none of it was it. i just wanted somewhere anonymous where people are going through the same thing and nobody's pretending they're not. so i built it.")
                                                        .font(.custom("Georgia", size: 12))
                                                        .foregroundColor(Color(hex: "999999"))
                                                        .lineSpacing(4)
                                                        .multilineTextAlignment(.center)
                                                        .padding(.horizontal, 24)
                                                    
                                                    Text("— tess")
                                                        .font(.custom("Georgia-Italic", size: 11))
                                                        .foregroundColor(Color(hex: "c0c0c0"))
                                                    
                                                    VStack(spacing: 2) {
                                                        Text("toska v1.0")
                                                            .font(.system(size: 9))
                                                            .foregroundColor(Color(hex: "d0d0d0"))
                                                        Text("for the things you can't say out loud")
                                                            .font(.custom("Georgia-Italic", size: 9))
                                                            .foregroundColor(Color(hex: "d0d0d0").opacity(0.5))
                                                    }
                                                    .padding(.top, 4)
                                                }
                                                .padding(.top, 16)
                                                .padding(.bottom, 32)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .onAppear {
                    loadSettings()
                }
        .onChange(of: settings) { oldValue, newValue in
            if isLoaded && oldValue != newValue { debounceSave() }
        }
        .alert("delete account?", isPresented: $showDeleteAlert) {
            Button("cancel", role: .cancel) {}
            Button("delete", role: .destructive) { deleteAccount() }
        } message: {
            Text("this is permanent. everything you said here goes with it.")
        }
        .alert("sign in again to delete", isPresented: $showReauthAlert) {
            Button("sign out") {
                            PushNotificationManager.shared.clearFCMToken()
                            try? Auth.auth().signOut()
                            NotificationCenter.default.post(name: .userDidSignOut, object: nil)
                            dismiss()
                        }
                        Button("cancel", role: .cancel) {}
                    } message: {
                        Text("sign out and back in first. then try again.")
                    }
                    .alert("sign out?", isPresented: $showSignOutAlert) {
                        Button("cancel", role: .cancel) {}
                        Button("sign out") {
                            PushNotificationManager.shared.clearFCMToken()
                            try? Auth.auth().signOut()
                            NotificationCenter.default.post(name: .userDidSignOut, object: nil)
                            dismiss()
                        }
                    }

        .sheet(isPresented: $showChangeEmail) { ChangeEmailView() }
        .sheet(isPresented: $showChangePassword) { ChangePasswordView() }
    }
    
    // MARK: - Components
    
    func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(.horizontal, 16)
    }
    
    func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color(hex: "b0b0b0"))
            .padding(.leading, 4)
    }
    
    func toggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "2a2a2a"))
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "c0c0c0"))
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Color(hex: "9198a8"))
                .scaleEffect(0.8)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
    
    func miniToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "555555"))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Color(hex: "9198a8"))
                .scaleEffect(0.7)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
        .padding(.leading, 14)
    }
    
    func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            HStack {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "2a2a2a"))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .light))
                    .foregroundColor(Color(hex: "d0d0d0"))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
    }
    
    // MARK: - Data
    
    func loadSettings() {
           guard let uid = Auth.auth().currentUser?.uid else { return }
           Task { @MainActor in
               let snapshot = try? await Firestore.firestore()
                   .collection("users").document(uid).getDocumentAsync()
               guard let data = snapshot?.data() else {
                   isLoaded = true
                   return
               }
               settings = UserSettings(
                   allowSharing: data["allowSharing"] as? Bool ?? true,
                   showFollowerCount: data["showFollowerCount"] as? Bool ?? false,
                   notifyLikes: data["notifyLikes"] as? Bool ?? true,
                   notifyReplies: data["notifyReplies"] as? Bool ?? true,
                   notifyFollows: data["notifyFollows"] as? Bool ?? true,
                   notifyMilestones: data["notifyMilestones"] as? Bool ?? true,
                   notifyWitness: data["notifyWitness"] as? Bool ?? true,
                   pushEnabled: data["pushEnabled"] as? Bool ?? true,
                   gentleCheckIn: data["gentleCheckIn"] as? Bool ?? true
               )
               isLoaded = true
           }
       }
    func debounceSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            saveSettings()
        }
    }
    
    func saveSettings() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Task { @MainActor in
                    do {
                        try await Firestore.firestore().collection("users").document(uid).updateData([                            "allowSharing": settings.allowSharing,
                            "showFollowerCount": settings.showFollowerCount,
                            "notifyLikes": settings.notifyLikes,
                            "notifyReplies": settings.notifyReplies,
                            "notifyFollows": settings.notifyFollows,
                            "notifyMilestones": settings.notifyMilestones,
                            "notifyWitness": settings.notifyWitness,
                            "pushEnabled": settings.pushEnabled,
                            "gentleCheckIn": settings.gentleCheckIn,
                        ])
                    } catch {
                        print("⚠️ saveSettings failed: \(error)")
                        loadSettings()
                    }
                }    }
    

    // NOTE: This writes a document to `pendingDeletions` and then deletes the
       // Firebase Auth account. A Cloud Function is expected to watch that collection
       // and clean up the user's posts, notifications, followers, etc.
       // If the function fails, the user's data is orphaned. Monitor `pendingDeletions`
       // for documents older than ~5 minutes that have no `completedAt` field,
       // and add retry logic to the Cloud Function.
       func deleteAccount() {
           guard let uid = Auth.auth().currentUser?.uid else { return }
           isDeleting = true
           deleteError = ""

           Firestore.firestore().collection("pendingDeletions").document(uid).setData([
            "uid": uid,
            "requestedAt": FieldValue.serverTimestamp()
        ]) { writeError in
            Task { @MainActor in
                if let writeError = writeError {
                    isDeleting = false
                    deleteError = "couldn't reach the server — please try again: \(writeError.localizedDescription)"
                    return
                }

                await AppleSignInHelper.revokeTokenIfNeeded()
                
                Auth.auth().currentUser?.delete { error in
                    Task { @MainActor in
                        if let error = error {
                            isDeleting = false
                            Firestore.firestore().collection("pendingDeletions").document(uid).setData([
                                "cancelled": true,
                                "cancelledAt": FieldValue.serverTimestamp()
                            ], merge: true)
                            let nsError = error as NSError
                            if nsError.code == AuthErrorCode.requiresRecentLogin.rawValue {
                                showReauthAlert = true
                            } else {
                                deleteError = "failed to delete account: \(error.localizedDescription)"
                            }
                            return
                        }

                        isDeleting = false
                                             NotificationCenter.default.post(name: .userDidSignOut, object: nil)
                                             dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Change Email View

@MainActor
struct ChangeEmailView: View {
    @Environment(\.dismiss) var dismiss
    @State private var newEmail = ""
    @State private var isSaving = false
    @State private var message = ""
    @State private var isError = false
    
    var isValidEmail: Bool {
        newEmail.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil
    }
    
    var body: some View {
        ZStack {
            Color(hex: "f0f1f3").ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Text("cancel").font(.system(size: 13)).foregroundColor(Color(hex: "999999"))
                    }
                    Spacer()
                    Text("change email").font(.system(size: 14, weight: .medium)).foregroundColor(Color(hex: "2a2a2a"))
                    Spacer()
                    Button { updateEmail() } label: {
                        Text("save").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(!isValidEmail || isSaving ? Color(hex: "d0d0d0") : Color(hex: "9198a8"))
                            .cornerRadius(16)
                    }
                    .disabled(!isValidEmail || isSaving)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                Rectangle().fill(Color(hex: "e4e6ea")).frame(height: 0.5)
                
                VStack(alignment: .leading, spacing: 16) {
                    Text("current email")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "b0b0b0"))
                    
                    Text(Auth.auth().currentUser?.email ?? "unknown")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "2a2a2a"))
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: "e4e6ea").opacity(0.5))
                        .cornerRadius(10)
                    
                    Text("new email")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "b0b0b0"))
                    
                    TextField("new email address", text: $newEmail)
                        .font(.system(size: 13))
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(11)
                        .background(Color.white)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "e4e6ea"), lineWidth: 0.5))
                    
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(isError ? Color(hex: "c45c5c") : Color(hex: "6ba58e"))
                    }
                    
                    Text("you may need to sign out and back in before changing your email.")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "cccccc"))
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                
                Spacer()
            }
        }
    }
    
    func updateEmail() {
        let trimmed = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil else {
            message = "please enter a valid email"
            isError = true
            return
        }
        isSaving = true
        message = ""
        Auth.auth().currentUser?.sendEmailVerification(beforeUpdatingEmail: trimmed) { error in
            Task { @MainActor in
                isSaving = false
                if let error = error {
                    let nsError = error as NSError
                    if nsError.code == AuthErrorCode.requiresRecentLogin.rawValue {
                        message = "please sign out and sign back in, then try again"
                    } else {
                        message = error.localizedDescription
                    }
                    isError = true
                } else {
                    message = "verification email sent — check your inbox"
                    isError = false
                }
            }
        }
    }
}

// MARK: - Change Password View

@MainActor
struct ChangePasswordView: View {
    @Environment(\.dismiss) var dismiss
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var message = ""
    @State private var isError = false
    @State private var dismissTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack {
            Color(hex: "f0f1f3").ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        dismissTask?.cancel()
                        dismiss()
                    } label: {
                        Text("cancel").font(.system(size: 13)).foregroundColor(Color(hex: "999999"))
                    }
                    Spacer()
                    Text("change password").font(.system(size: 14, weight: .medium)).foregroundColor(Color(hex: "2a2a2a"))
                    Spacer()
                    Button { updatePassword() } label: {
                        Text("save").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(newPassword.isEmpty || isSaving ? Color(hex: "d0d0d0") : Color(hex: "9198a8"))
                            .cornerRadius(16)
                    }
                    .disabled(newPassword.isEmpty || isSaving)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                Rectangle().fill(Color(hex: "e4e6ea")).frame(height: 0.5)
                
                VStack(alignment: .leading, spacing: 16) {
                    Text("new password")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "b0b0b0"))
                    
                    SecureField("at least 6 characters", text: $newPassword)
                        .font(.system(size: 13))
                        .padding(11)
                        .background(Color.white)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "e4e6ea"), lineWidth: 0.5))
                    
                    Text("confirm password")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "b0b0b0"))
                    
                    SecureField("type it again", text: $confirmPassword)
                        .font(.system(size: 13))
                        .padding(11)
                        .background(Color.white)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "e4e6ea"), lineWidth: 0.5))
                    
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(isError ? Color(hex: "c45c5c") : Color(hex: "6ba58e"))
                    }
                    
                    Text("you may need to sign out and back in before changing your password.")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "cccccc"))
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                
                Spacer()
            }
        }
    }
    
    func updatePassword() {
        guard newPassword.count >= 6 else {
            message = "password must be at least 6 characters"
            isError = true
            return
        }
        guard newPassword == confirmPassword else {
            message = "passwords don't match"
            isError = true
            return
        }
        isSaving = true
        message = ""
        Auth.auth().currentUser?.updatePassword(to: newPassword) { error in
            Task { @MainActor in
                isSaving = false
                if let error = error {
                    message = error.localizedDescription
                    isError = true
                } else {
                    message = "password updated"
                    isError = false
                    dismissTask?.cancel()
                    dismissTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard !Task.isCancelled else { return }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Blocked Users List
//
// Simple Settings sub-screen listing everyone the current user has blocked.
// Each row shows the stored handle (captured at block time) and an "unblock"
// button. Unblocking calls through to BlockedUsersCache which handles the
// optimistic local update + Firestore write.
//
// We read directly from users/{uid}/blocked rather than from BlockedUsersCache
// because the cache only stores IDs — the per-doc `handle` field is needed
// to render recognizable rows.

@MainActor
struct BlockedUsersListView: View {
    @Environment(\.dismiss) var dismiss
    @State private var blocked: [BlockedUserRow] = []
    @State private var isLoading = true

    struct BlockedUserRow: Identifiable, Equatable {
        let id: String   // the blocked user's uid
        let handle: String
        let blockedAt: Date
    }

    var body: some View {
        ZStack {
            Color(hex: "f0f1f3").ignoresSafeArea()

            VStack(spacing: 0) {
                if isLoading {
                    Spacer()
                    ProgressView().tint(Color(hex: "9198a8"))
                    Spacer()
                } else if blocked.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "person.slash")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(Color(hex: "d0d0d0"))
                        Text("no blocked users")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(hex: "b0b0b0"))
                        Text("people you block will show up here. you can unblock them any time.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "cccccc"))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(blocked) { row in
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: "9198a8").opacity(0.1))
                                            .frame(width: 36, height: 36)
                                        Text(String(row.handle.replacingOccurrences(of: "anonymous_", with: "").prefix(1)).uppercased())
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundColor(Color(hex: "9198a8"))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.handle)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(Color(hex: "2a2a2a"))
                                        Text("blocked \(FeedView.timeAgoString(from: row.blockedAt)) ago")
                                            .font(.system(size: 10))
                                            .foregroundColor(Color(hex: "b0b0b0"))
                                    }
                                    Spacer()
                                    Button {
                                        unblock(row)
                                    } label: {
                                        Text("unblock")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(Color(hex: "9198a8"))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color(hex: "9198a8").opacity(0.08))
                                            .cornerRadius(8)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                Divider().padding(.leading, 68)
                            }
                        }
                        .background(Color.white)
                        .cornerRadius(12)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                    }
                }
            }
        }
        .navigationTitle("blocked users")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
    }

    func load() {
        guard let uid = Auth.auth().currentUser?.uid else {
            isLoading = false
            return
        }
        Task { @MainActor in
            let snapshot = try? await Firestore.firestore()
                .collection("users").document(uid).collection("blocked")
                .order(by: "blockedAt", descending: true)
                .getDocumentsAsync()
            let rows: [BlockedUserRow] = snapshot?.documents.map { doc in
                let data = doc.data()
                return BlockedUserRow(
                    id: doc.documentID,
                    handle: data["handle"] as? String ?? "anonymous",
                    blockedAt: (data["blockedAt"] as? Timestamp)?.dateValue() ?? Date()
                )
            } ?? []
            blocked = rows
            isLoading = false
        }
    }

    func unblock(_ row: BlockedUserRow) {
        // Optimistically remove from the list so the row disappears immediately.
        // The cache's unblock() writes to Firestore and reverts on error, so
        // in the rare failure case the row will reappear on next load.
        blocked.removeAll { $0.id == row.id }
        BlockedUsersCache.shared.unblock(row.id)
    }
}
