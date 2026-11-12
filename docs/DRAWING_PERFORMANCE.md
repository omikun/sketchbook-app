# Drawing performance: 2026-11-10

The drawing path previously regenerated the active stroke’s complete stamp buffer, rerasterized every visible historical stroke, and copied/serialized document state on the input thread. Max-opacity strokes additionally required a mask/composite pass every frame, including old artwork.

## Changes

- Cache completed stroke prefixes per visible layer at the current viewport resolution. Extend a cache when completed artwork is appended; rebuild when its prefix changes. Preserve layer order around live strokes. The budget is 64 MiB and at most four layers; uncached layers use the original replay path.
- Append new sample segments into immutable GPU buffer chunks. Merge chunks in a binary hierarchy to keep draw-call count small; never overwrite buffers the GPU can still read. Corrections invalidate the affected stroke’s geometry.
- Use disposable, nonserialized geometry versions and a synchronized sample index instead of full point-array equality/index rebuilding for each update.
- Keep content generations separate from presence/status/tool updates. Idle heartbeats do not request canvas redraws. Matching acknowledgements retain the already-visible optimistic document.
- Save periodic snapshots and completed strokes on an ordered background queue. Backgrounding, room changes and paper-color commits retain an ordered synchronous flush. Local artwork no longer maintains a second full confirmed copy on every sample batch.

## Desktop benchmark

The same optimized Swift diagnostic workload was run before and after the changes on the local Apple Silicon Mac: one layer, 500 completed max-opacity strokes with 100 samples each, a growing live stroke, a 512 × 512 offscreen Metal target, and 20 measured frames after the cold frame. The sample-processing check submits 1,250 batches of eight points, reaching 10,001 points in one local stroke.

| Measurement | Before | After |
| --- | ---: | ---: |
| Mean CPU command encoding | 5.627 ms | 0.190 ms |
| Mean completed-command GPU time | 31.738 ms | 0.049 ms |
| Sample-batch processing p95 | 1.228 ms | 0.00217 ms |

Raw results: [before](benchmarks/drawing-before.json), [after](benchmarks/drawing-after.json). The diagnostic fixture is `tests/CanvasPerformanceTests.swift`, compiled with `-O` against the same shader library as the renderer tests. The baseline was captured from the pre-optimization working tree; the current renderer’s `useHistoryCache = false` provides a replay reference, but does not restore the old input/store implementation.

These are desktop subsystem timings, not physical-iPad frame rates or end-to-end Pencil latency. They exclude cold loading, UI composition, display presentation and network/server processing. Physical-device release-build measurements remain necessary before making an FPS claim.

## Regression coverage

- Real GPU pixel comparisons cover max-opacity self-overlap, pressure maxima, separate strokes, legacy accumulation, cached versus replayed layer order, append-only geometry, cache extension on commit, corrections, undo, hidden layers, paper changes, zoom and high-DPI masks. Cached color compositing permits a two-byte per-channel rounding tolerance.
- Model checks cover sample corrections across copied document branches and confirm that rendering/index metadata does not enter saved files or network payloads.
- Store checks cover zero content changes from presence, ordered background snapshots, synchronous flush, reload and current local-session snapshots.
- Native multi-client integration covers optimistic drawing, synchronization, undo/redo, presence, room resize, pressure/opacity, paper color and save/rejoin recovery.

## Eraser isolation

Eraser strokes use destination-out blending on their owning layer. Completed erasing extends the same layer-prefix cache. If a live eraser, or an uncached layer containing erasing, needs isolation, the renderer reuses one viewport-sized working color surface before compositing that layer over lower layers and paper. This additional surface is separate from the 64 MiB completed-prefix cache budget. The eraser never blends destination-out directly against the flattened canvas.

## Remaining costs

The live stroke still needs rasterization; max-opacity rendering preserves its full coverage mask semantics. Older corrections or undo can rebuild a layer prefix. Pan, zoom and drawable/canvas-size changes invalidate viewport caches. This does not implement sparse tiles, checkpoints or a server operation log. The server still copies/serializes complete documents per accepted edit, and its existing document/sample limits remain unchanged.
