import SwiftUI

/// Shows `content` at its natural height, and only when that is taller than
/// `maxHeight` puts it in a `ScrollView` of exactly `maxHeight`.
///
/// A `MenuBarExtra(.window)` sizes its window to the content's *ideal* size,
/// which rules out the obvious approaches:
/// - a bare `ScrollView` has almost no ideal height, so the popover collapses
///   to just the footer;
/// - `.frame(maxHeight:)` makes the view flexible, and the window then grows
///   to `maxHeight`, leaving a screenful of empty space under the content.
///
/// So the content's natural height is measured, and the non-scrolling path has
/// no flexible frame at all. The measurement cannot loop: inside the
/// `ScrollView` the content is still laid out at its natural height, so it
/// reports the same value it did outside.
struct FittingScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content

    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        if naturalHeight > maxHeight {
            ScrollView {
                measured
            }
            .frame(height: maxHeight)
        } else {
            measured
        }
    }

    private var measured: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                naturalHeight = height
            }
    }
}

enum PopoverMetrics {
    /// Tallest a popover screen may be before it scrolls: most of the visible
    /// screen, leaving room for the menu bar and the footer.
    @MainActor
    static var maxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(360, screen - 120)
    }
}
