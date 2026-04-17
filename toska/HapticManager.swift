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
