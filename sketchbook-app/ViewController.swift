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
                            UIGestureRecognizerDelegate {
    private let store = CanvasStore()
    private var canvas: DrawingView!
    private var renderer: CanvasRenderer!
    private var viewport = CanvasViewport()
    private var selectedLayerID: String?
    private var activeStrokeID: String?
    private var activeTouch: UITouch?
    private var estimates: [NSNumber: (String, String, CanvasViewport)] = [:]
    private var color = UIColor(red: 0.12, green: 0.18, blue: 0.26, alpha: 1)
    private var activeTool: CanvasDrawingTool = .brush
    private var brushSettings = CanvasToolSettings()
    private var eraserSettings = CanvasToolSettings(width: 32)
    private var currentSettings: CanvasToolSettings {
        get { activeTool == .eraser ? eraserSettings : brushSettings }
        set { if activeTool == .eraser { eraserSettings = newValue } else { brushSettings = newValue } }
    }
    private var brushWidth: Double { get { currentSettings.width } set { currentSettings.width = newValue } }
    private var brushOpacity: Double { get { currentSettings.opacity } set { currentSettings.opacity = newValue } }
    private var maxOpacity: Bool { get { currentSettings.maxOpacity } set { currentSettings.maxOpacity = newValue } }
    private var opacityAtDragStart = 1.0
    private var editingPaper = false
    private var paperPreview: CanvasInk?
    private var activeLine: CanvasStroke?
    private var rulerHeld = false
    private var rulerLocked = false
    private var rulerDownTime: TimeInterval?
    private var rulerUsedDuringHold = false
    private var brushDynamics: CanvasBrushDynamics { get { currentSettings.dynamics } set { currentSettings.dynamics = newValue } }
    private var fingerDrawing = false
    private let controls = CanvasEditorControls()
    private var sizeAtDragStart = 16.0
    private var heartbeat: Timer?
    private var layerSignature = ""
    private var renderedVersion: UInt64?
    private var renderedViewport: CanvasViewport?
    private var renderedLine: UUID?
    private var renderedPaper: CanvasInk?

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
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "brushWidth") != nil { brushWidth = min(512, max(1, defaults.double(forKey: "brushWidth"))) }
        if let data = defaults.data(forKey: "brushDynamics"), let value = try? JSONDecoder().decode(CanvasBrushDynamics.self, from: data), value.isValid { brushDynamics = value }
        if defaults.object(forKey: "brushOpacity") != nil { brushOpacity = min(1, max(0, defaults.double(forKey: "brushOpacity"))) }
        if defaults.object(forKey: "brushMaxOpacity") != nil { maxOpacity = defaults.bool(forKey: "brushMaxOpacity") }
        fingerDrawing = defaults.bool(forKey: "fingerDrawing")
        if let rgb = defaults.array(forKey: "brushColor") as? [Double], rgb.count == 3 {
            color = UIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        }
        if let data = defaults.data(forKey: "eraserSettings"), let settings = try? JSONDecoder().decode(CanvasToolSettings.self, from: data), settings.isValid { eraserSettings = settings }
        activeTool = CanvasDrawingTool(rawValue: defaults.string(forKey: "drawingTool") ?? "brush") ?? .brush
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

    private func configureLayout() {
        for child in [canvas!, controls] {
            child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: view.leadingAnchor), child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.topAnchor.constraint(equalTo: view.topAnchor), child.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        controls.configure(target: self, actions: [
            .selectBrush: #selector(selectBrush), .selectEraser: #selector(selectEraser),
            .toggleInterface: #selector(toggleInterface),
            .pickColor: #selector(pickColor),
            .toggleBrush: #selector(toggleBrush),
            .undo: #selector(undo),
            .redo: #selector(redo),
            .toggleLayers: #selector(toggleLayers),
            .toggleFinger: #selector(toggleFinger),
            .fitCanvas: #selector(fitCanvas),
            .resizeCanvas: #selector(resizeCanvas),
            .connectRoom: #selector(connectRoom),
            .dragBrushSize: #selector(dragBrushSize(_:)),
            .addLayer: #selector(addLayer),
            .changeSize: #selector(changeSize(_:)),
            .toggleOpacity: #selector(toggleOpacity), .dragOpacity: #selector(dragOpacity(_:)),
            .changeOpacity: #selector(changeOpacity(_:)), .pickBackground: #selector(pickBackground),
            .rulerDown: #selector(rulerDown), .rulerUp: #selector(rulerUp), .rulerCancel: #selector(rulerCancel)
        ])
        controls.setTool(activeTool)
        controls.brushPanel.setDynamics(brushDynamics)
        controls.brushPanel.setMaxOpacity(maxOpacity)
        controls.brushPanel.maxOpacityChanged = { [weak self] enabled in
            guard let self else { return }; self.finishStroke(); self.maxOpacity = enabled; self.saveToolPreferences()
        }
        controls.brushPanel.changed = { [weak self] value in
            guard let self else { return }; self.finishStroke(); self.brushDynamics = value; self.saveToolPreferences()
        }
        controls.colorPanel.changed = { [weak self] color in
            guard let self else { return }
            if self.editingPaper {
                guard self.store.canResize else { return }
                self.paperPreview = self.ink(from: color); self.refresh()
            } else { self.color = color; self.saveToolPreferences(); self.refresh() }
        }
        controls.colorPanel.committed = { [weak self] in self?.commitPaper() }
    }
    private func showPanel(_ panel: UIView?, forceOpen: Bool = false) { finishStroke(); commitPaper(); controls.showPanel(panel, forceOpen: forceOpen) }
    private func ink(from color: UIColor) -> CanvasInk {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return CanvasInk(red: r, green: g, blue: b, alpha: 1)
    }
    private func commitPaper() {
        guard let preview = paperPreview else { return }
        paperPreview = nil
        if store.canResize && preview != store.document.paperColor {
            store.submit(CanvasOperation(kind: "background", authorID: store.authorID, color: preview))
            store.save()
        }
        refresh()
    }
    @objc private func toggleInterface() { finishStroke(); commitPaper(); rulerCancel(); controls.toggleInterface() }
    @objc private func selectBrush() { selectTool(.brush) }
    @objc private func selectEraser() { selectTool(.eraser) }
    private func selectTool(_ tool: CanvasDrawingTool) {
        finishStroke(); activeTool = tool
        controls.setTool(tool); controls.brushPanel.setDynamics(brushDynamics); controls.brushPanel.setMaxOpacity(maxOpacity)
        saveToolPreferences(); refresh()
    }
    @objc private func toggleBrush() {
        let switching = controls.brushPanel.mode != .size
        controls.setBrushMode(.size); showPanel(controls.brushPanel, forceOpen: switching)
    }
    @objc private func dragBrushSize(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { finishStroke(); commitPaper(); sizeAtDragStart = brushWidth }
        let delta = gesture.translation(in: view)
        brushWidth = min(512, max(1, sizeAtDragStart + Double(delta.x - delta.y) * 0.5))
        saveToolPreferences(); refresh()
        controls.showAdjustment(gesture.state == .ended || gesture.state == .cancelled ? nil : "Size · \(Int(brushWidth)) px", near: controls.sizeButton)
    }
    @objc private func toggleOpacity() {
        let switching = controls.brushPanel.mode != .opacity
        controls.setBrushMode(.opacity); showPanel(controls.brushPanel, forceOpen: switching)
    }
    @objc private func dragOpacity(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { finishStroke(); commitPaper(); opacityAtDragStart = brushOpacity }
        let delta = gesture.translation(in: view)
        brushOpacity = min(1, max(0, opacityAtDragStart + Double(delta.x - delta.y) / 200))
        saveToolPreferences(); refresh()
        controls.showAdjustment(gesture.state == .ended || gesture.state == .cancelled ? nil : "Opacity · \(Int(brushOpacity * 100))%", near: controls.opacityButton)
    }
    @objc private func changeOpacity(_ slider: UISlider) { finishStroke(); brushOpacity = Double(slider.value); saveToolPreferences(); refresh() }
    @objc private func rulerDown() {
        rulerDownTime = ProcessInfo.processInfo.systemUptime; rulerUsedDuringHold = false; rulerHeld = true; refresh()
    }
    @objc private func rulerUp() {
        let quickTap = rulerDownTime.map { ProcessInfo.processInfo.systemUptime - $0 < 0.3 } ?? true
        if quickTap && !rulerUsedDuringHold { rulerLocked.toggle() }
        rulerCancel()
    }
    @objc private func rulerCancel() { rulerHeld = false; rulerDownTime = nil; refresh() }
    private func canvasTouchCount(_ event: UIEvent?) -> Int {
        event?.allTouches?.filter { $0.view === canvas && $0.phase != .ended && $0.phase != .cancelled }.count ?? 1
    }
    private func saveToolPreferences() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(brushSettings.dynamics) { defaults.set(data, forKey: "brushDynamics") }
        defaults.set(brushSettings.maxOpacity, forKey: "brushMaxOpacity")
        defaults.set(brushSettings.opacity, forKey: "brushOpacity")
        defaults.set(brushSettings.width, forKey: "brushWidth")
        if let data = try? JSONEncoder().encode(eraserSettings) { defaults.set(data, forKey: "eraserSettings") }
        defaults.set(activeTool.rawValue, forKey: "drawingTool")
        defaults.set(fingerDrawing, forKey: "fingerDrawing")
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        defaults.set([Double(r), Double(g), Double(b)], forKey: "brushColor")
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
        if let activeTouch, activeTouch.type == .direct, canvasTouchCount(event) > 1 { finishStroke(); return }
        guard activeTouch == nil, let touch = touches.first(where: { $0.type == .pencil || (fingerDrawing && $0.type == .direct) }),
              touch.type == .pencil || canvasTouchCount(event) == 1,
              let layer = store.document.layers.first(where: { $0.id == selectedLayerID && $0.ownerID == store.authorID && $0.visible }) else { return }
        let sample = point(touch)
        guard (0...store.document.width).contains(sample.x), (0...store.document.height).contains(sample.y) else { return }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let strokeColor = activeTool == .eraser ? CanvasInk(red: 0, green: 0, blue: 0, alpha: brushOpacity) : CanvasInk(red: r, green: g, blue: b, alpha: brushOpacity)
        let stroke = CanvasStroke(layerID: layer.id, authorID: store.authorID,
                                  color: strokeColor, width: brushWidth, dynamics: brushDynamics, maxOpacity: maxOpacity, tool: activeTool, points: [sample])
        activeStrokeID = stroke.id; activeTouch = touch
        if rulerHeld || rulerLocked {
            rulerUsedDuringHold = rulerHeld
            var line = stroke
            line.points.append(CanvasPoint(x: sample.x, y: sample.y, pressure: sample.pressure))
            activeLine = line
            store.activity(layerID: layer.id, drawing: true); refresh(); return
        }
        if estimates.count > 4096 { estimates.removeAll() }
        if let index = touch.estimationUpdateIndex { estimates[index] = (stroke.id, sample.id, viewport) }
        store.submit(CanvasOperation(kind: "beginStroke", authorID: store.authorID, stroke: stroke))
        store.activity(layerID: layer.id, drawing: true)
    }
    private func move(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let strokeID = activeStrokeID else { return }
        if var line = activeLine, let origin = line.points.first, let end = line.points.last {
            var endpoint = point(touch, id: end.id)
            // Pencil force falls to zero on lift; keep the last in-contact line pressure.
            if touch.phase == .ended || touch.phase == .cancelled { endpoint.pressure = end.pressure }
            line.points[1] = CanvasStraightLine.endpoint(from: origin, to: endpoint)
            line.invalidateGeometry(); activeLine = line; refresh(); return
        }
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
        if let line = activeLine {
            activeLine = nil
            store.submit(CanvasOperation(kind: "beginStroke", authorID: store.authorID, stroke: line))
        }
        store.submit(CanvasOperation(kind: "endStroke", authorID: store.authorID, strokeID: strokeID))
        store.activity(layerID: selectedLayerID, drawing: false)
        store.saveEventually()
    }
    @objc private func backgrounded() { finishStroke(); commitPaper(); rulerCancel(); store.save() }

    private func refresh() {
        guard renderer != nil else { return }
        if !store.document.layers.contains(where: { $0.id == selectedLayerID && $0.ownerID == store.authorID }) {
            selectedLayerID = store.ownLayers.last?.id
        }
        if renderedVersion != store.contentVersion || renderedViewport != viewport || renderedLine != activeLine?.renderVersion || renderedPaper != paperPreview {
            var preview = store.document
            if let paperPreview, store.canResize { preview.background = paperPreview }
            if let activeLine { preview.strokes.append(activeLine) }
            renderer.document = preview; renderer.viewport = viewport; canvas.setNeedsDisplay()
            renderedVersion = store.contentVersion; renderedViewport = viewport
            renderedLine = activeLine?.renderVersion; renderedPaper = paperPreview
        }
        controls.undoButton.isEnabled = activeStrokeID == nil && store.document.undoTarget(for: store.authorID) != nil
        controls.redoButton.isEnabled = activeStrokeID == nil && store.document.redoTarget(for: store.authorID) != nil
        controls.resizeButton.isEnabled = store.canResize && activeStrokeID == nil
        controls.colorButton.tintColor = color
        for (button, tool) in [(controls.brushToolButton, CanvasDrawingTool.brush), (controls.eraserToolButton, CanvasDrawingTool.eraser)] {
            button.accessibilityValue = activeTool == tool ? "Selected" : "Not selected"
            button.backgroundColor = activeTool == tool ? UIColor(red: 0.45, green: 0.36, blue: 0.78, alpha: 1) : UIColor(red: 0.18, green: 0.18, blue: 0.32, alpha: 0.94)
        }
        controls.opacityButton.accessibilityValue = "\(Int(brushOpacity * 100)) percent"
        controls.opacityButton.tintColor = UIColor.white.withAlphaComponent(max(0.15, brushOpacity))
        controls.brushPanel.opacityLabel.text = "\(activeTool == .eraser ? "Eraser opacity" : "Opacity") · \(Int(brushOpacity * 100))%"
        controls.brushPanel.opacitySlider.value = Float(brushOpacity)
        let paper = paperPreview ?? store.document.paperColor
        controls.backgroundButton.tintColor = UIColor(red: paper.red, green: paper.green, blue: paper.blue, alpha: 1)
        controls.backgroundButton.accessibilityValue = controls.colorPanel.colorDescription(controls.backgroundButton.tintColor)
        controls.backgroundButton.isEnabled = store.canResize
        controls.backgroundButton.accessibilityHint = store.canResize ? "Change the paper behind your strokes" : "Only the room host can change paper color"
        controls.backgroundButton.alpha = store.canResize ? 1 : 0.35
        controls.rulerButton.backgroundColor = rulerHeld || rulerLocked ? UIColor(red: 0.45, green: 0.36, blue: 0.78, alpha: 1) : UIColor(red: 0.18, green: 0.18, blue: 0.32, alpha: 0.94)
        controls.rulerButton.accessibilityValue = rulerLocked ? "Locked" : (rulerHeld ? "Held" : "Off")
        controls.fingerButton.backgroundColor = fingerDrawing ? UIColor(red: 0.38, green: 0.32, blue: 0.72, alpha: 1) : UIColor(red: 0.18, green: 0.18, blue: 0.32, alpha: 0.94)
        controls.fingerButton.accessibilityValue = fingerDrawing ? "On" : "Off; use Apple Pencil"
        controls.sizeLabel.text = "\(activeTool == .eraser ? "Eraser" : "Brush") · \(Int(brushWidth)) px"
        controls.brushSlider.value = Float(brushWidth)
        controls.sizeButton.accessibilityValue = "\(Int(brushWidth)) pixels"
        controls.colorButton.accessibilityValue = controls.colorPanel.colorDescription(color)
        for control in [controls.undoButton, controls.redoButton, controls.resizeButton] { control.alpha = control.isEnabled ? 1 : 0.35 }
        controls.zoomButton.accessibilityValue = "\(Int(viewport.zoom * 100)) percent of fit"
        controls.statusLabel.text = "\(Int(store.document.width)) × \(Int(store.document.height)) · \(Int(viewport.zoom * 100))% · \(store.status)"
        let signature = store.document.layers.map { layer in
            "\(layer.id):\(layer.visible):\(selectedLayerID == layer.id):\(store.activeArtists(on: layer.id).map(\.authorID).joined())"
        }.joined(separator: "|")
        if signature != layerSignature { layerSignature = signature; controls.layerTable.reloadData() }
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
    @objc private func toggleLayers() { showPanel(controls.layerPanel) }
    @objc private func fitCanvas() { finishStroke(); viewport = CanvasViewport(); refresh() }
    @objc private func toggleFinger() { finishStroke(); fingerDrawing.toggle(); saveToolPreferences(); refresh() }
    @objc private func changeSize(_ slider: UISlider) { finishStroke(); brushWidth = Double(slider.value); saveToolPreferences(); refresh() }
    @objc private func pickColor() {
        commitPaper()
        let switching = editingPaper; editingPaper = false
        controls.colorPanel.setTitle("INK"); controls.colorPanel.setColor(color)
        showPanel(controls.colorPanel, forceOpen: switching)
    }
    @objc private func pickBackground() {
        guard store.canResize else { return }
        commitPaper()
        let switching = !editingPaper; editingPaper = true
        let paper = store.document.paperColor
        controls.colorPanel.setTitle("PAPER")
        controls.colorPanel.setColor(UIColor(red: paper.red, green: paper.green, blue: paper.blue, alpha: 1))
        showPanel(controls.colorPanel, forceOpen: switching)
    }
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
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.view === canvas && otherGestureRecognizer.view === canvas
    }

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
