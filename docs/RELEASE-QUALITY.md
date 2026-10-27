# Release quality evidence and remaining checks

Source audit: 27 October 2026, Xcode 27.1. This records implementation and
repeatable checks; it does not certify App Store answers or physical-device
accessibility, camera, signing, or account behavior. GitHub #13, #14, #16 and #17
remain authoritative release gates.

## Data-flow inventory

| Feature / service | Data leaving the device | Trigger and local handling |
| --- | --- | --- |
| iCloud / CloudKit | Collection names/settings, item fields, barcodes, tags, photos/assets, events, ratings/comments, participant/share metadata | Collaboration uses the configured Apple container in Development for Debug and Production for Release. The app stores local SwiftData records; the host codec owns domain mapping and journal while the kit owns direct transport/lifecycle. Native Apple UI owns invitations and participant management. |
| Open Food Facts (`world.openfoodfacts.org`) | Barcode for item lookup; entered search text for name search; normal network headers/IP | Food lookup/search in Add Item. Provider results and source snapshots may be stored with the item. |
| Open Products / Beauty / Pet Food Facts (`world.openproductsfacts.org`, `world.openbeautyfacts.org`, `world.openpetfoodfacts.org`) | Barcode and normal network headers/IP | Category-specific lookup, including fallback after games/board-games provider. No API key is supplied to these services. |
| Games EAN (`levelcomplete.de/api/v3a`) | Barcode and the user's API key in the `Apikey` HTTPS header; normal network headers/IP | User-initiated game lookup. User supplies a key in Settings; Keychain stores it on this device. Requests use an ephemeral uncached session; no built-in credential. Historical credential revocation still requires provider-side evidence. |
| GameUPC (`api.gameupc.com`) | Barcode; normal network headers/IP | Board-game lookup; returned BoardGameGeek metadata/images are references from the provider response. |
| Open Library (`openlibrary.org`, `covers.openlibrary.org`) | ISBN/barcode for metadata, cover identifier for image request; normal network headers/IP | Book lookup and cover download. A failed primary lookup may try the ISBN endpoint. |
| MusicBrainz (`musicbrainz.org`) | Barcode query; normal network headers/IP | Music-release lookup. |
| Provider-returned image hosts | Requested image URL/path; normal network headers/IP | Add/Edit Item downloads a selected provider's cover/image. These hosts are response-defined rather than a fixed allowlist. Imported image bytes may later become local/shared collection data. |
| User-configured web/HTML sources | Configured URL/path/query and ordinary request headers/IP | Explicit HTML import and configured scheduled sync; query strings may contain user-entered content. The app does not send the full local collection to the website. Inspect each chosen website's own behavior. |
| GitHub support/privacy links | Browser request and any content the user chooses to submit | Settings opens project support and README privacy links. Support reports must not include a store copy without the user's intent; recovery exports contain actual library data. |

Camera barcode recognition uses VisionKit; OCR uses Apple's on-device Vision
request on selected/captured image bytes. The current source does not upload
camera frames or OCR images to a separate OCR service. Photos selected through
`PhotosPicker` use the system's selected-item access; the app does not request
full photo-library access. Captured/selected photos can subsequently be saved
in the library and CloudKit graph.

Local notifications use system authorization and per-device preferences.
UserDefaults stores presentation/onboarding/notification preferences; file
metadata is read to validate a recovery copy. The privacy manifest declares
those required-reason APIs. No advertising, analytics SDK, location, microphone,
or contacts API was found in the current application source. A provider still
receives the normal network metadata noted above; absence of an analytics SDK
is not a claim about third-party server retention.

## Local library environment separation

Local stores are separated as well as CloudKit engine state. Relative to the
application's Application Support directory, Debug uses
`CollectionManager/Development/CollectionManager.store` with Development iCloud.
Production keeps the original `CollectionManager/CollectionManager.store` path
with Production iCloud. Choosing a build does not move or copy the other
library into its environment.

An older unmarked library at the Production path requires an explicit
**Confirm library environment and open** decision before it can open. The
recovery screen identifies this build's expected environment and offers a store
copy first; Retry alone does not authorize the choice. The environment marker
is written only after the store opens successfully.

If Debug has no separate Development store and an original library exists, the
recovery screen requires **Create separate development library** before creating
one. This also covers an original library whose environment is unknown: Debug
does not guess its environment or upload that original graph to Development.
An existing unmarked target store likewise requires explicit environment review.
A valid marker naming the opposite environment cannot be overridden by either
confirmation or Retry; use the matching build. No recovery path automatically
relabels, deletes, or recreates that library.

Environment-policy checks used isolated temporary stores. No actual existing
user library was opened, relabeled, migrated, moved, or deleted during this
validation. Signed environment separation and real-account compatibility remain
release gates below; source checks do not establish those results.

## Implemented accessibility and localization changes

- Onboarding pages scroll instead of clipping their title/body at large text
  sizes; heading traits identify page titles and decorative art is hidden.
  Next honors Reduce Motion for app-triggered transitions.
- The scanner waits for camera authorization before creating/starting the
  scanner, avoiding a permission-request race. Close remains available during
  scanning, errors and permission checks; guidance explains manual entry.
  Barcode recognition posts a localized accessibility announcement.
- Unsupported camera capture offers a recoverable explanation and Close action.
- `Resources/InfoPlist.xcstrings` holds the English camera usage description,
  ready for localization. The app uses system photo selection without requesting
  unnecessary library-wide permission.
- Native Xcode localization export extracts live SwiftUI/localized keys into
  `Localizable.xcstrings`. English is the source language. Extraction is not a
  translation review; dynamically composed domain labels/error text outside
  localized APIs still require an explicit string audit before adding locales.

Reproduce the native catalog extraction from a clean, resolved checkout:

```sh
xcodebuild -exportLocalizations -project CollectionManager.xcodeproj \
  -localizationPath /tmp/CollectionManager-localizations-mac -exportLanguage en \
  CODE_SIGNING_ALLOWED=NO
xcodebuild -exportLocalizations -project CollectionManager.xcodeproj -sdk iphoneos \
  -localizationPath /tmp/CollectionManager-localizations-ios -exportLanguage en \
  CODE_SIGNING_ALLOWED=NO
```

The checked-in catalog contains 475 keys, including seven environment-recovery
strings added after the platform-export union. Entries are retained manually so
exporting one platform cannot remove the other's strings. Refresh both exports and review their union when UI changes.
Review catalog diffs; do not ship generated sample strings or claim untranslated
entries are complete. Inspect the built bundle's localized `InfoPlist.strings`
for `NSCameraUsageDescription` as part of the release build check.

## Checks still requiring actual evidence

Keep these unchecked until the named person/device/account and result are recorded:

- [ ] On a physical supported iPhone and iPad, run VoiceOver through onboarding,
  collection create/open, card/table edit Save/Revert, import review, scanner,
  ratings/comments and sharing. Verify focus order, names, values, hints and no
  camera/scanner focus trap; record OS/device and defects.
- [ ] Use the largest accessibility text sizes with long collection/item/status
  names in portrait, landscape and iPad Split View. Verify content/Close/Save
  remain reachable and no destructive action is obscured.
- [ ] Complete keyboard-only navigation on macOS/iPad: tab order, toolbar actions,
  menus, table fields, dialogs and focus restoration after Save/Revert.
- [ ] Check light/dark high-contrast appearances; confirm text/icon status conveys
  meaning without color and error text remains readable. Check Reduce Motion
  for all app transitions and system scanner UI on device.
- [ ] Run Xcode double-length and right-to-left pseudolanguages through critical
  screens. Review date/number/quantity formatting, pluralized dynamic messages,
  and all runtime strings before promising another supported language.
- [ ] Deny/grant camera permission on a fresh physical install; verify barcode
  capture, close/manual fallback, selected-photo picker and unavailable camera.
- [ ] Review every provider's current terms/privacy and actual server data handling;
  publish a stable public privacy policy and confirm the Settings links.
- [ ] The App Store Connect owner completes privacy answers for the exact shipped
  data flow, including third-party services, user content/photos, identifiers and
  participant metadata. Record the submitted answers and release build. A source
  inventory or manifest is not proof those answers were submitted.
- [ ] Revoke the historical Games EAN key at the provider; record revocation evidence
  without posting the credential. Scan the final release bundle for the old value.
- [ ] Validate signed Debug/Release/archive entitlements and privacy resources on
  each supported platform, with the CloudKit account matrix in #10. Build output
  without signing does not establish App Store distribution readiness.

Additional identity/invitation data: the existing collaborator identity can use a
saved device/host display name and opaque local participant ID in ratings and
comments. Existing values are retained for compatibility. The app durably archives
pending CKShare invitation metadata in its private preferences, partitioned by
build environment, to retry interrupted cold/warm deliveries. It never logs that
metadata or invitation links. Confirm provider retention and App Store answers
against the final signed build; an empty collected-data manifest is not evidence
that every provider retains nothing.

## Observed automation blockers (27 October 2026)

GitHub run 40518083919 failed selecting Xcode 27.1: its macos-26 image lists
26.0.1 through 26.6 only. No self-hosted runner is registered. The workflow fails
explicitly instead of using an incompatible compiler; workflow_dispatch accepts
a runner label once an authorized Xcode 27.1 host is available. Repeat the same
clean-clone commands locally meanwhile. Do not mark CI green until an actual
remote run succeeds.

Local expanded UI smoke tests compile with an isolated-store launch mode and
ad-hoc test-only entitlement override. macOS denied kTCCServiceDeveloperTool
without allowing a prompt. Enable Developer Tools access for the execution app
in System Settings → Privacy & Security, or run from an authorized Xcode/test
host, then repeat the full UI suite. The agent did not change system permissions.

A macOS Production archive signed with the available Apple Development identity
was created and its embedded entitlements inspected: intended container,
Production, sandbox and camera were present. This is not App Store distribution
validation. Inspection exposed missing outbound network permission; the project
now explicitly enables network client access for product providers and web sync.
The final archive must be rechecked after all integration commits.
