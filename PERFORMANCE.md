# Performance baseline

Use `CollectionPerformanceFixture.items(count:)` with 1,000, 10,000, and 25,000 items. Run on one current iPhone, one iPad, and My Mac in Release with the same OS/build. Capture launch-to-list, collection open, card/table scroll, search typing, filter/sort changes, import completion, and memory with thumbnails enabled.

Record median and p95 interaction latency, peak resident memory, and whether frames remain responsive during typing and scrolling. Use Instruments Time Profiler, Allocations, and SwiftUI template; keep the fixture seed and build number with each result. A regression is actionable when the same device/build shows a sustained responsiveness change, not because a single simulator run is noisy.

The current data path still materializes the selected collection for filtering and sorting. Follow-up work should move expensive preparation off the main actor, avoid full-resolution image decoding for list rows, and introduce query/paging only after this baseline is recorded. Do not change the visual design to hide a data-flow regression.
