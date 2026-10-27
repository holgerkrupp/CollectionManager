# Audited V1 compatibility fixture

Generated on 27 October 2026 using the actual top-level @Model types from
CollectionManager commit 5bf59645f4fe851b8516ecc0af5e57b122b7e771, on Xcode 27.1.
The temporary hosted fixture generation test inserted all nine record types and
passed. The original sources remained unmodified; only test hosting/startup
isolation infrastructure was applied to the temporary clone.

This is synthetic data only: one collection, item with image/metadata, membership,
rating, comment, event, web-sync configuration, pending delete, and sync token.
The WAL was checkpointed when the generating process exited. Never regenerate
this file using the current schema to hide a compatibility regression.

PersistenceMigrationTests copies this fixture to a temporary location, opens it
through the production migration plan, verifies all records, exports a recovery
copy and reopens that copy. Add future versions to that test matrix.
