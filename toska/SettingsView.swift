import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

struct UserSettings: Equatable {
    var allowSharing = true
    var showFollowerCount = false
    var notifyLikes = true
    var notifyReplies = true
    var notifyFollows = true
    var notifyReposts = true
    var notifySaves = true
    var notifyMessages = true
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
    @State private var showContentPolicy = false
    // Analytics opt-out. UserDefaults-backed because the Telemetry namespace
    // (which is non-View) reads the same key directly. Default true; flipping
    // off short-circuits all Telemetry.* calls everywhere in the app.
    @AppStorage("toska_shareAnonymousUsage") private var shareAnonymousUsage: Bool = true
    // Surfaced when a settings save fails so the user knows their toggle
    // didn't actually persist (otherwise the toggle silently snaps back).
    @State private var saveErrorBanner: String? = nil
    // Data export progress + error states. The export gathers everything
    // the user has authored across collections and writes a JSON file
    // before presenting iOS share sheet.
    @State private var isExporting = false
    @State private var exportError: String? = nil
    
    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()
            
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
                        .foregroundColor(Color.toskaTextDark)
                    Spacer()
                    Image(systemName: "xmark").font(.system(size: 13)).foregroundColor(.clear)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                
                if let banner = saveErrorBanner {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                        Text(banner)
                            .font(.system(size: 11))
                        Spacer()
                    }
                    .foregroundColor(Color(hex: "c45c5c"))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(hex: "c45c5c").opacity(0.06))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {

                        // MARK: - Privacy
                        settingsGroup {
                            groupHeader("privacy")
                            VStack(spacing: 0) {
                                toggleRow("allow sharing", subtitle: "let people share your words", isOn: $settings.allowSharing)
                                Divider().padding(.leading, 14)
                                toggleRow("show follower count", subtitle: "let others see how many people follow you", isOn: $settings.showFollowerCount)
                                Divider().padding(.leading, 14)
                                toggleRow("share anonymous usage data", subtitle: "helps us fix bugs and improve the app. never includes what you wrote.", isOn: $shareAnonymousUsage)
                                Divider().padding(.leading, 14)
                                actionRow("view content policy") { showContentPolicy = true }
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
                                    miniToggle("messages", isOn: $settings.notifyMessages)
                                    Divider().padding(.leading, 28)
                                    miniToggle("reposts", isOn: $settings.notifyReposts)
                                    Divider().padding(.leading, 28)
                                    miniToggle("saves", isOn: $settings.notifySaves)
                                    Divider().padding(.leading, 28)
                                    miniToggle("new followers", isOn: $settings.notifyFollows)
                                    Divider().padding(.leading, 28)
                                    miniToggle("milestones", isOn: $settings.notifyMilestones)
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
                                            .foregroundColor(Color.toskaTextDark)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .light))
                                            .foregroundColor(Color.toskaDivider)
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
                                                        Divider().padding(.leading, 14)
                                                        actionRow(isExporting ? "preparing export..." : "export my data") {
                                                            exportData()
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
                                                        .foregroundColor(Color.toskaTextLight)
                                                    
                                                    Text("i went through a breakup. talked to everyone. they ran out of things to say and i ran out of people to say it to. everyone had moved on but i was still sad. i was on reddit at 2am, downloading random apps, watching sad tiktoks. none of it was it. i just wanted somewhere anonymous where people are going through the same thing and nobody's pretending they're not. so i built it.")
                                                        .font(.custom("Georgia", size: 12))
                                                        .foregroundColor(Color(hex: "999999"))
                                                        .lineSpacing(4)
                                                        .multilineTextAlignment(.center)
                                                        .padding(.horizontal, 24)
                                                    
                                                    Text("— tess")
                                                        .font(.custom("Georgia-Italic", size: 11))
                                                        .foregroundColor(Color.toskaTimestamp)
                                                    
                                                    VStack(spacing: 2) {
                                                        Text("toska v1.0")
                                                            .font(.system(size: 9))
                                                            .foregroundColor(Color.toskaDivider)
                                                        Text("for the things you can't say out loud")
                                                            .font(.custom("Georgia-Italic", size: 9))
                                                            .foregroundColor(Color.toskaDivider.opacity(0.5))
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
        .fullScreenCover(isPresented: $showContentPolicy) {
            // Read-only re-display of the policy the user accepted at signup.
            // Both buttons just dismiss — there's no acceptance flow here
            // (they've already accepted; this is for review only).
            PolicyAcceptanceView(
                onAccept: { showContentPolicy = false },
                onDecline: { showContentPolicy = false }
            )
        }
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
            .foregroundColor(Color.toskaTextLight)
            .padding(.leading, 4)
    }
    
    func toggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(Color.toskaTextDark)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundColor(Color.toskaTimestamp)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Color.toskaBlue)
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
                .tint(Color.toskaBlue)
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
                    .foregroundColor(Color.toskaTextDark)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .light))
                    .foregroundColor(Color.toskaDivider)
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
                   notifyReposts: data["notifyReposts"] as? Bool ?? true,
                   notifySaves: data["notifySaves"] as? Bool ?? true,
                   notifyMessages: data["notifyMessages"] as? Bool ?? true,
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
                        try await Firestore.firestore().collection("users").document(uid).updateData([
                            "allowSharing": settings.allowSharing,
                            "showFollowerCount": settings.showFollowerCount,
                            "notifyLikes": settings.notifyLikes,
                            "notifyReplies": settings.notifyReplies,
                            "notifyFollows": settings.notifyFollows,
                            "notifyReposts": settings.notifyReposts,
                            "notifySaves": settings.notifySaves,
                            "notifyMessages": settings.notifyMessages,
                            "notifyMilestones": settings.notifyMilestones,
                            "notifyWitness": settings.notifyWitness,
                            "pushEnabled": settings.pushEnabled,
                            "gentleCheckIn": settings.gentleCheckIn,
                        ])
                    } catch {
                        print("⚠️ saveSettings failed: \(error)")
                        // Tell the user their change didn't persist before
                        // we re-pull the server state and visually revert
                        // their toggle. Without this, the toggle just snaps
                        // back with no explanation.
                        saveErrorBanner = "couldn't save — check your connection. your last change didn't stick."
                        loadSettings()
                        // Auto-clear after a few seconds so the banner doesn't
                        // linger forever.
                        Task {
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            guard !Task.isCancelled else { return }
                            saveErrorBanner = nil
                        }
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

           // Clear FCM token before triggering deletion. Without this, the
           // server can keep pushing to the now-orphaned device until the
           // token rotates or the OS reaps it on next app uninstall.
           PushNotificationManager.shared.clearFCMToken()

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

    // MARK: - Data Export
    //
    // Required for GDPR compliance (Article 15, Right of Access) and a strong
    // signal for Apple privacy review. Produces a single JSON file containing
    // everything THIS user has authored or owned, then presents the iOS share
    // sheet so they can save it to Files / iCloud / email it to themselves.
    //
    // Deliberately excludes:
    //   - other users' content (only the requesting user's own data)
    //   - direct messages (two-party data — the other party hasn't consented
    //     to having their messages exported)
    //   - blocked-user IDs (just count + own-handle blocks; we don't list
    //     the IDs of people they've blocked, which is metadata about others)
    //
    // Anything missing here can be requested via support email per the
    // content policy.

    func exportData() {
        guard let uid = Auth.auth().currentUser?.uid, !isExporting else { return }
        isExporting = true
        exportError = nil

        Task { @MainActor in
            defer { isExporting = false }
            let db = Firestore.firestore()
            var payload: [String: Any] = [
                "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "exportFormatVersion": 1,
                "policyVersionAccepted": currentPolicyVersion
            ]

            // Account doc (handle, counts, settings, acceptance fields)
            if let userSnap = try? await db.collection("users").document(uid).getDocumentAsync(),
               let data = userSnap.data() {
                // Strip fcmToken (device-specific, not useful in an export)
                var account = data
                account.removeValue(forKey: "fcmToken")
                account.removeValue(forKey: "fcmTokenUpdatedAt")
                // Merge in the private subcollection (email, etc.) since
                // post-migration those fields no longer live on the main
                // user doc but are still the user's own data.
                if let privateSnap = try? await db.collection("users").document(uid)
                    .collection("private").document("data").getDocumentAsync(),
                   var privateData = privateSnap.data() {
                    privateData.removeValue(forKey: "fcmToken")
                    privateData.removeValue(forKey: "fcmTokenUpdatedAt")
                    for (k, v) in privateData { account[k] = v }
                }
                payload["account"] = sanitizeForJSON(account)
            }

            // Posts authored
            if let postsSnap = try? await db.collection("posts")
                .whereField("authorId", isEqualTo: uid)
                .order(by: "createdAt", descending: true)
                .getDocumentsAsync() {
                payload["posts"] = postsSnap.documents.map { doc -> [String: Any] in
                    var item = doc.data()
                    item["id"] = doc.documentID
                    return sanitizeForJSON(item) as? [String: Any] ?? item
                }
            }

            // Replies authored (collection group across all posts)
            if let repliesSnap = try? await db.collectionGroup("replies")
                .whereField("authorId", isEqualTo: uid)
                .order(by: "createdAt", descending: true)
                .getDocumentsAsync() {
                payload["replies"] = repliesSnap.documents.map { doc -> [String: Any] in
                    var item = doc.data()
                    item["id"] = doc.documentID
                    item["postId"] = doc.reference.parent.parent?.documentID ?? ""
                    return sanitizeForJSON(item) as? [String: Any] ?? item
                }
            }

            // Liked + saved post IDs (just IDs — full post content belongs
            // to the original author)
            if let likedSnap = try? await db.collection("users").document(uid).collection("liked").getDocumentsAsync() {
                payload["likedPostIds"] = likedSnap.documents.map { $0.documentID }
            }
            if let savedSnap = try? await db.collection("users").document(uid).collection("saved").getDocumentsAsync() {
                payload["savedPostIds"] = savedSnap.documents.map { $0.documentID }
            }

            // Following + followers (handles only — never user IDs of others,
            // which would let the export be cross-referenced with leaked data)
            if let followingSnap = try? await db.collection("users").document(uid).collection("following").getDocumentsAsync() {
                payload["followingHandles"] = followingSnap.documents.compactMap { $0.data()["handle"] as? String }
            }
            if let followersSnap = try? await db.collection("users").document(uid).collection("followers").getDocumentsAsync() {
                payload["followerHandles"] = followersSnap.documents.compactMap { $0.data()["handle"] as? String }
            }

            // Notifications history (own inbox)
            if let notifSnap = try? await db.collection("users").document(uid).collection("notifications")
                .order(by: "createdAt", descending: true)
                .getDocumentsAsync() {
                payload["notifications"] = notifSnap.documents.map { doc -> [String: Any] in
                    var item = doc.data()
                    item["id"] = doc.documentID
                    return sanitizeForJSON(item) as? [String: Any] ?? item
                }
            }

            // Serialize and present share sheet
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys]
                )
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("toska-export-\(stamp).json")
                try data.write(to: url, options: .atomic)
                presentShareSheet(with: [url])
                // Schedule cleanup. The share sheet runs modally; by the time
                // this 5-minute window elapses the user has either copied the
                // export to wherever they wanted or dismissed the sheet. The
                // file shouldn't sit in temp containing the user's full data
                // history indefinitely.
                Task.detached(priority: .background) {
                    try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                    try? FileManager.default.removeItem(at: url)
                }
            } catch {
                exportError = "couldn't build export — try again."
                print("⚠️ exportData serialize/write failed: \(error)")
            }
        }
    }

    /// Recursively converts Firestore-specific types (Timestamp, FieldValue,
    /// DocumentReference) into JSON-friendly forms so JSONSerialization can
    /// encode them without throwing on the first non-plist value.
    private func sanitizeForJSON(_ value: Any) -> Any {
        if let ts = value as? Timestamp {
            return ISO8601DateFormatter().string(from: ts.dateValue())
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues { sanitizeForJSON($0) }
        }
        if let array = value as? [Any] {
            return array.map { sanitizeForJSON($0) }
        }
        if let ref = value as? DocumentReference {
            return ref.path
        }
        return value
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
            LateNightTheme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Text("cancel").font(.system(size: 13)).foregroundColor(Color(hex: "999999"))
                    }
                    Spacer()
                    Text("change email").font(.system(size: 14, weight: .medium)).foregroundColor(Color.toskaTextDark)
                    Spacer()
                    Button { updateEmail() } label: {
                        Text("save").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(!isValidEmail || isSaving ? Color.toskaDivider : Color.toskaBlue)
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
                        .foregroundColor(Color.toskaTextLight)
                    
                    Text(Auth.auth().currentUser?.email ?? "unknown")
                        .font(.system(size: 13))
                        .foregroundColor(Color.toskaTextDark)
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: "e4e6ea").opacity(0.5))
                        .cornerRadius(10)
                    
                    Text("new email")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.toskaTextLight)
                    
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
            LateNightTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        dismissTask?.cancel()
                        dismiss()
                    } label: {
                        Text("cancel").font(.system(size: 13)).foregroundColor(Color(hex: "999999"))
                    }
                    Spacer()
                    Text("change password").font(.system(size: 14, weight: .medium)).foregroundColor(Color.toskaTextDark)
                    Spacer()
                    Button { updatePassword() } label: {
                        Text("save").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(newPassword.isEmpty || isSaving ? Color.toskaDivider : Color.toskaBlue)
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
                        .foregroundColor(Color.toskaTextLight)
                    
                    SecureField("at least 6 characters", text: $newPassword)
                        .font(.system(size: 13))
                        .padding(11)
                        .background(Color.white)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "e4e6ea"), lineWidth: 0.5))
                    
                    Text("confirm password")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.toskaTextLight)
                    
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
            LateNightTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                if isLoading {
                    Spacer()
                    ProgressView().tint(Color.toskaBlue)
                    Spacer()
                } else if blocked.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "person.slash")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(Color.toskaDivider)
                        Text("no blocked users")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.toskaTextLight)
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
                                            .fill(Color.toskaBlue.opacity(0.1))
                                            .frame(width: 36, height: 36)
                                        Text(String(row.handle.replacingOccurrences(of: "anonymous_", with: "").prefix(1)).uppercased())
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundColor(Color.toskaBlue)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.handle)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(Color.toskaTextDark)
                                        Text("blocked \(FeedView.timeAgoString(from: row.blockedAt)) ago")
                                            .font(.system(size: 10))
                                            .foregroundColor(Color.toskaTextLight)
                                    }
                                    Spacer()
                                    Button {
                                        unblock(row)
                                    } label: {
                                        Text("unblock")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(Color.toskaBlue)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.toskaBlue.opacity(0.08))
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
