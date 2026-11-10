# Shared Sketchbook

An iPad drawing app with a Metal canvas and native editor controls. Requires iOS/iPadOS 15 or later and Xcode with the Metal toolchain installed.

## Drawing and layers

- Apple Pencil draws by default. The hand button enables one-finger drawing.
- Pinch with two fingers to zoom; drag with two fingers to pan. The fit button resets the viewport. Each iPad has its own viewport.
- Open **Layers** using the stacked-layers button. The window scrolls for many participants/layers. Tap your layer to select it; use **+** to create another. Other participants' layers show the owner and are read-only.
- A colored dot and **Drawing now** indicate live activity. The participant's indicator color is independent of their brush color. Idle dots are gray. Stale activity expires after four seconds; presence is not saved as artwork.
- Undo/redo affect only your completed strokes, across your layers. Starting a new stroke clears your stroke redo history. Undo does not undo canvas resizing.
- The crop button changes canvas dimensions (64–8192 pixels per side). Resize is anchored at the top-left and preserves all stroke coordinates, including artwork outside the new bounds. Expanding the canvas reveals that artwork again. It does not stretch the painting.
- Local artwork saves automatically. Local canvases and shared rooms have separate files. Use **Return to local canvas** in the connection dialog to switch back.

## Run the collaboration server with Docker

See [server/README.md](server/README.md) for Docker and Cloudflare setup. The app does not need a server for local drawing.

## Validation

Build the `sketchbook-app` scheme for an iPad or iPad Simulator. Install Xcode's Metal toolchain if prompted (`xcodebuild -downloadComponent MetalToolchain`).

Model and viewport checks:

```sh
swiftc sketchbook-app/CanvasDocument.swift tests/CanvasDocumentTests.swift -o /tmp/canvas-model-tests
/tmp/canvas-model-tests
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

The old prototype managers and renderer remain in the repository for reference; the editor no longer uses them. This first version has circular pressure-sensitive brushes, layer ownership/visibility, and stroke undo. It does not include erasing, layer reordering, export, or a document browser.

The server is designed for a small self-hosted group: one process, SQLite, up to 64 connections per room, 256 layers, 10,000 strokes, 50,000 samples per stroke, and a 16 MiB JSON document. It saves a full document per accepted edit and the client redraws visible strokes on changes. Profile and replace these with incremental storage/dirty tiles before using very large documents or high traffic. Do not run multiple server replicas against the same room database.
