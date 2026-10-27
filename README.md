# CollectionManager

CollectionManager is a SwiftUI app for personal libraries of food, drinks, games,
books, music and other products. It supports custom statuses and metadata,
search/filter/sort, tags, images, CSV/HTML import, product lookup, ratings,
comments and native iCloud sharing.

## Build and supported platforms

Use **Xcode 27.1 / Swift 6.4 or newer**. The 1.0 target declares iPhone/iPad
(iOS 26.0+) and macOS (26.6+); visionOS is not a release platform. Clone and open
`CollectionManager.xcodeproj`. The shared `CollectionManager` scheme includes
`CollectionManager.xctestplan`; `Production` archives Release.

CloudKitCollaborationKit is a remote package pinned to
`5e9a09d7af84f4be9c7df7908c13c9ccfd35af82`; `Package.resolved` is committed.
No sibling repository is required. The symbol picker is bundled locally.

```sh
xcodebuild -resolvePackageDependencies -project CollectionManager.xcodeproj -scheme CollectionManager
xcodebuild -project CollectionManager.xcodeproj -scheme CollectionManager -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project CollectionManager.xcodeproj -scheme CollectionManager -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project CollectionManager.xcodeproj -scheme CollectionManager -destination 'platform=macOS' -only-testing:CollectionManagerTests CODE_SIGNING_ALLOWED=NO
```

Test stores are intentionally isolated in Debug test runs. Production startup
never falls back to an empty in-memory library. UI tests use `--ui-testing` and
a temporary store; their ad-hoc signing overrides are test commands only. See
[release quality](docs/RELEASE-QUALITY.md) for the observed Developer Tools and
hosted-Xcode blockers. A failing CI toolchain check is not a passing build.

## Architecture

- `Domain/` has Sendable collection, item, status, import and metadata values.
- `Persistence/SwiftDataModels.swift` freezes the actual V1 model definitions.
  V2 adds local transport metadata and indexes, with a lightweight migration.
  The checked-in audited V1 SQLite fixture must never be regenerated from a
  newer schema to hide a regression. Future model edits require a new version.
- `Services/Repositories.swift` commits local changes, events and outgoing intent
  together. Typed fetch/save/validation/permission failures reach AppStore;
  failed transactions roll back. Stored authority is checked at mutation
  boundaries, including imports, background writes and App Intents.
- `Store/AppStore.swift` owns observable state and durable-in-memory edit sessions
  above adaptive cards/table branches. User Save/Revert and navigation decisions
  control drafts; representation changes do not commit them.
- `CollectionRecordCodec` confines SwiftData work to a ModelActor. It owns stable
  CloudKit records, assets, per-record conflict rules, durable outgoing snapshots,
  engine state, scope/zone routing, and interrupted handoff/reconciliation.
- `CollectionCloudCoordinator` uses one kit pool for the active account and its
  private/shared databases. SwiftData stays `cloudKitDatabase: .none`.
  The old manual service is retained as inactive compatibility reference; it is
  never instantiated by the new app path. Manual change tokens are retained as
  recovery evidence, not interpreted as engine serialization.
- `CollectionSharingSession` uses the kit lifecycle and native ShareLink,
  UICloudSharingController and macOS CloudKit management. Current CKShare state
  supplies owner/editor/viewer authority. Viewers cannot write ratings/comments
  because those are CloudKit writes too. A network failure does not delete data.
- `ItemQueryProcessor` prepares cancellable search/filter/sort results off the
  UI actor; generation checks reject obsolete results. A bounded ImageIO cache
  downsamples display images without altering original stored/shared assets.

## Persistence and safe recovery

A failed persistent-store open presents recovery UI with retry, safe diagnostics
and store-copy export, including actual SQLite `-wal`/`-shm` members. It never
replaces, resets or deletes the original store. App Intents/background scheduling
are installed only after the persistent store opens.

Outgoing payloads/deletes remain durable until their own upload generation is
acknowledged. Fetched changes commit before engine progress can advance. The kit
stops progress on local commit failure and resumes from durable state after
restart. Newer local edits/deletes survive older acknowledgements. The account
partition is opaque and never logged; another account cannot silently adopt the
existing local graph.

On first transport handoff, older rows without proven pending intent are saved as
recoverable candidates. An absent server row may be a remote deletion, so the app
does not automatically upload it. Settings → Recovered changes lets the user
review and explicitly upload the **current** local value. Unresolved candidates
keep the handoff incomplete. Source migrations and tests do not prove signed
existing-share parity or a safe binary downgrade. Never downgrade against the
upgraded store as automatic recovery; preserve a full copy and investigate first.

## Imports and providers

Games EAN requires the user's own API key, saved explicitly in this device's
Keychain. No built-in credential or build-setting fallback is supplied. Missing,
invalid and rate-limited requests have safe error paths. The previously public
credential still requires provider-side revocation evidence.

CSV/HTML imports use mapping/review. Missing or invalid imported statuses use the
persisted collection default; explicit valid choices remain intact. Barcode rules
and stored write permissions apply to direct, CSV, web and intent writes. Invalid
metadata fails before a batch mutates data.

## Privacy and security

Local data and photos can be uploaded to the user's CloudKit private/shared
records; invited collaborators can receive shared content. Ratings/comments can
include a saved participant display name (historically a device/host name) and
opaque participant ID. Pending invitation metadata is archived privately for
retry; invitation URLs, participant content and credentials are not logged.

Product services receive barcode/search input and network request metadata;
Games EAN additionally receives the user-supplied authentication header.
User-configured HTML sources receive normal web requests. PhotosPicker grants
access only to selected images; camera access supports scanning and item photos.
See [the data-flow inventory](docs/RELEASE-QUALITY.md), the privacy manifest and
localized camera usage copy. Provider retention/App Store disclosures require
owner verification; the manifest alone is not a complete privacy assessment.
Support and privacy links and app version/build are available in Settings.

## Release readiness

[Issue #16](https://github.com/holgerkrupp/CollectionManager/issues/16) is the
release hub; [#17](https://github.com/holgerkrupp/CollectionManager/issues/17) owns
kit adoption. See [CloudKit release procedures](CloudKit-RELEASE.md),
[measured host performance](PERFORMANCE.md), [release quality](docs/RELEASE-QUALITY.md)
and [validation evidence](docs/VALIDATION.md). `duo.md` is forward-looking guidance;
its optional platform ideas are outside 1.0 beyond the draft-safety work.

Production schema deployment, signed multi-account invitation/permission/revocation
and mixed-client validation, physical-device accessibility/performance, provider
revocation, distribution validation and App Store disclosures remain real gates.
Do not call #10, #16 or #17 complete based on mocks, unsigned builds or procedures.
