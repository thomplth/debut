import AppKit

public final class PlateView: NSView {
    public static let plateHeight: CGFloat = 110
    public static let iconSize: CGFloat = 56
    public static let iconSpacing: CGFloat = 20
    public static let padding: CGFloat = 24
    public static let minPlateWidth: CGFloat = 300

    private let plate: PlateData
    private let isSelected: Bool
    private let selectedAppIndex: Int?

    public init(plate: PlateData, isSelected: Bool, selectedAppIndex: Int?) {
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

    override public var intrinsicContentSize: NSSize {
        let iconsWidth = CGFloat(max(plate.apps.count, 1)) * Self.iconSize
            + CGFloat(max(0, plate.apps.count - 1)) * Self.iconSpacing
        let width = max(iconsWidth + Self.padding * 2, Self.minPlateWidth)
        return NSSize(width: width, height: Self.plateHeight)
    }

    private func setupAppearance() {
        guard let layer else { return }
        layer.cornerRadius = 18
        layer.masksToBounds = false

        if isSelected {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            layer.borderWidth = 1.5
            layer.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        } else {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            layer.borderWidth = 0.5
            layer.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        }
    }

    private func layoutContent() {
        let nameLabel = NSTextField(labelWithString: plate.name)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .white.withAlphaComponent(isSelected ? 0.9 : 0.5)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])

        guard !plate.apps.isEmpty else {
            let emptyLabel = NSTextField(labelWithString: "No apps")
            emptyLabel.font = .systemFont(ofSize: 11)
            emptyLabel.textColor = .white.withAlphaComponent(0.25)
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 8),
            ])
            return
        }

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

        NSLayoutConstraint.activate([
            iconsContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconsContainer.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            iconsContainer.heightAnchor.constraint(equalToConstant: Self.iconSize),
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
            let fallback = NSImage(size: NSSize(width: 64, height: 64))
            fallback.lockFocus()
            NSColor.white.withAlphaComponent(0.1).setFill()
            let path = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 56, height: 56), xRadius: 12, yRadius: 12)
            path.fill()
            let label = app.name.prefix(2).uppercased()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(
                at: NSPoint(x: 32 - size.width / 2, y: 32 - size.height / 2),
                withAttributes: attrs
            )
            fallback.unlockFocus()
            imageView.image = fallback
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
            indicator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            indicator.layer?.cornerRadius = 2
            indicator.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(indicator)

            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                indicator.topAnchor.constraint(equalTo: container.bottomAnchor, constant: 4),
                indicator.widthAnchor.constraint(equalToConstant: 20),
                indicator.heightAnchor.constraint(equalToConstant: 3),
            ])
        }

        return container
    }
}
