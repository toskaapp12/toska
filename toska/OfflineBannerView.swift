import SwiftUI

@MainActor
struct OfflineBannerView: View {
    var network = NetworkMonitor.shared
    var body: some View {
        if network.showOfflineBanner {
            HStack(spacing: 8) {
                Image(systemName: network.isConnected ? "wifi" : "wifi.slash")
                    .font(.system(size: 11))
                Text(network.isConnected ? "back online" : "no connection · tap to retry")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(network.isConnected ? Color.toskaGreen : Color.toskaError)
            .contentShape(Rectangle())
            .onTapGesture {
                // Tap acts as a soft refresh hint — the offline-detection
                // path is passive (NWPathMonitor) so tapping doesn't itself
                // re-check connectivity, but it gives the user agency to
                // close the banner and re-trigger their last action manually.
                guard !network.isConnected else { return }
                NotificationCenter.default.post(
                    name: NSNotification.Name("UserRequestedNetworkRetry"),
                    object: nil
                )
            }
            .accessibilityLabel(network.isConnected ? "Back online" : "No connection")
            .accessibilityHint(network.isConnected ? "" : "Double-tap to retry")
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: network.showOfflineBanner)
            .animation(.easeInOut(duration: 0.3), value: network.isConnected)
        }
    }
}
