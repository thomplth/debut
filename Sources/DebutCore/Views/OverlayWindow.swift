import AppKit

public final class OverlayWindow: NSWindow, @unchecked Sendable {
    private let overlayView: OverlayContentView

    public init() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        self.overlayView = OverlayContentView()

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = overlayView
    }

    public func update(viewModel: OverlayViewModel) {
        overlayView.update(viewModel: viewModel)
    }

    public func showOverlay() {
        guard let screen = NSScreen.main else { return }
        setFrame(screen.frame, display: true)
        makeKeyAndOrderFront(nil)
        overlayView.animateIn()
    }

    public func hideOverlay() {
        overlayView.animateOut { [weak self] in
            DispatchQueue.main.async {
                self?.orderOut(nil)
            }
        }
    }
}

final class OverlayContentView: NSView {
    private let backdropView: NSVisualEffectView
    private let stackContainer: NSView
    private var plateViews: [PlateView] = []

    override init(frame: NSRect) {
        self.backdropView = NSVisualEffectView()
        self.stackContainer = NSView()
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        backdropView.blendingMode = .behindWindow
        backdropView.material = .hudWindow
        backdropView.state = .active
        backdropView.alphaValue = 0
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdropView)

        stackContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackContainer)

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackContainer.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.85),
        ])
    }

    func update(viewModel: OverlayViewModel) {
        plateViews.forEach { $0.removeFromSuperview() }
        plateViews.removeAll()

        let plates = viewModel.plates
        guard !plates.isEmpty else { return }

        let spacing: CGFloat = 16
        var yOffset: CGFloat = 0
        var totalHeight: CGFloat = 0

        for plate in plates.reversed() {
            let plateView = PlateView(
                plate: plate,
                isSelected: plate.index == viewModel.activeStageIndex,
                selectedAppIndex: plate.index == viewModel.activeStageIndex ? viewModel.selectedAppIndex : nil
            )
            plateView.translatesAutoresizingMaskIntoConstraints = false
            stackContainer.addSubview(plateView)
            plateViews.append(plateView)

            NSLayoutConstraint.activate([
                plateView.centerXAnchor.constraint(equalTo: stackContainer.centerXAnchor),
                plateView.bottomAnchor.constraint(equalTo: stackContainer.bottomAnchor, constant: -yOffset),
                plateView.heightAnchor.constraint(equalToConstant: PlateView.plateHeight),
            ])

            yOffset += PlateView.plateHeight + spacing
            totalHeight = yOffset - spacing
        }

        stackContainer.constraints.filter { $0.firstAttribute == .height }.forEach { $0.isActive = false }
        stackContainer.heightAnchor.constraint(equalToConstant: totalHeight).isActive = true

        let activeIndex = viewModel.activeStageIndex
        let activeCenterY = totalHeight / 2
        let plateFullHeight = PlateView.plateHeight + spacing
        let activePlateCenter = totalHeight - (CGFloat(activeIndex) * plateFullHeight + PlateView.plateHeight / 2)
        let offset = activeCenterY - activePlateCenter
        stackContainer.constraints.filter { $0.firstAttribute == .centerY }.forEach { $0.constant = offset }
    }

    func animateIn() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            backdropView.animator().alphaValue = 1.0
            stackContainer.animator().alphaValue = 1.0
        }
    }

    func animateOut(completion: @escaping @Sendable () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            backdropView.animator().alphaValue = 0.0
            stackContainer.animator().alphaValue = 0.0
        }, completionHandler: completion)
    }
}
