# Performance measurements and remaining device work

Measured on 27 October 2026: MacBook Pro, Apple M4 Pro, 24 GiB RAM,
arm64 macOS 27.2 (26B123), Xcode 27.1 (27A9275), Swift 6.4.
These are elapsed host CPU/data-path measurements, not frame latency or signed
release/device acceptance. The CPU/search baseline uses isolated temporary SQLite stores, no
CloudKit network, and no image data. A separate real-JPEG host memory run is
recorded below.

## Repeat the checked-in benchmark

Run the shared scheme's Core plan on My Mac:

```sh
xcodebuild test -project CollectionManager.xcodeproj \
  -scheme CollectionManager -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/CM-performance \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:CollectionManagerTests/PerformanceSearchTests
```

`testMeasuredHostBaseline` prints one `CM_HOST_BASELINE` JSON report per size.
It measures five fixture creations, one index build, seven samples each of
search/filter/title sort, one SQLite seed transaction, and three container
reopens/repository fetches. Reports include sample median and nearest-rank p95;
with seven or fewer samples p95 is the maximum, not a statistically stable tail
estimate. Reopens can benefit from the OS filesystem cache and are not cold
application launches. SQLite seed timing includes record conversion/insertion
and save, but excludes import mapping, event/outbox creation and network upload.
The fixture has deterministic, already naturally ordered titles, so title sort
is a favorable case rather than an adversarial/random-order bound.

The same checked-in tests also passed using Debug plus
`SWIFT_OPTIMIZATION_LEVEL=-O` (five tests, including the date-parser regression
suite). This keeps unsigned test isolation enabled; it is an optimized test
build, not a signed Release acceptance run. Add the optimization setting and
`-only-testing:CollectionManagerTests/PerformanceTagParsingTests` to the command
above to reproduce it. After the date-tag precheck, median milliseconds were:

| Items | Fixture | Index build (one sample) | Previous search | Indexed search | State + brand filter | Natural title sort |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 1.61 | 0.64 | 2.17 | 1.66 | 0.013 | 0.32 |
| 10,000 | 11.62 | 4.93 | 20.79 | 17.54 | 0.109 | 2.91 |
| 50,000 | 57.60 | 24.56 | 107.07 | 95.09 | 1.382 | 15.54 |

Search uses `group-17`, all existing searchable fields, lowercase substring
matching, and identical matching IDs. The index keeps precomputed text keyed by
item ID, rebuilding when item data or locale changes rather than per keystroke.
It stores no image bytes or provider source payload. This removes repeated text
assembly, but 50k search still takes roughly 95 ms on this host: the full selected
collection remains materialized, and background preparation/query/paging work
and device interaction measurements remain necessary.


## SwiftData baseline before date-tag fast rejection

The checked-in benchmark passed in Debug before the date-tag parser optimization.
All times below are milliseconds. Container reopen and repository read are sample
medians; store seed is one transaction. The fixture has no ratings/comments, so
this does not measure a large collaboration history.

| Items | SQLite seed write | Container reopen | Repository fetch + decode | Previous search | Indexed search |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 2980.89 | 1.01 | 36.49 | 3.01 | 1.83 |
| 10,000 | 30788.90 | 1.22 | 400.35 | 29.34 | 18.69 |
| 50,000 | 151424.91 | 1.31 | 2008.50 | 157.13 | 103.94 |

The measured seed-write hotspot was the conversion path's date-tag extraction:
`ItemRecord.init` attempted ten freshly allocated DateFormatters for every
ordinary text tag. The new precheck rejects characters that no configured
POSIX date format can round-trip before formatter allocation. Numeric/separator
strings still use the original parsers and precedence, including years longer
than four digits. Regression tests cover all ten supported formats, ambiguous
month/day precedence and invalid dates. The optimized after-change run measured SQLite seed writes of
86.07/782.60/4484.17 ms and repository fetch/decode medians of
35.25/356.50/1803.52 ms at 1k/10k/50k. A matching unoptimized Debug rerun also passed all seven search, date and
thumbnail tests. Its after-change seed transactions were 88.86/817.85/4397.65 ms
at 1k/10k/50k, compared with 2980.89/30788.90/151424.91 ms before. At 50k this is about
34 times faster for this measured fixture conversion/write transaction. Repeated
numeric or date-like tags still invoke formatters; this is not a bound for every
import, and the single write sample should be repeated on target hardware.
After-change Debug repository fetch/decode medians were 36.44/362.22/1851.97 ms.

The card thumbnail path now downsamples with ImageIO to at most 192 pixels
before display. Its actor-owned cache strictly retains at most 128 derivatives
and 32 MiB of decoded pixel data. It keys by image content and requested size,
transforms EXIF orientation, and ignores stale canceled UI requests. Original
stored/synced bytes remain unchanged. Synthetic-image tests check dimensions,
orientation, reuse, invalid input and cache budgets; they do not prove scrolling
or whole-process memory behavior with a real photo library.

## Actual JPEG host memory measurement

The targeted `PerformanceImageMemoryTests` run passed on the same Mac/toolchain
in Debug on 27 October 2026 (one test, zero failures/skips). Reproduce with:

```sh
xcodebuild test -project CollectionManager.xcodeproj \
  -scheme CollectionManager -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/CM-image-memory \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:CollectionManagerTests/PerformanceImageMemoryTests
```

Each item is a distinct SQLite record with an actual 512×512, 9,585-byte encoded
JPEG. The source is a repetitive synthetic color gradient; seed rows intentionally
share one source Data buffer. The timed repository fetch reads blobs from those
persisted records. “Original bytes” sums returned Data lengths; it is logical
retained content, not a claim of that many unique physical allocations. Repeated
scene content, compression, mapping and allocator reuse make this favorable
compared with distinct full-resolution photographs.

| Items | Original bytes (MiB) | Store files (MiB) | Seed write (ms) | Repository fetch/decode (ms) | First thumbnail (ms) | All repeated-image thumbnail requests (ms) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 9.14 | 10.21 | 117.42 | 61.04 | 2.92 | 56.29 |
| 10,000 | 91.41 | 100.57 | 1076.06 | 518.10 | 0.75 | 554.20 |
| 50,000 | 457.05 | 502.62 | 5709.58 | 2868.05 | 1.13 | 2772.07 |

The test samples actual resident size (`MACH_TASK_BASIC_INFO`) and physical
footprint (`TASK_VM_INFO`). All values below are MiB at named snapshots,
**not peak memory**. All three sizes run sequentially in one host process; prior
allocator/framework state can affect later starting snapshots.

| Items | Resident before | Resident after fetch | Footprint after fetch | Resident after thumbnails | Footprint after thumbnails |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 117.70 | 158.97 | 83.67 | 165.67 | 85.16 |
| 10,000 | 159.34 | 345.72 | 150.11 | 349.36 | 154.33 |
| 50,000 | 336.94 | 1161.31 | 620.36 | 1165.38 | 624.45 |

After the repeated-image requests, every size also decodes 160 distinct JPEG
variants with binary image marks, exercising real eviction. All three runs
retained exactly 128 derivatives and 18.00 MiB of decoded pixels, within the
128-entry/32-MiB limits. The 160-variant pass took 196.17/196.11/200.93 ms at
1k/10k/50k. Further JSON snapshots include after seed and after clearing the
returned item array/cache; that cleanup snapshot keeps the container open and
is not a claim that all SQLite/framework memory returned to the OS.

The fixture caps logical compressed content at 512 MiB and stops if process
physical footprint exceeds 2 GiB. Actual 50k store files were 502.62 MiB, and the
largest recorded resident snapshot was 1165.38 MiB, below the requested host
budget. The test does not sample continuously and establishes no peak bound.
It does not measure photo-rich device scrolling, frame latency, OS memory
pressure, camera-sized images, full import mapping/outbox/network work or signed
CloudKit performance. Those release gates remain open.

## Device and release acceptance still open

Use 1k, 10k and 50k fixtures on a current iPhone, iPad and Mac in the final Release
build. Capture launch-to-list, collection open, card/table scroll, search typing,
filter/sort changes, full import completion, and peak/resident memory. Use
Instruments Time Profiler, Allocations and SwiftUI; retain device, OS, build,
fixture and cold/warm conditions with results. Check UI responsiveness while
sync/import is active and preserve selection/edit-session behavior.

`includeThumbnails` currently supplies zero-filled placeholder bytes, not valid
encoded images. It can exercise allocations only. Use real encoded images at
representative resolutions and distinct assets to measure decoding, thumbnail
caching, lazy loading, scrolling and memory. The separate JPEG test above
establishes bounded host data-path snapshots; neither fixture establishes
physical-device photo scrolling or memory acceptance.

Measure final #17 upload/download counts separately at 1k/10k/50k; a small edit
or unchanged refresh must not cause a recurring full collection scan/query.
Production CloudKit latency, real-account conflicts and signed-device behavior
require their own evidence. Keep #12 open until the remaining interactions,
images, device/memory and transport measures pass.

The final app now evaluates search/filter/sort through `ItemQueryProcessor` on a
cancellable detached task and publishes only the latest request generation. Locale
changes rebuild search text; collection selection clears the prior visible scope.
Seven query tests cover parity, captured numeric locale and cancellation. The
measurements above remain host data-path evidence; moving work off the main actor
does not itself establish measured frame latency or image-heavy device memory.
