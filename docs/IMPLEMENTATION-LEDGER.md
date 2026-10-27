# 1.0 coordination ledger — 27 October 2026

Coordinator exclusively owns Git mutations, project/schemes/dependencies, CI,
AppStore.swift and integration. Main only; no agent Git mutations or worktrees.
MealPlan is read-only, including existing local modifications.

## Foundation wave (active)

- Agent A owns `Services/Repositories.swift`, `Store/PersistentStoreStartup.swift`,
  `Persistence/SwiftDataModels.swift`, and new `CollectionManagerTests/Persistence*`
  files. Acceptance: typed failures distinguish fetch failure from empty data;
  writes/outbox commit or roll back together; recoverable SQLite export includes
  actual sidecars with unique directories; immutable version-specific models and
  fixture opening coverage. Coordinate AppStore API changes with coordinator.
- Agent B owns `Services/RecognitionServices.swift`, `Views/SettingsViews.swift`,
  new credential helper files and `CollectionManagerTests/Provider*` files.
  Acceptance: no built-in credential; user-supplied Keychain only; safe missing,
  invalid and rate-limit handling with injected-network tests; accurate Settings
  copy. Provider revocation remains external absent actual authorized access.
- Agent C owns `Views/CollectionDetailView.swift`, `Views/CollectionTableView.swift`,
  new edit-session files and `CollectionManagerTests/EditSession*` files.
  Acceptance: durable parent-owned draft session survives adaptive branches;
  explicit save/revert and semantic navigation protection; multi-field regression
  tests. Coordinate AppStore changes with coordinator.
- Agent C additionally owns `Views/RootView.swift` for semantic navigation prompts (explicit coordinator handoff).
- Coordinator owns all remaining files and baseline verification. Shared project
  changes stay with coordinator. Agents stop editing before batch review/tests.

## Verification baseline

CollectionManager main 5bf59645f4fe851b8516ecc0af5e57b122b7e771;
kit main 860b0f3d5950a9129056c2056a00e21cb08827b0.
Xcode 27.1 (27A9275). Fresh remote clones in `/tmp/cm-validation`.
Build/test outcomes will be recorded after completion, without treating unsigned
builds as signing or real-account sharing evidence.

## Kit durability audit (Agent B, after credential writer paused)

Agent B may edit only generic `Sources/CollaborationCloudKit/CloudKitSyncEnginePool.swift`
and new kit `Tests/CloudKitCollaborationKitTests/Durable*` files if an actual
failure-acknowledgement gap is found. Preserve public APIs and Core Data backend.
Acceptance: a failing host apply cannot allow durable engine progress to skip
records, with deterministic regression evidence. Coordinator alone commits/pushes.

## Independent quality work (after foundation writers freeze)

Agent C now owns `Services/PerformanceFixtures.swift`, new
`Services/ItemSearchIndex.swift`, new `CollectionManagerTests/Performance*` files
and `PERFORMANCE.md`. Acceptance: repeatable measured 1k/10k/50k host CPU baseline
with actual hardware/toolchain, preserve search semantics, avoid rebuilding full
search haystacks per keypress. UI/device/image/network measures stay explicitly
unverified. Agent C may read but not edit AppStore; coordinator integrates index.
Agent B next owns new collaboration lifecycle files and CloudSharingView.swift
only after coordinator supplies host adapter/root interface; no writes meanwhile.

## Collaboration lifecycle (Agent B active)

Agent B owns new `Services/CollectionSharingSession.swift`,
`Views/CloudSharingView.swift` and new `Sharing*` tests. Agreed integration:
`CollectionSharingSession` takes injected package pool, synchronous cached root
plan closure and async permission/locator persistence closure; coordinator
constructs it after host codec startup. Expose native backend to UI, authoritative
refresh, invitation coordinator. Never introduce a second transport. Coordinator
alone edits AppStore/app delivery registration and CloudKitSharingService.swift.

## Release resource audit (Agent B)

After lifecycle freeze, Agent B owns `Views/OnboardingView.swift`,
`Views/ScannerViews.swift`, `Localizable.xcstrings`, new `Resources/InfoPlist.xcstrings`,
and new `docs/RELEASE-QUALITY.md`. Acceptance: fix concrete accessibility and
Reduce Motion gaps, accurate privacy/provider flow inventory, localized camera
copy, long-string/RTL readiness checks. Do not claim device/App Store evidence.
Privacy manifest remains coordinator-owned. Other UI files read-only.

## Foundation verification

Fresh remote baseline: unsigned macOS/iOS Release passed; original 3 macOS tests
passed; kit warnings-as-errors passed. Generic kit durability fix reviewed,
16 tests passed, pushed main `239da36a97d8f4904786e49ae0354f93f0a5f5c3`.
Combined foundation macOS suite: 34 passed, 0 failures (performance measurement
method excluded from this quick gate). Audited V1 fixture and recovery export
reopen tests passed. Original share UI retained for this foundation commit;
package lifecycle wrapper is staged infrastructure until transport integration.
macOS unsigned UI runner was killed before connecting; ad-hoc signing retry is
being diagnosed. This is not a successful UI or signed sharing result.

Agent C ownership additionally includes `Services/TagUtilities.swift`,
`Services/ItemThumbnailCache.swift`, `Views/ItemViews.swift` (ItemThumbnail only),
and new thumbnail/date regression tests. Preserve persisted images and domain IDs;
use bounded downsample cache. Other ItemViews edits remain coordinator-owned.

## Deterministic sync acceptance and UI smoke ownership

Agent C additionally owns new `CollectionManagerTests/CodecAcceptanceTests.swift`;
Agent A owns codec source and `PersistenceTransportTests.swift`. Findings flow to A.
Agent B now owns `CollectionManagerUITests/CollectionManagerUITests.swift` only,
expanding actual smoke flows against test-isolated stores. Coordinator owns all
project/scheme/signing changes. Mac UI runs may clear entitlements only as an
explicit command-line test override; shipped entitlements remain unchanged.

## Kit startup reentrancy correction (Agent B)

Agent B exclusively owns kit `CloudKitSyncEnginePool.swift` and new
`PoolStartup*` tests to coalesce concurrent pool.start/shutdown across actor
suspensions. Preserve APIs and durable barrier; coordinator tests/commits/pushes
kit before advancing the remote pin. No agent Git mutations.

## Off-main query preparation (Agent C)

Agent C owns new `Services/ItemQueryProcessor.swift`, new query regression tests,
and nonisolated value-type annotations in `Domain/Models.swift` only (no stored
model/schema changes). Acceptance: background search/filter/sort preserves existing
ordering/nil/tie semantics and cancellation. Coordinator alone wires AppStore,
using generation checks so stale queries/collection results never publish.

Final handoff: Agent A froze codec/schema/startup and PersistenceTransport files;
coordinator owns those now. Agent A temporarily retains Repositories.swift and
new persistence validation tests to enforce typed JSON validation and configured
status rules before any batch writes. V1 remains unchanged.

## Final review corrections

All domain/schema/code writers are paused; coordinator owns integrated files.
Agent B is limited to actual simulator UI test selector corrections. The final
source keeps missing legacy zones recoverable rather than recreating them.
Explicit new-collection intent is durable in the existing outbox. Confirmed
leave/revocation suspends only the affected shared locator and keeps local data;
queued engine writes are filtered by current stored permissions too. Baseline
candidate review is an explicit user action, not an automatic retry.
Kit main `5e9a09d7af84f4be9c7df7908c13c9ccfd35af82` is pushed and pinned remotely.

Agent C final measurement ownership: new PerformanceImageMemoryTests.swift and
PERFORMANCE.md only, for actual host image-heavy seed/fetch/thumbnail memory at
1k/10k and bounded50k stress. No app/UI/source/project writes. Run tests only
when coordinator hands the app test-run slot back (simulator UI currently active).

Source freeze gate:81 macOS unit tests passed,0 failures/skips, including both
host performance datasets; earlier iPhone77 unit +2 UI tests passed. All source
writers are stopped. Agent B is executing existing iPad smoke tests without edits.
Integration commit is followed by a genuinely fresh remote clone and final
platform builds/tests; production/account/distribution gates stay open.

Agent C test-only final ownership: new ImportMappingTests.swift covering actual
column mapping/type inference, conditional status/default provenance, malformed
input policy and metadata/date/tag mapping. No production files or test runners;
coordinator executes once all platform test launches finish.

## Final environment boundary

Coordinator owns startup policy/UI and canonical zone routing. Agent A owns only new StoreEnvironmentPolicyTests.swift; acceptance: explicit legacy choice, wrong-environment refusal, corrupt-marker recovery and complete export. Agent B owns RELEASE-QUALITY.md evidence refresh only. All other agent writers remain frozen.
