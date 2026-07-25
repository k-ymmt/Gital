import SwiftUI

/// Multi-line text input with the app's rounded-border chrome and a
/// placeholder overlay; shared by the commit and agent composers.
struct PlaceholderTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var height: CGFloat = 58

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12.5))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.separator, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 10)
                        .allowsHitTesting(false)
                }
            }
    }
}
