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

## Caller completion audit

Agent C owns only CollectionSettingsWindow.swift, ItemViews.swift, HTMLImportView.swift and TagManagementView.swift at their actual Views paths. Acceptance: keep editors open and do not run dependent tag/import updates when AppStore persistence returns failure; distinguish valid zero-update from failure. No tests/Git mutations. Coordinator reviews and serializes final verification. Other writers remain frozen.

Coordinator additionally owns CollectionManagerUITests.swift for a real iPad representation/rotation draft smoke test. Acceptance: unsaved table input survives cards/table and orientation changes; explicit Revert clears it without insertion. This supplements multi-field deterministic tests; Mac/Split View/device checks remain separate.

Agent B owns only new CollectionManagerUITests/ReleaseFlowsUITests.swift. Acceptance: practical isolated iOS UI coverage for CSV review, collection settings, filter/sort, Settings/provider and permission/error/share-opening states using existing public flows. No production/network/account claims, no app source changes, no runners/Git. Coordinator alone runs/reviews. Existing core smoke file remains coordinator-owned.

Coordinator owns CollectionDetailView.swift test fixture entry: Debug plus --ui-testing and CM_TEST_CSV_FIXTURE=basic replaces only the system picker selection with a bounded known CSV. Real parser/mapping/review/import remain exercised against isolated test store. Release has no fixture entry. Agent B may use this agreed fake.

Final UI follow-through: all agent files frozen. Coordinator restored local reloads in UI-test mode, isolated mutable layout preferences, removed nested settings navigation, and added in-form save feedback. CI now selects actual installed iPhone/iPad device types and runs their suites after Mac tests. Final evidence is recorded only after passing runs.

Final read-only localization audit: Agent B reads current strings/catalog for #13 and reports concrete interpolation/formatting gaps; no edits or runners. Source stays frozen pending coordinator assessment. Physical VoiceOver and App Store/provider verification remain external.

## Final localization completion batch

Read-only audit found remaining code work, not a device-only gate. Agent A owns Domain/Models.swift, Services/TagUtilities.swift and new LocalizationFormattingTests.swift: localize presentation labels and format metadata values by locale without changing any persisted IDs/schema/user-authored values; preserve category group identity used for filtering. Agent B owns only Services/RecognitionServices.swift and Services/Repositories.swift for LocalizedError/static validation copy; no persistence/transaction/transport logic changes. Agent C owns only Views/CSVImportView.swift, Views/WebSyncViews.swift, Views/ItemViews.swift, Views/SettingsViews.swift, Views/ImportReviewView.swift and Views/TagManagementView.swift for whole localized count/dynamic presentation strings; preserve actions/interfaces and test selectors. Coordinator owns catalog/plural entries, project/CI, all Git, other source, and final verification. Agents do not run tests or mutate Git. Tests/runners remain coordinator-serialized. All agents hand back/freeze before final batch review.

Localization ownership handoff: Coordinator hands AppStore.swift, PersistentStoreStartup.swift, CollectionRecordCodec.swift (error-description block only), CloudKitSharingService.swift (SharingError block only), and CollectionSharingSession.swift to Agent B for display-string lookup only. No field, control-flow, account, routing, permission or transaction changes; coordinator reviews each hunk before accepting ownership back. Other source writers frozen. Agent B must not run tests/Git or edit catalog. Remaining coordinator labels (CSV delimiter/HTML field/settings pane/color display) localize without changing parser/source identifiers.

Final measured cache preparation: 50k localized search-index build measured ~83ms; coordinator moves that derived preparation off the UI actor too. Agent C owns only new Services/ItemDerivedState.swift and CollectionManagerTests/ItemDerivedStateTests.swift, using agreed ItemDerivedState.prepare(items:locale:) throws -> ItemDerivedState with index/brands/date flag/stats Sendable values. Acceptance: deterministic derivation, cancellation, query/canonical semantics and latest-item replacement wins. Coordinator alone edits AppStore and adds cancellable ItemSearchIndex.prepared(items:locale:) API. No agent runners/Git.

Native table cache: SDK27.1 declares SortComparator: Hashable, Sendable and KeyPathComparator conforms. Agent C now owns CollectionTableView.swift plus new CollectionTableSort.swift/TableSortTests.swift. Preserve existing comparator values/order exactly, move sorting to cancellable detached task, publish only matching visible-items revision/order, and fall back to current visible rows while pending (never old scope). Coordinator adds read-only visibleItemsRevision incremented whenever visible results publish/reset. No schema/UI action changes. Acceptance: explicit column order, stable IDs, cancellation and current revision; no main-actor sort on view reevaluation. No agent runners/Git.

Mutable onboarding/layout UI-test preferences now share a stable UUID suite through ApplicationPreferences. Test launch environment chooses only initial onboarding; no argument-domain override can prevent Skip/Save from persisting. Production uses the existing standard preferences domain. Onboarding tests require Skip to disappear before starting another flow. All agent writers frozen; coordinator owns final tests/catalog/docs.

Measured import completion batch: actual parse/mapping/atomic repository import measured 1k/10k/50k; 50k took~22.8s with 100k events/150k outgoing intents, exposing a main-actor import freeze. Agent A owns Repositories.swift and new BackgroundImportTests.swift: make the context-confined repository nonisolated/non-Sendable if the compiler allows without model/schema changes; add actor-local import wrappers reusing the same validation/journal/save implementation and Sendable failure injection. Reuse captured settings during new-import barcode preflight rather than refetching per draft. Agreed actor signatures importDrafts(_:collectionID:failureInjector:) and importNewDrafts(_:collectionID:allowsDuplicates:failureInjector:) throw, returning Void. Agent C owns ImportReviewView.swift only for async import task/progress/disabled dismissal/local failure retention. Coordinator owns AppStore async Bool wrappers, captures collection ID before await and reloads only the active scope, plus catalogs/benchmarks. Public mutation authority remains the repository; no UI prefilter may bypass existing-item barcode preservation. All other writers frozen. No agent runners/Git; coordinator compiles/reviews/tests before commit.

Async import scope follow-through: Coordinator owns DetailView original target capture and AppStore optional explicit collectionID arguments. Agent C additionally owns CSVImportView.swift/HTMLImportView.swift alongside ImportReviewView.swift: required immutable collectionID parameters through every mapping/review layer; use original collection settings, reject pre-start selection changes before metadata writes, and schedule HTML background configuration against original target after await. Agent A's background import files are frozen; no model/schema writes beyond existing transactions. These interfaces must be integrated before testing/commit.

Final import preparation follows the measured ~0.8s parse/mapping phase off the UI actor too. Agent A owns only NEW CSVImportAnalysis.swift/CSVImportAnalysisTests.swift with agreed pure Sendable source()/mapping() snapshots, bounded examples and cached type/conversion/title/duplicate analysis, preserving current semantics and source IDs. Agent C owns only CSVImportView.swift/HTMLImportView.swift: cancellable generation-checked source/analysis/review tasks, immutable snapshots, bounded five-row HTML preview, progress/disabled review while pending. Coordinator owns nonisolated pure HTML helper annotations and full compiler/test integration. No agent catalog/Git/runners; no model/schema or business-write changes.

Agent A may add only one deterministic interleaved-context test in BackgroundImportTests.swift: pause a source update before save, commit a later manual same-item edit on the main context, then resume and record/assert the newer user edit is preserved or the import fails atomically. No production changes, runners or Git; coordinator will verify the actual SDK merge behavior before final integration.

Observed interleaved data-loss repair (not hypothetical): SDK let an older staged source import overwrite a later manual edit. Agent A owns new StoreWriteCoordinator.swift, Repositories.swift and StoreWriteCoordinatorTests.swift. Agreed coordinator API: Snapshot=[UUID:UInt64]; static forContainer(ModelContainer)->StoreWriteCoordinator; snapshot()->Snapshot; static changedCollections(in:ModelContext)->Set<UUID>; commit(expected:Snapshot?,changedCollections:Set<UUID>,save:()->Void throws)throws->Snapshot. Use Synchronization.Mutex (no unchecked Sendable), fail-fast if another commit owns the gate, reject affected-collection revision mismatches before save, increment scopes only after success. Same physical disk URL key across container instances; distinct in-memory containers. Core repo wraps public operation scopes with nested begin/end snapshot (clear on exit), passes expected snapshot into save; capture snapshots before manual background deletes too. No model/schema/payload changes.

Agent C owns only CollectionRecordCodec.swift and new codec interleave test file: same begin/end snapshot scopes around operations, commit via coordinator including nested conflict-resolution/ack commits; metadata-only commits don't advance collection revisions, domain/member/config changes do. Avoid no-op membership timestamp writes. Failure rolls back and must flow through existing durable delegate barrier. Coordinator owns CollectionCloudCoordinator factory creation off the UI executor and integration/tests/docs. All prior writers frozen, no agent tests/runners/Git. Coordinator reviews every mutation path before commit.

Final audit found source-URL/table drift: Agent B owns HTMLImportView.swift only. Tie fetched tables to immutable loadedSourceURL, invalidate/cancel pending network work on URL edits/local file selection; reject stale response generations. Never pair URL B with URL A's table/mapping. Agent C's previous view ownership is finished; its codec scope stays separate. No runners/Git. Coordinator will add import metadata fields to the same background transaction after Agent A hands back repository ownership, so failed imports leave no new fields/intents.

The same audited source drift/pre-mutated model issue exists in WebSyncEditorView. Agent B owns WebSyncViews.swift for URL/table generation binding and repository-scoped update closure. Agent A owns Repositories.swift and new WebSyncWriteTests.swift only: addWebSync(_:metadataFieldsToCreate:[]) and updateWebSync(_:metadataFieldsToCreate:[],update:(WebSyncRecord)throws->Void), capture snapshot/authority before invoking update, stage fields/config in same save. Coordinator owns matching AppStore forwarding API. No agents run tests/Git; current complete suite is read-only against prior snapshot, rerun affected tests after this small repair.

Final verification handback: all three agent writers frozen. Coordinator alone fixed the iOS notification callback isolation warning, required nonnil optimistic snapshots for domain writes, reconciled both SDK localization exports, and bundled CSV/HTML sheet targets with their content after the real CSV UI test exposed an empty first presentation. Remaining work is final clean-clone verification, evidence reconciliation and direct-main pushes; no agent owns writable files now.

## Legacy default.store recovery — 28 October 2026

Coordinator owns new LegacyStoreRecovery.swift, recovery view/tests, AppStore/App startup/Settings/background recovery gates and codec bootstrap idempotence. No agent writers. Preserve the existing user edit to CollectionManager.xcscheme. Acceptance: inspect/migrate only a copied legacy store; additive ID-preserving atomic import; current values, authority and tombstones win; retain legacy queue/tokens and current transport state; durable receipt/restart idempotence; pause cloud/background replay pending explicit review; test synthetic failures and private real backup without committing user data; update existing iPhone installation without uninstalling. Frozen V1/V2 schema shapes remain unchanged.

Scope narrowed by the user: this unpublished installation needs recovery only once. Removed the proposed general recovery view/settings flow; use explicit one-time launch arguments and an atomic local receipt instead. Coordinator verified all 155 unit tests (including the private device-backup trial), raw legacy field/ID preservation, current authority/zone/owner preservation, and signed Production iOS build. No user database or device identifiers enter Git. The user's scheme edit remains excluded from staging.
