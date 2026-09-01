import SwiftUI

/// The flat switcher: one plate holding every window from every space, in global MRU order.
///
/// Structurally this is a single stage that happens to contain the whole session, so it draws
/// with the stage's own card, grid and glass rather than a parallel set that could drift from
/// them. What it deliberately does not inherit is the stack: there are no spaces to focus,
/// scroll between, or drop a window onto.
public struct AltTabOverlayView: View {
    public let viewModel: AltTabOverlayViewModel

    public init(viewModel: AltTabOverlayViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geo in
            let metrics = viewModel.metrics(containerSize: geo.size)
            let layout = viewModel.layout(containerSize: geo.size)
            let plateSize = layout.stageSize

            ZStack {
                ForEach(Array(viewModel.windows.enumerated()), id: \.element.id) { index, window in
                    WindowPreviewView(
                        window: window,
                        isWindowSelected: viewModel.isSelected(index),
                        metrics: metrics,
                        appearance: viewModel.appearance
                    )
                    .offset(layout.cardOffsetFromCenter(at: index))
                }
            }
            .frame(width: plateSize.width, height: plateSize.height)
            .background {
                Color.clear.modifier(LiquidGlassModifier(
                    cornerRadius: CGFloat(viewModel.appearance.stageCornerRadius)
                        * metrics.scaleFactor,
                    appearance: viewModel.appearance
                ))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
