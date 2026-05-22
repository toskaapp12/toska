import SwiftUI
import FirebaseAuth
import FirebaseFirestore

@MainActor
struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var currentStep = 0
    @State private var selectedStage: String? = nil
    // Crystallization beat — when a stage is selected, fetch how many
    // others picked the same one and show it inline below the buttons
    // ("47 others are in this with you tonight"). The aggregate lives
    // at meta/breakupStageCounts and is maintained server-side by
    // onBreakupStageChanged. nil while loading or on read failure
    // (we just hide the line — softer than an error).
    @State private var stageCohortCount: Int? = nil
    @State private var stageCountTask: Task<Void, Never>? = nil
    @State private var selectedMood: String? = nil
    @State private var userHandle = "anonymous"
    @State private var showFirstPostCompose = false
    @State private var firstPostPublished = false

    // Breakup-stage axis. Captured first (as a step) so the rest of the
    // experience can be framed around where the user actually is in
    // their breakup, not just what they're feeling right now. Stored to
    // users/{uid}/private/data alongside selectedMood. Order matters —
    // arranged loosely by recency so the first option is the freshest
    // wound and "still in it" sits in the middle (it's its own thing,
    // not a stage on a timeline).
    let breakupStages: [String] = [
        "it just happened",
        "a few weeks in",
        "months in",
        "a year or more",
        "still in it",
        "they left",
        "i left",
    ]

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
    // Triggers the "couldn't save that" alert when a skip-or-complete flow
    // fails to persist hasCompletedOnboarding (or selectedMood). Without
    // this, the previous code marked the user as done locally even when
    // the Firestore write failed — leading to "stuck mid-onboarding" loops
    // on next launch (ContentView re-checks the flag and re-shows the
    // onboarding cover).
    @State private var onboardingSaveError = false
    @State private var isFinishingOnboarding = false
    
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
            // Step 1 (identity / handle reveal) is the only light-bg step.
            // All other steps are dark — including the new stage step (2)
            // which carries the same emotional weight as mood (3) and
            // first-post (4).
            if currentStep == 1 {
                Color(hex: "faf8f5").ignoresSafeArea()
            } else {
                Color(hex: "0a0908").ignoresSafeArea()
            }

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { index in
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
                case 2: stageStep
                case 3: moodStep
                case 4: firstPostStep
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
                            saveStageAndAdvance()
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
                            // Skip stage → still advance to mood. We don't
                            // mark onboarding complete on stage-skip because
                            // the user hasn't yet seen the mood / first-post
                            // steps which finish the flow.
                            withAnimation(.easeInOut(duration: 0.3)) {
                                currentStep = 3
                            }
                        } label: {
                            Text("skip")
                                .font(.system(size: 11))
                                .foregroundColor(Color.white.opacity(0.3))
                        }
                    } else if currentStep == 3 {
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
                            finishOnboarding(persistMood: true)
                        } label: {
                            Text(isFinishingOnboarding ? "saving…" : "skip")
                                .font(.system(size: 11))
                                .foregroundColor(Color.white.opacity(0.3))
                        }
                        .disabled(isFinishingOnboarding)
                    } else if currentStep == 4 {
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
                            finishOnboarding(persistMood: true)
                        } label: {
                            Text(isFinishingOnboarding ? "saving…" : "skip for now")
                                .font(.system(size: 11))
                                .foregroundColor(Color.white.opacity(0.3))
                        }
                        .disabled(isFinishingOnboarding)
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
            EdgeSwipeDismissWrapper {
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
        }
        .fullScreenCover(isPresented: $showPolicyAcceptance) {
            EdgeSwipeDismissWrapper {
            PolicyAcceptanceView(
                onAccept: {
                    Task { @MainActor in
                        guard let uid = Auth.auth().currentUser?.uid else {
                            showPolicyAcceptance = false
                            return
                        }
                        do {
                            try await recordPolicyAcceptance(for: uid)
                            showPolicyAcceptance = false
                        } catch {
                            print("⚠️ recordPolicyAcceptance failed: \(error)")
                            Telemetry.recordError(error, context: "recordPolicyAcceptance.signup.v\(currentPolicyVersion)")
                            // Leave the modal up; user can retry. The user
                            // is mid-signup, so re-prompting on next launch
                            // would mean seeing this modal twice.
                        }
                    }
                },
                onDecline: {
                    Telemetry.policyDeclined(version: currentPolicyVersion, atSignup: true)
                    showPolicyAcceptance = false
                    declineAndSignOut()
                }
            )
            }
        }
        .fullScreenCover(isPresented: $showFirstPostCompose) {
            EdgeSwipeDismissWrapper {
            ComposeView(
                initialText: "",
                initialTag: selectedMood,
                onPostSuccess: {
                    showFirstPostCompose = false
                    firstPostPublished = true
                    // Small delay so the user sees the compose dismiss,
                    // then await the hasCompletedOnboarding write before
                    // flipping isComplete. finishOnboarding internally
                    // surfaces failures via onboardingSaveError so the
                    // user can retry instead of getting stuck mid-flow.
                    Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        finishOnboarding(persistMood: false)
                    }
                }
            )
            }
        }
        .alert("couldnt save that", isPresented: $moodSaveError) {
            Button("try again") {}
        } message: {
            Text("we couldnt save your mood. check your connection and try again.")
        }
        .alert("couldnt finish that", isPresented: $onboardingSaveError) {
            Button("try again") {}
        } message: {
            Text("we couldnt save your progress. check your connection and try again.")
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
    func saveStageAndAdvance() {
        // Stage is the load-bearing personalization signal — it tells us
        // where the user is in their breakup, which the rest of the app
        // can frame around (feed weighting, prompt selection, anniversary
        // logic). Stored alongside selectedMood in the owner-only private
        // subcollection. Advance optimistically: a transient write
        // failure shouldn't block the user from continuing onboarding,
        // and Settings can re-prompt if the value didn't land.
        Task { @MainActor in
            if let uid = Auth.auth().currentUser?.uid, let stage = selectedStage {
                do {
                    try await Firestore.firestore().collection("users").document(uid)
                        .collection("private").document("data")
                        .setData(["breakupStage": stage], merge: true)
                } catch {
                    print("⚠️ Onboarding stage save failed: \(error)")
                    Telemetry.recordError(error, context: "Onboarding.saveStage")
                    // Best-effort — fall through to advance. Unlike mood,
                    // there's no in-app surface yet that breaks if stage
                    // is missing, and we don't want a network blip to
                    // strand the user on the stage step.
                }
            }
            withAnimation(.easeInOut(duration: 0.3)) {
                currentStep = 3
            }
        }
    }

    /// Awaits the hasCompletedOnboarding write and (optionally) the mood
    /// write, only flipping `isComplete` if both succeed. Replaces the
    /// fire-and-forget shape that left the user "stuck mid-onboarding"
    /// when the writes silently failed: the local flag flipped, but the
    /// server state didn't, so the next launch re-showed onboarding.
    /// Surfaces failures via the existing onboardingSaveError alert so
    /// the user can retry.
    ///
    /// `persistMood` is true when the caller wants the currently-selected
    /// mood pinned to the private/data subcollection alongside the flag.
    /// The mood-only / flag-only branches both go through this method to
    /// keep the rollback semantics identical.
    func finishOnboarding(persistMood: Bool) {
        guard !isFinishingOnboarding else { return }
        isFinishingOnboarding = true
        Task { @MainActor in
            defer { isFinishingOnboarding = false }
            guard let uid = Auth.auth().currentUser?.uid else {
                // No auth means the cover will dismiss into a sign-in
                // surface anyway; flip and let ContentView re-resolve.
                Telemetry.onboardingCompleted()
                isComplete = true
                return
            }
            let userRef = Firestore.firestore().collection("users").document(uid)
            do {
                try await userRef.setData(
                    ["hasCompletedOnboarding": true],
                    merge: true
                )
                if persistMood, let mood = selectedMood {
                    try await userRef.collection("private").document("data")
                        .setData(["selectedMood": mood], merge: true)
                }
            } catch {
                Telemetry.recordError(error, context: "Onboarding.finishOnboarding")
                onboardingSaveError = true
                return
            }
            Telemetry.onboardingCompleted()
            isComplete = true
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
                currentStep = 4
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
                
                Text("this is a place for the things\nyou wish youd said to them.")
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
    
    var stageStep: some View {
        VStack(spacing: 12) {
            Text("where are you in it")
                .font(.custom("Georgia-Italic", size: 24))
                .foregroundColor(.white)

            Text("nobody else has to know.\nthis just helps us know what to show you.")
                .font(.system(size: 11))
                .foregroundColor(Color.toskaBlue)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.bottom, 8)

            VStack(spacing: 6) {
                ForEach(breakupStages, id: \.self) { stage in
                    Button {
                        selectedStage = stage
                        fetchStageCohortCount(for: stage)
                    } label: {
                        Text(stage)
                            .font(.system(size: 13, weight: selectedStage == stage ? .semibold : .regular))
                            .foregroundColor(selectedStage == stage ? .white : Color.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                selectedStage == stage
                                    ? Color.toskaBlue.opacity(0.55)
                                    : Color.white.opacity(0.05)
                            )
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(
                                        selectedStage == stage
                                            ? Color.toskaBlue
                                            : Color.white.opacity(0.08),
                                        lineWidth: 0.5
                                    )
                            )
                    }
                }
            }
            .padding(.horizontal, 24)

            // Crystallization moment — once a stage is picked, show a
            // single line of social proof with the live cohort count.
            // Hidden while loading or on read failure (count == nil) and
            // when no stage is selected yet (selectedStage == nil).
            if let stage = selectedStage, let n = stageCohortCount, n > 0 {
                Text(cohortLine(forCount: n, stage: stage))
                    .font(.custom("Georgia-Italic", size: 13))
                    .foregroundColor(Color.toskaBlue.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: stageCohortCount)
    }

    /// Renders the social-proof line under the stage list. Singular vs.
    /// plural copy tunes for n=1 ("one other person...") so the line
    /// doesn't read as off-by-one. The displayed count is read at
    /// stage-button tap time, BEFORE saveStageAndAdvance fires the
    /// onBreakupStageChanged trigger — so for first-time onboarders
    /// (the dominant case) the user is not yet in the aggregate and
    /// rawCount is already the "others" count. Subtracting 1 here
    /// would under-state by one; keep rawCount as-is.
    func cohortLine(forCount rawCount: Int, stage: String) -> String {
        if rawCount <= 0 {
            return "youre the first one tonight."
        } else if rawCount == 1 {
            return "one other person is in this with you tonight."
        } else {
            return "\(rawCount) others are in this with you tonight."
        }
    }

    /// Reads meta/breakupStageCounts and pulls the count for the chosen
    /// stage. Cancels any in-flight request when the user picks a
    /// different stage so the latest selection wins. The trigger that
    /// maintains the aggregate (functions/index.js: onBreakupStageChanged)
    /// fires when saveStageAndAdvance writes to private/data, so the
    /// count reflects the user's own selection too — see cohortLine
    /// for the -1 adjustment.
    func fetchStageCohortCount(for stage: String) {
        stageCountTask?.cancel()
        stageCohortCount = nil
        stageCountTask = Task { @MainActor in
            do {
                let snap = try await Firestore.firestore()
                    .collection("meta").document("breakupStageCounts")
                    .getDocumentAsync()
                guard !Task.isCancelled, self.selectedStage == stage else { return }
                let raw = snap.data()?[stage]
                if let asInt = raw as? Int { self.stageCohortCount = asInt }
                else if let asInt64 = raw as? Int64 { self.stageCohortCount = Int(asInt64) }
                else if let asNumber = raw as? NSNumber { self.stageCohortCount = asNumber.intValue }
                else { self.stageCohortCount = 0 }
            } catch {
                // Silent fallback — the line just doesn't render. Better
                // than surfacing a load error inside the onboarding flow.
                print("⚠️ fetchStageCohortCount failed: \(error)")
            }
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
