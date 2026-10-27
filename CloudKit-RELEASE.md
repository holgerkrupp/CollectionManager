# CloudKit release procedure

The app uses the container `iCloud.de.holgerkrupp.CollectionManager`. Debug uses Development through `CollectionManager-Debug.entitlements`; the Release target uses `CollectionManager.entitlements` with Production.

Before a release:

Older unmarked libraries stop for explicit environment confirmation. Confirm the historical library belongs to Production before opening it in Release. Debug offers a separate Development library and preserves the original; do not relabel/copy a Development graph into Production as automatic recovery. Preserve the `.environment` marker with SQLite sidecars in recovery copies.

1. Build a clean Release archive and inspect the signed entitlements. Confirm the container identifier and Production environment.
2. Review `Collection`, `CollectionItem`, `CollectionEvent`, `CollectionItemRating`, and `CollectionItemComment`, including settings JSON fields and asset fields. Add queryable/sortable indexes only where the deployed implementation requires them.
3. Test schema changes in Development with a fixture created by the previous released build. Deploy the reviewed schema to Production from CloudKit Dashboard. Never make a Development-only field a release dependency.
4. Run the multi-account matrix: owner creates/shares; editor accepts and edits; viewer accepts and is rejected locally; items, settings, ratings, comments and photos converge; offline edits and delete-vs-edit conflicts converge deterministically; revocation and leaving a share make only the affected shared collection unavailable/read-only while preserving its recovery data.
5. Test accepting an invitation while the app is closed and while it is already running, plus iCloud sign-out/sign-in, temporary account unavailability, reinstall, and restore.

Record the date, build number, schema deployment, Apple IDs/test roles (without storing credentials), device/OS versions, and known limitations with the release candidate. Production deployment and real-account verification cannot be simulated by the local unit test suite.

## Package handoff and preserved data

The direct SwiftData backend keeps `.none`; the kit owns one private/shared engine
pair, and the app owns codec, journal and merge policy. Record types, zone/root
names and parent references remain unchanged. The local V2 schema adds transport
metadata only; it does not require a new CloudKit record schema.

Do not interpret manual `CKServerChangeToken` values as engine serialization.
The app retains prior token/defaults bytes, pages baseline snapshots, and sends
only proven outgoing intent. Server-confirmed rows reconcile against current
system fields. Unmatched baseline rows are quarantined locally for explicit
Settings review, without automatic upload or deletion. A missing old zone/share
must not be recreated as recovery; only an explicit new-collection transaction
can authorize creating a new zone.

For the real-account test, start with existing shares from the audited build and
queued edits/tombstones, export a recovery copy, upgrade, interrupt after every
handoff stage, restart and compare record/root/share/participant identities and
pending generations. Include child-first invitation pages, several owners/zones,
viewer downgrades, signed-out/return-to-original-account, large backlogs, old save
acknowledgements after newer deletes, and photos changed during conflict retry.
A successful acceptance message does not establish completed import.

The current conservative policy retains revoked/left collection data locally as
read-only recovery data and suspends that shared scope. It never deletes owner
or unrelated data on network/account errors. An explicit recipient Leave action
uses the kit; owner stop/participant administration uses Apple's native controls.
Verify both locally and on CloudKit with real accounts. Do not downgrade an older
binary against the upgraded V2 store as automatic recovery. Preserve a complete
copy and pending work; backward binary compatibility and mixed old/new clients
require explicit validation before rollout.

For a historical library without a transport owner marker, verify that the currently signed-in Apple Account is its original account before confirming the recovery prompt. The old schema did not record an authoritative account identity; confirmation is a required manual migration gate. Once bound, account switches fail closed and retain pending work.
