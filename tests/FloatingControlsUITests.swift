import XCTest

final class FloatingControlsUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["Brush tool"].waitForExistence(timeout: 10))
        app.buttons["Brush tool"].tap()
    }
    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }
    func testFloatingPanelsAndFocusMode() {
        let layers = app.buttons["Layers"]
        XCTAssertTrue(layers.waitForExistence(timeout: 10))
        XCTAssertFalse(app.tables["layerWindow"].isHittable)
        app.buttons["Brush color"].tap()
        let field = app.descendants(matching: .any)["Saturation and brightness"]
        XCTAssertTrue(field.isHittable)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3)).tap()
        let ink = app.buttons["Brush color"].value as? String
        XCTAssertNotNil(ink)
        XCTAssertTrue(ink?.hasPrefix("#") == true)
        let hue = app.descendants(matching: .any)["Hue"]
        hue.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        let firstHue = app.buttons["Brush color"].value as? String
        hue.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertNotEqual(app.buttons["Brush color"].value as? String, firstHue)
        let colorShot = XCTAttachment(screenshot: app.screenshot()); colorShot.name = "Floating color picker"; colorShot.lifetime = .keepAlways; add(colorShot)
        layers.tap()
        XCTAssertTrue(app.tables["layerWindow"].isHittable)
        XCTAssertTrue(field.exists)
        app.buttons["toggleInterface"].tap()
        XCTAssertFalse(layers.isHittable)
        XCTAssertFalse(app.tables["layerWindow"].isHittable)
        app.buttons["toggleInterface"].tap()
        XCTAssertTrue(layers.isHittable)
        XCTAssertTrue(app.tables["layerWindow"].exists)
        XCTAssertTrue(field.exists)
        let cleanShot = XCTAttachment(screenshot: app.screenshot()); cleanShot.name = "Full canvas"; cleanShot.lifetime = .keepAlways; add(cleanShot)
    }
    func testBrushSizingPersistsAndSharingIsReachableInLandscape() {
        let brush = app.buttons["Brush size; drag right to increase"]
        XCTAssertTrue(brush.waitForExistence(timeout: 10))
        let beforeDrag = brush.value as? String
        let start = brush.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 100, dy: 0)))
        XCTAssertNotEqual(brush.value as? String, beforeDrag)
        brush.tap()
        let slider = app.sliders["Brush width in canvas pixels"]
        XCTAssertTrue(slider.isHittable)
        slider.adjust(toNormalizedSliderPosition: 0.25)
        let chosen = brush.value as? String
        XCTAssertNotNil(chosen)
        app.terminate(); app.launch()
        XCTAssertTrue(brush.waitForExistence(timeout: 10))
        XCTAssertEqual(brush.value as? String, chosen)
        XCUIDevice.shared.orientation = .landscapeLeft
        let dock = app.scrollViews["floatingTools"]
        if !app.buttons["Connect to shared canvas"].isHittable { dock.swipeUp() }
        app.buttons["Connect to shared canvas"].tap()
        XCTAssertTrue(app.alerts["Shared canvas"].waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
        if !app.buttons["Resize canvas"].isHittable { dock.swipeUp() }
        app.buttons["Resize canvas"].tap()
        XCTAssertTrue(app.alerts["Resize canvas"].waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
    }
    func testPressureControlsPersist() {
        app.buttons["Brush size; drag right to increase"].tap()
        let panel = app.scrollViews["brushSettings"]
        let minimum = app.sliders["Size minimum"]
        minimum.adjust(toNormalizedSliderPosition: 0.15)
        let response = app.sliders["Size response curve"]
        response.adjust(toNormalizedSliderPosition: 0.7)
        app.buttons["Brush opacity; drag to adjust"].tap()
        let opacity = app.sliders["Opacity minimum"]
        if !opacity.isHittable { panel.swipeUp() }
        opacity.adjust(toNormalizedSliderPosition: 0.1)
        let saved = opacity.value as? String
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Pressure settings"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launch()
        app.buttons["Brush opacity; drag to adjust"].tap()
        if !opacity.isHittable { panel.swipeUp() }
        XCTAssertEqual(opacity.value as? String, saved)
    }

    func testDragOpacityAndPaperColorPersist() {
        let opacity = app.buttons["Brush opacity; drag to adjust"]
        XCTAssertTrue(opacity.waitForExistence(timeout: 10))
        opacity.tap()
        app.sliders["Brush opacity"].adjust(toNormalizedSliderPosition: 0.5)
        opacity.tap()
        let before = opacity.value as? String
        let start = opacity.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 70, dy: -20)))
        let dragged = opacity.value as? String
        XCTAssertNotEqual(dragged, before)
        app.buttons["Paper color"].tap()
        app.buttons["Black swatch"].tap()
        XCTAssertEqual(app.buttons["Paper color"].value as? String, "#000000")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Paper color picker"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launch()
        XCTAssertEqual(app.buttons["Paper color"].value as? String, "#000000")
        XCTAssertEqual(opacity.value as? String, dragged)
        app.buttons["Paper color"].tap(); app.buttons["White swatch"].tap(); app.buttons["Paper color"].tap()
    }
    func testRulerHoldAndLockedStraightLine() {
        let ruler = app.buttons["Straight line; hold or tap to lock"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        ruler.press(forDuration: 0.6)
        XCTAssertEqual(ruler.value as? String, "Off")
        ruler.tap()
        XCTAssertEqual(ruler.value as? String, "Locked")
        let finger = app.buttons["Toggle finger drawing"]
        let enabledFinger = finger.value as? String == "On"
        if !enabledFinger { finger.tap() }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.455))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.buttons["Undo my last stroke"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Snapped straight line"; shot.lifetime = .keepAlways; add(shot)
        ruler.tap(); XCTAssertEqual(ruler.value as? String, "Off")
        app.buttons["Undo my last stroke"].tap()
        if !enabledFinger { finger.tap() }
    }

    func testSeparateSettingsAndUniformOpacityPersist() {
        app.buttons["Brush size; drag right to increase"].tap()
        XCTAssertTrue(app.sliders["Brush width in canvas pixels"].exists)
        XCTAssertTrue(app.sliders["Size minimum"].exists)
        XCTAssertFalse(app.sliders["Brush opacity"].exists)
        XCTAssertFalse(app.sliders["Opacity minimum"].exists)
        app.buttons["Brush opacity; drag to adjust"].tap()
        XCTAssertTrue(app.sliders["Brush opacity"].exists)
        XCTAssertTrue(app.sliders["Opacity minimum"].exists)
        XCTAssertFalse(app.sliders["Brush width in canvas pixels"].exists)
        XCTAssertFalse(app.sliders["Size minimum"].exists)
        let toggle = app.switches["Non-accumulating stroke opacity"]
        let panel = app.scrollViews["brushSettings"]
        if !toggle.isHittable { panel.swipeUp() }
        let before = toggle.value as? String
        toggle.tap()
        let selected = toggle.value as? String
        XCTAssertNotEqual(selected, before)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Opacity-only settings"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launch()
        app.buttons["Brush opacity; drag to adjust"].tap()
        if !toggle.isHittable { panel.swipeUp() }
        XCTAssertEqual(toggle.value as? String, selected)
        if toggle.value as? String != "1" { toggle.tap() }
        app.buttons["Brush size; drag right to increase"].tap()
        let sizeShot = XCTAttachment(screenshot: app.screenshot()); sizeShot.name = "Size-only settings"; sizeShot.lifetime = .keepAlways; add(sizeShot)
        XCTAssertFalse(toggle.exists)
    }

    func testPanelsMoveResizeAndRemainOpenTogether() {
        app.buttons["Brush color"].tap()
        let color = app.otherElements["floatingColorPanel"]
        let drag = app.otherElements["dragColorPanel"]
        XCTAssertTrue(drag.waitForExistence(timeout: 5))
        let original = color.frame
        let start = drag.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 40, dy: 60)))
        XCTAssertGreaterThan(color.frame.minY, original.minY + 30)
        let moved = color.frame
        let ink = app.buttons["Brush color"].value as? String
        let grip = app.otherElements["resizeColorPanel"]
        let resizeStart = grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        resizeStart.press(forDuration: 0.1, thenDragTo: resizeStart.withOffset(CGVector(dx: 70, dy: 60)))
        XCTAssertGreaterThan(color.frame.width, moved.width + 10)
        XCTAssertGreaterThan(color.frame.height, moved.height + 20)
        XCTAssertEqual(app.buttons["Brush color"].value as? String, ink)
        let resized = color.frame
        app.buttons["Close color picker panel"].tap()
        XCTAssertFalse(drag.exists)
        app.buttons["Brush color"].tap()
        XCTAssertEqual(color.frame.width, resized.width, accuracy: 1)
        XCTAssertEqual(color.frame.minY, resized.minY, accuracy: 1)
        app.buttons["Brush size; drag right to increase"].tap()
        app.buttons["Layers"].tap()
        XCTAssertTrue(app.otherElements["dragBrushPanel"].exists)
        XCTAssertTrue(app.otherElements["dragLayersPanel"].exists)
        XCTAssertTrue(drag.exists)
        let status = app.staticTexts["canvasStatus"]
        XCTAssertEqual(status.frame.maxX, app.frame.maxX, accuracy: 1)
        XCTAssertEqual(status.frame.maxY, app.frame.maxY, accuracy: 1)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Movable concurrent panels"; shot.lifetime = .keepAlways; add(shot)
        XCUIDevice.shared.orientation = .landscapeLeft
        for id in ["floatingColorPanel", "floatingBrushPanel", "floatingLayersPanel"] {
            let panel = app.otherElements[id]
            XCTAssertTrue(panel.exists)
            XCTAssertLessThanOrEqual(panel.frame.maxX, app.frame.maxX + 1)
            XCTAssertLessThanOrEqual(panel.frame.maxY, app.frame.maxY + 1)
        }
    }

    func testEraserSettingsAreIndependentAndPersist() {
        let brushSize = app.buttons["Brush size; drag right to increase"]
        let brushOpacity = app.buttons["Brush opacity; drag to adjust"]
        brushSize.tap(); app.sliders["Brush width in canvas pixels"].adjust(toNormalizedSliderPosition: 0.2)
        let savedBrushSize = brushSize.value as? String
        brushOpacity.tap(); app.sliders["Brush opacity"].adjust(toNormalizedSliderPosition: 0.3)
        let savedBrushOpacity = brushOpacity.value as? String
        app.buttons["Eraser tool"].tap()
        XCTAssertEqual(app.buttons["Eraser tool"].value as? String, "Selected")
        app.sliders["Eraser opacity"].adjust(toNormalizedSliderPosition: 0.75)
        let savedEraserOpacity = app.buttons["Eraser opacity; drag to adjust"].value as? String
        app.buttons["Eraser size; drag right to increase"].tap()
        app.sliders["Eraser width in canvas pixels"].adjust(toNormalizedSliderPosition: 0.6)
        let savedEraserSize = app.buttons["Eraser size; drag right to increase"].value as? String
        app.sliders["Size minimum"].adjust(toNormalizedSliderPosition: 0.4)
        let savedCurve = app.sliders["Size minimum"].value as? String
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Independent eraser settings"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launch()
        XCTAssertEqual(app.buttons["Eraser tool"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["Eraser size; drag right to increase"].value as? String, savedEraserSize)
        XCTAssertEqual(app.buttons["Eraser opacity; drag to adjust"].value as? String, savedEraserOpacity)
        app.buttons["Eraser size; drag right to increase"].tap()
        XCTAssertEqual(app.sliders["Size minimum"].value as? String, savedCurve)
        app.buttons["Brush tool"].tap()
        XCTAssertEqual(brushSize.value as? String, savedBrushSize)
        XCTAssertEqual(brushOpacity.value as? String, savedBrushOpacity)
    }

}
