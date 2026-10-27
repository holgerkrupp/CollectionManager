# CollectionManager

CollectionManager is a SwiftUI collection-management app for keeping personal libraries of food and drinks, games, books, music, cosmetics, pet food, toys, and other products. Items can be searched, filtered, sorted, tagged, rated, commented on, photographed, imported from CSV/HTML, enriched from product providers, and shared with collaborators through CloudKit.

## Supported platforms

The 1.0 target is intentionally limited to iPhone, iPad, and macOS. visionOS/xrOS is not a declared release platform until it has a separate test pass. The project uses iOS 26.0 and macOS 26.6 deployment targets and is built with Xcode 27.1 or newer.

## Architecture

- `Domain/` contains platform-neutral collection, item, status, metadata, barcode, event, and import models.
- `Persistence/` contains the SwiftData records. `CollectionManagerSchemaV1` is the immutable released schema identity; future model changes must add a new version and migration stage.
- `Services/Repositories.swift` is the local repository and outbox boundary. Local edits and sync mutations are committed together where possible.
- `Store/AppStore.swift` owns UI state, optimistic edits, rollback, permissions, and user-facing errors.
- `Services/CloudKitSharingService.swift` maps collections to custom CloudKit zones, uses private/shared databases, persists change tokens, registers zone subscriptions, and keeps failed outbox mutations pending.
- `Views/` contains adaptive cards/table editing, import review, scanning, settings, and sharing UI.

## Persistence and collaboration

The app opens a persistent store in the application-support directory. Startup never replaces a failed store with an in-memory database. If the store cannot be opened, the app shows a recovery screen with retry, privacy-safe diagnostics, and a safe store-copy export. Store files are preserved.

CloudKit collaboration uses the private database for owner collections and the shared database for accepted shares. Collection settings, statuses, metadata definitions, default status, and barcode requirements are part of the shared settings payload. Offline local mutations remain in a SwiftData outbox until CloudKit confirms them. Debug builds use the Development CloudKit environment; Release builds use Production.

## Imports and providers

CSV and HTML imports use a review/mapping step before writing. Product lookup is provider-based and currently includes Open Food Facts plus category-specific providers for games, board games, books, and music. Only the minimum lookup data is sent to a provider: normally a barcode or search query. API credentials belong in Keychain or Xcode build configuration; reusable credentials must never be committed.

## Build from a clean clone

1. Install Xcode 27.1 or newer on macOS.
2. Clone this repository and open `CollectionManager.xcodeproj`.
3. Select the `CollectionManager` scheme and a supported iPhone/iPad simulator, connected device, or My Mac destination.
4. Build Debug for local development. Debug uses the CloudKit Development environment; do not use it for production data.
5. Select the `Production` scheme/configuration for an archive candidate. Signing and CloudKit capabilities must be configured in the Apple Developer account.

There are no sibling package dependencies. The SF Symbol picker is bundled under `Views/`, and generated `build/`/DerivedData output is ignored.

## Privacy and security

Collection data, photos, ratings, comments, and collaboration metadata can be stored in the user’s local store and iCloud/CloudKit shared records. Product lookup can send a barcode or search text to the selected provider. HTML/web sync sends requests to URLs explicitly configured by the user. Camera access is used for barcode scanning and photos. See `PrivacyInfo.xcprivacy` and the in-app Privacy information link for the current release disclosure.

Diagnostics use structured logging and avoid item titles, notes, barcodes, photos, API keys, and comment text. The Games EAN key is loaded from Keychain/build configuration and is not a committed reusable secret.

## Release readiness

The authoritative 1.0 work list is tracked in [GitHub issue #16](https://github.com/holgerkrupp/CollectionManager/issues/16) and its linked issues. The repository includes the implementation baseline; production CloudKit deployment, multi-account verification, device accessibility testing, signing, and App Store disclosures remain release-gate activities.

### Release candidate check

- Start from a fresh clone and build Debug and Release for My Mac plus a supported iOS destination.
- Verify the Debug entitlement resolves to Development and the archive resolves to Production.
- Run unit/UI tests and the large-collection benchmark fixture.
- In CloudKit Dashboard, validate indexes and deploy the intended schema to Production before TestFlight.
- Test owner/editor/viewer sharing with two or three real Apple IDs, including offline edits, conflicts, revocation, leaving a share, and reinstall/restore.
- Confirm privacy answers, camera copy, support/privacy links, version/build number, VoiceOver, Dynamic Type, keyboard navigation, light/dark contrast, and reduced motion.
- Archive, validate signing/entitlements, and record known limitations with the release candidate.

## Development status

The focused implementation work is linked from issue #16. `TODO.md` is a short map of remaining work, not a second source of detailed requirements. Released schema versions are immutable; changes to persisted models require a new version, fixture, migration stage, and migration test.
