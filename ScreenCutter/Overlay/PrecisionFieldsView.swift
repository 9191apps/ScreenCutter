import AppKit

/// Four-field pixel editor for a selection. The model clamps in `PrecisionInput`;
/// this view only turns text into integers and shows the point equivalent.
@MainActor
final class PrecisionFieldsViewController: NSViewController, NSTextFieldDelegate {
    private let metrics: DisplayMetrics
    private var rect: PixelRect
    var onPreview: ((PixelRect) -> Void)?
    var onApply: ((PixelRect) -> Void)?
    var onCancel: (() -> Void)?

    private let xField = NSTextField()
    private let yField = NSTextField()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let pointsLabel = NSTextField(labelWithString: "")

    init(metrics: DisplayMetrics, rect: PixelRect) {
        self.metrics = metrics
        self.rect = rect
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 300, height: 176)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 176))
        view = container

        for field in [xField, yField, widthField, heightField] {
            configure(field)
        }
        xField.stringValue = "\(rect.x)"
        yField.stringValue = "\(rect.y)"
        widthField.stringValue = "\(rect.width)"
        heightField.stringValue = "\(rect.height)"

        let grid = NSGridView(views: [
            [label("X"), xField, label("Y"), yField],
            [label("W"), widthField, label("H"), heightField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)

        pointsLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        pointsLabel.textColor = .secondaryLabelColor
        pointsLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pointsLabel)
        updatePointsLabel()

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "应用", target: self, action: #selector(applyClicked))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(buttons)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),

            pointsLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
            pointsLabel.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            pointsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            buttons.topAnchor.constraint(equalTo: pointsLabel.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(xField)
    }

    private func configure(_ field: NSTextField) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        field.formatter = formatter
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.controlSize = .small
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func parsedRect() -> PixelRect? {
        guard let x = Int(xField.stringValue.trimmingCharacters(in: .whitespaces)),
              let y = Int(yField.stringValue.trimmingCharacters(in: .whitespaces)),
              let width = Int(widthField.stringValue.trimmingCharacters(in: .whitespaces)),
              let height = Int(heightField.stringValue.trimmingCharacters(in: .whitespaces)),
              width >= 1, height >= 1 else {
            return nil
        }
        return PrecisionInput.rect(x: x, y: y, width: width, height: height, in: metrics)
    }

    private func updatePointsLabel() {
        guard let rect = parsedRect() else {
            pointsLabel.stringValue = "请输入不小于 1 的整数宽高（像素）"
            return
        }
        let width = CGFloat(rect.width) / metrics.scaleX
        let height = CGFloat(rect.height) / metrics.scaleY
        let widthText = String(format: "%.1f", width)
        let heightText = String(format: "%.1f", height)
        pointsLabel.stringValue = "\(rect.x), \(rect.y) · \(rect.width) × \(rect.height) px · \(widthText) × \(heightText) pt"
    }

    func controlTextDidChange(_ obj: Notification) {
        updatePointsLabel()
        if let rect = parsedRect() {
            onPreview?(rect)
        }
    }

    @objc private func applyClicked() {
        guard let rect = parsedRect() else {
            NSSound.beep()
            return
        }
        self.rect = rect
        onApply?(rect)
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}
