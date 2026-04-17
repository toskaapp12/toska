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
                        .foregroundColor(Color.toskaBlue)
                }
                
                HStack(spacing: 0) {
                    if !isMe {
                        Rectangle()
                            .fill(Color.toskaBlue.opacity(0.3))
                            .frame(width: 2)
                            .cornerRadius(1)
                    }
                    
                    Text(text)
                        .font(.custom("Georgia", size: 14))
                        .foregroundColor(LateNightTheme.primaryText)
                        .lineSpacing(Toska.bodyLineSpacing)
                        .padding(.horizontal, isMe ? 0 : 10)
                        .padding(.vertical, 2)
                }
                
                HStack(spacing: 4) {
                    Text(time)
                        .font(.system(size: 9))
                        .foregroundColor(Color.toskaDivider)
                    
                    if isMe && isSeen {
                        Text("seen")
                            .font(.system(size: 9))
                            .foregroundColor(Color.toskaBlue.opacity(0.4))
                    }
                }
            }
            
            if !isMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
