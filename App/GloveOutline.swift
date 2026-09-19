import SwiftUI
import UIKit

/// Use Apple's carefully proportioned outline rather than an improvised hand drawing.
struct GloveOutline: View {
    private let image = UIImage(systemName: "hand.raised", withConfiguration:
        UIImage.SymbolConfiguration(pointSize: 240, weight: .ultraLight))!
    var body: some View {
        Image(uiImage: image).renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(.primary.opacity(0.9))
            .accessibilityHidden(true)
    }
}
