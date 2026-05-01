import SwiftUI
import FirebaseAuth
import FirebaseFirestore

@MainActor
struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var currentStep = 0
    @State private var selectedMood: String? = nil
    @State private var userHandle = "anonymous"
    @State private var showFirstPostCompose = false
    @State private var firstPostPublished = false

    // Age + policy gates. Shown as fullScreenCovers before the onboarding
    // steps become visible, only for users whose user doc doesn't already
    // have acceptance fields. Email signups pass through CreateAccountView's
    // gate and arrive here with fields set, so this is a no-op for them.
    // Apple/Google new signups arrive here without fields set, so the gate
    // runs. This keeps a single gate implementation regardless of auth method.
    @State private var showAgeGate = false
    @State private var showPolicyAcceptance = false
    @State private var acceptanceChecked = false
    @State private var moodSaveError = false
    
    let tags = sharedTags
    
    // MARK: - Writing prompts per mood
    
    let moodPrompts: [String: [String]] = [
            "longing": [
                "whats the thing you keep almost texting them",
                "what do you miss that youd never admit out loud",
                "its 2am. what are you thinking about.",
            ],
            "anger": [
                "what did they do that you still cant forgive",
                "say the thing you held back. right now.",
                "whats the part that makes you angry every time you think about it",
            ],
            "regret": [
                "whats the moment you keep replaying",
                "what would you have said if you could go back",
                "what do you wish you did differently. be honest.",
            ],
            "acceptance": [
                "whats the part youve finally stopped fighting",
                "when did you realize you were going to survive this",
                "what did losing them teach you about yourself",
            ],
            "confusion": [
                "what part still doesnt make sense no matter how many times you think about it",
                "are you sad or angry or both. you dont have to know.",
                "what are you feeling that you cant even name",
            ],
            "unsent": [
                "type the text youll never send.",
                "start with dear you. finish it however you need to.",
                "say it here. they wont see it. but you will.",
            ],
            "moving on": [
                "are you actually moving on or just getting quieter about it",
                "whats the first thing you did just for yourself after",
                "what would you tell someone whos where you were 3 months ago",
            ],
            "still love you": [
                "be honest. would you take them back right now.",
                "whats the hardest part about still loving someone who left",
                "do you think they know. do you want them to.",
            ],
        ]
    
    func promptForMood(_ mood: String?) -> String {
            guard let mood = mood, let prompts = moodPrompts[mood] else {
                return "say the thing you cant say out loud..."
            }
            let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
            return prompts[dayOfYear % prompts.count]
        }
    var promptTimeLabel: String {
            let hour = Calendar.current.component(.hour, from: Date())
            if hour >= 21 || hour < 5 { return "tonight's prompt" }
            else if hour < 12 { return "this morning's prompt" }
            else if hour < 17 { return "this afternoon's prompt" }
            else { return "this evening's prompt" }
        }
    var body: some View {
        ZStack {
            if currentStep == 0 || currentStep == 2 || currentStep == 3 {
                Color(hex: "0a0908").ignoresSafeArea()
            } else {
                Color(hex: "faf8f5").ignoresSafeArea()
            }
            
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index <= currentStep ? Color.toskaBlue : Color.toskaBlue.opacity(0.2))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 30)
                
                Spacer()
                
                switch currentStep {
                case 0: welcomeStep
                case 1: identityStep
                case 2: moodStep
                case 3: firstPostStep
                default: EmptyView()
                }
                
                Spacer()

                // Gate every forward-navigation control on acceptanceChecked.
                // Without this, a fast tapper can advance from welcome →
                // mood → "skip" before checkAcceptanceStatus's async read
                // returns and triggers the age-gate fullScreenCover —
                // completing onboarding without ever seeing the gate. The
                // server hasConfirmedAdult() rule still blocks publishing,
                // but Apple expects the user to take an affirmative action
                // before reaching content surfaces. Until the read resolves
                // we render a small spinner in place of the buttons.
                VStack(spacing: 8) {
                    if !acceptanceChecked {
                        ProgressView()
                            .tint(Color.toskaBlue)
                            .padding(.vertical, 18)
                    } else if currentStep < 2 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                currentStep += 1
                            }
                        } label: {
                            Text("next")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(currentStep == 0 ? Color(hex: "0a0908") : .white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(currentStep == 0 ? Color.white : Color.toskaBlue)
                                .cornerRadius(12)
                        }
                    } else if currentStep == 2 {
                        Button {
                            saveMoodAndAdvance()
                        } label: {
                            Text("next")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color(hex: "0a0908"))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color.white)
                                .cornerRadius(12)
                        }
                        
                        Button {
                                                    if let uid = Auth.auth().currentUser?.uid {
                                                        let userRef = Firestore.firestore().collection("users").document(uid)
                                                        userRef.setData(["hasCompletedOnboarding": true], merge: true) { error in
                                                            if let error = error {
                                                                print("⚠️ Onboarding skip (mood) write failed: \(error)")
                                                            }
                                                        }
                                                        // Mood is sensitive — store in the owner-only private
                                                        // subcollection rather than on the main user doc.
                                                        if let mood = selectedMood {
                                                            userRef.collection("private").document("data")
                                                                .setData(["selectedMood": mood], merge: true)
                                                        }
                                                    }
                                                    Telemetry.onboardingCompleted(); isComplete = true
                                                } label: {
                                                    Text("skip")
                                                        .font(.system(size: 11))
                                                        .foregroundColor(Color.white.opacity(0.3))
                                                }
                    } else if currentStep == 3 {
                        Button {
                            showFirstPostCompose = true
                        } label: {
                            Text("say it")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color(hex: "0a0908"))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color.white)
                                .cornerRadius(12)
                        }
                        
                        Button {
                                                    if let uid = Auth.auth().currentUser?.uid {
                                                        let userRef = Firestore.firestore().collection("users").document(uid)
                                                        userRef.setData(["hasCompletedOnboarding": true], merge: true) { error in
                                                            if let error = error {
                                                                print("⚠️ Onboarding skip-for-now write failed: \(error)")
                                                            }
                                                        }
                                                        if let mood = selectedMood {
                                                            userRef.collection("private").document("data")
                                                                .setData(["selectedMood": mood], merge: true)
                                                        }
                                                    }
                                                    Telemetry.onboardingCompleted(); isComplete = true
                                                } label: {
                                                    Text("skip for now")
                                                        .font(.system(size: 11))
                                                        .foregroundColor(Color.white.opacity(0.3))
                                                }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            loadHandle()
            checkAcceptanceStatus()
        }
        .fullScreenCover(isPresented: $showAgeGate) {
            AgeGateView(
                onConfirmAdult: {
                    // Mark the user adult-confirmed via the confirmAdult
                    // Cloud Function. firestore.rules denies clients from
                    // writing `confirmedAdult` directly, so this is the
                    // only legitimate path. Failure is logged but does
                    // not block progression — the next launch's
                    // checkAcceptanceStatus will re-show the gate if the
                    // server write didn't land.
                    if let uid = Auth.auth().currentUser?.uid {
                        confirmAdultServerSideFireAndForget(uid: uid)
                    }
                    showAgeGate = false
                    showPolicyAcceptance = true
                },
                onDecline: {
                    // User is under 17 — delete the account we just created
                    // via Apple/Google/email, sign out, and send them back to
                    // the splash screen.
                    Telemetry.ageGateDeclined()
                    showAgeGate = false
                    declineAndSignOut()
                }
            )
        }
        .fullScreenCover(isPresented: $showPolicyAcceptance) {
            PolicyAcceptanceView(
                onAccept: {
                    if let uid = Auth.auth().currentUser?.uid {
                        recordPolicyAcceptance(for: uid)
                    }
                    showPolicyAcceptance = false
                },
                onDecline: {
                    Telemetry.policyDeclined(version: currentPolicyVersion, atSignup: true)
                    showPolicyAcceptance = false
                    declineAndSignOut()
                }
            )
        }
        .fullScreenCover(isPresented: $showFirstPostCompose) {
            ComposeView(
                initialText: "",
                initialTag: selectedMood,
                onPostSuccess: {
                    showFirstPostCompose = false
                    firstPostPublished = true
                    if let uid = Auth.auth().currentUser?.uid {
                                            Firestore.firestore().collection("users").document(uid).setData([
                                                "hasCompletedOnboarding": true
                                            ], merge: true) { error in
                                                if let error = error {
                                                    print("⚠️ Onboarding complete write failed: \(error)")
                                                }
                                            }
                                        }
                    // Small delay so the user sees the compose dismiss
                    Task {
                                            try? await Task.sleep(nanoseconds: 400_000_000)
                        Telemetry.onboardingCompleted(); isComplete = true
                    }
                }
            )
        }
        .alert("couldnt save that", isPresented: $moodSaveError) {
            Button("try again") {}
        } message: {
            Text("we couldnt save your mood. check your connection and try again.")
        }
    }
    
    func loadHandle() {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            Task { @MainActor in
                let snapshot = try? await Firestore.firestore()
                    .collection("users").document(uid).getDocumentAsync()
                userHandle = snapshot?.data()?["handle"] as? String ?? "anonymous"
            }
        }

    /// Reads the user doc once and decides whether to show the age + policy
    /// gates. Users who already accepted (e.g. via CreateAccountView's gate)
    /// skip this entirely. Apple/Google new signups hit this path because
    /// AppleSignInHelper creates the user doc without acceptance fields.
    func checkAcceptanceStatus() {
        guard !acceptanceChecked else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Task { @MainActor in
            do {
                let snapshot = try await Firestore.firestore()
                    .collection("users").document(uid).getDocumentAsync()
                let data = snapshot.data() ?? [:]
                let confirmedAdult = data["confirmedAdult"] as? Bool ?? false
                let acceptedVersion = data["acceptedPolicyVersion"] as? Int ?? 0
                // Only lock acceptanceChecked to true on a successful read.
                // If the read fails transiently, the next onAppear will
                // retry instead of silently skipping the gate. Previously
                // a network blip flipped the flag true and a user who had
                // already accepted was shown the age gate a second time
                // (confirmedAdult defaults to false on fetch failure).
                acceptanceChecked = true
                if !confirmedAdult || acceptedVersion < currentPolicyVersion {
                    showAgeGate = true
                }
            } catch {
                print("⚠️ checkAcceptanceStatus failed: \(error)")
                // Leave acceptanceChecked false so a subsequent onAppear retries.
            }
        }
    }

    /// User declined the age or policy gate. We must not let them continue —
    /// sign them out and delete the just-created auth account so nothing is
    /// retained for someone who didn't agree to the terms.
    func declineAndSignOut() {
        // Clear FCM token before deleting the auth account. Without this,
        // the server can keep pushing to a device whose user just opted out.
        PushNotificationManager.shared.clearFCMToken()
        Task { @MainActor in
            do {
                try await Auth.auth().currentUser?.delete()
            } catch {
                print("⚠️ gate decline: auth delete failed, falling back to signOut: \(error)")
                try? Auth.auth().signOut()
            }
            NotificationCenter.default.post(name: .userDidSignOut, object: nil)
            isComplete = false
        }
    }
    func saveMoodAndAdvance() {
        // Previously this fired the Firestore write and advanced the UI
        // without awaiting. On a network/permission failure the user saw
        // the next step and their mood was never persisted — no feedback,
        // and Settings would later show "no mood selected". Now we await
        // the write and only advance on success.
        Task { @MainActor in
            if let uid = Auth.auth().currentUser?.uid, let mood = selectedMood {
                // Mood is sensitive — written to the owner-only private
                // subcollection so other authenticated users can't read it
                // off the main user doc. UserDefaults remains unused
                // because it is unencrypted on disk.
                do {
                    try await Firestore.firestore().collection("users").document(uid)
                        .collection("private").document("data")
                        .setData(["selectedMood": mood], merge: true)
                } catch {
                    print("⚠️ Onboarding mood save failed: \(error)")
                    Telemetry.recordError(error, context: "Onboarding.saveMood")
                    // Surface the error to the user rather than silently
                    // advancing — the mood drives personalization downstream.
                    moodSaveError = true
                    return
                }
            }
            withAnimation(.easeInOut(duration: 0.3)) {
                currentStep = 3
            }
        }
    }
    
    var welcomeStep: some View {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 50, height: 50)
                    Text("t")
                        .font(.custom("Georgia-Italic", size: 34))
                        .foregroundColor(.white)
                }
                .padding(.bottom, 8)
                
                Text("toska")
                    .font(.custom("Georgia-Italic", size: 28))
                    .foregroundColor(.white)
                    .padding(.bottom, 4)
                
                Text("i built this during a breakup.\ni was tired of pretending i was fine\nand had nowhere to say the real stuff.\nso i made somewhere.")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                
                Text("this is a place for the things\nyou cant say out loud.")
                    .font(.custom("Georgia-Italic", size: 13))
                    .foregroundColor(Color.toskaBlue.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
    
    var identityStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "theatermasks")
                .font(.system(size: 28))
                .foregroundColor(Color.toskaBlue)
                .padding(.bottom, 4)
            
            Text("youre anonymous here")
                            .font(.custom("Georgia-Italic", size: 24))
                            .foregroundColor(Color(hex: "111111"))
                        
                        Text("no names. no faces. just what you feel.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "999999"))
                            .padding(.bottom, 12)
            
            HStack {
                Text(userHandle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.toskaBlue)
                Spacer()
                Text("your handle")
                    .font(.system(size: 9))
                    .foregroundColor(Color(hex: "cccccc"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(hex: "e8e2d9"), lineWidth: 0.5)
            )
            .padding(.horizontal, 32)
            
            Text("nobody knows who you are here.\nthats the whole point.")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "cccccc"))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 4)
        }
    }
    
    var moodStep: some View {
            VStack(spacing: 12) {
                Text("where are you at right now")
                                    .font(.custom("Georgia-Italic", size: 24))
                                    .foregroundColor(.white)
                                
                                Text("well show you people who feel the same")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color.toskaBlue)
                                    .padding(.bottom, 8)
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(tags, id: \.name) { tag in
                        Button {
                            selectedMood = tag.name
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tag.icon)
                                    .font(.system(size: 12))
                                Text(tag.name)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(selectedMood == tag.name ? .white : Color(hex: tag.colorHex))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(selectedMood == tag.name ? Color(hex: tag.colorHex).opacity(0.6) : Color(hex: tag.colorHex).opacity(0.1))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selectedMood == tag.name ? Color(hex: tag.colorHex) : Color.clear, lineWidth: 0.5)
                            )
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        
        var firstPostStep: some View {
            VStack(spacing: 16) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(Color.toskaBlue)
                    .padding(.bottom, 4)
                
                Text("say the thing")
                                    .font(.custom("Georgia-Italic", size: 24))
                                    .foregroundColor(.white)
                                
                                Text("the thing youve been holding in.\nthe thing you type and delete.\nsay it here. no one knows its you.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color.white.opacity(0.4))
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(3)
                                    .padding(.bottom, 8)
                
                // Show the prompt as inspiration
                VStack(spacing: 8) {
                    Text(promptTimeLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color.toskaBlue)
                        .tracking(1)
                    
                    Text(promptForMood(selectedMood))
                        .font(.custom("Georgia-Italic", size: 16))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 24)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
                .background(Color.white.opacity(0.04))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.toskaBlue.opacity(0.15), lineWidth: 0.5)
                )
                .padding(.horizontal, 24)
                
                if let mood = selectedMood {
                    HStack(spacing: 5) {
                        let tagData = tags.first(where: { $0.name == mood })
                        Image(systemName: tagData?.icon ?? "tag")
                            .font(.system(size: 10))
                        Text(mood)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(tagColor(for: mood).opacity(0.6))
                    .padding(.top, 4)
                }
            }
        }
    }
