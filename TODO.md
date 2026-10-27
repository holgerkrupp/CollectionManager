# Shared Collection TODO

Release planning is now tracked by the focused [1.0 ship issues](https://github.com/holgerkrupp/CollectionManager/issues/16). This file is an implementation map only; issue acceptance criteria are authoritative. Last reconciled with the current code on 2026-09-27.

This checklist compares the original product brief with the implementation currently in the project. Status labels:

- `[x]` implemented and usable
- `[~]` partially implemented or needs production hardening
- `[ ]` not implemented

## P0 — Required for a production collaboration app

### CloudKit collaboration

- `[x]` Use the registered `iCloud.de.holgerkrupp.CollectionManager` production container in `CollectionManager.entitlements` and `CloudKitSharingService.swift`.
- `[~]` Share a collection root and child item records using `CKShare` and a custom zone. The native share sheet and deterministic child mapping are wired; production container/schema configuration is still required.
- `[x]` Add deterministic CloudKit record mapping and synchronization for collections, items, tags, metadata, and lifecycle events.
- `[x]` Fetch and merge collection and item records from both the owner’s private database and the participant shared database.
- `[x]` Add offline mutation/outbox records and retry synchronization when connectivity returns.
- `[~]` Add conflict resolution using record change tags / server records. Timestamp-based local conflict resolution is implemented; server change-tag handling remains a deployment-hardening task.
- `[~]` Handle remote deletions, revoked access, leaving a share, and share acceptance URLs. Share URL acceptance and deletion mutations are wired; revoked-access and leave-share UI still need device validation.
- `[x]` Persist and enforce collection member roles: owner, editor, viewer.
- `[x]` Add sync state and friendly sync-error UI.
- `[ ]` Add CloudKit container schema deployment and device testing with multiple iCloud accounts.

### Local persistence and migration

- `[x]` Collections, items, and basic events persist in SwiftData and remain available offline.
- `[~]` The app seeds demo collections on a fresh store; replace demo seeding with an onboarding/create-first-collection flow for release builds.
- `[x]` Add the immutable `CollectionManagerSchemaV1`, migration plan, and persistent-store opening path. Migration fixtures/tests remain release verification work in [#5](https://github.com/holgerkrupp/CollectionManager/issues/5).
- `[~]` Add indexes/query strategy appropriate for thousands or tens of thousands of items; baseline fixture/documentation work is tracked in [#12](https://github.com/holgerkrupp/CollectionManager/issues/12).
- `[ ]` Capture all local writes as syncable mutations instead of saving only directly to the local store.

## P1 — Core product behavior from the brief

### Domain model

- `[x]` Stable UUIDs, generalized collections, flexible item states, typed `MetadataValue`, quantities, tags, barcode values, photos, and basic event records exist.
- `[~]` `CollectionMember`, `Tag`, `ExternalIdentifier`, and `ImportProvenance` are not separate persisted domain entities yet.
- `[ ]` Add owner/creator/actor identifiers to collections, items, and events.
- `[ ]` Add collection type/template identifiers and schema versions.
- `[ ]` Add first-class date added, date acquired, date consumed, previous state, structured metadata, and notes to event records.
- `[~]` Consumed items are retained during normal UI deletion, but deletion policy and permissions need to be enforced in the repository and CloudKit layer.

### Collection settings and editing

- `[x]` Collections can be created and edited.
- `[x]` Each collection can add, remove, reorder, rename, recolor, and customize the icons for its statuses.
- `[x]` Global settings screen exists using `@AppStorage`.
- `[x]` Collection settings persist statuses, default status, barcode requirement, and metadata in local and CloudKit settings payloads. Existing payloads migrate to the first status and `false`; remaining device/sync verification is tracked in [#7](https://github.com/holgerkrupp/CollectionManager/issues/7).
- `[~]` Collection categories now include food, video games, board games, books, music, cosmetics, pet food, other products, and custom; category-driven barcode/provider support and detail fields are wired. More templates remain to be added.
- `[ ]` Add collection deletion/archive behavior and confirmation policy.

### Items and lifecycle history

- `[x]` Add, edit, delete, quantity, tags, brand, variant, description, status, barcode, and photo fields work locally.
- `[x]` State changes create a basic `stateChanged` event; item creation creates a `created` event.
- `[ ]` Add `acquired`, `consumed`, `restored`, `quantityChanged`, `metadataChanged`, and `imported` event types.
- `[ ]` Add a searchable item history/timeline view.
- `[ ]` Add direct lifecycle actions such as “Move to storage”, “Consume”, and “Restore”.
- `[ ]` Prevent deletion of consumed items or replace deletion with archive behavior.

### Import/export

- `[x]` Per-collection CSV file import exists with a review-before-save step.
- `[~]` CSV parsing supports common title/brand/variant/state/quantity/tags columns, but it needs robust quoted CSV parsing, column mapping, validation, duplicate handling, and error reporting.
- `[ ]` Add JSON import/export.
- `[ ]` Add export of a collection including metadata, tags, events, and provenance.
- `[ ]` Add import provenance per item: source file, source row, imported timestamp, and provider.
- `[ ]` Add per-collection import templates/mappings and saved mappings.

### Search, filters, and sorting

- `[x]` Offline search covers title, brand, variant, description, barcode, tags, and metadata display values.
- `[x]` State and brand filters are available as chips/menu filters.
- `[ ]` Add tag, collection, date added, date consumed, and metadata filters.
- `[ ]` Add composable multi-filter state with visible removable filter chips.
- `[ ]` Add sorting by title, brand, date added, modified date, and consumed date with ascending/descending order.
- `[ ]` Add indexed/search-optimized SwiftData queries for large collections.

## P2 — Recognition and product enrichment

### Barcode scanning

- `[x]` VisionKit `DataScannerViewController` is wired for EAN-13, EAN-8, and UPC-E style scanning.
- `[x]` UPC-A values are normalized to a canonical 13-digit representation; scanner/manual input both use the same `Barcode` type.
- `[x]` Barcode normalization is centralized in `Barcode`.
- `[x]` After scanning or manual entry, the add flow reports whether the barcode is already consumed, in storage, or otherwise present in the selected collection.
- `[x]` Manual barcode entry fallback is available when scanning is unavailable.
- `[x]` Add scanner availability handling, camera permission states, and user-facing errors.

### Photos and recognition

- `[x]` Take Photo and Choose Existing Photo flows are wired; image data is stored with the item.
- `[x]` Add OCR/text recognition from captured or selected photos using Vision; recognized text is inserted into the editable proposal.
- `[ ]` Add product-label recognition and editable recognition proposals.
- `[ ]` Add Foundation Models / Apple Intelligence enrichment where available, with availability checks and opt-in behavior.
- `[ ]` Add image resizing, deduplication, thumbnails, and CloudKit asset storage.

### Product metadata providers

- `[x]` `ProductMetadataProvider` and provider-independent `ProductMetadata` are implemented.
- `[x]` `OpenFoodFactsProvider` queries the current API with an identifiable User-Agent.
- `[x]` Provider DTOs are kept inside the provider implementation and mapped into domain-neutral metadata.
- `[x]` Barcode lookup pre-fills an editable Add Item proposal.
- `[x]` Add provider errors, rate limiting, in-memory caching, privacy messaging, and retry behavior.

## P3 — Quality, security, and platform readiness

- `[~]` Add unit/UI coverage for barcode normalization, CSV import, metadata encoding, filtering, sorting, repository CRUD, event creation, migrations, failure paths, and sharing; tracked in [#11](https://github.com/holgerkrupp/CollectionManager/issues/11).
- `[ ]` Add CloudKit integration tests with an in-memory/local fake and a real development-container test target.
- `[ ]` Add UI tests for add/edit/import/settings/share flows.
- `[~]` Persistence save failures now roll back, log a privacy-safe typed error, and are surfaced by the startup/recovery and destructive-operation paths. Finish the repository fetch audit in [#4](https://github.com/holgerkrupp/CollectionManager/issues/4).
- `[ ]` Add accessibility labels, Dynamic Type review, VoiceOver order, and reduced-motion support.
- `[ ]` Add localization and String Catalog coverage.
- `[ ]` Add privacy strings for camera/photos/iCloud and review entitlements before App Store submission.
- `[ ]` Add iPad split-view layouts and later macOS conditional presentation support.
- `[ ]` Add structured logging and privacy-safe diagnostics.
- `[x]` 1.0 platform scope is iPhone/iPad/macOS with aligned project/target settings. Archive/device validation remains in [#14](https://github.com/holgerkrupp/CollectionManager/issues/14).

## Focused release work

- [#2](https://github.com/holgerkrupp/CollectionManager/issues/2) clean-clone reproducibility and CI build hygiene
- [#3](https://github.com/holgerkrupp/CollectionManager/issues/3) persistent-store startup recovery
- [#4](https://github.com/holgerkrupp/CollectionManager/issues/4) complete typed persistence error propagation
- [#5](https://github.com/holgerkrupp/CollectionManager/issues/5) schema fixtures and migration tests
- [#8](https://github.com/holgerkrupp/CollectionManager/issues/8) adaptive edit-session regression coverage
- [#9](https://github.com/holgerkrupp/CollectionManager/issues/9) incremental CloudKit validation and conflict tests
- [#10](https://github.com/holgerkrupp/CollectionManager/issues/10) production CloudKit deployment and real-account matrix
- [#11](https://github.com/holgerkrupp/CollectionManager/issues/11) automated tests and clean-clone CI
- [#12](https://github.com/holgerkrupp/CollectionManager/issues/12) performance baselines
- [#13](https://github.com/holgerkrupp/CollectionManager/issues/13) privacy/accessibility/localization/support verification
- [#14](https://github.com/holgerkrupp/CollectionManager/issues/14) archive and platform verification
- [#15](https://github.com/holgerkrupp/CollectionManager/issues/15) repository documentation

## Current implementation entry points

- Domain models: `CollectionManager/Domain/Models.swift`
- SwiftData models: `CollectionManager/Persistence/SwiftDataModels.swift`
- Local repository: `CollectionManager/Services/Repositories.swift`
- CloudKit share creation: `CollectionManager/Services/CloudKitSharingService.swift`
- CSV importer: `CollectionManager/Services/CSVImporter.swift`
- App state and CRUD: `CollectionManager/Store/AppStore.swift`
- Add/edit/photo/scanner UI: `CollectionManager/Views/ItemViews.swift`, `ScannerViews.swift`
- Collection/settings/share UI: `CollectionManager/Views/RootView.swift`, `CollectionDetailView.swift`, `SettingsViews.swift`, `CloudSharingView.swift`
