import UIKit

/// Compact HSV controls, matching the original on-canvas picker without a modal sheet.
final class CanvasColorPanel: UIView {
    var changed: ((UIColor) -> Void)?
    var committed: (() -> Void)?
    private var swatches: [UIButton] = []
    private let field = CanvasColorField(hueStrip: false)
    private let hue = CanvasColorField(hueStrip: true)
    private let title = UILabel()
    private let value = UILabel()

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 0.13, green: 0.13, blue: 0.21, alpha: 0.98)
        title.text = "INK"; title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .lightGray
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        value.textColor = .white; value.textAlignment = .right
        for child in [title, value, field, hue] { addSubview(child) }
        field.addTarget(self, action: #selector(fieldChanged), for: .valueChanged)
        hue.addTarget(self, action: #selector(hueChanged), for: .valueChanged)
        for control in [field, hue] { control.addTarget(self, action: #selector(commitColor), for: .editingDidEnd) }
        let presets: [(String, UIColor)] = [("White", .white), ("Warm paper", UIColor(red: 0.94, green: 0.9, blue: 0.8, alpha: 1)), ("Gray", UIColor(white: 0.5, alpha: 1)), ("Black", .black)]
        for (name, color) in presets {
            let button = UIButton(type: .custom); button.backgroundColor = color
            button.layer.cornerRadius = 12; button.layer.borderWidth = 1; button.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
            button.accessibilityLabel = "\(name) swatch"
            button.addAction(UIAction { [weak self] _ in self?.setColor(color); self?.changed?(color); self?.committed?() }, for: .touchUpInside)
            swatches.append(button); addSubview(button)
        }
        accessibilityIdentifier = "canvasColorPanel"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = CGRect(x: 14, y: 12, width: 40, height: 16)
        value.frame = CGRect(x: 58, y: 12, width: bounds.width - 72, height: 16)
        field.frame = CGRect(x: 14, y: 38, width: bounds.width - 28, height: max(16, bounds.height - 118))
        hue.frame = CGRect(x: 14, y: bounds.height - 66, width: bounds.width - 28, height: 22)
        for (i, button) in swatches.enumerated() { button.frame = CGRect(x: 14 + CGFloat(i) * (bounds.width - 52) / 3, y: bounds.height - 38, width: 24, height: 24) }
    }
    func setTitle(_ text: String) { title.text = text }
    func setColor(_ color: UIColor) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Keep the hue while selecting white/black, so dragging back restores the same ink family.
        if s > 0 { field.hue = h; hue.hue = h }
        field.saturation = s; field.brightness = b
        updateValue()
    }
    func colorDescription(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
    private func updateValue() {
        value.text = colorDescription(field.color)
        field.setNeedsDisplay(); hue.setNeedsDisplay()
        field.accessibilityValue = "Saturation \(Int(field.saturation * 100)) percent, brightness \(Int(field.brightness * 100)) percent"
        hue.accessibilityValue = "\(Int(hue.hue * 360)) degrees"
    }
    @objc private func commitColor() { committed?() }
    @objc private func fieldChanged() { updateValue(); changed?(field.color) }
    @objc private func hueChanged() { field.hue = hue.hue; updateValue(); changed?(field.color) }
}

private final class CanvasColorField: UIControl {
    var hue: CGFloat = 0
    var saturation: CGFloat = 1
    var brightness: CGFloat = 1
    var color: UIColor { UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1) }
    private let hueStrip: Bool
    init(hueStrip: Bool) {
        self.hueStrip = hueStrip
        super.init(frame: .zero)
        isOpaque = false; layer.cornerRadius = 6; clipsToBounds = true
        isAccessibilityElement = true; accessibilityTraits = .adjustable
        accessibilityLabel = hueStrip ? "Hue" : "Saturation and brightness"
        accessibilityHint = hueStrip ? "Swipe up or down to adjust hue" : "Swipe up or down to adjust brightness; tap or drag to choose saturation"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let space = CGColorSpaceCreateDeviceRGB()
        if hueStrip {
            let colors = (0...6).map { UIColor(hue: CGFloat($0) / 6, saturation: 1, brightness: 1, alpha: 1).cgColor }
            if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: bounds.width, y: 0), options: [])
            }
        } else {
            UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill(); context.fill(bounds)
            if let white = CGGradient(colorsSpace: space, colors: [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: nil) {
                context.drawLinearGradient(white, start: .zero, end: CGPoint(x: bounds.width, y: 0), options: [])
            }
            if let black = CGGradient(colorsSpace: space, colors: [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.cgColor] as CFArray, locations: nil) {
                context.drawLinearGradient(black, start: .zero, end: CGPoint(x: 0, y: bounds.height), options: [])
            }
        }
        let x = min(bounds.width - 6, max(6, (hueStrip ? hue : saturation) * bounds.width))
        let y = hueStrip ? bounds.midY : min(bounds.height - 6, max(6, (1 - brightness) * bounds.height))
        let marker = CGRect(x: x - 5, y: y - 5, width: 10, height: 10)
        context.setStrokeColor(UIColor.black.cgColor); context.setLineWidth(4); context.strokeEllipse(in: marker)
        context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(2); context.strokeEllipse(in: marker)
    }
    private func update(_ touch: UITouch) {
        let p = touch.location(in: self)
        guard bounds.width > 0, bounds.height > 0 else { return }
        if hueStrip { hue = min(1, max(0, p.x / bounds.width)) }
        else { saturation = min(1, max(0, p.x / bounds.width)); brightness = 1 - min(1, max(0, p.y / bounds.height)) }
        setNeedsDisplay(); sendActions(for: .valueChanged)
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { update(touch); return true }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { update(touch); return true }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { if let touch { update(touch) }; sendActions(for: .editingDidEnd) }
    override func cancelTracking(with event: UIEvent?) { sendActions(for: .editingDidEnd) }
    override func accessibilityIncrement() { adjust(0.05) }
    override func accessibilityDecrement() { adjust(-0.05) }
    private func adjust(_ delta: CGFloat) {
        if hueStrip { hue = min(1, max(0, hue + delta)) }
        else { brightness = min(1, max(0, brightness + delta)) }
        setNeedsDisplay(); sendActions(for: [.valueChanged, .editingDidEnd])
    }
}
