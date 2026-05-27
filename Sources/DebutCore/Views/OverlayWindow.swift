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
    private let backdropView: NSVisualEffectView
    private let stackContainer: NSView
    private var plateViews: [PlateView] = []
    private var stackHeightConstraint: NSLayoutConstraint?
    private var stackCenterYConstraint: NSLayoutConstraint?

    public override init(frame: NSRect) {
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

        let centerY = stackContainer.centerYAnchor.constraint(equalTo: centerYAnchor)
        stackCenterYConstraint = centerY

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerY,
        ])
    }

    public func update(viewModel: OverlayViewModel) {
        plateViews.forEach { $0.removeFromSuperview() }
        plateViews.removeAll()
        stackHeightConstraint?.isActive = false

        let plates = viewModel.plates
        guard !plates.isEmpty else { return }

        let spacing: CGFloat = 12

        let maxWidth = plates.map { plate -> CGFloat in
            let iconsWidth = CGFloat(plate.apps.count) * PlateView.iconSize
                + CGFloat(max(0, plate.apps.count - 1)) * PlateView.iconSpacing
            return max(iconsWidth + PlateView.padding * 2, PlateView.minPlateWidth)
        }.max() ?? PlateView.minPlateWidth

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
                plateView.widthAnchor.constraint(equalToConstant: maxWidth),
                plateView.heightAnchor.constraint(equalToConstant: PlateView.plateHeight),
            ])
        }

        // Stack top to bottom (index 0 at top)
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

        stackContainer.widthAnchor.constraint(equalToConstant: maxWidth).isActive = true

        // Offset to center the active plate on screen
        let totalHeight = CGFloat(plates.count) * PlateView.plateHeight + CGFloat(plates.count - 1) * spacing
        let activeIndex = viewModel.activeStageIndex
        let activePlateTop = CGFloat(activeIndex) * (PlateView.plateHeight + spacing)
        let activePlateCenter = activePlateTop + PlateView.plateHeight / 2
        let offset = totalHeight / 2 - activePlateCenter
        stackCenterYConstraint?.constant = offset

        plateViews = views
    }

    func animateIn() {
        stackContainer.alphaValue = 0
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
