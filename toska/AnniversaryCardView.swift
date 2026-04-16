import SwiftUI
import FirebaseAuth
import FirebaseFirestore

@MainActor
struct AnniversaryCardView: View {
    let post: AnniversaryPostData
    let postId: String

    @State private var showReflection = false
    @State private var reflectionText = ""
    @State private var reflectionSaved = false
    @State private var isSaving = false
    @State private var showNameWarning = false
    @State private var showGentleCheck = false
    @State private var gentleCheckLevel: CrisisLevel = .soft
    @State private var saveError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "c9a97a"))

                Text("one year ago today")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "c9a97a"))
                    .tracking(0.3)

                Spacer()

                Text(post.dateString)
                    .font(.system(size: 9, weight: .light))
                    .foregroundColor(Color(hex: "c9a97a").opacity(0.5))
            }
            .padding(.bottom, 10)

            Text(post.text)
                .font(.custom("Georgia", size: 14))
                .foregroundColor(Color(hex: "2a2a2a"))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)

            if let tag = post.tag {
                Text(tag)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(tagColor(for: tag).opacity(0.6))
                    .padding(.bottom, 8)
            }

            if !saveError.isEmpty {
                Text(saveError)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "c45c5c"))
                    .padding(.bottom, 4)
            }

            if reflectionSaved {
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle()
                        .fill(Color(hex: "c9a97a").opacity(0.2))
                        .frame(height: 0.5)

                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 8))
                        Text("how you feel now")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(Color(hex: "c9a97a").opacity(0.6))
                    .padding(.top, 4)

                    Text(reflectionText)
                        .font(.custom("Georgia", size: 13))
                        .foregroundColor(Color(hex: "2a2a2a").opacity(0.8))
                        .lineSpacing(3)
                }
            } else if showReflection {
                VStack(alignment: .leading, spacing: 8) {
                    Rectangle()
                        .fill(Color(hex: "c9a97a").opacity(0.2))
                        .frame(height: 0.5)

                    Text("how do you feel about this now?")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "c9a97a").opacity(0.7))
                        .padding(.top, 4)

                    TextField("reflect on this moment...", text: $reflectionText, axis: .vertical)
                        .font(.custom("Georgia", size: 13))
                        .foregroundColor(Color(hex: "2a2a2a"))
                        .lineLimit(4)

                    HStack {
                        Spacer()
                        Button {
                            attemptSaveReflection()
                        } label: {
                            HStack(spacing: 4) {
                                if isSaving {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .tint(.white)
                                } else {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10))
                                }
                                Text("save")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                reflectionText.isEmpty || isSaving
                                    ? Color(hex: "d0d0d0")
                                    : Color(hex: "c9a97a")
                            )
                            .cornerRadius(14)
                        }
                        .disabled(reflectionText.isEmpty || isSaving)
                    }
                }
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showReflection = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 10))
                        Text("how do you feel about this now?")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(Color(hex: "c9a97a"))
                    .padding(.top, 4)
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(hex: "c9a97a").opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: Color(hex: "c9a97a").opacity(0.06), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .onAppear {
            checkExistingReflection()
        }
        .alert("keep it anonymous", isPresented: $showNameWarning) {
            Button("edit") {}
            Button("save anyway", role: .destructive) {
                if let level = crisisCheckLevelRespectingSetting(for: reflectionText) {
                    gentleCheckLevel = level
                    showGentleCheck = true
                } else {
                    saveReflection()
                }
            }
        } message: {
            Text("your reflection may include a name or identifying info. toska is anonymous for everyone.")
        }
        .overlay {
            if showGentleCheck {
                CrisisCheckInView(
                    isPresented: $showGentleCheck,
                    level: gentleCheckLevel,
                    onProceed: { saveReflection() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showGentleCheck)
    }

    // MARK: - Functions

    func checkExistingReflection() {
           guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else { return }
           Task { @MainActor in
               do {
                   let snapshot = try await Firestore.firestore()
                       .collection("posts").document(postId)
                       .collection("reflections").document(uid)
                       .getDocumentAsync()
                   if let data = snapshot.data(), snapshot.exists {
                       reflectionText = data["text"] as? String ?? ""
                       reflectionSaved = true
                   }
               } catch {
                   print("⚠️ checkExistingReflection failed: \(error)")
               }
           }
       }

    func attemptSaveReflection() {
        guard !reflectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if containsNameOrIdentifyingInfo(reflectionText) {
            showNameWarning = true
            return
        }
        if let level = crisisCheckLevelRespectingSetting(for: reflectionText) {
            gentleCheckLevel = level
            showGentleCheck = true
            return
        }
        saveReflection()
    }

    func saveReflection() {
        guard let uid = Auth.auth().currentUser?.uid,
              !postId.isEmpty,
              !isSaving else { return }
        let trimmedReflection = reflectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReflection.isEmpty else { return }
        isSaving = true
        saveError = ""
        Task { @MainActor in
                    do {
                        try await Firestore.firestore()
                            .collection("posts").document(postId)
                            .collection("reflections").document(uid)
                            .setData([
                                "authorId": uid,
                                "text": trimmedReflection,
                                "createdAt": FieldValue.serverTimestamp()
                            ])
                        isSaving = false
                        saveError = ""
                        withAnimation(.easeInOut(duration: 0.3)) {
                            reflectionSaved = true
                        }
                    } catch {
                        print("⚠️ saveReflection failed: \(error)")
                        isSaving = false
                        saveError = "couldn't save. try again."
                    }
                }
    }
}
