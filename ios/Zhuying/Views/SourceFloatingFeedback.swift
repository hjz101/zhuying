import SwiftUI
import UIKit

/// Feedback belongs to the visible page, independently of its scroll position.
private struct SourceFloatingFeedback: ViewModifier {
    @Environment(\.themeAppearance) private var appearance
    let message: String?
    let identifier: String
    @State private var visible = false

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if visible, let message, !message.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12).accessibilityIdentifier(identifier)
                    Button { visible = false } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 44, height: 44)
                    }.accessibilityLabel("关闭反馈")
                }
                .padding(.leading, 16).padding(.trailing, 2)
                .foregroundStyle(appearance.palette.green)
                .background(appearance.palette.card, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(appearance.palette.line))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.horizontal, 18).padding(.top, 8)
                .accessibilityIdentifier(identifier + "Overlay")
            }
        }
        .task(id: message) {
            visible = message?.isEmpty == false
            guard visible else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            visible = false
        }
    }
}

extension View {
    func sourceFloatingFeedback(_ message: String?, identifier: String) -> some View {
        modifier(SourceFloatingFeedback(message: message, identifier: identifier))
    }
}
