import SwiftUI
/// The approved drawing includes its microphone. HandBackup retains the previous version.
struct GloveOutline: View {
    var body: some View {
        Image("HandPreferred").resizable().scaledToFit()
            .clipShape(FlatWristCut())
            .accessibilityHidden(true)
    }
}

/// Cut in source coordinates without redrawing, recentering, or scaling the art.
private struct FlatWristCut: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                    height: rect.height * 1515 / 1692))
    }
}
