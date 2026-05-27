import AppKit

final class PlateView: NSView {
    static let plateHeight: CGFloat = 100
    static let iconSize: CGFloat = 64
    static let iconSpacing: CGFloat = 16
    static let labelHeight: CGFloat = 16
    static let padding: CGFloat = 20

    private let plate: PlateData
    private let isSelected: Bool
    private let selectedAppIndex: Int?

    init(plate: PlateData, isSelected: Bool, selectedAppIndex: Int?) {
        self.plate = plate
        self.isSelected = isSelected
        self.selectedAppIndex = selectedAppIndex
        super.init(frame: .zero)
        wantsLayer = true
        setupAppearance()
        layoutContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupAppearance() {
        guard let layer else { return }
        layer.cornerRadius = 16
        layer.masksToBounds = true

        if isSelected {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
            layer.borderWidth = 2
            layer.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        } else {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            layer.borderWidth = 0
        }
    }

    private func layoutContent() {
        let nameLabel = NSTextField(labelWithString: plate.name)
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .white.withAlphaComponent(0.7)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])

        let iconsContainer = NSView()
        iconsContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconsContainer)

        var iconViews: [NSView] = []
        for (index, app) in plate.apps.enumerated() {
            let iconView = makeAppIcon(app: app, isAppSelected: selectedAppIndex == index)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconsContainer.addSubview(iconView)
            iconViews.append(iconView)

            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
                iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
                iconView.centerYAnchor.constraint(equalTo: iconsContainer.centerYAnchor),
            ])

            if let prev = iconViews.dropLast().last {
                iconView.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: Self.iconSpacing).isActive = true
            } else {
                iconView.leadingAnchor.constraint(equalTo: iconsContainer.leadingAnchor).isActive = true
            }
        }

        if let lastIcon = iconViews.last {
            lastIcon.trailingAnchor.constraint(equalTo: iconsContainer.trailingAnchor).isActive = true
        }

        let totalWidth = CGFloat(plate.apps.count) * Self.iconSize + CGFloat(max(0, plate.apps.count - 1)) * Self.iconSpacing

        NSLayoutConstraint.activate([
            iconsContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconsContainer.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            iconsContainer.heightAnchor.constraint(equalToConstant: Self.iconSize),
            iconsContainer.widthAnchor.constraint(equalToConstant: totalWidth),

            widthAnchor.constraint(greaterThanOrEqualToConstant: totalWidth + Self.padding * 2),
        ])
    }

    private func makeAppIcon(app: PlateAppData, isAppSelected: Bool) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            imageView.image = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            imageView.image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: app.name)
        }

        container.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        if isAppSelected {
            let indicator = NSView()
            indicator.wantsLayer = true
            indicator.layer?.backgroundColor = NSColor.white.cgColor
            indicator.layer?.cornerRadius = 2
            indicator.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(indicator)

            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                indicator.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: 4),
                indicator.widthAnchor.constraint(equalToConstant: 24),
                indicator.heightAnchor.constraint(equalToConstant: 4),
            ])
        }

        return container
    }
}
