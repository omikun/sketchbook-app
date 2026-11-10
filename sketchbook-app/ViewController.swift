import UIKit
import MetalKit

private final class DrawingView: MTKView {
    var began: ((Set<UITouch>, UIEvent?) -> Void)?
    var moved: ((Set<UITouch>, UIEvent?) -> Void)?
    var ended: ((Set<UITouch>, UIEvent?) -> Void)?
    var corrected: ((Set<UITouch>) -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { began?(touches, event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { moved?(touches, event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { ended?(touches, event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { ended?(touches, event) }
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) { corrected?(touches) }
}

final class ViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
                            UIGestureRecognizerDelegate, UIColorPickerViewControllerDelegate {
    private let store = CanvasStore()
    private var canvas: DrawingView!
    private var renderer: CanvasRenderer!
    private var viewport = CanvasViewport()
    private var selectedLayerID: String?
    private var activeStrokeID: String?
    private var activeTouch: UITouch?
    private var estimates: [NSNumber: (String, String, CanvasViewport)] = [:]
    private var color = UIColor(red: 0.12, green: 0.18, blue: 0.26, alpha: 1)
    private var brushWidth = 16.0
    private var fingerDrawing = false
    private let layerPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let layerTable = UITableView(frame: .zero, style: .plain)
    private let statusLabel = UILabel()
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private let resizeButton = UIButton(type: .system)
    private let colorButton = UIButton(type: .system)
    private let fingerButton = UIButton(type: .system)
    private let zoomButton = UIButton(type: .system)
    private let sizeLabel = UILabel()
    private var heartbeat: Timer?
    private var layerSignature = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        guard let device = MTLCreateSystemDefaultDevice() else {
            showUnavailable("This device cannot run the Metal canvas."); return
        }
        canvas = DrawingView(frame: .zero, device: device)
        canvas.colorPixelFormat = .bgra8Unorm_srgb
        canvas.isPaused = true; canvas.enableSetNeedsDisplay = true
        canvas.isMultipleTouchEnabled = true
        do { renderer = try CanvasRenderer(device: device, format: canvas.colorPixelFormat) }
        catch { showUnavailable(error.localizedDescription); return }
        canvas.delegate = renderer
        configureLayout()
        configureInput()
        store.changed = { [weak self] in self?.refresh() }
        store.message = { [weak self] detail in self?.showMessage(detail) }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.heartbeat() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIScene.didEnterBackgroundNotification, object: nil)
        refresh()
    }

    deinit { heartbeat?.invalidate(); NotificationCenter.default.removeObserver(self) }

    private func button(_ button: UIButton = UIButton(type: .system), symbol: String, label: String, action: Selector) -> UIButton {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }
    private func configureLayout() {
        let topScroll = UIScrollView()
        topScroll.showsHorizontalScrollIndicator = false
        let top = UIStackView(arrangedSubviews: [
            button(symbol: "person.2", label: "Connect to shared canvas", action: #selector(connectRoom)),
            button(undoButton, symbol: "arrow.uturn.backward", label: "Undo my last stroke", action: #selector(undo)),
            button(redoButton, symbol: "arrow.uturn.forward", label: "Redo my stroke", action: #selector(redo)),
            button(zoomButton, symbol: "arrow.up.left.and.arrow.down.right", label: "Fit canvas to screen", action: #selector(fitCanvas)),
            button(resizeButton, symbol: "crop", label: "Resize canvas", action: #selector(resizeCanvas)),
            button(symbol: "square.3.layers.3d", label: "Show or hide layer window", action: #selector(toggleLayers))
        ])
        let tools = UIStackView()
        tools.axis = .horizontal; tools.spacing = 8; tools.alignment = .center
        tools.addArrangedSubview(button(colorButton, symbol: "circle.fill", label: "Choose brush color", action: #selector(pickColor)))
        tools.addArrangedSubview(button(fingerButton, symbol: "hand.draw", label: "Toggle finger drawing", action: #selector(toggleFinger)))
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let slider = UISlider(); slider.minimumValue = 1; slider.maximumValue = 128; slider.value = Float(brushWidth)
        slider.accessibilityLabel = "Brush width in canvas pixels"
        slider.addTarget(self, action: #selector(changeSize(_:)), for: .valueChanged)
        tools.addArrangedSubview(slider); tools.addArrangedSubview(sizeLabel)
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel; statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "canvasStatus"
        for child in [topScroll, tools, canvas!, statusLabel, layerPanel] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        top.translatesAutoresizingMaskIntoConstraints = false; topScroll.addSubview(top)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topScroll.topAnchor.constraint(equalTo: safe.topAnchor), topScroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            topScroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12), topScroll.heightAnchor.constraint(equalToConstant: 48),
            top.topAnchor.constraint(equalTo: topScroll.contentLayoutGuide.topAnchor), top.bottomAnchor.constraint(equalTo: topScroll.contentLayoutGuide.bottomAnchor),
            top.leadingAnchor.constraint(equalTo: topScroll.contentLayoutGuide.leadingAnchor), top.trailingAnchor.constraint(equalTo: topScroll.contentLayoutGuide.trailingAnchor),
            top.heightAnchor.constraint(equalTo: topScroll.frameLayoutGuide.heightAnchor),
            tools.topAnchor.constraint(equalTo: topScroll.bottomAnchor), tools.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            tools.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12), tools.heightAnchor.constraint(equalToConstant: 48),
            canvas.topAnchor.constraint(equalTo: tools.bottomAnchor), canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor), canvas.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16), statusLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -6), statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            layerPanel.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 12), layerPanel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            layerPanel.widthAnchor.constraint(equalToConstant: 280), layerPanel.heightAnchor.constraint(equalTo: canvas.heightAnchor, multiplier: 0.55)
        ])
        layerPanel.layer.cornerRadius = 16; layerPanel.clipsToBounds = true
        let title = UILabel(); title.text = "Layers"; title.font = .preferredFont(forTextStyle: .headline)
        let add = button(symbol: "plus", label: "Add my layer", action: #selector(addLayer))
        let header = UIStackView(arrangedSubviews: [title, add]); header.alignment = .center
        let legend = UILabel(); legend.text = "Colored dot = drawing now"; legend.font = .preferredFont(forTextStyle: .caption2); legend.textColor = .secondaryLabel
        layerTable.backgroundColor = .clear; layerTable.dataSource = self; layerTable.delegate = self
        layerTable.rowHeight = 68; layerTable.register(UITableViewCell.self, forCellReuseIdentifier: "layer")
        layerTable.accessibilityIdentifier = "layerWindow"
        let content = UIStackView(arrangedSubviews: [header, legend, layerTable]); content.axis = .vertical; content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false; layerPanel.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: layerPanel.contentView.leadingAnchor, constant: 12), content.trailingAnchor.constraint(equalTo: layerPanel.contentView.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: layerPanel.contentView.topAnchor, constant: 6), content.bottomAnchor.constraint(equalTo: layerPanel.contentView.bottomAnchor, constant: -8)
        ])
    }

    private func configureInput() {
        canvas.began = { [weak self] touches, event in self?.begin(touches, event: event) }
        canvas.moved = { [weak self] touches, event in self?.move(touches, event: event) }
        canvas.ended = { [weak self] touches, event in
            guard let self, let touch = self.activeTouch, touches.contains(touch) else { return }
            self.move(touches, event: event); self.finishStroke()
        }
        canvas.corrected = { [weak self] touches in self?.correct(touches) }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:))); pan.minimumNumberOfTouches = 2
        for gesture in [pinch, pan] {
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            gesture.delegate = self; canvas.addGestureRecognizer(gesture)
        }
        let interaction = UIPencilInteraction(); interaction.delegate = self; canvas.addInteraction(interaction)
    }
    private func point(_ touch: UITouch, id: String = UUID().uuidString, using transform: CanvasViewport? = nil) -> CanvasPoint {
        let location = touch.preciseLocation(in: canvas)
        let p = (transform ?? viewport).point(x: location.x, y: location.y, viewWidth: canvas.bounds.width, viewHeight: canvas.bounds.height, document: store.document)
        let pressure = touch.type == .pencil && touch.maximumPossibleForce > 0 ? touch.force / touch.maximumPossibleForce : 1
        return CanvasPoint(id: id, x: min(16384, max(-8192, p.0)), y: min(16384, max(-8192, p.1)), pressure: Double(pressure))
    }
    private func begin(_ touches: Set<UITouch>, event: UIEvent?) {
        if let activeTouch, activeTouch.type == .direct, (event?.allTouches?.count ?? 0) > 1 { finishStroke(); return }
        guard activeTouch == nil, let touch = touches.first(where: { $0.type == .pencil || (fingerDrawing && $0.type == .direct) }),
              touch.type == .pencil || (event?.allTouches?.count ?? 1) == 1,
              let layer = store.document.layers.first(where: { $0.id == selectedLayerID && $0.ownerID == store.authorID && $0.visible }) else { return }
        let sample = point(touch)
        guard (0...store.document.width).contains(sample.x), (0...store.document.height).contains(sample.y) else { return }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let stroke = CanvasStroke(layerID: layer.id, authorID: store.authorID,
                                  color: CanvasInk(red: r, green: g, blue: b, alpha: a), width: brushWidth, points: [sample])
        activeStrokeID = stroke.id; activeTouch = touch
        if estimates.count > 4096 { estimates.removeAll() }
        if let index = touch.estimationUpdateIndex { estimates[index] = (stroke.id, sample.id, viewport) }
        store.submit(CanvasOperation(kind: "beginStroke", authorID: store.authorID, stroke: stroke))
        store.activity(layerID: layer.id, drawing: true)
    }
    private func move(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let strokeID = activeStrokeID else { return }
        let samples = (event?.coalescedTouches(for: touch) ?? [touch]).map { touch -> CanvasPoint in
            let existing = touch.estimationUpdateIndex.flatMap { estimates[$0] }
            let sample = point(touch, id: existing?.0 == strokeID ? existing!.1 : UUID().uuidString)
            if let index = touch.estimationUpdateIndex { estimates[index] = (strokeID, sample.id, viewport) }
            return sample
        }
        store.submit(CanvasOperation(kind: "samples", authorID: store.authorID, strokeID: strokeID, points: samples))
    }
    private func correct(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let index = touch.estimationUpdateIndex, let (strokeID, sampleID, transform) = estimates[index] else { continue }
            store.submit(CanvasOperation(kind: "samples", authorID: store.authorID, strokeID: strokeID, points: [point(touch, id: sampleID, using: transform)]))
            if touch.estimatedPropertiesExpectingUpdates.isEmpty { estimates.removeValue(forKey: index) }
        }
    }
    private func finishStroke() {
        guard let strokeID = activeStrokeID else { return }
        activeTouch = nil; activeStrokeID = nil
        store.submit(CanvasOperation(kind: "endStroke", authorID: store.authorID, strokeID: strokeID))
        store.activity(layerID: selectedLayerID, drawing: false)
        store.save()
    }
    @objc private func backgrounded() { finishStroke(); store.save() }

    private func refresh() {
        guard renderer != nil else { return }
        if !store.document.layers.contains(where: { $0.id == selectedLayerID && $0.ownerID == store.authorID }) {
            selectedLayerID = store.ownLayers.last?.id
        }
        renderer.document = store.document; renderer.viewport = viewport; canvas.setNeedsDisplay()
        undoButton.isEnabled = activeStrokeID == nil && store.document.undoTarget(for: store.authorID) != nil
        redoButton.isEnabled = activeStrokeID == nil && store.document.redoTarget(for: store.authorID) != nil
        resizeButton.isEnabled = store.canResize && activeStrokeID == nil
        colorButton.tintColor = color; fingerButton.tintColor = fingerDrawing ? .systemBlue : .secondaryLabel
        fingerButton.accessibilityValue = fingerDrawing ? "On" : "Off; use Apple Pencil"
        sizeLabel.text = "\(Int(brushWidth)) px"
        zoomButton.accessibilityValue = "\(Int(viewport.zoom * 100)) percent of fit"
        statusLabel.text = "\(Int(store.document.width)) × \(Int(store.document.height)) · \(Int(viewport.zoom * 100))% · \(store.status)"
        let signature = store.document.layers.map { layer in
            "\(layer.id):\(layer.visible):\(selectedLayerID == layer.id):\(store.activeArtists(on: layer.id).map(\.authorID).joined())"
        }.joined(separator: "|")
        if signature != layerSignature { layerSignature = signature; layerTable.reloadData() }
    }
    private var displayedLayers: [CanvasLayer] { Array(store.document.layers.reversed()) }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { displayedLayers.count }
    private func participantColor(_ id: String) -> UIColor {
        let number = id.utf8.reduce(0) { ($0 * 31 + Int($1)) % 360 }
        return UIColor(hue: CGFloat(number) / 360, saturation: 0.8, brightness: 0.85, alpha: 1)
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let layer = displayedLayers[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "layer", for: indexPath)
        let active = store.activeArtists(on: layer.id)
        let mine = layer.ownerID == store.authorID
        var content = cell.defaultContentConfiguration()
        content.text = layer.name
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryText = "\(mine ? "You" : layer.ownerName) · \(!active.isEmpty ? "Drawing now" : (layer.visible ? (mine ? "Editable" : "Read only") : "Hidden"))"
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        content.image = UIImage(systemName: "circle.fill")
        content.imageProperties.maximumSize = CGSize(width: 10, height: 10)
        content.imageProperties.tintColor = active.first.map { participantColor($0.authorID) } ?? .tertiaryLabel
        content.textProperties.color = layer.visible ? .label : .secondaryLabel
        cell.contentConfiguration = content
        cell.backgroundColor = selectedLayerID == layer.id ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
        let eye = UIButton(type: .system)
        eye.setImage(UIImage(systemName: layer.visible ? "eye" : "eye.slash"), for: .normal)
        eye.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        eye.isEnabled = mine; eye.accessibilityLabel = "\(layer.visible ? "Hide" : "Show") \(layer.name)"
        eye.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.finishStroke()
            self.store.submit(CanvasOperation(kind: "layerVisibility", authorID: self.store.authorID, layerID: layer.id, visible: !layer.visible))
        }, for: .touchUpInside)
        cell.accessoryView = eye
        cell.accessibilityLabel = "\(layer.name), \(content.secondaryText ?? "")"
        cell.accessibilityTraits = selectedLayerID == layer.id ? [.selected, .button] : .button
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let layer = displayedLayers[indexPath.row]
        guard layer.ownerID == store.authorID else { showMessage("\(layer.ownerName) owns this layer. Select one of your layers to paint."); return }
        finishStroke(); selectedLayerID = layer.id; refresh()
    }

    @objc private func undo() { finishStroke(); store.undo() }
    @objc private func redo() { finishStroke(); store.redo() }
    @objc private func addLayer() { finishStroke(); store.addLayer(); selectedLayerID = store.ownLayers.last?.id; refresh() }
    @objc private func toggleLayers() { layerPanel.isHidden.toggle() }
    @objc private func fitCanvas() { finishStroke(); viewport = CanvasViewport(); refresh() }
    @objc private func toggleFinger() { finishStroke(); fingerDrawing.toggle(); refresh() }
    @objc private func changeSize(_ slider: UISlider) { brushWidth = Double(slider.value); refresh() }
    @objc private func pickColor() {
        finishStroke()
        let picker = UIColorPickerViewController(); picker.selectedColor = color; picker.supportsAlpha = false; picker.delegate = self
        present(picker, animated: true)
    }
    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) { color = viewController.selectedColor; refresh() }
    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        guard activeTouch?.type != .pencil else { return }
        finishStroke()
        let anchor = gesture.location(in: canvas)
        viewport.zoom(by: gesture.scale, anchorX: anchor.x, anchorY: anchor.y, viewWidth: canvas.bounds.width, viewHeight: canvas.bounds.height)
        gesture.scale = 1; refresh()
    }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard activeTouch?.type != .pencil else { return }
        finishStroke()
        let delta = gesture.translation(in: canvas)
        viewport.panX += delta.x; viewport.panY += delta.y
        gesture.setTranslation(.zero, in: canvas); refresh()
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    @objc private func resizeCanvas() {
        finishStroke()
        let alert = UIAlertController(title: "Resize canvas", message: "Enter dimensions from 64 to 8192 pixels. The top-left stays fixed. Cropped artwork is preserved and reappears if you expand the canvas. In a shared room, only the host can resize.", preferredStyle: .alert)
        for value in [store.document.width, store.document.height] {
            alert.addTextField { field in field.keyboardType = .numberPad; field.text = String(Int(value)) }
        }
        alert.textFields?[0].accessibilityLabel = "Canvas width"
        alert.textFields?[1].accessibilityLabel = "Canvas height"
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Resize", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields,
                  let w = Double(fields[0].text ?? ""), let h = Double(fields[1].text ?? ""),
                  (64...8192).contains(w), (64...8192).contains(h) else { self?.showMessage("Use dimensions between 64 and 8192 pixels."); return }
            self.store.submit(CanvasOperation(kind: "resize", authorID: self.store.authorID, width: w, height: h))
            self.viewport = CanvasViewport(); self.refresh()
        })
        present(alert, animated: true)
    }
    @objc private func connectRoom() {
        finishStroke()
        let alert = UIAlertController(title: "Shared canvas", message: "Connect to your Docker server using its secure WebSocket address. Your local canvas stays saved separately. The first participant becomes the host.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "wss://canvas.example.com"; $0.text = UserDefaults.standard.string(forKey: "canvasEndpoint"); $0.autocapitalizationType = .none; $0.keyboardType = .URL }
        alert.addTextField { $0.placeholder = "Room name"; $0.text = UserDefaults.standard.string(forKey: "canvasRoom") ?? "sketchbook"; $0.autocapitalizationType = .none }
        alert.addTextField { $0.placeholder = "Room access token"; $0.isSecureTextEntry = true; $0.autocapitalizationType = .none }
        alert.addTextField { $0.placeholder = "Your name"; $0.text = "Artist" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if store.isRoom { alert.addAction(UIAlertAction(title: "Return to local canvas", style: .default) { [weak self] _ in self?.store.useLocalCanvas(); self?.viewport = CanvasViewport(); self?.refresh() }) }
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields, let url = URL(string: fields[0].text ?? ""),
                  ["wss", "ws"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  let room = fields[1].text, !room.isEmpty, room.count <= 64,
                  let token = fields[2].text, !token.isEmpty else { self?.showMessage("Enter a WebSocket address, room name, and access token."); return }
            UserDefaults.standard.set(url.absoluteString, forKey: "canvasEndpoint"); UserDefaults.standard.set(room, forKey: "canvasRoom")
            self.estimates.removeAll(); self.viewport = CanvasViewport()
            self.store.connect(url: url, room: room, token: token, name: fields[3].text ?? "Artist")
        })
        present(alert, animated: true)
    }
    private func showUnavailable(_ detail: String) {
        let label = UILabel(frame: view.bounds); label.text = detail; label.numberOfLines = 0; label.textAlignment = .center
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(label)
    }
    private func showMessage(_ detail: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Sketchbook", message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}

extension ViewController: UIPencilInteractionDelegate {
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) { pickColor() }
}
