import UIKit

enum HapticStyle {
    case postAppear      // soft notification when scrolling past special content
    case feltThis        // light impact on like
    case milestone       // success notification
    case compose         // soft when opening compose
    case send            // medium on post/send
    case streak          // rigid for streak celebration
    case whisper         // soft for ephemeral content
    case tabSwitch       // selection changed
}

struct HapticManager {
    static func play(_ style: HapticStyle) {
        switch style {
        case .postAppear:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.4)
        case .feltThis:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .milestone:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .compose:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.3)
        case .send:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .streak:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.6)
        case .whisper:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.2)
        case .tabSwitch:
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
