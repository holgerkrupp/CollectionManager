# CollectionManager 1.0 validation — 27 October 2026

This records actual evidence, not release approval. Toolchain: Xcode 27.1
(27A9275), Swift 6.4; M4 Pro / 24 GiB host, macOS 27.2. App language mode remains
Swift 5 with its documented actor isolation; the package builds in Swift 6 mode.

## Baseline and source

Fresh remote clones at app `5bf59645f4fe851b8516ecc0af5e57b122b7e771` and kit
`860b0f3d5950a9129056c2056a00e21cb08827b0` passed unsigned macOS/iOS Release,
the original three macOS tests, and kit tests with warnings as errors. The
MealPlan reference was read at `c1285b95dc29d83479045e0bdd02421e474e000b`;
its two existing local changes were preserved without modification.

Final source: **37ca6f8e613b47dba334bec0eb82d699055f7354**. The final checkout was cloned from remote main,
with a new build directory and the checked-in remote package resolution; no
sibling package override or production library was used.

Kit main `1bdf33bb4b2d82e4c1782ba905ace0d132f545a4` is pinned in the project
and Package.resolved. Its 21 tests passed with warnings as errors. Changes cover
durable apply/progress failure, concurrent engine startup/shutdown, and an
opt-in throwing SwiftData codec while retaining existing APIs/Core Data.

## Final verification

| Fresh-clone check | Actual result |
| --- | --- |
| macOS unit suite | 150 passed, zero failures |
| iPhone Simulator iOS 27.1 | 150 unit + 6 UI passed; 1 iPad-only test skipped |
| Native iPad Simulator iOS 27.0 | All 7 UI tests passed, including rotation/representation draft ownership |
| Unsigned macOS/iOS Release | Both passed |
| Development-signed Production archive, macOS/iOS | Both passed; deep/strict signature checks passed |
| Embedded entitlements | Intended container; Production in both archives; Development in signed Debug; macOS outbound network enabled |
| Localized camera usage copy | Present in the built English InfoPlist.strings on both platforms |
| Kit | 21 passed with warnings as errors |

All app verification used Swift warnings as errors with suppression disabled.
Apple's metadata tool emitted its informational no-AppIntents-dependency warning
for test targets; no Swift compiler warnings were suppressed. The UI suites
exercise onboarding, CRUD, search/filter/sort, settings validation, credential
Settings, the real CSV parser/review/import, offline sharing recovery and largest
accessibility text/forced RTL. No native real-account sharing result is implied.

[Machine-readable results](VALIDATION-RESULTS.json) are extracted from final
xcresult summaries. Local full logs/results/archives are under
`/tmp/cm-validation/release-*`; no machine-specific signing profile or personal
account information is checked in.

Earlier source `1ac6b5a` independently passed a fresh-clone 104-test macOS suite,
104 iPhone unit tests, five iPhone UI flows (one iPad-only skip), six native iPad
UI flows, unsigned Release builds and development-signed Production archives
for macOS/iOS. Final results above supersede those counts.

The expanded suite covers the audited original V1 SQLite fixture → immutable
V2 migration, export/reopen including real WAL/SHM, unreadable/corrupt startup,
fetch/save failures and rollback, settings/defaults/permissions/import provenance,
edit ownership, provider errors, account/environment/multi-zone routing,
child-only remote deltas, conflict/deletion generations, restart handoff,
assets, local query/cache preparation and cancellation, and locale formatting.
Tests operate on isolated temporary stores/preferences, never the user's library.

A deterministic interleaved-context test initially failed: an older staged source
import overwrote a later manual edit under the real SDK. The repair adds a shared
per-store, per-collection optimistic revision fence to repository and codec
commits. Stale or busy commits fail atomically and retain the newer data and
journal. The gate never waits for a long background flush on the UI thread.
It is an in-process writer contract; it does not assert coordination between
separate app processes or permit an older binary to open an upgraded store.

## Environment limits

The actual hosted CI run [40556559465](https://github.com/holgerkrupp/CollectionManager/actions/runs/40556559465)
failed selecting required Xcode 27.1 before compilation: the hosted macos-26
image listed only Xcode 26.x. The workflow explicitly selects 27.1 and supports a
custom runner label through workflow_dispatch; no compatible self-hosted runner
was registered. A green remote workflow is still required.

The fresh macOS UI target builds. A fresh runtime probe was stopped after TCC
reported `kTCCServiceDeveloperTool` denied for `com.openai.codex`, without allowing
a prompt (`release-ui-authorization.log`). Developer mode was disabled. No macOS
UI runtime pass is claimed; these settings were not changed. Connected physical
iPhone/iPad devices reported unavailable. Simulator flows do not establish
physical-device VoiceOver, performance or native multi-account sharing acceptance.

Development-signed archive entitlement inspection is evidence of configured
container/environment, not distribution approval. In particular the development
iOS archive retains get-task-allow. No distribution-signed export or App Store
validation was performed.

## Measured performance

See [PERFORMANCE.md](../PERFORMANCE.md) for conditions and limitations. Matching
Debug samples reduced 50k seed from 151,425 to 4,398 ms and 10k from 30,789 to
818 ms. A later locale-aware 50k sample measured index preparation 83.44 ms,
indexed search 91.94 ms, uncached search 161.75 ms and fetch/decode 1735.72 ms.
These phases and table header sorting now run on cancellable workers.

The full parser/mapping/repository/event/outbox import path measured 333.05 ms
at 1k, 3.585 s at 10k and 19.883 s at 50k after removing repeated validation
fetches (before: 368.26 ms / 4.040 s / 22.807 s). A later complete run including the write fence measured
308.16 ms / 3.524 s / 20.545 s; these samples show host variance.
The app performs preparation
and saving away from its UI executor, with explicit progress/failure retention.

Real JPEG host snapshots at 50k measured roughly 1161 MiB resident / 620 MiB
footprint after fetch; 128 thumbnails used 18 MiB decoded pixels. These are
samples, not peaks. The selected collection still materializes original
compressed image blobs. Device frames/peak memory/full-resolution images and
real incremental network counts remain acceptance gates.

## Precise remaining actions

1. Revoke/rotate the historical Games EAN credential at the provider and prove
   the old value no longer authorizes requests. Do not publish the value.
2. Run the complete workflow on an authorized Xcode 27.1 runner, including
   migration fixtures and macOS UI. Authorize Developer Tools or run from Xcode.
3. Before opening an unmarked historical library, confirm its original Apple
   Account and environment in recovery. Debug offers a separate Development
   library; it must not silently adopt the original Production store.
4. Deploy/review the Production schema and execute CloudKit-RELEASE.md using
   signed owner/editor/viewer accounts: existing/new native invitations, roles,
   revoke/leave/stop, offline conflicts/deletes, reinstall/account changes,
   interrupted legacy handoff and old/new-client parity. Review ambiguous
   legacy snapshots explicitly. Record real 1k/10k/50k transfer counts.
5. On supported physical iPhone/iPad/Mac, measure launch/open/search/filter/sort,
   scroll/import frames and full-resolution image memory/peak; complete
   VoiceOver, largest text, keyboard, contrast and long-string/RTL workflows.
   The simulator includes a largest-text/forced-RTL smoke, not this full matrix.
6. Verify provider retention and privacy policy/App Store answers, then validate
   distribution-signed exports and supported-device archives. English is the
   sole 1.0 language; no additional translation is claimed.

#2 is closed. Implementation issues #3/#4/#8/#15 can close with the local
acceptance evidence; #5 remains open for its actual CI migration requirement.
#6/#7/#9–#14/#16/#17 retain only their documented external/device/CI/release
acceptance work. **#10, #16 and #17 remain open.**

## Pushed implementation commits

All changes landed directly on main; no branches, PRs or worktrees were created.

| Repository | Commit | Change |
| --- | --- | --- |
| CollectionManager | `9956a5a` | Persistence, credential and edit-session foundation |
| CollectionManager | `82deb37` | V2 transport, native sharing, measured performance and release resources |
| CollectionManager | `8f316e9` | Preserve visible committed results during recoverable sync failure |
| CollectionManager | `daeae5f` | Stored permissions and failed ratings |
| CollectionManager | `42b891b` | CSV malformed quotes and mapped tags |
| CollectionManager | `16be870` | Environment/account isolation and canonical shared routing |
| CollectionManager | `1ac6b5a` | Failure-retaining editors and release UI flows |
| CollectionManager | `37ca6f8` | Responsive atomic imports, concurrent-write fences, locale formatting and final regression coverage |
| CloudKitCollaborationKit | `239da36` | Durable apply/state progress barrier |
| CloudKitCollaborationKit | `5e9a09d` | Concurrent pool lifecycle ownership |
| CloudKitCollaborationKit | `1bdf33b` | Compatible opt-in durable SwiftData dispatch |

The following evidence-only commit updates this document and issue dispositions;
application/package source is unchanged from the tested revisions above.
