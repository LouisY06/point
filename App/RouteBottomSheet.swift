import SwiftUI

/// A bounded route surface: the handle drags, content scrolls, and buttons never toggle the sheet.
struct RouteBottomSheet<Header: View, Details: View>: View {
    let maxHeight: CGFloat
    let bottomInset: CGFloat
    let onHeight: (CGFloat) -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let details: () -> Details
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed = false
    @State private var drag: CGFloat = 0
    @State private var headerHeight: CGFloat = 160
    @State private var detailsHeight: CGFloat = 260

    private var minimum: CGFloat { min(maxHeight, 44 + headerHeight + bottomInset + 8) }
    private var maximum: CGFloat { min(maxHeight, 44 + headerHeight + detailsHeight + bottomInset + 26) }
    private var snapped: CGFloat { collapsed ? minimum : maximum }
    private var visible: CGFloat { min(maximum, max(minimum, snapped - drag)) }
    private var canCollapse: Bool { maximum - minimum > 8 }
    private var movement: Animation { reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.24) }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(movement) { collapsed.toggle() }
            } label: {
                Capsule().fill(Color.secondary).frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity).frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Expand trip details" : "Collapse trip details")
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            .accessibilityHidden(!canCollapse)
            .disabled(!canCollapse)
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    withAnimation(movement) {
                        collapsed = snapped - value.predictedEndTranslation.height < (minimum + maximum) / 2
                        drag = 0
                    }
                })

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header()
                            .id("route-header")
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                        details()
                            .opacity(visible > minimum + 1 || !canCollapse ? 1 : 0)
                            .accessibilityHidden(collapsed && canCollapse)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
                    }
                    .padding(.horizontal, 24)
                }
                .scrollDisabled(collapsed && canCollapse)
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.top)
                .onChange(of: collapsed) { _, isCollapsed in
                    if isCollapsed { scroll.scrollTo("route-header", anchor: .top) }
                }
                .onChange(of: headerHeight) { _, _ in
                    // A new trip instruction can change the header's height. Keep its start
                    // visible instead of inheriting a scroll offset from the previous phase.
                    scroll.scrollTo("route-header", anchor: .top)
                }
            }
            // Keep safe-area space outside the scroll viewport; otherwise collapsed details peek
            // through this padding even though VoiceOver correctly considers them hidden.
            Color.clear.frame(height: bottomInset + 8)
        }
        .frame(height: visible, alignment: .top)
        .background(PointTheme.background, in: UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
        .onChange(of: snapped) { _, height in onHeight(height) }
        .onAppear { onHeight(snapped) }
    }
}
