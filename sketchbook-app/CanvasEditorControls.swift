import UIKit

// Presentation and hit testing live here; artwork and input remain in ViewController.
enum CanvasEditorAction {
    case selectBrush, selectEraser, toggleInterface, pickColor, toggleBrush, undo, redo, toggleLayers, toggleFinger, fitCanvas, resizeCanvas, connectRoom, dragBrushSize, addLayer, changeSize, toggleOpacity, dragOpacity, changeOpacity, pickBackground, rulerDown, rulerUp, rulerCancel
}

final class CanvasEditorControls: UIView {
    private weak var target: UIViewController?
    private var actions: [CanvasEditorAction: Selector] = [:]
    let layerPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    let layerTable = UITableView(frame: .zero, style: .plain)
    let statusLabel = CanvasStatusLabel()
    let brushToolButton = UIButton(type: .custom)
    let eraserToolButton = UIButton(type: .custom)
    let undoButton = UIButton(type: .system)
    let redoButton = UIButton(type: .system)
    let resizeButton = UIButton(type: .system)
    let colorButton = UIButton(type: .system)
    let fingerButton = UIButton(type: .system)
    let zoomButton = UIButton(type: .system)
    let opacityButton = UIButton(type: .custom)
    let backgroundButton = UIButton(type: .custom)
    let rulerButton = UIButton(type: .custom)
    private let adjustmentLabel = UILabel()
    let sizeButton = UIButton(type: .custom)
    let layersButton = UIButton(type: .custom)
    let interfaceButton = UIButton(type: .custom)
    let toolScroll = UIScrollView()
    let colorPanel = CanvasColorPanel()
    let brushPanel = CanvasBrushPanel()
    var brushSlider: UISlider { brushPanel.widthSlider }
    var sizeLabel: UILabel { brushPanel.widthLabel }
    private var interfaceHidden = false
    private lazy var brushWindow = CanvasFloatingPanel(content: brushPanel, title: "Brush", id: "Brush", size: CGSize(width: 224, height: 446), minimumSize: CGSize(width: 224, height: 196))
    private lazy var colorWindow = CanvasFloatingPanel(content: colorPanel, title: "Color picker", id: "Color", size: CGSize(width: 224, height: 372), minimumSize: CGSize(width: 224, height: 248), resizable: true)
    private lazy var layersWindow = CanvasFloatingPanel(content: layerPanel, title: "Layers", id: "Layers", size: CGSize(width: 280, height: 356), minimumSize: CGSize(width: 240, height: 200))
    private var windows: [CanvasFloatingPanel] { [brushWindow, colorWindow, layersWindow] }
    private var panelArea: CGRect {
        let safe = safeAreaLayoutGuide.layoutFrame
        return CGRect(x: safe.minX + 68, y: safe.minY + 8, width: max(0, safe.width - 76), height: max(0, safe.height - 16))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for window in windows where window.hasPlacement { window.reflow(in: panelArea) }
    }

    init() { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(target: UIViewController, actions: [CanvasEditorAction: Selector]) {
        self.target = target; self.actions = actions
        configureLayout()
    }

    // Empty overlay space passes directly through to the Metal canvas.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    private func button(_ button: UIButton = UIButton(type: .custom), symbol: String, label: String, action: Selector) -> UIButton {
        button.setImage(UIImage(systemName: symbol == "eraser" && UIImage(systemName: "eraser") == nil ? "pencil.slash" : symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        button.accessibilityLabel = label
        button.addTarget(target, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.backgroundColor = UIColor(red: 0.18, green: 0.18, blue: 0.32, alpha: 0.94)
        button.tintColor = .white
        button.layer.cornerRadius = 22
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.18
        button.layer.shadowRadius = 6
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        return button
    }

    private func configureLayout() {
        let safe = safeAreaLayoutGuide
        let reveal = button(interfaceButton, symbol: "circle.grid.2x2", label: "Hide or show drawing controls", action: actions[.toggleInterface]!)
        reveal.accessibilityIdentifier = "toggleInterface"
        reveal.translatesAutoresizingMaskIntoConstraints = false; addSubview(reveal)
        toolScroll.translatesAutoresizingMaskIntoConstraints = false
        toolScroll.showsVerticalScrollIndicator = false
        toolScroll.delaysContentTouches = false
        toolScroll.clipsToBounds = true
        addSubview(toolScroll)
        let tools = UIStackView(arrangedSubviews: [
            button(brushToolButton, symbol: "paintbrush.pointed", label: "Brush tool", action: actions[.selectBrush]!),
            button(eraserToolButton, symbol: "eraser", label: "Eraser tool", action: actions[.selectEraser]!),
            button(colorButton, symbol: "circle.fill", label: "Brush color", action: actions[.pickColor]!),
            button(sizeButton, symbol: "smallcircle.filled.circle", label: "Brush size; drag right to increase", action: actions[.toggleBrush]!),
            button(opacityButton, symbol: "circle.lefthalf.filled", label: "Brush opacity; drag to adjust", action: actions[.toggleOpacity]!),
            button(rulerButton, symbol: "ruler", label: "Straight line; hold or tap to lock", action: actions[.rulerUp]!),
            button(backgroundButton, symbol: "square.fill", label: "Paper color", action: actions[.pickBackground]!),
            button(undoButton, symbol: "arrow.uturn.backward", label: "Undo my last stroke", action: actions[.undo]!),
            button(redoButton, symbol: "arrow.uturn.forward", label: "Redo my stroke", action: actions[.redo]!),
            button(layersButton, symbol: "square.3.layers.3d", label: "Layers", action: actions[.toggleLayers]!),
            button(fingerButton, symbol: "hand.draw", label: "Toggle finger drawing", action: actions[.toggleFinger]!),
            button(zoomButton, symbol: "arrow.up.left.and.arrow.down.right", label: "Fit canvas to screen", action: actions[.fitCanvas]!),
            button(resizeButton, symbol: "crop", label: "Resize canvas", action: actions[.resizeCanvas]!),
            button(symbol: "person.2", label: "Connect to shared canvas", action: actions[.connectRoom]!)
        ])
        tools.axis = .vertical; tools.spacing = 10; tools.alignment = .center
        tools.translatesAutoresizingMaskIntoConstraints = false; toolScroll.addSubview(tools)
        toolScroll.accessibilityIdentifier = "floatingTools"
        let sizeDrag = UIPanGestureRecognizer(target: target, action: actions[.dragBrushSize]!)
        sizeDrag.delegate = target as? UIGestureRecognizerDelegate
        sizeButton.addGestureRecognizer(sizeDrag)
        let opacityDrag = UIPanGestureRecognizer(target: target, action: actions[.dragOpacity]!)
        opacityDrag.delegate = target as? UIGestureRecognizerDelegate
        opacityButton.addGestureRecognizer(opacityDrag)
        toolScroll.panGestureRecognizer.require(toFail: sizeDrag)
        toolScroll.panGestureRecognizer.require(toFail: opacityDrag)
        rulerButton.addTarget(target, action: actions[.rulerDown]!, for: .touchDown)
        rulerButton.addTarget(target, action: actions[.rulerCancel]!, for: [.touchUpOutside, .touchCancel])
        NSLayoutConstraint.activate([
            reveal.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12), reveal.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            toolScroll.leadingAnchor.constraint(equalTo: reveal.leadingAnchor, constant: -8), toolScroll.widthAnchor.constraint(equalToConstant: 60),
            toolScroll.topAnchor.constraint(equalTo: reveal.bottomAnchor, constant: 16), toolScroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
            tools.leadingAnchor.constraint(equalTo: toolScroll.contentLayoutGuide.leadingAnchor), tools.trailingAnchor.constraint(equalTo: toolScroll.contentLayoutGuide.trailingAnchor),
            tools.topAnchor.constraint(equalTo: toolScroll.contentLayoutGuide.topAnchor), tools.bottomAnchor.constraint(equalTo: toolScroll.contentLayoutGuide.bottomAnchor),
            tools.widthAnchor.constraint(equalTo: toolScroll.frameLayoutGuide.widthAnchor)
        ])
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.alpha = 0.75
        statusLabel.isUserInteractionEnabled = false
        statusLabel.backgroundColor = UIColor(white: 0.12, alpha: 1)
        statusLabel.layer.cornerRadius = 10; statusLabel.clipsToBounds = true
        statusLabel.textAlignment = .center; statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "canvasStatus"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false; addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
        configurePanels()
        adjustmentLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        adjustmentLabel.textColor = .white; adjustmentLabel.backgroundColor = UIColor(red: 0.13, green: 0.13, blue: 0.21, alpha: 0.98)
        adjustmentLabel.layer.cornerRadius = 12; adjustmentLabel.clipsToBounds = true
        adjustmentLabel.textAlignment = .center; adjustmentLabel.isUserInteractionEnabled = false
        adjustmentLabel.isHidden = true; addSubview(adjustmentLabel)
    }

    private func configurePanels() {
        for window in windows {
            addSubview(window)
            window.availableArea = { [weak self] in self?.panelArea ?? .zero }
            window.closed = { [weak self] in self?.updatePanelVisibility() }
        }
        let title = UILabel(); title.text = "My layers"; title.font = .preferredFont(forTextStyle: .headline)
        let add = button(symbol: "plus", label: "Add my layer", action: actions[.addLayer]!)
        let header = UIStackView(arrangedSubviews: [title, add]); header.alignment = .center
        let legend = UILabel(); legend.text = "Colored dot = drawing now"; legend.font = .preferredFont(forTextStyle: .caption2); legend.textColor = .secondaryLabel
        layerTable.backgroundColor = .clear; layerTable.dataSource = target as? UITableViewDataSource; layerTable.delegate = target as? UITableViewDelegate
        layerTable.rowHeight = 68; layerTable.register(UITableViewCell.self, forCellReuseIdentifier: "layer")
        layerTable.accessibilityIdentifier = "layerWindow"
        let content = UIStackView(arrangedSubviews: [header, legend, layerTable]); content.axis = .vertical; content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false; layerPanel.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: layerPanel.contentView.leadingAnchor, constant: 12), content.trailingAnchor.constraint(equalTo: layerPanel.contentView.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: layerPanel.contentView.topAnchor, constant: 6), content.bottomAnchor.constraint(equalTo: layerPanel.contentView.bottomAnchor, constant: -8)
        ])
        brushSlider.addTarget(target, action: actions[.changeSize]!, for: .valueChanged)
        brushPanel.opacitySlider.addTarget(target, action: actions[.changeOpacity]!, for: .valueChanged)
    }

    func setTool(_ tool: CanvasDrawingTool) {
        let erasing = tool == .eraser
        brushPanel.setTool(erasing: erasing)
        brushWindow.setTitle(erasing ? "Eraser" : "Brush")
        sizeButton.accessibilityLabel = erasing ? "Eraser size; drag right to increase" : "Brush size; drag right to increase"
        opacityButton.accessibilityLabel = erasing ? "Eraser opacity; drag to adjust" : "Brush opacity; drag to adjust"
    }
    func setBrushMode(_ mode: CanvasBrushPanel.Mode) {
        brushPanel.showSettings(mode)
        brushWindow.setContentHeight(mode == .size ? 410 : 510)
    }
    func showPanel(_ target: UIView?, forceOpen: Bool = false) {
        guard let target else {
            for window in windows { window.isOpen = false }
            updatePanelVisibility(); return
        }
        guard let window = windows.first(where: { $0.content === target }) else { return }
        window.isOpen = !window.isOpen || forceOpen
        if window.isOpen {
            window.present(in: panelArea, avoiding: windows.filter { $0 !== window && $0.isOpen }.map(\.frame))
            bringSubviewToFront(window)
        }
        updatePanelVisibility()
    }
    private func updatePanelVisibility() {
        for window in windows { window.isHidden = interfaceHidden || !window.isOpen }
        layersButton.accessibilityValue = layersWindow.isOpen ? "Open" : "Closed"
    }
    func showAdjustment(_ text: String?, near button: UIButton) {
        guard let text else { adjustmentLabel.isHidden = true; return }
        let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: self)
        adjustmentLabel.frame = CGRect(x: toolScroll.frame.maxX + 4, y: max(safeAreaInsets.top, center.y - 20), width: 140, height: 40)
        adjustmentLabel.text = text; adjustmentLabel.isHidden = false
        bringSubviewToFront(adjustmentLabel)
    }
    func toggleInterface() {
        interfaceHidden.toggle(); updatePanelVisibility()
        toolScroll.isHidden = interfaceHidden; statusLabel.isHidden = interfaceHidden
        interfaceButton.alpha = interfaceHidden ? 0.4 : 1
        interfaceButton.accessibilityValue = interfaceHidden ? "Hidden" : "Visible"
    }
}
