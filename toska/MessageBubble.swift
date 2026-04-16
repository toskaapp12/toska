import SwiftUI

struct MessageBubble: View {
    let text: String
    let time: String
    let isMe: Bool
    var senderHandle: String? = nil
    var isSeen: Bool = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isMe { Spacer(minLength: 60) }
            
            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                if let sender = senderHandle, !isMe {
                    Text(sender)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "9198a8"))
                }
                
                HStack(spacing: 0) {
                    if !isMe {
                        Rectangle()
                            .fill(Color(hex: "9198a8").opacity(0.3))
                            .frame(width: 2)
                            .cornerRadius(1)
                    }
                    
                    Text(text)
                        .font(.custom("Georgia", size: 14))
                        .foregroundColor(isMe ? Color(hex: "2a2a2a") : Color(hex: "3a3a3a"))
                        .lineSpacing(3)
                        .padding(.horizontal, isMe ? 0 : 10)
                        .padding(.vertical, 2)
                }
                
                HStack(spacing: 4) {
                    Text(time)
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "d0d0d0"))
                    
                    if isMe && isSeen {
                        Text("seen")
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "9198a8").opacity(0.4))
                    }
                }
            }
            
            if !isMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
