import AppKit

public final class PlateView: NSView {
    public static let plateHeight: CGFloat = 140
    public static let iconSize: CGFloat = 80
    public static let iconSpacing: CGFloat = 8
    public static let padding: CGFloat = 18
    public static let minPlateWidth: CGFloat = 200
    public static let labelHeight: CGFloat = 20
    public static let topInset: CGFloat = 10
    public static let iconTopInset: CGFloat = 14

    private let plate: PlateData
    private let isSelected: Bool
    private let selectedAppIndex: Int?

    public init(plate: PlateData, isSelected: Bool, selectedAppIndex: Int?) {
        self.plate = plate
        self.isSelected = isSelected
        self.selectedAppIndex = selectedAppIndex
        super.init(frame: .zero)
        wantsLayer = true
        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public static func plateWidth(forAppCount count: Int) -> CGFloat {
        let iconsWidth = CGFloat(max(count, 1)) * iconSize + CGFloat(max(0, count - 1)) * iconSpacing
        return max(iconsWidth + padding * 2, minPlateWidth)
    }

    private func setupContent() {
        let effect = NSVisualEffectView()
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.blendingMode = .behindWindow
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        addSubview(effect)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if isSelected {
            effect.layer?.borderWidth = 2
            effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        }

        let nameLabel = NSTextField(labelWithString: plate.name)
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .white.withAlphaComponent(isSelected ? 0.85 : 0.5)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: Self.padding),
            nameLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: Self.topInset),
        ])

        guard !plate.apps.isEmpty else {
            let emptyLabel = NSTextField(labelWithString: "Empty")
            emptyLabel.font = .systemFont(ofSize: 11)
            emptyLabel.textColor = .white.withAlphaComponent(0.2)
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: effect.centerYAnchor, constant: 10),
            ])
            return
        }

        for (index, app) in plate.apps.enumerated() {
            let isAppSelected = selectedAppIndex == index
            let col = makeAppColumn(app: app, isAppSelected: isAppSelected)
            col.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(col)

            let x = Self.padding + CGFloat(index) * (Self.iconSize + Self.iconSpacing)
            NSLayoutConstraint.activate([
                col.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: x),
                col.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: Self.iconTopInset - 4),
                col.widthAnchor.constraint(equalToConstant: Self.iconSize),
            ])
        }
    }

    private func makeAppColumn(app: PlateAppData, isAppSelected: Bool) -> NSView {
        let column = NSView()

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = iconForApp(app)
        column.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: column.topAnchor),
            imageView.centerXAnchor.constraint(equalTo: column.centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            imageView.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])

        let nameLabel = NSTextField(labelWithString: app.name)
        nameLabel.font = .systemFont(ofSize: 10)
        nameLabel.textColor = .white.withAlphaComponent(isAppSelected ? 0.9 : 0.0)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 2),
            nameLabel.centerXAnchor.constraint(equalTo: column.centerXAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.iconSize + 10),
            nameLabel.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])

        if isAppSelected {
            let bg = NSView()
            bg.wantsLayer = true
            bg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            bg.layer?.cornerRadius = 10
            bg.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(bg, positioned: .below, relativeTo: imageView)

            NSLayoutConstraint.activate([
                bg.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
                bg.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
                bg.widthAnchor.constraint(equalToConstant: Self.iconSize + 8),
                bg.heightAnchor.constraint(equalToConstant: Self.iconSize + 8),
            ])
        }

        return column
    }

    private func iconForApp(_ app: PlateAppData) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: Self.iconSize, height: Self.iconSize)
            return icon
        }
        let img = NSImage(size: NSSize(width: Self.iconSize, height: Self.iconSize))
        img.lockFocus()
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: Self.iconSize - 12, height: Self.iconSize - 12), xRadius: 14, yRadius: 14).fill()
        let label = String(app.name.prefix(2)).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.35),
        ]
        let sz = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: Self.iconSize / 2 - sz.width / 2, y: Self.iconSize / 2 - sz.height / 2), withAttributes: attrs)
        img.unlockFocus()
        return img
    }
}
