# Rendering optimization plan

## Scope and baseline

Keep stroke samples and operations as the authoritative document. Add disposable raster caches to reduce GPU work. Preserve per-author undo/redo, layer ordering, Pencil corrections, collaboration, independent viewports, and non-destructive canvas resizing.

The current renderer caches an immutable `MTLBuffer` per stroke, but clears and rerasterizes all visible strokes on every requested redraw. It rebuilds the active stroke's entire stamp buffer when samples change. Presence/status callbacks request unnecessary redraws. No physical-iPad timing has been measured; the workload calculations below are not FPS benchmarks.

## Workload: 1,000 strokes × 200 points × 1,000 document-pixel path length

Assume 199 equally spaced segments, full pressure, all artwork visible, and one document pixel mapping to one render-target pixel. Existing spacing is `max(0.5, brushWidth / 8)` and each segment independently rounds its stamp count upward:

`stampsPerStroke = 1 + 199 * ceil((1000 / 199) / spacing)`

| Brush diameter | Stamps across document | GPU stamp buffers | Approximate square-fragment coverage per redraw |
| --- | ---: | ---: | ---: |
| 8 px | 1,195,000 | 36.47 MiB | 76.48 million |
| 16 px (default) | 598,000 | 18.25 MiB | 153.09 million |
| 32 px | 399,000 | 12.18 MiB | 408.58 million |
| 64 px | 200,000 | 6.10 MiB | 819.20 million |
| 128 px | 200,000 | 6.10 MiB | 3.28 billion |

Each stamp occupies 32 buffer bytes and uses six vertices. At 16 px this means 3.588 million vertex invocations and 1,001 draw calls including paper per redraw. At 60 redraws/second the nominal square coverage is 9.19 billion fragment samples/second, before clipping and other hardware effects. This is repeated coverage, not unique canvas pixels. Actual coverage scales with squared viewport pixel scale and squared pressure-derived diameter. These are analytical estimates, not GPU counter measurements.

A generated four-layer fixture using the actual Swift Codable types, UUID sample IDs and 200,000 points encoded to 18,179,752 bytes (17.34 MiB) in Swift. The server's `json.dumps` representation was 18.89 MiB. Exact size depends on coordinates and IDs. This exceeds the current 16 MiB server document limit, so the present server cannot accept this full scenario unchanged.

## Phase 1: Measure and remove unnecessary work

1. Add reproducible 100/1,000/5,000-stroke fixtures, with 200 points per stroke and 1,000-pixel paths. Cover widths 8/16/32/64/128, pressure variation, overlap, and 1/4/16 visible layers.
2. On a physical baseline iPad, record release-build CPU input processing, stamp generation, command encoding, completed command-buffer GPU time, presented-frame intervals, dropped frames, peak memory and allocations. Use GPU start/end timestamps only after completion. Include a recent Pro iPad if 120 Hz support is a goal. Simulator/desktop timings are not iPad timings.
3. Test cold load, warmed static redraw, continuous local drawing, four concurrent remote artists, pan/zoom, latest/older stroke undo, redo, late Pencil correction and resize. Separate loading/recovery time from steady-state frame time.
4. Split document-content, viewport, tool-control and presence notifications. Presence/activity changes refresh layer rows only. Coalesce drawing changes to one render per display interval. A truly idle canvas schedules zero render passes.
5. Replace full stroke equality checks with geometry revisions and explicit append/correction ranges. Keep layer-to-stroke indexes and stroke bounds to avoid repeated full-document scans. Do not retessellate geometry for visibility or presence changes.
6. Append stamps only for new input segments, using chunked/ring-buffer allocation with completion-based lifetime management. Corrections invalidate affected segments. Initially preserve the existing spacing/raster output; any spacing-quality change requires separate visual validation.

## Phase 2: Cache committed artwork by layer and tile

Use sparse 256 × 256 document-space tiles as an initial tunable size. Key tiles by layer, tile coordinate and raster-resolution bucket, with per-tile content generation and cache epoch. Do not invalidate an entire layer for a change to one tile.

- Keep immutable stroke samples, stroke order, bounds and a spatial index in the document/render model. Bounds include the brush footprint; indexed membership must account for strokes crossing a tile even if no sampled point is inside it.
- Incrementally paint new confirmed segments into affected tiles using premultiplied-alpha blending in a consistent color space. Use persistent render-target storage and correct Metal load/store actions; memoryless attachments cannot serve as persistent caches.
- Keep the live/estimated stroke provisional in a small affected-region surface or geometry overlay. Composite that preview at its owning layer's stack position, so it does not appear above higher layers. Incorporate it into committed tiles exactly once.
- For a dirty tile, clear and replay intersecting visible strokes in their original order. Clip replay to the tile and include a sampling gutter so interpolation does not create seams. Conservative invalidation is preferable to a visually incorrect incremental update.
- Display frames composite visible cached tiles in layer order and live previews. Consolidate compatible tile quads with an atlas/texture array and batched instancing where measurements justify it. Draw cost then tracks visible tiles/layers and changed segments rather than total historical stamps.
- Late pressure/position corrections invalidate the union of old and new affected bounds. Reconciliation with server operations uses stable IDs/revisions so acknowledgements do not paint strokes twice. Unexpected history changes fall back to replay of the affected tiles.

At 2048 × 2736, one full RGBA8 layer is 21.375 MiB. A full 256-pixel tile grid is 88 tiles or 22 MiB before gutters. Four fully populated layers are about 88 MiB before previews/checkpoints; 16 would be about 352 MiB. An 8192-square RGBA8 layer alone is 256 MiB. Allocate sparsely, budget caches, and evict rebuildable tiles; do not allocate full-canvas textures for every participant or stroke.

## Phase 3: Bound undo cost and memory

- Undo/redo keep the existing per-author stroke visibility operations. Mark only tiles intersecting that stroke dirty. Regenerate them from the closest valid checkpoint before the changed stroke, then replay subsequent visible strokes that intersect each tile.
- Checkpoint selected hot tiles after a measured amount of replay work, rather than every stroke. Record the exact history prefix represented by each checkpoint. An undo/correction before that prefix invalidates the checkpoint; it cannot be reused simply because its texture exists.
- Bound checkpoint count and bytes with an LRU policy. Releasing caches must not discard editable history or reduce undo depth.
- Zoom/pan reuse existing tiles immediately. At high zoom, rerasterize visible tiles into bounded higher-resolution buckets; fixed document-resolution tiles would otherwise pixelate. Avoid rebuilding the entire document on every pinch update.
- Canvas shrinking changes clipping; expanding schedules newly exposed tiles. Preserve out-of-bounds samples and existing unaffected tile caches.
- Keep resource writes and reads ordered, and prevent the CPU from overwriting GPU-visible staging data still in flight. Switch completed tile generations atomically to avoid partially rebuilt frames.

## Phase 4: Remove the synchronization/storage bottleneck

The present service copies and serializes the full document for each operation. Each client also persists full snapshots and can rebuild optimistic state on every acknowledgement. These costs become significant at 200,000 points even after rendering improves.

- Store accepted operations incrementally, with periodic consistent snapshots and transactional operation-ID deduplication.
- Send ordered point batches/deltas. Use compact stroke-local point indexes for sample corrections instead of a UUID string per point, while preserving globally unique stroke/operation IDs. Version the wire/storage schema and provide decoding/migration for saved sessions.
- Move checkpoint encoding and disk writes off the input-critical path, using immutable snapshots or a serial persistence worker. Avoid copying the entire history to apply a small sample batch.
- Compact/version the snapshot format and reconsider document/sample limits from measured memory and recovery time. Raising the 16 MiB limit alone does not fix per-update serialization.
- Keep reconnect recovery gap-free: snapshot revision R, then operations R+1 onward, then deduplicated replay of local pending operations. Preserve server authorship checks and host-only resize.

## Validation and acceptance targets

These are proposed targets to verify on a named physical iPad, not measured results:

- At the 1,000-stroke fixture, aim for p95 CPU input/encoding work below 2 ms and p95 GPU canvas work below 4 ms for steady-state interaction; report complete presented-frame performance separately. A 120 Hz frame has 8.33 ms; 60 Hz has 16.67 ms.
- Aim for p95 undo/redo visual completion under 50 ms for the fixture, without long main-thread stalls. Tune tile/checkpoint policy against overlapping broad strokes, not only sparse paths.
- Zero idle canvas redraws from presence/status timers.
- No growth in normal steady-state stamp replay cost proportional to total historical strokes after caches warm. Cold load, cache misses and undo remain explicitly measured replay paths.
- Full document replay and tiled replay must produce equivalent compositing within agreed antialiasing/color tolerances. Cover translucent overlaps, layer order, corrections, tile edges, resize clipping, and multiple live previews.
- All existing ownership, undo/redo, reconnection and restart tests continue passing. Add offline queue/reconciliation tests with the large fixture.
- Verify cache eviction/memory-pressure recovery and high-zoom detail. Report cache memory separately from editable document/history and networking buffers.

Deliver phase 1 and its measurements first, then tile caching, then checkpoint/LOD refinement. Complete storage changes before claiming end-to-end support for the 200,000-point shared-room workload.

## References

- [Apple: completed command-buffer GPU timing](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime)
- [Apple: render-target load/store actions](https://developer.apple.com/documentation/metal/setting-load-and-store-actions/)
- [Apple: Metal Performance HUD metrics](https://developer.apple.com/documentation/xcode/understanding-metal-performance-hud-metrics)
