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

public final class OverlayContentView: NSView {
    private let stackContainer: NSView
    private var plateViews: [PlateView] = []
    private var stackCenterYConstraint: NSLayoutConstraint?
    private var stackWidthConstraint: NSLayoutConstraint?

    public override init(frame: NSRect) {
        self.stackContainer = NSView()
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        stackContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackContainer)

        let centerY = stackContainer.centerYAnchor.constraint(equalTo: centerYAnchor)
        stackCenterYConstraint = centerY

        NSLayoutConstraint.activate([
            stackContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerY,
        ])
    }

    public func update(viewModel: OverlayViewModel) {
        plateViews.forEach { $0.removeFromSuperview() }
        plateViews.removeAll()
        stackWidthConstraint?.isActive = false

        let plates = viewModel.plates
        guard !plates.isEmpty else { return }

        let spacing: CGFloat = 12

        let maxAppCount = plates.map(\.apps.count).max() ?? 0
        let plateWidth = PlateView.plateWidth(forAppCount: maxAppCount)

        var views: [PlateView] = []
        for plate in plates {
            let plateView = PlateView(
                plate: plate,
                isSelected: plate.index == viewModel.activeStageIndex,
                selectedAppIndex: plate.index == viewModel.activeStageIndex ? viewModel.selectedAppIndex : nil
            )
            plateView.translatesAutoresizingMaskIntoConstraints = false
            stackContainer.addSubview(plateView)
            views.append(plateView)

            NSLayoutConstraint.activate([
                plateView.centerXAnchor.constraint(equalTo: stackContainer.centerXAnchor),
                plateView.widthAnchor.constraint(equalToConstant: plateWidth),
                plateView.heightAnchor.constraint(equalToConstant: PlateView.plateHeight),
            ])
        }

        for (i, view) in views.enumerated() {
            if i == 0 {
                view.topAnchor.constraint(equalTo: stackContainer.topAnchor).isActive = true
            } else {
                view.topAnchor.constraint(equalTo: views[i - 1].bottomAnchor, constant: spacing).isActive = true
            }
        }
        if let lastView = views.last {
            lastView.bottomAnchor.constraint(equalTo: stackContainer.bottomAnchor).isActive = true
        }

        let wc = stackContainer.widthAnchor.constraint(equalToConstant: plateWidth)
        wc.isActive = true
        stackWidthConstraint = wc

        let totalHeight = CGFloat(plates.count) * PlateView.plateHeight + CGFloat(plates.count - 1) * spacing
        let activeIndex = viewModel.activeStageIndex
        let activePlateTop = CGFloat(activeIndex) * (PlateView.plateHeight + spacing)
        let activePlateCenter = activePlateTop + PlateView.plateHeight / 2
        stackCenterYConstraint?.constant = totalHeight / 2 - activePlateCenter

        plateViews = views
    }

    func animateIn() {
        stackContainer.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            stackContainer.animator().alphaValue = 1.0
        }
    }

    func animateOut(completion: @escaping @Sendable () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            stackContainer.animator().alphaValue = 0.0
        }, completionHandler: completion)
    }
}
