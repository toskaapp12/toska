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

            VStack(alignment: isMe ? .trailing : .leading, spacing: 5) {
                if let sender = senderHandle, !isMe {
                    Text(sender)
                        .font(.system(size: 12, weight: .semibold))
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
                        .font(.custom("Georgia", size: 16))
                        .foregroundColor(isMe ? Color.toskaTextDark : Color(hex: "2a2a2a"))
                        .lineSpacing(4)
                        .padding(.horizontal, isMe ? 0 : 12)
                        .padding(.vertical, 2)
                }

                HStack(spacing: 4) {
                    Text(time)
                        .font(.system(size: 10))
                        .foregroundColor(Color.toskaDivider)

                    if isMe && isSeen {
                        Text("seen")
                            .font(.system(size: 10))
                            .foregroundColor(Color.toskaBlue.opacity(0.5))
                    }
                }
            }

            if !isMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
