# CloudKit release procedure

The app uses the container `iCloud.de.holgerkrupp.CollectionManager`. Debug uses Development through `CollectionManager-Debug.entitlements`; the Release target uses `CollectionManager.entitlements` with Production.

Before a release:

1. Build a clean Release archive and inspect the signed entitlements. Confirm the container identifier and Production environment.
2. Review `Collection`, `CollectionItem`, `CollectionEvent`, `CollectionItemRating`, and `CollectionItemComment`, including settings JSON fields and asset fields. Add queryable/sortable indexes only where the deployed implementation requires them.
3. Test schema changes in Development with a fixture created by the previous released build. Deploy the reviewed schema to Production from CloudKit Dashboard. Never make a Development-only field a release dependency.
4. Run the multi-account matrix: owner creates/shares; editor accepts and edits; viewer accepts and is rejected locally; items, settings, ratings, comments and photos converge; offline edits and delete-vs-edit conflicts converge deterministically; revocation and leaving a share remove only the affected shared collection.
5. Test accepting an invitation while the app is closed and while it is already running, plus iCloud sign-out/sign-in, temporary account unavailability, reinstall, and restore.

Record the date, build number, schema deployment, Apple IDs/test roles (without storing credentials), device/OS versions, and known limitations with the release candidate. Production deployment and real-account verification cannot be simulated by the local unit test suite.
