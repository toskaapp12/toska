import Foundation
import Combine
import SwiftUI
import FirebaseFirestore

// MARK: - Client policy / kill switch (2026-09-21)
//
// Live mirror of config/clientPolicy — the server-side lever that exists so
// a bad shipped build or a misbehaving feature can be handled WITHOUT a
// full App Store review cycle:
//   minBuild : builds below this show a blocking update screen.
//   kill     : per-feature flags — compose / replies / gifs / search / share.
//   notice   : app-wide maintenance banner text.
//
// FAIL-OPEN by construction: a missing doc, a read error, or an absent field
// means "everything enabled, no minimum". The switch can only ever turn
// things off deliberately — its absence can never brick the app. Writes are
// rules-denied for clients (Admin SDK only), so no user can flip switches.
@MainActor
final class ClientPolicyManager: ObservableObject {
    static let shared = ClientPolicyManager()

    @Published private(set) var minBuild = 0
    @Published private(set) var kill: [String: Bool] = [:]
    @Published private(set) var notice = ""

    private var listener: ListenerRegistration?

    var updateRequired: Bool {
        let current = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? Int.max
        return current < minBuild
    }

    /// Fail-open feature gate: only an explicit `true` kill flag disables.
    func enabled(_ feature: String) -> Bool { kill[feature] != true }

    func start() {
        guard listener == nil else { return }
        listener = Firestore.firestore().collection("config").document("clientPolicy")
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let d = snap?.data() ?? [:]
                    self.minBuild = d["minBuild"] as? Int ?? 0
                    self.kill = d["kill"] as? [String: Bool] ?? [:]
                    self.notice = d["notice"] as? String ?? ""
                }
            }
    }
}

// MARK: - Blocking update screen
//
// Shown over everything when the running build is below minBuild. Paper
// styling per the design system; the only action is the App Store.
struct UpdateRequiredView: View {
    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("toska")
                    .font(ToskaFont.serifMedium(30))
                    .foregroundColor(ToskaColor.text)
                Text("this version needs an update")
                    .font(ToskaFont.serif(19))
                    .foregroundColor(ToskaColor.text)
                Text("something important changed on our side. update to keep going — your words are safe.")
                    .font(ToskaFont.sans(13.5))
                    .foregroundColor(ToskaColor.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button {
                    if let url = URL(string: "https://apps.apple.com/app/id6762859709") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("update toska")
                        .font(ToskaFont.sans(14, weight: .semibold))
                        .foregroundColor(ToskaColor.onAccent)
                        .frame(height: 54)
                        .padding(.horizontal, 36)
                        .background(ToskaColor.accent, in: Capsule())
                }
                .padding(.top, 8)
            }
        }
    }
}
