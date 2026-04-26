import UIKit

enum HapticStyle {
    case postAppear
    case feltThis
    case milestone
    case compose
    case send
    case streak
    case whisper
    case tabSwitch
}

@MainActor
struct HapticManager {
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static let selectionGenerator = UISelectionFeedbackGenerator()

    /// Call once at app launch to prewarm the haptic engine. Without
    /// `.prepare()`, the very first call to any generator's `impactOccurred()`
    /// has a 50–100 ms latency while iOS spins up the Taptic Engine. After
    /// the first warm-up, every subsequent haptic is instant. The first
    /// user-facing haptic in a session (typically a tab switch or a like)
    /// would otherwise feel laggy compared to all the ones that follow.
    static func prepareAll() {
        softGenerator.prepare()
        lightGenerator.prepare()
        mediumGenerator.prepare()
        rigidGenerator.prepare()
        notificationGenerator.prepare()
        selectionGenerator.prepare()
    }

    static func play(_ style: HapticStyle) {
        switch style {
        case .postAppear:
            softGenerator.impactOccurred(intensity: 0.4)
        case .feltThis:
            lightGenerator.impactOccurred()
        case .milestone:
            notificationGenerator.notificationOccurred(.success)
        case .compose:
            softGenerator.impactOccurred(intensity: 0.3)
        case .send:
            mediumGenerator.impactOccurred()
        case .streak:
            rigidGenerator.impactOccurred(intensity: 0.6)
        case .whisper:
            softGenerator.impactOccurred(intensity: 0.2)
        case .tabSwitch:
            selectionGenerator.selectionChanged()
        }
    }
}
