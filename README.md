# Shared Sketchbook

An iPad drawing app with a full-screen Metal canvas and compact floating controls. Requires iOS/iPadOS 15 or later and Xcode with the Metal toolchain installed.

## Drawing and layers

- The canvas fills the screen. Small purple controls float along the left edge; the grid button hides/restores the controls. Scroll the buttons vertically in a short window. Layers, ink, and brush panels start closed and can stay open together. Drag each title bar to move it, close it with ×, and drag the color picker’s bottom-right grip to resize it. Panel positions and color-picker size survive closing/reopening during the session; rotation keeps panels on screen. Hiding/restoring controls also restores the open panels.
- Tap the ink dot for the custom saturation/brightness square and hue strip. Tap the brush circle for a 1–512 pixel size slider, or drag the circle right/left to increase/decrease the brush size. Color, size, and finger-drawing preference are remembered across launches.
- The brush panel includes independent size and stamp-opacity pressure curves. Set the light-touch/firm-pressure percentages and a soft, linear, or firm response. Equal minimum/maximum values turn pressure variation off for that property. Finger input uses full pressure; the opacity panel’s **Uniform stroke opacity** toggle controls stamp build-up. Settings are remembered and captured in each stroke; existing strokes keep their original response.
- **Uniform stroke opacity** is enabled for new strokes by default: stamps within a stroke use the highest opacity at each pixel, including pressure and edge coverage. Separate strokes still blend normally. Turn it off in opacity settings for accumulating/highlighter behavior. The choice is remembered and saved per stroke; older saved strokes retain their original accumulating appearance.
- Drag the size or opacity button right/up to increase, left/down to decrease, with a live value readout. Tap size for size-only settings; tap opacity for opacity-only settings. Overall opacity multiplies the pressure-opacity curve without changing it.
- The paper button opens quick white, warm-paper, gray, and black swatches plus the custom color picker. Paper color is saved with the canvas and shared; the room host controls it, like canvas size. The picker previews immediately and commits when you lift your finger/Pencil.
- Hold the ruler with one hand while drawing with the other to make a straight line at any angle. Within two degrees of horizontal/vertical it snaps to that axis. A quick ruler tap locks/unlocks line mode for one-handed use. Each line has a local live preview and is shared as a completed, undoable stroke on lift. The mode is captured when a stroke starts, so releasing the ruler early still completes that line.
- Select the brush or eraser with their separate floating tool buttons. Size, opacity, pressure curves and uniform/accumulating mode are saved independently for each tool. The size/opacity buttons and settings card edit the selected tool. Erasing removes ink only from your selected layer, reveals lower layers and paper, and supports stroke undo/redo; it does not paint with the paper color.
- Apple Pencil draws by default. The hand button enables one-finger drawing.
- Pinch with two fingers to zoom; drag with two fingers to pan. The fit button resets the viewport. Each iPad has its own viewport.
- Open **Layers** using the stacked-layers button. The window scrolls for many participants/layers. Tap your layer to select it; use **+** to create another. Other participants' layers show the owner and are read-only.
- A colored dot and **Drawing now** indicate live activity. The participant's indicator color is independent of their brush color. Idle dots are gray. Stale activity expires after four seconds; presence is not saved as artwork.
- Undo/redo affect only your completed strokes, across your layers. Starting a new stroke clears your stroke redo history. Undo does not undo canvas resizing.
- The crop button changes canvas dimensions (64–8192 pixels per side). Resize is anchored at the top-left and preserves all stroke coordinates, including artwork outside the new bounds. Expanding the canvas reveals that artwork again. It does not stretch the painting.
- Local artwork saves automatically. Local canvases and shared rooms have separate files. Use **Return to local canvas** in the connection dialog to switch back.

## Run the collaboration server with Docker

See [server/README.md](server/README.md) for Docker and Cloudflare setup. The app does not need a server for local drawing. Update the app and server together for shared pressure dynamics, uniform stroke opacity, paper colors, and eraser strokes; older app versions do not render custom pressure curves.

## Validation

Build the `sketchbook-app` scheme for an iPad or iPad Simulator. Install Xcode's Metal toolchain if prompted (`xcodebuild -downloadComponent MetalToolchain`).

The shared Xcode scheme also includes `FloatingControlsUITests`. Run **Product → Test** on an iPad Simulator to check panel switching, hiding/restoring controls, remembered brush sizing, separate size/opacity cards, the uniform-opacity toggle, and sharing/resize access in landscape.

Model and viewport checks:

```sh
swiftc sketchbook-app/CanvasDocument.swift tests/CanvasDocumentTests.swift -o /tmp/canvas-model-tests
/tmp/canvas-model-tests
```

GPU pixel regression checks on an Apple Silicon Mac verify max-opacity retracing, pressure maxima, separate-stroke blending, legacy accumulation, mixed stroke order, and zoom/high-DPI masks using the app’s actual shaders:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun -sdk macosx metal -c sketchbook-app/Shaders.metal -o /tmp/canvas-render.air
xcrun -sdk macosx metallib /tmp/canvas-render.air -o /tmp/canvas-render.metallib
xcrun -sdk macosx swiftc -sdk "$(xcrun -sdk macosx --show-sdk-path)" -target arm64-apple-macosx15.0 sketchbook-app/CanvasDocument.swift sketchbook-app/CanvasRenderer.swift tests/CanvasRenderingTests.swift -o /tmp/canvas-render-tests
/tmp/canvas-render-tests /tmp/canvas-render.metallib
```

Real WebSocket tests with four participants, ownership checks, activity, undo/redo, resize, retry deduplication, and server restart recovery:

```sh
python3 -m venv /tmp/canvas-tests
/tmp/canvas-tests/bin/pip install -r server/requirements.txt
/tmp/canvas-tests/bin/python -m unittest discover -s tests -p 'test_*.py' -v
```

Native Swift client/server integration (macOS):

```sh
swiftc sketchbook-app/CanvasDocument.swift sketchbook-app/CanvasStore.swift tests/CanvasSyncTests.swift -o /tmp/canvas-sync-tests
/tmp/canvas-tests/bin/python tests/run_native_sync.py /tmp/canvas-sync-tests
```

## Structure and limits

`CanvasDocument` owns serializable artwork and document operations. `CanvasStore` serializes optimistic local edits, persistence, acknowledgements and reconnects. `CanvasRenderer` renders immutable per-stroke stamp buffers; textures are not the document. `ViewController` owns native controls, input and the local viewport.

`CanvasEditorControls` owns the floating controls and touch pass-through; `CanvasFloatingPanel` owns draggable/resizable panel chrome. The padded status badge sits flush at the bottom-right screen edge at 75% opacity. `CanvasColorPanel` owns the custom HSV picker; `CanvasBrushPanel` owns size and pressure controls. Finished artwork is cached per visible layer within a 64 MiB/four-layer budget, live geometry appends in immutable chunks, and routine saves run on a serial worker. See [drawing performance measurements](docs/DRAWING_PERFORMANCE.md). Editor actions continue to use the same document/store operations.

The old prototype managers and renderer remain in the repository for reference; the editor no longer uses them. This first version has circular pressure-sensitive brushes, layer ownership/visibility, and stroke undo. It does not include layer reordering, export, or a document browser.

The server is designed for a small self-hosted group: one process, SQLite, up to 64 connections per room, 256 layers, 10,000 strokes, 50,000 samples per stroke, and a 16 MiB JSON document. It saves a full document per accepted edit and the client redraws visible strokes on changes. Profile and replace these with incremental storage/dirty tiles before using very large documents or high traffic. Do not run multiple server replicas against the same room database.
