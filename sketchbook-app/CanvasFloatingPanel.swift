import UIKit

/// Movable chrome keeps dragging separate from sliders, color sampling and layer scrolling.
final class CanvasFloatingPanel: UIView {
    let content: UIView
    var isOpen = false
    var closed: (() -> Void)?
    var availableArea: (() -> CGRect)?
    private(set) var hasPlacement = false
    private var requestedSize: CGSize
    private let minimumSize: CGSize
    private let resizable: Bool
    private let dragHandle = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .custom)
    private let resizeHandle = UIView()
    private let resizeImage = UIImageView(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"))
    private var gestureStart = CGRect.zero
    private let headerHeight: CGFloat = 36
    private var footerHeight: CGFloat { resizable ? 32 : 0 }

    init(content: UIView, title: String, id: String, size: CGSize, minimumSize: CGSize, resizable: Bool = false) {
        self.content = content; self.requestedSize = size; self.minimumSize = minimumSize; self.resizable = resizable
        super.init(frame: CGRect(origin: .zero, size: size))
        accessibilityIdentifier = "floating\(id)Panel"
        backgroundColor = UIColor(red: 0.13, green: 0.13, blue: 0.21, alpha: 0.98)
        layer.cornerRadius = 18; clipsToBounds = true
        layer.borderWidth = 1; layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        content.translatesAutoresizingMaskIntoConstraints = true
        addSubview(content); addSubview(dragHandle); addSubview(closeButton)
        titleLabel.text = title; titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        dragHandle.addSubview(titleLabel)
        dragHandle.accessibilityIdentifier = "drag\(id)Panel"
        dragHandle.isAccessibilityElement = true; dragHandle.accessibilityLabel = "Move \(title.lowercased()) panel"
        dragHandle.accessibilityHint = "Drag to move this panel"
        dragHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
        closeButton.tintColor = .lightGray; closeButton.accessibilityLabel = "Close \(title.lowercased()) panel"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        if resizable {
            addSubview(resizeHandle); resizeHandle.addSubview(resizeImage)
            resizeImage.tintColor = .lightGray; resizeImage.contentMode = .scaleAspectFit
            resizeHandle.isAccessibilityElement = true; resizeHandle.accessibilityLabel = "Resize color picker"
            resizeHandle.accessibilityIdentifier = "resize\(id)Panel"
            resizeHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resize(_:))))
        }
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        dragHandle.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - 40), height: headerHeight)
        titleLabel.frame = dragHandle.bounds.insetBy(dx: 14, dy: 8)
        closeButton.frame = CGRect(x: bounds.width - 40, y: 0, width: 40, height: headerHeight)
        content.frame = CGRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight - footerHeight))
        resizeHandle.frame = CGRect(x: bounds.width - 44, y: bounds.height - 44, width: 44, height: 44)
        resizeImage.frame = CGRect(x: 17, y: 17, width: 17, height: 17)
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if result != nil { superview?.bringSubviewToFront(self) }
        return result
    }
    func setTitle(_ title: String) {
        titleLabel.text = title
        dragHandle.accessibilityLabel = "Move \(title.lowercased()) panel"
        closeButton.accessibilityLabel = "Close \(title.lowercased()) panel"
    }
    func present(in area: CGRect, avoiding occupied: [CGRect]) {
        if !hasPlacement {
            let size = fittedSize(in: area)
            let xs = ([area.minX] + occupied.map { $0.maxX + 12 }).sorted()
            let ys = ([min(area.minY + 64, area.maxY - size.height)] + occupied.map { $0.maxY + 12 }).sorted()
            var placement: CGRect?
            outer: for y in ys {
                for x in xs {
                    let candidate = CGRect(origin: CGPoint(x: x, y: max(area.minY, y)), size: size)
                    if area.contains(candidate) && !occupied.contains(where: { $0.insetBy(dx: -5, dy: -5).intersects(candidate) }) {
                        placement = candidate; break outer
                    }
                }
            }
            frame = placement ?? CGRect(x: area.minX + CGFloat(occupied.count % 3) * 20,
                                        y: area.minY + 64 + CGFloat(occupied.count % 4) * 36,
                                        width: size.width, height: size.height)
            hasPlacement = true
        }
        reflow(in: area)
    }
    func reflow(in area: CGRect) {
        guard area.width > 0, area.height > 0 else { return }
        let size = fittedSize(in: area)
        frame = CGRect(x: min(max(area.minX, frame.minX), area.maxX - size.width),
                       y: min(max(area.minY, frame.minY), area.maxY - size.height), width: size.width, height: size.height)
    }
    func setContentHeight(_ height: CGFloat) {
        requestedSize.height = height + headerHeight + footerHeight
        if let area = availableArea?() { reflow(in: area) }
    }
    private func fittedSize(in area: CGRect) -> CGSize {
        CGSize(width: min(area.width, max(minimumSize.width, requestedSize.width)),
               height: min(area.height, max(minimumSize.height, requestedSize.height)))
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let area = availableArea?() else { return }
        if gesture.state == .began { gestureStart = frame; superview?.bringSubviewToFront(self) }
        let delta = gesture.translation(in: superview)
        frame.origin = CGPoint(x: gestureStart.minX + delta.x, y: gestureStart.minY + delta.y)
        hasPlacement = true; reflow(in: area)
    }
    @objc private func resize(_ gesture: UIPanGestureRecognizer) {
        guard let area = availableArea?() else { return }
        if gesture.state == .began { gestureStart = frame; superview?.bringSubviewToFront(self) }
        let delta = gesture.translation(in: superview)
        requestedSize = CGSize(width: min(max(minimumSize.width, gestureStart.width + delta.x), area.maxX - frame.minX),
                               height: min(max(minimumSize.height, gestureStart.height + delta.y), area.maxY - frame.minY))
        reflow(in: area)
    }
    @objc private func close() { isOpen = false; isHidden = true; closed?() }
}

/// Padding belongs to the label so text changes and wrapping keep the same rounded badge.
final class CanvasStatusLabel: UILabel {
    private let padding = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: padding)) }
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let text = super.textRect(forBounds: bounds.inset(by: padding), limitedToNumberOfLines: numberOfLines)
        return text.inset(by: UIEdgeInsets(top: -padding.top, left: -padding.left, bottom: -padding.bottom, right: -padding.right))
    }
}
