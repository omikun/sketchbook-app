import UIKit

/// Brush settings stay in a small, scrollable card; curves are captured per stroke.
final class CanvasBrushPanel: UIVisualEffectView {
    enum Mode { case size, opacity }
    private(set) var mode: Mode = .size
    let maxOpacityToggle = UISwitch()
    var maxOpacityChanged: ((Bool) -> Void)?
    private var erasing = false
    private let transparencyLabel = UILabel()
    private let transparencyRow = UIStackView()
    private let hint = UILabel()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let reset = UIButton(type: .system)
    let widthSlider: UISlider = CanvasBrushSlider()
    let widthLabel = UILabel()
    let opacitySlider: UISlider = CanvasBrushSlider()
    let opacityLabel = UILabel()
    var changed: ((CanvasBrushDynamics) -> Void)?
    private var dynamics = CanvasBrushDynamics()
    private let size = PressureCurveEditor(title: "SIZE", minimum: 0.25, maximum: 1)
    private let opacity = PressureCurveEditor(title: "OPACITY", minimum: 1, maximum: 1)

    init() {
        super.init(effect: nil)
        contentView.backgroundColor = UIColor(red: 0.13, green: 0.13, blue: 0.21, alpha: 0.98)
        widthLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium); widthLabel.textColor = .white
        widthSlider.minimumValue = 1; widthSlider.maximumValue = 512
        widthSlider.minimumTrackTintColor = .systemPurple
        widthSlider.accessibilityLabel = "Brush width in canvas pixels"
        opacitySlider.minimumValue = 0; opacitySlider.maximumValue = 1
        opacitySlider.minimumTrackTintColor = .systemPurple
        opacitySlider.accessibilityLabel = "Brush opacity"
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium); opacityLabel.textColor = .white
        transparencyLabel.text = "Uniform stroke opacity"; transparencyLabel.textColor = .white
        transparencyLabel.font = .systemFont(ofSize: 12); transparencyLabel.numberOfLines = 2
        maxOpacityToggle.onTintColor = .systemPurple
        maxOpacityToggle.accessibilityLabel = "Non-accumulating stroke opacity"
        maxOpacityToggle.addTarget(self, action: #selector(transparencyChanged), for: .valueChanged)
        transparencyRow.addArrangedSubview(transparencyLabel); transparencyRow.addArrangedSubview(maxOpacityToggle)
        transparencyRow.alignment = .center; transparencyRow.spacing = 8
        hint.numberOfLines = 0; hint.font = .systemFont(ofSize: 10); hint.textColor = .lightGray
        reset.setTitle("Reset pressure response", for: .normal)
        reset.tintColor = UIColor(red: 0.75, green: 0.7, blue: 1, alpha: 1); reset.titleLabel?.font = .systemFont(ofSize: 12)
        reset.addTarget(self, action: #selector(resetCurves), for: .touchUpInside)

        stack.axis = .vertical; stack.spacing = 10
        scroll.accessibilityIdentifier = "brushSettings"
        scroll.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: contentView.topAnchor), scroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -28)
        ])
        size.changed = { [weak self] curve in self?.dynamics.size = curve; self?.notify() }
        opacity.changed = { [weak self] curve in self?.dynamics.opacity = curve; self?.notify() }
        showSettings(.size)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setDynamics(_ value: CanvasBrushDynamics) {
        dynamics = value; size.setCurve(value.size); opacity.setCurve(value.opacity)
    }
    func showSettings(_ mode: Mode) {
        self.mode = mode
        for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
        let children: [UIView] = mode == .size ? [widthLabel, widthSlider, size, hint, reset] : [opacityLabel, opacitySlider, opacity, transparencyRow, hint, reset]
        for child in children { stack.addArrangedSubview(child) }
        updateHint(); scroll.setContentOffset(.zero, animated: false)
    }
    func setTool(erasing: Bool) {
        self.erasing = erasing
        widthSlider.accessibilityLabel = erasing ? "Eraser width in canvas pixels" : "Brush width in canvas pixels"
        opacitySlider.accessibilityLabel = erasing ? "Eraser opacity" : "Brush opacity"
        maxOpacityToggle.accessibilityLabel = erasing ? "Non-accumulating eraser opacity" : "Non-accumulating stroke opacity"
        transparencyLabel.text = erasing ? "Uniform eraser opacity" : "Uniform stroke opacity"
        updateHint()
    }
    func setMaxOpacity(_ enabled: Bool) { maxOpacityToggle.isOn = enabled; updateHint() }
    private func updateHint() {
        if erasing {
            hint.text = mode == .size ? "Drag the size button to resize the eraser.\nOnly your selected layer is erased." :
                (maxOpacityToggle.isOn ? "Overlapping stamps use their strongest erasing opacity. Separate passes erase further." : "Erasing builds up with each stamp within a pass.")
            return
        }
        hint.text = mode == .size ? "Drag the size button to resize.\nFinger input uses full pressure." :
            (maxOpacityToggle.isOn ? "Overlapping stamps use their highest opacity within this stroke. Separate strokes still build up." : "Stamp opacity builds up within a stroke, like a highlighter.")
    }
    @objc private func transparencyChanged() { updateHint(); maxOpacityChanged?(maxOpacityToggle.isOn) }
    @objc private func resetCurves() {
        let defaults = CanvasBrushDynamics()
        if mode == .size { dynamics.size = defaults.size } else { dynamics.opacity = defaults.opacity }
        setDynamics(dynamics); notify()
    }
    private func notify() { changed?(dynamics) }
}

private final class PressureCurveEditor: UIStackView {
    var changed: ((CanvasPressureCurve) -> Void)?
    private let minimum = CanvasBrushSlider()
    private let maximum = CanvasBrushSlider()
    private let exponent = CanvasBrushSlider()
    private let labels = [UILabel(), UILabel(), UILabel()]
    private let graph = PressureCurveGraph()
    private var curve: CanvasPressureCurve

    init(title: String, minimum: Double, maximum: Double) {
        curve = CanvasPressureCurve(minimum: minimum, maximum: maximum)
        super.init(frame: .zero)
        axis = .vertical; spacing = 2
        let heading = UILabel(); heading.text = "\(title) · PRESSURE"; heading.textColor = .white; heading.font = .systemFont(ofSize: 10, weight: .semibold)
        addArrangedSubview(heading); addArrangedSubview(graph)
        graph.heightAnchor.constraint(equalToConstant: 44).isActive = true
        for (i, slider) in [self.minimum, self.maximum, exponent].enumerated() {
            labels[i].textColor = .lightGray; labels[i].font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            slider.minimumValue = i == 2 ? 0.2 : 0; slider.maximumValue = i == 2 ? 4 : 1
            slider.accessibilityLabel = "\(title.capitalized) \(["minimum", "maximum", "response curve"][i])"
            slider.minimumTrackTintColor = UIColor(red: 0.62, green: 0.58, blue: 1, alpha: 1)
            slider.addTarget(self, action: #selector(adjust(_:)), for: .valueChanged)
            addArrangedSubview(labels[i]); addArrangedSubview(slider)
        }
        setCurve(curve)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setCurve(_ value: CanvasPressureCurve) {
        curve = value
        minimum.value = Float(value.minimum); maximum.value = Float(value.maximum); exponent.value = Float(value.exponent)
        labels[0].text = "Light touch   \(Int(value.minimum * 100))%"
        labels[1].text = "Firm pressure \(Int(value.maximum * 100))%"
        labels[2].text = String(format: "Response %.2f · %@", value.exponent, value.exponent < 0.95 ? "soft" : (value.exponent > 1.05 ? "firm" : "linear"))
        graph.curve = value; graph.setNeedsDisplay()
    }
    @objc private func adjust(_ sender: UISlider) {
        if sender === minimum { curve.minimum = Double(sender.value); curve.maximum = max(curve.minimum, curve.maximum) }
        else if sender === maximum { curve.maximum = Double(sender.value); curve.minimum = min(curve.maximum, curve.minimum) }
        else { curve.exponent = Double(sender.value) }
        setCurve(curve); changed?(curve)
    }
}

private final class PressureCurveGraph: UIView {
    var curve = CanvasPressureCurve(minimum: 0, maximum: 1)
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor(red: 0.09, green: 0.09, blue: 0.16, alpha: 1).cgColor)
        context.fill(bounds)
        context.beginPath()
        let area = bounds.insetBy(dx: 4, dy: 4)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.12).cgColor); context.setLineWidth(1)
        context.stroke(area)
        context.setStrokeColor(UIColor(red: 0.7, green: 0.64, blue: 1, alpha: 1).cgColor); context.setLineWidth(2)
        for i in 0...60 {
            let p = Double(i) / 60
            let point = CGPoint(x: area.minX + area.width * p, y: area.maxY - area.height * curve.value(at: p))
            if i == 0 { context.move(to: point) } else { context.addLine(to: point) }
        }
        context.strokePath()
    }
}

private final class CanvasBrushSlider: UISlider {
    init() {
        super.init(frame: .zero)
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
            let circle = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 16, height: 16))
            UIColor(white: 0.95, alpha: 1).setFill(); circle.fill()
            UIColor(red: 0.7, green: 0.64, blue: 1, alpha: 1).setStroke(); circle.lineWidth = 2; circle.stroke()
        }
        setThumbImage(thumb, for: .normal)
        maximumTrackTintColor = UIColor.white.withAlphaComponent(0.15)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        CGRect(x: 2, y: bounds.midY - 1.5, width: max(0, bounds.width - 4), height: 3)
    }
}
