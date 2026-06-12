import SwiftUI

@MainActor
struct OfflineBannerView: View {
    var network = NetworkMonitor.shared
    var body: some View {
        if network.showOfflineBanner {
            HStack(spacing: 8) {
                Image(systemName: network.isConnected ? "wifi" : "wifi.slash")
                    .font(.system(size: 11))
                Text(network.isConnected ? "back online" : "no connection")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(network.isConnected ? Color.toskaFollowGreen : Color.toskaErrorRed)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: network.showOfflineBanner)
            .animation(.easeInOut(duration: 0.3), value: network.isConnected)
        }
    }
}
